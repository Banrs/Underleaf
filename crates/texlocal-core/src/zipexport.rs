//! Project ZIP export via the zip crate. The archive is completed in a sibling
//! temporary file and moved into place only after success, so a destination
//! inside the project cannot archive itself and failures never leave a partial
//! ZIP at the requested path.
//!
//! What goes in is what an import takes back: everything but the compile
//! output, the project's own settings and `projects::is_litter`. Dotfiles the
//! file tree hides (.latexmkrc) are the author's and are archived.

use std::ffi::OsStr;
use std::fs::{self, DirEntry, File};
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::atomic::{create_temp, persist};
use crate::error::CoreError;
use crate::projects::is_litter;
use crate::{BUILD_DIR, SETTINGS_FILE};

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let root_canonical = dunce::canonicalize(root)?;
    let parent = dest.parent().filter(|p| !p.as_os_str().is_empty());
    let parent = parent.unwrap_or(Path::new("."));
    let (temp_path, file) = create_temp(parent).map_err(CoreError::at(dest))?;

    // Resolve the archive folder as the walk resolves the project, so a
    // destination spelled through a link is still recognised there.
    let mut export = Export {
        writer: ZipWriter::new(file),
        options: SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        root_canonical: &root_canonical,
        archive_dir: dunce::canonicalize(parent).map_err(CoreError::at(dest))?,
        archive_names: [dest.file_name(), temp_path.file_name()],
    };
    export.add_dir(root, &root_canonical, "")?;
    export.writer.finish()?.sync_all()?;
    persist(temp_path, dest).map_err(CoreError::at(dest))
}

/// The parts of an export that do not change as the walk descends: where the
/// archive is being written, and the two entries there (the destination and
/// its temporary sibling) that must not end up in it.
struct Export<'a> {
    writer: ZipWriter<File>,
    options: SimpleFileOptions,
    root_canonical: &'a Path,
    archive_dir: PathBuf,
    archive_names: [Option<&'a OsStr>; 2],
}

impl Export<'_> {
    /// `dir_canonical` is `dir` resolved, for excluding the archive itself.
    fn add_dir(&mut self, dir: &Path, dir_canonical: &Path, prefix: &str) -> Result<(), CoreError> {
        let mut entries = fs::read_dir(dir)?.collect::<io::Result<Vec<_>>>()?;
        entries.sort_by_key(DirEntry::file_name);
        let holds_archive = dir_canonical == self.archive_dir;

        for entry in entries {
            let file_name = entry.file_name();
            if holds_archive && self.archive_names.contains(&Some(file_name.as_os_str())) {
                continue;
            }
            match self.add_entry(&entry, prefix) {
                // Gone since the folder was listed (an editor's or a build's
                // temporary file): nothing left to export.
                Err(err) if err.status == 404 => {}
                added => added?,
            }
        }
        Ok(())
    }

    fn add_entry(&mut self, entry: &DirEntry, prefix: &str) -> Result<(), CoreError> {
        let name = entry.file_name().to_string_lossy().into_owned();
        if is_litter(&name) {
            return Ok(());
        }
        if prefix.is_empty()
            && (name.eq_ignore_ascii_case(BUILD_DIR) || name.eq_ignore_ascii_case(SETTINGS_FILE))
        {
            return Ok(());
        }
        let rel = if prefix.is_empty() {
            name
        } else {
            format!("{prefix}/{name}")
        };
        let path = entry.path();

        let entry_type = entry.file_type()?;
        if entry_type.is_symlink() {
            // Unresolvable (dangling, a loop), there is nothing to export, as
            // in the project walks; and never data reached through a link
            // outside the project.
            let inside =
                dunce::canonicalize(&path).is_ok_and(|t| t.starts_with(self.root_canonical));
            // Directory links are deliberately skipped. Following them creates
            // cycles and duplicates; regular directories below are still walked.
            if inside && fs::metadata(&path)?.is_file() {
                self.add_file(&rel, &path)?;
            }
        } else if entry_type.is_dir() {
            let canonical = dunce::canonicalize(&path)?;
            if canonical.starts_with(self.root_canonical) {
                let options = dated(self.options, entry.metadata().and_then(|m| m.modified()));
                self.writer.add_directory(format!("{rel}/"), options)?;
                self.add_dir(&path, &canonical, &rel)?;
            }
        } else if entry_type.is_file() {
            self.add_file(&rel, &path)?;
        }
        Ok(())
    }

    fn add_file(&mut self, rel: &str, path: &Path) -> Result<(), CoreError> {
        let mut file = File::open(path)?;
        let meta = file.metadata()?;
        let options = dated(self.options, meta.modified()).large_file(needs_zip64(meta.len()));
        self.writer.start_file(rel, options)?;
        // No flush per file: on a deflated entry that forces a sync block
        // into the stream, and the next start_file or finish ends it anyway.
        io::copy(&mut file, &mut self.writer)?;
        Ok(())
    }
}

