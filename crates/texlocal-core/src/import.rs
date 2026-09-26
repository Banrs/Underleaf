//! Bringing outside files into the library, for in-process hosts: a Finder
//! drop onto a project. It reads host-chosen absolute paths, so it is not in
//! `Service::call`, which the browser server exposes.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::service::{keep_both, Clash, Service, UploadSpec};
use crate::CoreError;

/// What to do with incoming files that land on existing entries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Conflict {
    /// Move the existing entries to the Trash.
    Replace,
    /// Give the incoming files free names beside them.
    KeepBoth,
}

#[derive(Debug, Serialize)]
pub struct Imported {
    pub saved: Vec<String>,
    pub existing: Vec<Clash>,
}

/// Dotfiles (.git, .DS_Store) and the resource forks of a Mac-made zip: the
/// project walks hide them, so an import that brought them would bring files
/// nobody sees.
fn hidden(name: &str) -> bool {
    name.starts_with('.') || name == "__MACOSX"
}

/// Files under a dropped path, with project-relative names that keep a
/// dropped folder's own name, and where to read each. Inside a folder,
/// hidden entries stay behind and symlinks are skipped, not followed: a drop
/// imports what was dropped, never what a link inside it points at.
fn collect(
    abs: &Path,
    rel: String,
    meta: fs::Metadata,
    files: &mut Vec<(UploadSpec, PathBuf)>,
) -> Result<(), CoreError> {
    if meta.is_file() {
        let spec = UploadSpec {
            path: rel,
            // Saturating, so a size past usize still fails the upload limit.
            size: usize::try_from(meta.len()).unwrap_or(usize::MAX),
        };
        files.push((spec, abs.to_path_buf()));
    } else if meta.is_dir() {
        for entry in fs::read_dir(abs)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !hidden(&name) {
                // DirEntry::metadata does not follow links.
                let meta = entry.metadata()?;
                collect(&entry.path(), format!("{rel}/{name}"), meta, files)?;
            }
        }
    }
    Ok(())
}

/// Import dropped files and folders into the project folder `dir`, with the
/// same validate-then-write rule as a browser upload: a bad path or oversize
/// file fails the drop before anything lands. Without `conflict`, a drop that
/// would land on existing entries writes nothing and reports them, for the
/// host to ask about.
pub fn import_files(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
) -> Result<Imported, CoreError> {
    let mut files = Vec::new();
    for abs in paths {
        let name = abs.file_name().unwrap_or_default().to_string_lossy();
        // A dropped link is followed: dropping it names what it points at.
        collect(abs, name.into_owned(), fs::metadata(abs)?, &mut files)?;
    }
    let (mut specs, sources): (Vec<_>, Vec<_>) = files.into_iter().unzip();
    let existing = service.validate_uploads(id, dir, &specs)?.existing;
    match conflict {
        None if !existing.is_empty() => {
            return Ok(Imported {
                saved: Vec::new(),
                existing,
            })
        }
        Some(Conflict::KeepBoth) => {
            for spec in &mut specs {
                spec.path = keep_both(&spec.path, &existing);
            }
        }
        _ => {}
    }
    let replace = conflict == Some(Conflict::Replace);
    let mut saved = Vec::new();
    for (spec, abs) in specs.iter().zip(&sources) {
        saved.push(service.upload_file(id, dir, &spec.path, &fs::read(abs)?, replace)?);
    }
    Ok(Imported { saved, existing })
}
