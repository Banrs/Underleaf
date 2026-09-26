//! Project ZIP export via the zip crate. The archive is completed in a sibling
//! temporary file and moved into place only after success, so a destination
//! inside the project cannot archive itself and failures never leave a partial
//! ZIP at the requested path.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use chrono::{Datelike, Timelike};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::atomic::{create_temp, replace};
use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

const LITTER: [&str; 3] = [".DS_Store", "Thumbs.db", "desktop.ini"];

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let root_canonical = fs::canonicalize(root)?;
    let (temp_path, file) = create_temp(dest)?;

    let result = (|| -> Result<(), CoreError> {
        // The folder the archive is written into, resolved the way the walk
        // resolves the project, so a destination spelled through a link (such
        // as macOS's /var for /private/var) is still recognised there.
        let parent = dest.parent().filter(|p| !p.as_os_str().is_empty());
        let mut export = Export {
            writer: ZipWriter::new(file),
            options: SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
            root_canonical: &root_canonical,
            archive_dir: fs::canonicalize(parent.unwrap_or(Path::new(".")))?,
            archive_names: [dest.file_name(), temp_path.file_name()],
            visited: HashSet::from([root_canonical.clone()]),
        };
        export.add_dir(root, &root_canonical, "")?;
        export.writer.finish()?.sync_all()?;
        Ok(replace(&temp_path, dest)?)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
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
    visited: HashSet<PathBuf>,
}

impl Export<'_> {
    /// `dir_canonical` is `dir` resolved, as the visited set records it.
    fn add_dir(&mut self, dir: &Path, dir_canonical: &Path, prefix: &str) -> Result<(), CoreError> {
        let mut entries = fs::read_dir(dir)?.collect::<io::Result<Vec<_>>>()?;
        entries.sort_by_key(|e| e.file_name());
        let holds_archive = dir_canonical == self.archive_dir;

        for entry in entries {
            let file_name = entry.file_name();
            if holds_archive && self.archive_names.contains(&Some(file_name.as_os_str())) {
                continue;
            }
            let name = file_name.to_string_lossy();
            // What Finder and Explorer leave in folders is nobody's content.
            if LITTER.iter().any(|l| name.eq_ignore_ascii_case(l)) {
                continue;
            }
            if prefix.is_empty() && (name.eq_ignore_ascii_case(BUILD_DIR) || name == SETTINGS_FILE)
            {
                continue;
            }
            let rel = if prefix.is_empty() {
                name.into_owned()
            } else {
                format!("{prefix}/{name}")
            };
            let path = entry.path();

            let entry_type = entry.file_type()?;
            if entry_type.is_symlink() {
                // Unresolvable (dangling, a loop): nothing to export, as in
                // the project walks.
                let Ok(target) = fs::canonicalize(&path) else {
                    continue;
                };
                if !target.starts_with(self.root_canonical) {
                    // Never export data reached through a link outside the project.
                    continue;
                }
                if fs::metadata(&path)?.is_file() {
                    self.add_file(&rel, &path)?;
                }
                // Directory links are deliberately skipped. Following them creates
                // cycles and duplicates; regular directories below are still walked.
                continue;
            }

            if entry_type.is_dir() {
                let canonical = fs::canonicalize(&path)?;
                if !canonical.starts_with(self.root_canonical) {
                    continue;
                }
                if !self.visited.insert(canonical.clone()) {
                    continue;
                }
                let options = dated(self.options, &path);
                self.writer.add_directory(format!("{rel}/"), options)?;
                self.add_dir(&path, &canonical, &rel)?;
            } else if entry_type.is_file() {
                self.add_file(&rel, &path)?;
            }
        }
        Ok(())
    }

    fn add_file(&mut self, rel: &str, path: &Path) -> Result<(), CoreError> {
        self.writer.start_file(rel, dated(self.options, path))?;
        // No flush per file: on a deflated entry that forces a sync block
        // into the stream, and the next start_file or finish ends it anyway.
        io::copy(&mut File::open(path)?, &mut self.writer)?;
        Ok(())
    }
}

/// `options` with the entry dated as `path` is. ZIP stores local time, as
/// unzipping tools show it; undated, every entry would say 1 January 1980.
fn dated(options: SimpleFileOptions, path: &Path) -> SimpleFileOptions {
    let Ok(modified) = fs::metadata(path).and_then(|meta| meta.modified()) else {
        return options;
    };
    let local = chrono::DateTime::<chrono::Local>::from(modified).naive_local();
    // Outside ZIP's 1980–2107, the entry keeps the default.
    let date = u16::try_from(local.year()).ok().and_then(|year| {
        zip::DateTime::from_date_and_time(
            year,
            local.month() as u8,
            local.day() as u8,
            local.hour() as u8,
            local.minute() as u8,
            local.second() as u8,
        )
        .ok()
    });
    date.map_or(options, |date| options.last_modified_time(date))
}