/// Past 4 GiB (a video, a data set), sizes need ZIP64's fields; and from
/// 3 GiB a file gets them too, as one that doesn't compress is stored a
/// little larger than it is, deflate's blocks each adding their header.
fn needs_zip64(len: u64) -> bool {
    len >= 3 << 30
}

/// `options` with the entry dated as `modified`. ZIP stores local time, as
/// unzipping tools show it; undated, every entry would say 1 January 1980.
fn dated(options: SimpleFileOptions, modified: io::Result<SystemTime>) -> SimpleFileOptions {
    let Ok(modified) = modified else {
        return options;
    };
    let local = chrono::DateTime::<chrono::Local>::from(modified).naive_local();
    // Outside ZIP's 1980–2107, the entry keeps the default.
    let date = zip::DateTime::try_from(local).ok();
    date.map_or(options, |date| options.last_modified_time(date))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::{project, zip_names};

    #[test]
    fn a_file_that_could_deflate_past_4_gib_is_written_as_zip64() {
        assert!(!needs_zip64(0));
        assert!(!needs_zip64((3 << 30) - 1));
        // Deflate stores what it can't compress in blocks of at most 65,535
        // bytes, 5 more each: under 4 GiB itself, over it once stored.
        let len: u64 = (1 << 32) - 1_000;
        assert!(len + len.div_ceil(65_535) * 5 > u32::MAX as u64);
        assert!(needs_zip64(len));
        assert!(needs_zip64(1 << 32));
    }

    #[test]
    fn litter_and_the_autosaves_temporary_file_stay_out_and_the_authors_dotfiles_go_in() {
        let (dir, root) = project();
        for (path, text) in [
            (".latexmkrc", "$pdf_mode = 1;"),
            (".git/HEAD", "ref"),
            ("figs/.DS_Store", "x"),
            ("figs/._a.png", "fork"),
            // What atomic::write leaves beside a document mid-save.
            (".texlocal-AbC123", "half"),
            ("figs/a.png", "png"),
        ] {
            let file = root.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, text).unwrap();
        }
        let dest = dir.path().join("out.zip");
        export_zip(&root, &dest).unwrap();
        assert_eq!(
            zip_names(&dest),
            [".latexmkrc", "figs/", "figs/a.png", "main.tex"]
        );
    }

    #[test]
    fn an_entry_that_vanishes_during_the_walk_is_left_out_not_a_failure() {
        let (dir, root) = project();
        fs::write(root.join("a.tex"), "a").unwrap();
        fs::write(root.join("gone.tex"), "x").unwrap();
        let canonical = dunce::canonicalize(&root).unwrap();
        let mut listed: Vec<_> = fs::read_dir(&root).unwrap().map(Result::unwrap).collect();
        listed.sort_by_key(DirEntry::file_name);
        // The folder was listed; then an editor removed its temporary file.
        fs::remove_file(root.join("gone.tex")).unwrap();

        let dest = dir.path().join("out.zip");
        let (temp, file) = create_temp(dir.path()).unwrap();
        let mut export = Export {
            writer: ZipWriter::new(file),
            options: SimpleFileOptions::default(),
            root_canonical: &canonical,
            archive_dir: dir.path().to_path_buf(),
            archive_names: [None, None],
        };
        for entry in &listed {
            match export.add_entry(entry, "") {
                Err(err) if err.status == 404 => {}
                added => added.unwrap(),
            }
        }
        export.writer.finish().unwrap();
        persist(temp, &dest).unwrap();
        assert_eq!(zip_names(&dest), ["a.tex", "main.tex"]);
    }

    #[test]
    fn a_destination_that_cannot_be_written_is_named() {
        let (dir, root) = project();
        let dest = dir.path().join("no such folder/out.zip");
        let err = export_zip(&root, &dest).unwrap_err();
        assert_eq!(err.status, 404);
        assert!(err.message.contains("out.zip"), "{}", err.message);
        assert!(!err.message.contains("os error"), "{}", err.message);
    }
}
