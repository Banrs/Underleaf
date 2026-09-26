//! Project ZIP export via the zip crate. The archive is completed in a sibling
//! temporary file and moved into place only after success, so a destination
//! inside the project cannot archive itself and failures never leave a partial
//! ZIP at the requested path.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let root_canonical = fs::canonicalize(root)?;
    let (temp_path, file) = create_sibling_temp(dest)?;

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
        Ok(replace_completed(&temp_path, dest)?)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

/// A fresh hidden name beside `dest`, ending in `.{ext}`.
fn sibling(dest: &Path, ext: &str) -> PathBuf {
    let parent = dest.parent().unwrap_or_else(|| Path::new("."));
    let name = dest
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_else(|| "archive.zip".into());
    let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    parent.join(format!(".{name}.texlocal-{}-{n}.{ext}", std::process::id()))
}

fn create_sibling_temp(dest: &Path) -> io::Result<(PathBuf, File)> {
    for _ in 0..100 {
        let candidate = sibling(dest, "tmp");
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => return Ok((candidate, file)),
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a temporary ZIP path",
    ))
}

fn replace_completed(temp: &Path, dest: &Path) -> io::Result<()> {
    match fs::rename(temp, dest) {
        Ok(()) => Ok(()),
        #[cfg(windows)]
        Err(err)
            if dest.exists()
                && matches!(
                    err.kind(),
                    io::ErrorKind::AlreadyExists | io::ErrorKind::PermissionDenied
                ) =>
        {
            let backup = sibling(dest, "bak");
            fs::rename(dest, &backup)?;
            match fs::rename(temp, dest) {
                Ok(()) => {
                    let _ = fs::remove_file(backup);
                    Ok(())
                }
                Err(replace_err) => {
                    // Best effort rollback; return the replacement error because
                    // it describes why the requested archive was not installed.
                    let _ = fs::rename(&backup, dest);
                    Err(replace_err)
                }
            }
        }
        Err(err) => Err(err),
    }
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
            if prefix.is_empty() && (name == BUILD_DIR || name == SETTINGS_FILE) {
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
                self.writer.add_directory(format!("{rel}/"), self.options)?;
                self.add_dir(&path, &canonical, &rel)?;
            } else if entry_type.is_file() {
                self.add_file(&rel, &path)?;
            }
        }
        Ok(())
    }

    fn add_file(&mut self, rel: &str, path: &Path) -> Result<(), CoreError> {
        self.writer.start_file(rel, self.options)?;
        // No flush per file: on a deflated entry that forces a sync block
        // into the stream, and the next start_file or finish ends it anyway.
        io::copy(&mut File::open(path)?, &mut self.writer)?;
        Ok(())
    }
}
