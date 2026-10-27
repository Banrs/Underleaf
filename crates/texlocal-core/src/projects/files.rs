use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use schemars::JsonSchema;
use serde::Serialize;
use serde_json::json;

use crate::atomic;
use crate::error::CoreError;
use crate::paths::{Project, after_entry, rel_key, safe_path, safe_write_path, same_entry};
use crate::settings::{UiState, move_ui, read_settings, read_ui, write_settings};
use crate::stamp::Stamp;

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct RenameResult {
    pub from: String,
    pub to: String,
    pub main_file: String,
    ui: UiState,
}

pub fn create_free(root: &Path, rel: &str, dir: bool) -> Result<String, CoreError> {
    for path in copy_paths(rel) {
        let abs = safe_write_path(root, &path)?;
        let error = |err| {
            if dir {
                CoreError::from(err)
            } else {
                write_error(&abs, err)
            }
        };
        (abs.parent().map_or(Ok(()), fs::create_dir_all)).map_err(error)?;

        let made = if dir {
            fs::create_dir(&abs)
        } else {
            fs::File::create_new(&abs).map(drop)
        };
        match made {
            Err(err) if err.kind() == ErrorKind::AlreadyExists => {}
            made => return made.map(|()| path).map_err(error),
        }
    }
    unreachable!("a free name")
}

pub(crate) fn write_creating(abs: &Path, contents: &[u8]) -> Result<Stamp, CoreError> {
    abs.parent()
        .map_or(Ok(()), fs::create_dir_all)
        .and_then(|()| atomic::write(abs, contents))
        .map_err(|err| write_error(abs, err))
}

pub(crate) struct Planned<D> {
    pub abs: PathBuf,
    pub bytes: Vec<u8>,
    pub was: Option<Vec<u8>>,
    pub done: D,
}

pub(crate) fn inside(root: &Path, abs: &Path) -> bool {
    for path in abs.ancestors() {
        match fs::symlink_metadata(path) {
            Err(err) if err.kind() == ErrorKind::NotFound => {}
            Err(_) => return false,
            Ok(_) => return fs::canonicalize(path).is_ok_and(|real| real.starts_with(root)),
        }
    }
    false
}

pub(crate) fn write_all<T, D>(
    items: impl IntoIterator<Item = T>,
    mut plan: impl FnMut(T) -> Result<Option<Planned<D>>, CoreError>,
) -> Result<Vec<D>, CoreError> {
    let mut written = Vec::new();
    let writing = items.into_iter().try_for_each(|item| {
        if let Some(planned) = plan(item)? {
            write_creating(&planned.abs, &planned.bytes)?;
            written.push(planned);
        }
        Ok(())
    });
    if let Err(err) = writing {
        for Planned { abs, was, .. } in &written {
            let _ = match was {
                Some(was) => write_creating(abs, was).map(drop),
                None => fs::remove_file(abs).map_err(CoreError::from),
            };
        }
        return Err(err);
    }
    Ok(written.into_iter().map(|planned| planned.done).collect())
}

fn write_error(abs: &Path, err: std::io::Error) -> CoreError {
    let file = abs.file_name().unwrap_or_default().to_string_lossy();
    let kind = err.kind();
    let fallback = CoreError::from(err);
    let message = match kind {
        ErrorKind::PermissionDenied => {
            let folder = abs.parent().and_then(Path::file_name).unwrap_or_default();
            let folder = folder.to_string_lossy();
            format!("You don’t have permission to save the file “{file}” in the folder “{folder}”.")
        }
        ErrorKind::ReadOnlyFilesystem => {
            format!("The file “{file}” couldn’t be saved because the volume is read only.")
        }
        ErrorKind::StorageFull => {
            format!("The file “{file}” couldn’t be saved because there isn’t enough space.")
        }
        _ => format!(
            "The file “{file}” couldn’t be saved ({}).",
            fallback.message
        ),
    };
    CoreError {
        message,
        ..fallback
    }
}

fn is_under(path: &str, dir: &str) -> bool {
    after_entry(path, dir).is_some_and(|rest| !rest.is_empty())
}

pub(super) fn occupied(src: &Path, dest: &Path) -> bool {
    fs::symlink_metadata(dest).is_ok() && !same_entry(src, dest)
}

pub fn rename_entry(project: &Project, from: &str, to: &str) -> Result<RenameResult, CoreError> {
    let root = &project.root;
    let (src, dest) = (safe_path(root, from)?, safe_write_path(root, to)?);
    let (from, to) = (rel_key(from)?, rel_key(to)?);
    if fs::symlink_metadata(&src).is_err() {
        return Err(CoreError::not_found("Not found"));
    }
    if occupied(&src, &dest) {
        return Err(CoreError::conflict("Destination already exists"));
    }
    if is_under(&to, &from) {
        return Err(CoreError::bad_request(
            "A folder can't be moved into itself",
        ));
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    let main_file = read_settings(&project.settings).main_file;
    let moved = |path: &str| after_entry(path, &from).map(|rest| format!("{to}{rest}"));
    let moved_main = moved(&main_file);
    atomic::rename_exclusive(&src, &dest)?;
    if let Some(main_file) = &moved_main
        && let Err(err) = write_settings(&project.settings, &json!({ "mainFile": main_file }))
    {
        return Err(match atomic::rename_exclusive(&dest, &src) {
            Ok(()) => err,
            Err(rollback) => CoreError::internal(format!(
                "{}; rename rollback failed: {rollback}",
                err.message
            )),
        });
    }
    move_ui(&project.ui, moved);
    Ok(RenameResult {
        from,
        to,
        main_file: moved_main.unwrap_or(main_file),
        ui: read_ui(&project.ui),
    })
}

pub(crate) type Trash = fn(&Path) -> Result<(), CoreError>;

pub(crate) fn discard_replaced(
    project: &Project,
    rel: &str,
    trash: Trash,
) -> Result<(), CoreError> {
    if is_under(&read_settings(&project.settings).main_file, rel) {
        return Err(CoreError::conflict(
            "Choose a different main file before replacing this folder",
        ));
    }
    trash(&safe_path(&project.root, rel)?)
}

pub(crate) fn copy_paths(rel: &str) -> impl Iterator<Item = String> {
    let (parent, name) = rel.rsplit_once('/').unwrap_or(("", rel));
    let numbered = move |n: u32| match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => format!("{stem} {n}.{ext}"),
        _ => format!("{name} {n}"),
    };
    let copies = std::iter::once(name.to_owned()).chain((2..).map(numbered));
    copies.map(move |copy| match parent {
        "" => copy,
        _ => format!("{parent}/{copy}"),
    })
}
