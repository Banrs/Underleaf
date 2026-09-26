//! Bringing outside files into the library, for in-process hosts: a Finder
//! drop onto a project, and File › Open of a folder, a .zip or a .tex made a
//! new project. Both read host-chosen absolute paths, so neither is in
//! `Service::call`, which the browser server exposes. Both block on the
//! disk; hosts call them off their UI thread, as they do every `tl_call`.

use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::json;
use zip::ZipArchive;

use crate::projects::{self, ProjectInfo};
use crate::service::{keep_both, Clash, Service, UploadSpec, UPLOAD_MAX_BYTES};
use crate::{templates, CoreError, BUILD_DIR};

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
/// dropped folder's own name (none for an empty `rel`), and where to read
/// each. Inside a folder, hidden entries stay behind and symlinks are
/// skipped, not followed: a drop imports what was dropped, never what a link
/// inside it points at.
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
                let rel = if rel.is_empty() {
                    name
                } else {
                    format!("{rel}/{name}")
                };
                collect(&entry.path(), rel, meta, files)?;
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

/// Where an imported project's file comes from.
enum Source {
    File(PathBuf),
    /// An entry of the chosen zip, by index.
    Zip(usize),
}

/// A zip's visible files; the contents of its one top folder if it has one,
/// as a zipped project folder unpacks.
fn zip_files(archive: &mut ZipArchive<File>) -> Result<Vec<(UploadSpec, Source)>, CoreError> {
    let mut files = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index(i)?;
        // No folders or links, and no name that would leave the project.
        let Some(path) = entry.enclosed_name().filter(|_| entry.is_file()) else {
            continue;
        };
        let parts: Vec<_> = path.iter().map(|p| p.to_string_lossy()).collect();
        if !parts.iter().any(|p| hidden(p)) {
            let spec = UploadSpec {
                path: parts.join("/"),
                size: usize::try_from(entry.size()).unwrap_or(usize::MAX),
            };
            files.push((spec, Source::Zip(i)));
        }
    }
    let top = files
        .first()
        .and_then(|(spec, _)| Some(format!("{}/", spec.path.split_once('/')?.0)));
    if let Some(top) = top.filter(|top| files.iter().all(|(s, _)| s.path.starts_with(top))) {
        for (spec, _) in &mut files {
            spec.path.drain(..top.len());
        }
    }
    Ok(files)
}

/// File › Open: a folder, a .zip or a single file from anywhere, copied into
/// a new project named after it ("Name 2" when that is taken), which is
/// returned. Only visible files come, as a drop brings them, and a top-level
/// `build` stays behind as the old project's compile output. The main file is
/// the chosen .tex, else the likeliest top-level one; with no TeX at all, the
/// blank template's main.tex.
pub fn import_project(service: &Service, src: &Path) -> Result<ProjectInfo, CoreError> {
    let meta = fs::metadata(src)?;
    let is_dir = meta.is_dir();
    let named =
        |name: Option<&std::ffi::OsStr>| name.unwrap_or_default().to_string_lossy().into_owned();
    let ext = named(src.extension()).to_lowercase();
    let (base, mut zip, mut files) = if is_dir {
        let mut found = Vec::new();
        collect(src, String::new(), meta, &mut found)?;
        let found = found.into_iter().map(|(s, p)| (s, Source::File(p)));
        (named(src.file_name()), None, found.collect())
    } else if ext == "zip" {
        let mut archive = ZipArchive::new(File::open(src)?)?;
        let found = zip_files(&mut archive)?;
        (named(src.file_stem()), Some(archive), found)
    } else {
        let spec = UploadSpec {
            path: named(src.file_name()),
            size: usize::try_from(meta.len()).unwrap_or(usize::MAX),
        };
        (
            named(src.file_stem()),
            None,
            vec![(spec, Source::File(src.into()))],
        )
    };
    files.retain(|(spec, _)| {
        let top = spec.path.split('/').next().unwrap_or_default();
        !top.eq_ignore_ascii_case(BUILD_DIR)
    });

    let (id, root) = (1..)
        .map(|n| match n {
            1 => base.clone(),
            n => format!("{base} {n}"),
        })
        .map(|name| projects::new_project_dir(&service.data_dir, &name))
        .find(|made| !made.as_ref().is_err_and(|err| err.status == 409))
        .expect("a free name")?;
    let result = (|| {
        let (specs, sources): (Vec<_>, Vec<_>) = files.into_iter().unzip();
        service.validate_uploads(&id, "", &specs)?;
        for (spec, source) in specs.iter().zip(sources) {
            let bytes = match source {
                Source::File(path) => fs::read(path)?,
                Source::Zip(i) => {
                    let mut bytes = Vec::new();
                    let entry = zip.as_mut().expect("a zip source").by_index(i)?;
                    // A declared size can lie; upload_file refuses past the limit.
                    entry
                        .take(UPLOAD_MAX_BYTES as u64 + 1)
                        .read_to_end(&mut bytes)?;
                    bytes
                }
            };
            service.upload_file(&id, "", &spec.path, &bytes, false)?;
        }
        let main = match (!is_dir && ext == "tex").then(|| named(src.file_name())) {
            None => projects::guess_main_file(&root)?,
            chosen => chosen,
        };
        let main = match main {
            Some(main) => main,
            None => {
                let (file, content) = templates::files("blank")[0];
                fs::write(root.join(file), content)?;
                file.to_string()
            }
        };
        projects::finish_project(id.clone(), &root, &json!({ "mainFile": main }))
    })();
    if result.is_err() {
        // Only copies are lost: the folder is the one made above.
        let _ = fs::remove_dir_all(&root);
    }
    result
}
