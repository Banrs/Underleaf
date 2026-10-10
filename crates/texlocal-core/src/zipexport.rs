//! Project ZIP export via the zip crate. The archive is completed in a sibling
//! temporary file and moved into place only after success, so a destination
//! inside the project cannot archive itself and failures never leave a partial
//! ZIP at the requested path.

use std::ffi::OsStr;
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::atomic::create_temp;
use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let root_canonical = fs::canonicalize(root)?;
    let (temp_path, file) = create_temp(dest, None)?;

    // Resolve the archive folder as the walk resolves the project, so a
    // destination spelled through a link is still recognised there.
    let parent = dest.parent().filter(|p| !p.as_os_str().is_empty());
    let mut export = Export {
        writer: ZipWriter::new(file),
        options: SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        root_canonical: &root_canonical,
        archive_dir: fs::canonicalize(parent.unwrap_or(Path::new(".")))?,
        archive_names: [dest.file_name(), temp_path.file_name()],
    };
    export.add_dir(root, &root_canonical, "")?;
    export.writer.finish()?.sync_all()?;
    temp_path.persist(dest).map_err(|err| err.error.into())
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
        entries.sort_by_key(|e| e.file_name());
        let holds_archive = dir_canonical == self.archive_dir;

        for entry in entries {
            let file_name = entry.file_name();
            if holds_archive && self.archive_names.contains(&Some(file_name.as_os_str())) {
                continue;
            }
            let name = file_name.to_string_lossy();
            // Finder's folder metadata is not project content.
            if name.eq_ignore_ascii_case(".DS_Store") {
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
                let options = dated(self.options, entry.metadata().and_then(|m| m.modified()));
                self.writer.add_directory(format!("{rel}/"), options)?;
                self.add_dir(&path, &canonical, &rel)?;
            } else if entry_type.is_file() {
                self.add_file(&rel, &path)?;
            }
        }
        Ok(())
    }

    fn add_file(&mut self, rel: &str, path: &Path) -> Result<(), CoreError> {
        let mut file = File::open(path)?;
        let meta = file.metadata()?;
        // Past 4 GiB (a video, a data set), sizes need ZIP64's fields.
        let options = dated(self.options, meta.modified()).large_file(meta.len() >= 1 << 32);
        self.writer.start_file(rel, options)?;
        // No flush per file: on a deflated entry that forces a sync block
        // into the stream, and the next start_file or finish ends it anyway.
        io::copy(&mut file, &mut self.writer)?;
        Ok(())
    }
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
