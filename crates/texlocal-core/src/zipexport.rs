//! Project ZIP export, built in a sibling temporary file and moved into place on success, so a failure leaves no partial ZIP.
//! What goes in is what an import takes back: all but what `left_out` names.

use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use std::time::SystemTime;

use serde_json::json;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::SETTINGS_FILE;
use crate::analyze::{Files, analyze_project};
use crate::atomic::{create_temp, persist};
use crate::checks::bib_file;
use crate::error::CoreError;
use crate::paths::{Project, fold_case, in_build_dir, safe_path, safe_rel_file};
use crate::projects::{Entry, is_litter, walk};
use crate::settings::{granted, read_settings};

/// `added`: files of the export's own, each at its path in the archive in place of the project's.
pub fn export_zip(root: &Path, dest: &Path, added: &[(String, Vec<u8>)]) -> Result<(), CoreError> {
    let parent = dest.parent().expect("a file is in a folder");
    let (file, temp_path) = create_temp(parent).map_err(CoreError::at(dest))?;
    // Resolved as the walk resolves the project, so a destination spelled through a link is recognised.
    let archive_dir = std::fs::canonicalize(parent).map_err(CoreError::at(dest))?;
    let archive = |entry: &Entry| {
        let names = [dest.file_name(), temp_path.file_name()];
        names.contains(&Some(OsStr::new(&entry.name)))
            && entry
                .path
                .parent()
                .and_then(|dir| std::fs::canonicalize(dir).ok())
                == Some(archive_dir.clone())
    };
    let replaced = |rel: &str| added.iter().any(|(path, _)| path.eq_ignore_ascii_case(rel));
    let mut writer = ZipWriter::new(file);
    walk(
        root,
        &|rel| !left_out(rel) && !replaced(rel),
        &mut |entry| {
            if entry.dir {
                let modified = fs::metadata(&entry.path).and_then(|meta| meta.modified());
                writer.add_directory(format!("{}/", entry.rel), options(modified))?;
            } else if !archive(entry) {
                // One gone since it was listed is left out.
                match add_file(&mut writer, &entry.rel, &entry.path) {
                    Err(err) if err.status == 404 => {}
                    added => added?,
                }
            }
            Ok(true)
        },
    )?;
    for (rel, bytes) in added {
        writer.start_file(rel, options(Ok(SystemTime::now())))?;
        writer.write_all(bytes)?;
    }
    writer.finish()?.sync_all()?;
    persist(temp_path, dest).map_err(CoreError::at(dest))
}

fn add_file(writer: &mut ZipWriter<File>, rel: &str, path: &Path) -> Result<(), CoreError> {
    let mut file = File::open(path)?;
    let meta = file.metadata()?;
    // Past 4 GiB sizes need ZIP64's fields, and from 3 GiB a file gets them too, since deflate
    // can store an incompressible one larger.
    let options = options(meta.modified()).large_file(meta.len() >= 3 << 30);
    writer.start_file(rel, options)?;
    // No flush per file: on a deflated entry it forces a sync block into the stream.
    io::copy(&mut file, writer)?;
    Ok(())
}
/// What arXiv takes beside the project's files: the main file's .bbl from the build folder,
/// beside the main file with its stem, and a 00README.json naming the compiler and the main file
/// as the top-level source. Refused while shell escape is on, as arXiv compiles without it, and
/// while the bibliography isn't compiled or is older than a .bib it names.
pub(crate) fn for_arxiv(project: &Project) -> Result<Vec<(String, Vec<u8>)>, CoreError> {
    let settings = read_settings(&project.settings);
    if granted(project) {
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
    let files = Files::default();
    let read = analyze_project(root, &files, &main, &main, None).files;
    let facts = read.iter().filter_map(|file| files.at(root, file));
    let named: Vec<String> = facts.flat_map(|f| f.bibliographies.clone()).collect();
    if named.is_empty() {
        return Ok(added);
    }
    // One outside the project is left alone.
    let modified = |path: &Path| fs::metadata(path).and_then(|meta| meta.modified()).ok();
    let mut bibs = (named.iter())
        .filter_map(|name| bib_file(name, |rel| modified(&safe_path(root, rel).ok()?)));
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

/// What an export leaves out and an import leaves behind, by its path in the
/// project: `is_litter` at any depth, and the compile output and the project's
/// own settings at the top, in any case.
pub(crate) fn left_out(rel: &str) -> bool {
    in_build_dir(rel) || fold_case(rel) == SETTINGS_FILE || rel.split('/').any(is_litter)
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
        // Spelt through a link into the project, as when a Save panel hands back /private/var
        // for a data folder under /var: a lexical comparison would archive the half-written ZIP.
        let alias = root.with_file_name("alias");
        std::os::unix::fs::symlink(&root, &alias).unwrap();
        export_zip(&root, &alias.join("project.zip"), &[]).unwrap();
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
        crate::settings::grant(&project, true).unwrap();
        refused("shell escape");
    }
}
