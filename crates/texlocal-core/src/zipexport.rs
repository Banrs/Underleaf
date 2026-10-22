//! Project ZIP export, built in a sibling temporary file and moved into place on success, so a failure leaves no partial ZIP.
//! What goes in is what an import takes back: all but what `left_out` names.

use std::ffi::OsStr;
use std::fs::{self, DirEntry, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde_json::json;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::SETTINGS_FILE;
use crate::analyze::{Files, analyze_project};
use crate::atomic::{create_temp, persist};
use crate::error::CoreError;
use crate::paths::{Project, in_build_dir, safe_path, safe_rel_file};
use crate::projects::is_litter;
use crate::settings::read_settings;

/// `added`: files of the export's own, each at its path in the archive in place of the project's.
pub fn export_zip(root: &Path, dest: &Path, added: &[(String, Vec<u8>)]) -> Result<(), CoreError> {
    let parent = dest.parent().expect("a file is in a folder");
    let (file, temp_path) = create_temp(parent).map_err(CoreError::at(dest))?;

    // Resolved as the walk resolves the project, so a destination spelled through a link is recognised.
    let mut export = Export {
        writer: ZipWriter::new(file),
        archive_dir: dunce::canonicalize(parent).map_err(CoreError::at(dest))?,
        archive_names: [dest.file_name(), temp_path.file_name()],
        added,
    };
    export.add_dir(root, "")?;
    for (rel, bytes) in added {
        export
            .writer
            .start_file(rel, options(Ok(SystemTime::now())))?;
        export.writer.write_all(bytes)?;
    }
    export.writer.finish()?.sync_all()?;
    persist(temp_path, dest).map_err(CoreError::at(dest))
}

/// What arXiv takes beside the project's files: the main file's .bbl from the build folder,
/// beside the main file with its stem, and a 00README.json naming the compiler and the main file
/// as the top-level source. Refused while shell escape is on, as arXiv compiles without it, and
/// while the bibliography isn't compiled or is older than a .bib it names.
pub(crate) fn for_arxiv(project: &Project) -> Result<Vec<(String, Vec<u8>)>, CoreError> {
    let settings = read_settings(&project.settings);
    if settings.shell_escape {
        return Err(CoreError::conflict(
            "arXiv compiles without shell escape. Turn Shell Escape off for this project, check that it still compiles, then export again.",
        ));
    }
    let main = safe_rel_file(&settings.main_file)?;
    let readme = json!({
        "spec_version": 1,
        "process": { "compiler": settings.engine },
        "sources": [{ "filename": main, "usage": "toplevel" }],
    });
    let readme = serde_json::to_vec_pretty(&readme).expect("JSON from JSON");
    let mut added = vec![("00README.json".to_owned(), readme)];
    let root = &project.root;
    let named = analyze_project(root, &Files::default(), &main, &main, None).bibliographies;
    if named.is_empty() {
        return Ok(added);
    }
    // BibTeX appends .bib to a name; biblatex takes it as written. One outside the project is
    // left alone.
    let modified = |path: &Path| fs::metadata(path).and_then(|meta| meta.modified()).ok();
    let mut bibs = named.iter().filter_map(|name| {
        let names = [format!("{name}.bib"), name.clone()];
        names
            .into_iter()
            .find_map(|rel| modified(&safe_path(root, &rel).ok()?))
    });
    let bbl = settings.output(&project.build, "bbl")?;
    if modified(&bbl).is_none_or(|compiled| bibs.any(|bib| bib > compiled)) {
        return Err(CoreError::conflict(
            "arXiv needs the bibliography as it was last compiled. Compile the project, then export again.",
        ));
    }
    let beside_main = Path::new(&main).with_extension("bbl");
    added.push((beside_main.to_string_lossy().into_owned(), fs::read(bbl)?));
    Ok(added)
}

struct Export<'a> {
    writer: ZipWriter<File>,
    archive_dir: PathBuf,
    archive_names: [Option<&'a OsStr>; 2],
    added: &'a [(String, Vec<u8>)],
}

impl Export<'_> {
    fn add_dir(&mut self, dir: &Path, prefix: &str) -> Result<(), CoreError> {
        let mut entries = fs::read_dir(dir)?.collect::<io::Result<Vec<_>>>()?;
        entries.sort_by_key(DirEntry::file_name);
        if dunce::canonicalize(dir)? == self.archive_dir {
            entries.retain(|entry| !self.archive_names.contains(&Some(&entry.file_name())));
        }
        self.add_entries(&entries, prefix)
    }

    /// Adds a folder's listed entries; one gone since it was listed is left out.
    fn add_entries(&mut self, entries: &[DirEntry], prefix: &str) -> Result<(), CoreError> {
        for entry in entries {
            match self.add_entry(entry, prefix) {
                Err(err) if err.status == 404 => {}
                added => added?,
            }
        }
        Ok(())
    }

    fn add_entry(&mut self, entry: &DirEntry, prefix: &str) -> Result<(), CoreError> {
        let rel = format!("{prefix}{}", entry.file_name().to_string_lossy());
        let replaced = || {
            self.added
                .iter()
                .any(|(path, _)| path.eq_ignore_ascii_case(&rel))
        };
        if left_out(&rel) || replaced() {
            return Ok(());
        }
        let path = entry.path();
        let entry_type = entry.file_type()?;
        // Links are followed to files only, as folder links can cycle.
        if entry_type.is_symlink() {
            if path.is_file() {
                self.add_file(&rel, &path)?;
            }
        } else if entry_type.is_dir() {
            let dir = format!("{rel}/");
            let modified = entry.metadata().and_then(|meta| meta.modified());
            self.writer.add_directory(dir.clone(), options(modified))?;
            self.add_dir(&path, &dir)?;
        } else if entry_type.is_file() {
            self.add_file(&rel, &path)?;
        }
        Ok(())
    }

    fn add_file(&mut self, rel: &str, path: &Path) -> Result<(), CoreError> {
        let mut file = File::open(path)?;
        let meta = file.metadata()?;
        // Past 4 GiB sizes need ZIP64's fields, and from 3 GiB a file gets them too, since deflate
        // can store an incompressible one larger.
        let options = options(meta.modified()).large_file(meta.len() >= 3 << 30);
        self.writer.start_file(rel, options)?;
        // No flush per file: on a deflated entry it forces a sync block into the stream.
        io::copy(&mut file, &mut self.writer)?;
        Ok(())
    }
}

