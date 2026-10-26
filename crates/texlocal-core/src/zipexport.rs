//! Project ZIP export, written where the host asks: the Mac app exports into a fresh folder of its own outside the project.
//! What goes in is what an import takes back: all but what `left_out` names.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::SETTINGS_FILE;
use crate::error::CoreError;
use crate::paths::{Project, fold_case, in_build_dir, safe_rel_file};
use crate::projects::{is_litter, walk};
use crate::settings::{Engine, granted, read_settings};

/// `added`: files of the export's own, each at its path in the archive in place of the project's.
pub fn export_zip(root: &Path, dest: &Path, added: &[(String, Vec<u8>)]) -> Result<(), CoreError> {
    let file = File::create(dest).map_err(CoreError::at(dest))?;
    let replaced = |rel: &str| added.iter().any(|(path, _)| path.eq_ignore_ascii_case(rel));
    let mut writer = ZipWriter::new(file);
    walk(
        root,
        &|rel| !left_out(rel) && !replaced(rel),
        true,
        &mut |entry| {
            if entry.dir {
                let modified = fs::metadata(&entry.path).and_then(|meta| meta.modified());
                writer.add_directory(format!("{}/", entry.rel), options(modified))?;
            } else {
                // One gone since it was listed is left out.
                match add_file(&mut writer, &entry.rel, &entry.path) {
                    Err(err) if err.kind == crate::ErrorKind::NotFound => {}
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
    Ok(())
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
/// What arXiv takes beside the project's files: a 00README.json naming the compiler and the main
/// file as the top-level source, and what the build made of the main file that arXiv doesn't
/// make itself. Refused while shell escape is on or the engine is LuaLaTeX, as arXiv compiles
/// without either.
pub(crate) fn for_arxiv(project: &Project) -> Result<Vec<(String, Vec<u8>)>, CoreError> {
    let settings = read_settings(&project.settings);
    if granted(project) {
        return Err(CoreError::conflict(
            "arXiv compiles without shell escape. Turn Shell Escape off for this project, check that it still compiles, then export again.",
        ));
    }
    if settings.engine == Engine::Lualatex {
        return Err(CoreError::conflict(
            "arXiv doesn't compile with LuaLaTeX. Choose pdfLaTeX or XeLaTeX for this project, check that it still compiles, then export again.",
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
    // arXiv runs BibTeX or Biber itself, but not makeindex or the glossary tools. TeX reads
    // `\jobname`'s files from the folder it runs in, and arXiv, as latexmk here, runs it from
    // the root whatever folder the main file is in.
    let stem = Path::new(&main)
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy();
    for ext in ["ind", "gls", "acr", "nls", "glstex"] {
        match fs::read(settings.output(&project.build, ext)?) {
            Ok(bytes) => added.push((format!("{stem}.{ext}"), bytes)),
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => return Err(err.into()),
        }
    }
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
    fn local(modified: SystemTime) -> Option<zip::DateTime> {
        let secs = modified.duration_since(UNIX_EPOCH).ok()?.as_secs();
        let secs = libc::time_t::try_from(secs).ok()?;
        // SAFETY: both pointers are to live locals; the call fills `tm`, or returns null, checked.
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        if unsafe { libc::localtime_r(&raw const secs, &raw mut tm) }.is_null() {
            return None;
        }
        let field = |value: libc::c_int| u8::try_from(value).ok();
        let year = u16::try_from(tm.tm_year + 1900).ok()?;
        let (month, day) = (field(tm.tm_mon + 1)?, field(tm.tm_mday)?);
        let (hour, minute, second) = (field(tm.tm_hour)?, field(tm.tm_min)?, field(tm.tm_sec)?);
        zip::DateTime::from_date_and_time(year, month, day, hour, minute, second).ok()
    }
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    let date = modified.ok().and_then(local);
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
        let secs = modified
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let date = std::process::Command::new("/bin/date")
            .args(["-r", &secs.to_string(), "+%Y-%m-%d %H:%M"])
            .output()
            .unwrap();
        let minute = String::from_utf8(date.stdout).unwrap();
        assert_eq!(dated.unwrap().to_string()[..16], *minute.trim_end());
    }

    #[test]
    fn a_destination_that_cannot_be_written_is_named() {
        let (dir, root) = project();
        let dest = dir.path().join("no such folder/out.zip");
        let err = export_zip(&root, &dest, &[]).unwrap_err();
        assert_eq!(err.kind, crate::ErrorKind::NotFound);
        assert!(err.message.contains("out.zip"), "{}", err.message);
    }

    fn read_entry(zip: &Path, name: &str) -> String {
        let mut archive = zip::ZipArchive::new(File::open(zip).unwrap()).unwrap();
        io::read_to_string(archive.by_name(name).unwrap()).unwrap()
    }

    #[test]
    fn an_arxiv_export_names_the_compiler_and_brings_the_index_to_the_root() {
        let (dir, root) = project();
        fs::create_dir_all(root.join("tex")).unwrap();
        fs::create_dir_all(root.join("build")).unwrap();
        for (path, text) in [
            (
                "tex/paper.tex",
                "\\documentclass{article}\n\\bibliography{refs}",
            ),
            ("refs.bib", "@book{k, title = {T}}"),
            ("build/paper.bbl", "\\begin{thebibliography}{1}"),
            ("build/paper.ind", "\\begin{theindex}"),
        ] {
            fs::write(root.join(path), text).unwrap();
        }
        let project = Project::in_folder(&root);
        let dest = dir.path().join("arxiv.zip");
        for engine in ["pdflatex", "xelatex"] {
            let settings = json!({ "mainFile": "tex/paper.tex", "engine": engine });
            write_settings(&project.settings, &settings).unwrap();
            let added = for_arxiv(&project).unwrap();
            export_zip(&root, &dest, &added).unwrap();
            let readme: serde_json::Value =
                serde_json::from_str(&read_entry(&dest, "00README.json")).unwrap();
            assert_eq!(
                readme,
                json!({
                    "spec_version": 1,
                    "process": { "compiler": engine },
                    "sources": [{ "filename": "tex/paper.tex", "usage": "toplevel" }],
                })
            );
        }
        assert_eq!(read_entry(&dest, "paper.ind"), "\\begin{theindex}");
        let names = zip_names(&dest);
        assert!(
            !names.iter().any(|name| name.ends_with(".bbl")),
            "{names:?}"
        );

        let refused = |text: &str| {
            let err = for_arxiv(&project).unwrap_err();
            assert_eq!(err.kind, crate::ErrorKind::Conflict);
            assert!(err.message.contains(text), "{}", err.message);
        };
        let settings = json!({ "mainFile": "tex/paper.tex", "engine": "lualatex" });
        write_settings(&project.settings, &settings).unwrap();
        refused("LuaLaTeX");
        crate::settings::grant(&project, true).unwrap();
        refused("shell escape");
    }
}
