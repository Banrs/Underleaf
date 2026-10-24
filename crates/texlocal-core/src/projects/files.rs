//! Making, moving and discarding the files and folders of a project.

use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;
use serde_json::json;

use crate::atomic;
use crate::error::CoreError;
use crate::paths::{Project, after_entry, rel_key, safe_path, safe_write_path, same_entry};
use crate::settings::{move_ui, read_settings, write_settings};
use crate::stamp::Stamp;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenameResult {
    pub from: String,
    pub to: String,
    pub main_file: String,
}

/// `rel`, or the first of its copies' names that is free, each tried with one create that fails
/// on anything there, so an entry another app makes meanwhile is kept.
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

/// A file one of `write_all`'s writes: `was` what it held, None if there was none, and `done`
/// what the caller answers for it.
pub(crate) struct Planned<D> {
    pub abs: PathBuf,
    pub bytes: Vec<u8>,
    pub was: Option<Vec<u8>>,
    pub done: D,
}

/// Whether what `abs` names is in the project at `root`, resolved: a link there to a file
/// elsewhere, as a cloned repository may hold, isn't, and a write across the project leaves it be.
pub(crate) fn inside(root: &Path, abs: &Path) -> bool {
    fs::canonicalize(abs)
        .ok()
        .is_none_or(|real| real.starts_with(root))
}

/// What `plan` makes of each item, written in turn, all or none: a plan or write that fails is the
/// error, and the files written before it are put back as they were, or removed if they weren't.
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
        // Each was just written where it is, so can be again.
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

/// A failed write in Foundation's words, as the hosts show it in an alert whose title already
/// says the file wasn't saved; its status is the file system's, as any other.
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

/// Whether a rename from `src` to `dest` would land on another entry. On a case-insensitive
/// volume, the default on macOS, a case-only rename's destination already "exists"
/// because it is `src` itself.
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
    fs::rename(&src, &dest)?;
    if let Some(main_file) = &moved_main
        && let Err(err) = write_settings(&project.settings, &json!({ "mainFile": main_file }))
    {
        return Err(match fs::rename(&dest, &src) {
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
    })
}

pub(crate) type Trash = fn(&Path) -> Result<(), CoreError>;

/// Delete to the Trash, so a mis-click is recoverable; a trash failure is reported and never
/// becomes a permanent delete.
pub(crate) fn discard(path: &Path) -> Result<(), CoreError> {
    // macOS's own tool moves it as FileManager's trashItem does, as the Mac app does, where
    // asking Finder would need the Automation permission. The path is absolute, so it can't be
    // read as an option; `-s` makes a failed move an error.
    let trashed = Command::new("/usr/bin/trash")
        .arg("-s")
        .arg(path)
        .output()?;
    if trashed.status.success() {
        return Ok(());
    }
    let said = String::from_utf8_lossy(&trashed.stderr);
    Err(CoreError::internal(format!(
        "Could not move the item to Trash: {}",
        said.trim()
    )))
}

/// Discard, by `trash`, an entry an incoming file of its name replaces. The main file may go,
/// since the file taking its place keeps it valid; a folder holding it may not, however the
/// upload spells its name.
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

/// `rel`, then "name 2.ext", "name 3.ext" and so on in its folder, as Finder numbers copies.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::project;
    use crate::settings::{read_ui, write_ui};

    #[test]
    fn a_write_refused_says_so_in_a_sentence_naming_the_file_and_folder() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().join("Thesis");
        fs::create_dir(&folder).unwrap();
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o555)).unwrap();
        let err = write_creating(&folder.join("main.tex"), b"x").unwrap_err();
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o755)).unwrap();
        let said = "You don’t have permission to save the file “main.tex” in the folder “Thesis”.";
        assert_eq!((err.status, err.message.as_str()), (403, said));
    }

    #[test]
    fn a_new_entry_takes_the_next_free_name() {
        let (_dir, root) = project();
        let made = [(); 3].map(|()| create_free(&root, "notes/untitled.tex", false).unwrap());
        let numbered = [
            "notes/untitled.tex",
            "notes/untitled 2.tex",
            "notes/untitled 3.tex",
        ];
        assert_eq!(made, numbered);
        let folders = [(); 2].map(|()| create_free(&root, "untitled folder", true).unwrap());
        assert_eq!(folders, ["untitled folder", "untitled folder 2"]);
        assert!(root.join("untitled folder 2").is_dir());
        for bad in [".texlocal.json", "../x.tex"] {
            assert_eq!(create_free(&root, bad, false).unwrap_err().status, 400);
        }
        fs::write(root.join("plain"), "a file").unwrap();
        assert!(create_free(&root, "plain/x.tex", false).is_err());
    }

    #[test]
    fn a_renamed_entry_takes_its_saved_interface_state_along() {
        let (_dir, root) = project();
        let project = Project::in_folder(&root);
        create_free(&root, "chapters/a.tex", false).unwrap();
        let patch = json!({
            "expandedFolders": ["other", "chapters/deep", "chapters"],
            "foldedHeadings": ["main.tex\t1:Intro#1", "chapters/a.tex\t1:Intro#1"],
            "file": "chapters/a.tex",
        });
        write_ui(&project.ui, &patch).unwrap();
        rename_entry(&project, "chapters", "content").unwrap();
        let state = read_ui(&project.ui);
        assert_eq!(state.expanded_folders, ["content", "content/deep", "other"]);
        let folds = ["content/a.tex\t1:Intro#1", "main.tex\t1:Intro#1"];
        assert_eq!(state.folded_headings, folds);
        assert_eq!(state.file.as_deref(), Some("content/a.tex"));
        rename_entry(&project, "content/a.tex", "content/b.tex").unwrap();
        let state = read_ui(&project.ui);
        assert_eq!(
            state.folded_headings,
            ["content/b.tex\t1:Intro#1", "main.tex\t1:Intro#1"]
        );
        assert_eq!(state.file.as_deref(), Some("content/b.tex"));
    }
}