/// What an export leaves out and an import leaves behind, by its path in the
/// project: `is_litter` at any depth, and the compile output and the project's
/// own settings at the top, in any case.
pub(crate) fn left_out(rel: &str) -> bool {
    in_build_dir(rel) || rel.eq_ignore_ascii_case(SETTINGS_FILE) || rel.split('/').any(is_litter)
}

/// A deflated entry dated as `modified`. ZIP stores local time, as unzipping
/// tools show it; undated, every entry would say 1 January 1980.
fn options(modified: io::Result<SystemTime>) -> SimpleFileOptions {
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    let Ok(modified) = modified else {
        return options;
    };
    let local = chrono::DateTime::<chrono::Local>::from(modified).naive_local();
    let date = zip::DateTime::try_from(local).ok();
    date.map_or(options, |date| options.last_modified_time(date))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::import::import_project;
    use crate::projects::testing::{project, zip_names};
    use crate::service::Service;
    use crate::settings::{read_settings, write_settings};

    #[test]
    fn a_project_exported_and_opened_again_keeps_every_file_the_author_made() {
        let (dir, root) = project();
        for (path, text) in [
            (".latexmkrc", "$pdf_mode = 1;"),
            (".gitignore", "build/"),
            ("chapters/intro.tex", "intro"),
            ("sub/.texlocal.json", "{}"),
            (".git/HEAD", "ref"),
            ("figs/.DS_Store", "x"),
            ("figs/._a.png", "fork"),
            ("figs/a.png", "png"),
            // What atomic::write leaves beside a document mid-save.
            (".texlocal-AbC123", "half"),
            ("Build/main.pdf", "output"),
        ] {
            let file = root.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, text).unwrap();
        }
        let settings = root.join(SETTINGS_FILE);
        write_settings(&settings, &serde_json::json!({ "engine": "lualatex" })).unwrap();
        fs::rename(settings, root.join(".TeXLocal.json")).unwrap();
        let dest = dir.path().join("out.zip");
        export_zip(&root, &dest, &[]).unwrap();
        let kept = [
            ".gitignore",
            ".latexmkrc",
            "chapters/",
            "chapters/intro.tex",
            "figs/",
            "figs/a.png",
            "main.tex",
            "sub/",
            "sub/.texlocal.json",
        ];
        assert_eq!(zip_names(&dest), kept);
        let inside = root.join("project.zip");
        fs::write(&inside, "old incomplete archive").unwrap();
        export_zip(&root, &inside, &[]).unwrap();
        assert_eq!(zip_names(&inside), kept);

        let service = Service::new(dir.path().join("again"));
        let copy = service
            .data_dir
            .join(import_project(&service, &dest).unwrap().id);
        export_zip(&copy, &dest, &[]).unwrap();
        assert_eq!(zip_names(&dest), kept);
        let latexmkrc = fs::read_to_string(copy.join(".latexmkrc")).unwrap();
        assert_eq!(latexmkrc, "$pdf_mode = 1;");
        assert_eq!(
            read_settings(&copy.join(SETTINGS_FILE)).engine,
            crate::settings::Engine::Pdflatex
        );
    }

    #[test]
    fn zip_export_dates_entries_as_their_files() {
        let (dir, root) = project();
        let dest = dir.path().join("out.zip");
        export_zip(&root, &dest, &[]).unwrap();
        let mut archive = zip::ZipArchive::new(File::open(&dest).unwrap()).unwrap();
        let dated = archive.by_name("main.tex").unwrap().last_modified();
        let modified = fs::metadata(root.join("main.tex")).unwrap().modified();
        let local = chrono::DateTime::<chrono::Local>::from(modified.unwrap());
        let minute = local.format("%Y-%m-%d %H:%M").to_string();
        assert_eq!(dated.unwrap().to_string()[..16], minute);
    }

    #[test]
    fn an_entry_that_vanishes_during_the_walk_is_left_out_not_a_failure() {
        let (dir, root) = project();
        fs::write(root.join("a.tex"), "a").unwrap();
        fs::write(root.join("gone.tex"), "x").unwrap();
        let mut listed: Vec<_> = fs::read_dir(&root).unwrap().map(Result::unwrap).collect();
        listed.sort_by_key(DirEntry::file_name);
        fs::remove_file(root.join("gone.tex")).unwrap();

        let dest = dir.path().join("out.zip");
        let mut export = Export {
            writer: ZipWriter::new(File::create(&dest).unwrap()),
            archive_dir: PathBuf::new(),
            archive_names: [None, None],
            added: &[],
        };
        export.add_entries(&listed, "").unwrap();
        export.writer.finish().unwrap();
        assert_eq!(zip_names(&dest), ["a.tex", "main.tex"]);
    }

    #[test]
    fn a_destination_that_cannot_be_written_is_named() {
        let (dir, root) = project();
        let dest = dir.path().join("no such folder/out.zip");
        let err = export_zip(&root, &dest, &[]).unwrap_err();
        assert_eq!(err.status, 404);
        assert!(err.message.contains("out.zip"), "{}", err.message);
    }

    fn read_entry(zip: &Path, name: &str) -> String {
        let mut archive = zip::ZipArchive::new(File::open(zip).unwrap()).unwrap();
        io::read_to_string(archive.by_name(name).unwrap()).unwrap()
    }

    #[test]
    fn an_arxiv_export_brings_the_bbl_beside_the_main_file_and_a_readme_naming_it() {
        let (dir, root) = project();
        fs::create_dir_all(root.join("tex")).unwrap();
        fs::create_dir_all(root.join("build")).unwrap();
        for (path, text) in [
            ("tex/paper.tex", "\\documentclass{article}\n\\input{back}"),
            // Named in a file the main file reads.
            ("back.tex", "\\bibliography{refs}"),
            ("refs.bib", "@book{k, title = {T}}"),
            ("build/paper.bbl", "\\begin{thebibliography}{1}"),
        ] {
            fs::write(root.join(path), text).unwrap();
        }
        let settings = json!({ "mainFile": "tex/paper.tex", "engine": "lualatex" });
        write_settings(&root.join(SETTINGS_FILE), &settings).unwrap();

        let dest = dir.path().join("arxiv.zip");
        let added = for_arxiv(&Project::in_folder(&root)).unwrap();
        export_zip(&root, &dest, &added).unwrap();
        let bbl = read_entry(&dest, "tex/paper.bbl");
        assert_eq!(bbl, "\\begin{thebibliography}{1}");
        let readme: serde_json::Value =
            serde_json::from_str(&read_entry(&dest, "00README.json")).unwrap();
        assert_eq!(
            readme,
            json!({
                "spec_version": 1,
                "process": { "compiler": "lualatex" },
                "sources": [{ "filename": "tex/paper.tex", "usage": "toplevel" }],
            })
        );
    }

    #[test]
    fn an_arxiv_export_is_refused_with_shell_escape_or_a_bibliography_not_compiled_since() {
        let (_dir, root) = project();
        fs::write(root.join("main.tex"), "\\addbibresource{refs.bib}").unwrap();
        fs::write(root.join("refs.bib"), "@book{k, title = {T}}").unwrap();
        let project = Project::in_folder(&root);
        let refused = |text: &str| {
            let err = for_arxiv(&project).unwrap_err();
            assert_eq!(err.status, 409);
            assert!(err.message.contains(text), "{}", err.message);
        };
        refused("Compile the project");

        fs::create_dir_all(&project.build).unwrap();
        let bbl = project.build.join("main.bbl");
        fs::write(&bbl, "").unwrap();
        let hour_ago = SystemTime::now() - std::time::Duration::from_secs(3600);
        File::options()
            .write(true)
            .open(&bbl)
            .unwrap()
            .set_modified(hour_ago)
            .unwrap();
        refused("Compile the project");

        let bib = File::options().write(true).open(root.join("refs.bib"));
        bib.unwrap().set_modified(hour_ago).unwrap();
        assert!(for_arxiv(&project).is_ok());
        write_settings(&project.settings, &json!({ "shellEscape": true })).unwrap();
        refused("shell escape");
    }
}
