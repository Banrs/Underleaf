//! Project ZIP export via the zip crate — replacing the `zip` CLI spawns in
//! electron/main.mjs and server/index.js, which had no Windows equivalent.
//! Exclusion parity with `zip -r <dest> . -x 'build/*' '.texlocal.json'`:
//! the top-level build tree and the top-level settings file stay out; nested
//! files of the same names are ordinary content.

use std::fs::File;
use std::io::{self, Write};
use std::path::Path;

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let file = File::create(dest)?;
    let mut writer = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    add_dir(&mut writer, options, root, "")?;
    writer
        .finish()
        .map_err(|e| CoreError::internal(e.to_string()))?;
    Ok(())
}

fn add_dir(
    writer: &mut ZipWriter<File>,
    options: SimpleFileOptions,
    dir: &Path,
    prefix: &str,
) -> Result<(), CoreError> {
    let mut entries: Vec<_> = std::fs::read_dir(dir)?.filter_map(|e| e.ok()).collect();
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
        // metadata() follows symlinks, where entry.file_type() does not: `zip -r`
        // archived a link's target content, and a symlinked references.bib or
        // figures directory is a normal thing for a project to contain. A broken
        // link has no target to read, so it is skipped rather than failing the
        // whole export.
        let Ok(file_type) = std::fs::metadata(&path).map(|m| m.file_type()) else {
            continue;
        };
        if file_type.is_dir() {
            writer
                .add_directory(format!("{rel}/"), options)
                .map_err(|e| CoreError::internal(e.to_string()))?;
            add_dir(writer, options, &path, &rel)?;
        } else if file_type.is_file() {
            writer
                .start_file(&rel, options)
                .map_err(|e| CoreError::internal(e.to_string()))?;
            let mut src = File::open(&path)?;
            io::copy(&mut src, writer)?;
            writer.flush()?;
        }
    }
    Ok(())
}
