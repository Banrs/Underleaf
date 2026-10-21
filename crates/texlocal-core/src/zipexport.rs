//! Project ZIP export, built in a sibling temporary file and moved into place on success, so a failure leaves no partial ZIP.
//! What goes in is what an import takes back: all but what `left_out` names.

use std::ffi::OsStr;
use std::fs::{self, DirEntry, File};
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::SETTINGS_FILE;
use crate::atomic::{create_temp, persist};
use crate::error::CoreError;
use crate::paths::in_build_dir;
use crate::projects::is_litter;

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let parent = dest.parent().expect("a file is in a folder");
    let (file, temp_path) = create_temp(parent).map_err(CoreError::at(dest))?;

    // Resolved as the walk resolves the project, so a destination spelled through a link is recognised.
    let mut export = Export {
        writer: ZipWriter::new(file),
        archive_dir: dunce::canonicalize(parent).map_err(CoreError::at(dest))?,
        archive_names: [dest.file_name(), temp_path.file_name()],
    };
    export.add_dir(root, "")?;
    export.writer.finish()?.sync_all()?;
    persist(temp_path, dest).map_err(CoreError::at(dest))
}

struct Export<'a> {
    writer: ZipWriter<File>,
    archive_dir: PathBuf,
    archive_names: [Option<&'a OsStr>; 2],
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
        if left_out(&rel) {
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
        export_zip(&root, &dest).unwrap();
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
        export_zip(&root, &inside).unwrap();
        assert_eq!(zip_names(&inside), kept);

        let service = Service::new(dir.path().join("again"));
        let copy = service
            .data_dir
            .join(import_project(&service, &dest).unwrap().id);
        export_zip(&copy, &dest).unwrap();
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
        export_zip(&root, &dest).unwrap();
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
        };
        export.add_entries(&listed, "").unwrap();
        export.writer.finish().unwrap();
        assert_eq!(zip_names(&dest), ["a.tex", "main.tex"]);
    }

    #[test]
    fn a_destination_that_cannot_be_written_is_named() {
        let (dir, root) = project();
        let dest = dir.path().join("no such folder/out.zip");
        let err = export_zip(&root, &dest).unwrap_err();
        assert_eq!(err.status, 404);
        assert!(err.message.contains("out.zip"), "{}", err.message);
    }
}
