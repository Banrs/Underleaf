//! Project ZIP export via the zip crate. The archive is completed in a sibling
//! temporary file and moved into place only after success, so a destination
//! inside the project cannot archive itself and failures never leave a partial
//! ZIP at the requested path.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::error::CoreError;
use crate::paths::normalize_abs;
use crate::{BUILD_DIR, SETTINGS_FILE};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let root_canonical = fs::canonicalize(root)?;
    let dest_abs = absolute_lexical(dest)?;
    let (temp_path, file) = create_sibling_temp(dest)?;
    let temp_abs = absolute_lexical(&temp_path)?;

    let result = (|| -> Result<(), CoreError> {
        let mut writer = ZipWriter::new(file);
        let options =
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        let mut visited = HashSet::new();
        visited.insert(root_canonical.clone());
        add_dir(
            &mut writer,
            options,
            root,
            "",
            &root_canonical,
            &dest_abs,
            &temp_abs,
            &mut visited,
        )?;
        let completed = writer
            .finish()
            .map_err(|e| CoreError::internal(e.to_string()))?;
        completed.sync_all()?;
        Ok(())
    })();

    if let Err(err) = result {
        let _ = fs::remove_file(&temp_path);
        return Err(err);
    }

    if let Err(err) = replace_completed(&temp_path, dest) {
        let _ = fs::remove_file(&temp_path);
        return Err(err.into());
    }
    Ok(())
}

fn absolute_lexical(path: &Path) -> io::Result<PathBuf> {
    if path.is_absolute() {
        Ok(normalize_abs(path))
    } else {
        Ok(normalize_abs(&std::env::current_dir()?.join(path)))
    }
}

fn create_sibling_temp(dest: &Path) -> io::Result<(PathBuf, File)> {
    let parent = dest.parent().unwrap_or_else(|| Path::new("."));
    let name = dest
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_else(|| "archive.zip".into());
    for _ in 0..100 {
        let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let candidate = parent.join(format!(
            ".{name}.texlocal-{}-{n}.tmp",
            std::process::id()
        ));
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
            let backup = sibling_backup(dest);
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

#[cfg(windows)]
fn sibling_backup(dest: &Path) -> PathBuf {
    let parent = dest.parent().unwrap_or_else(|| Path::new("."));
    let name = dest
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_else(|| "archive.zip".into());
    parent.join(format!(
        ".{name}.texlocal-{}-{}.bak",
        std::process::id(),
        TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}

#[allow(clippy::too_many_arguments)]
fn add_dir(
    writer: &mut ZipWriter<File>,
    options: SimpleFileOptions,
    dir: &Path,
    prefix: &str,
    root_canonical: &Path,
    dest_abs: &Path,
    temp_abs: &Path,
    visited: &mut HashSet<PathBuf>,
) -> Result<(), CoreError> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir)? {
        entries.push(entry?);
    }
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let name = entry.file_name().to_string_lossy().into_owned();
        if prefix.is_empty() && (name == BUILD_DIR || name == SETTINGS_FILE) {
            continue;
        }
        let rel = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        let path = entry.path();
        let path_abs = absolute_lexical(&path)?;
        if path_abs == *dest_abs || path_abs == *temp_abs {
            continue;
        }

        let entry_type = entry.file_type()?;
        if entry_type.is_symlink() {
            let target = match fs::canonicalize(&path) {
                Ok(target) => target,
                Err(err) if err.kind() == io::ErrorKind::NotFound => continue,
                Err(err) => return Err(err.into()),
            };
            if target != root_canonical && !target.starts_with(root_canonical) {
                // Never export data reached through a link outside the project.
                continue;
            }
            let meta = fs::metadata(&path)?;
            if meta.is_file() {
                add_file(writer, options, &rel, &path)?;
            }
            // Directory links are deliberately skipped. Following them creates
            // cycles and duplicates; regular directories below are still walked.
            continue;
        }

        if entry_type.is_dir() {
            let canonical = fs::canonicalize(&path)?;
            if canonical != root_canonical && !canonical.starts_with(root_canonical) {
                continue;
            }
            if !visited.insert(canonical) {
                continue;
            }
            writer
                .add_directory(format!("{rel}/"), options)
                .map_err(|e| CoreError::internal(e.to_string()))?;
            add_dir(
                writer,
                options,
                &path,
                &rel,
                root_canonical,
                dest_abs,
                temp_abs,
                visited,
            )?;
        } else if entry_type.is_file() {
            add_file(writer, options, &rel, &path)?;
        }
    }
    Ok(())
}

fn add_file(
    writer: &mut ZipWriter<File>,
    options: SimpleFileOptions,
    rel: &str,
    path: &Path,
) -> Result<(), CoreError> {
    writer
        .start_file(rel, options)
        .map_err(|e| CoreError::internal(e.to_string()))?;
    let mut src = File::open(path)?;
    io::copy(&mut src, writer)?;
    writer.flush()?;
    Ok(())
}
