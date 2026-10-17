//! Making, moving and discarding the files and folders of a project.

use std::fs;
use std::path::Path;

use serde::Serialize;
use serde_json::json;

use crate::atomic;
use crate::error::CoreError;
use crate::paths::{after_entry, rel_key, safe_path, safe_write_path, same_entry};
use crate::settings::{move_ui, read_settings, write_settings};
use crate::stamp::Stamp;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenameResult {
    pub from: String,
    pub to: String,
    pub main_file: String,
}

/// Make the file or folder `rel`, unless something is there already: whether
/// it was made.
fn make(root: &Path, rel: &str, dir: bool) -> Result<bool, CoreError> {
    let abs = safe_write_path(root, rel)?;
    if abs.exists() {
        return Ok(false);
    }
    if dir {
        fs::create_dir_all(&abs)?;
    } else {
        write_creating(&abs, b"")?;
    }
    Ok(true)
}

pub fn create_file(root: &Path, rel: &str, dir: bool) -> Result<(), CoreError> {
    if make(root, rel, dir)? {
        Ok(())
    } else {
        Err(CoreError::conflict("Already exists"))
    }
}

/// `create_file`, numbered past the names taken as Finder numbers copies
/// ("untitled.tex", "untitled 2.tex"); the path made.
pub fn create_free(root: &Path, rel: &str, dir: bool) -> Result<String, CoreError> {
    for path in copy_paths(rel) {
        if make(root, &path, dir)? {
            return Ok(path);
        }
    }
    unreachable!("a free name")
}

pub(crate) fn write_creating(abs: &Path, contents: &[u8]) -> Result<Stamp, CoreError> {
    if let Some(parent) = abs.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(atomic::write(abs, contents)?)
}

/// Whether `path` lies inside the folder `dir`, not as `dir` itself.
fn is_under(path: &str, dir: &str) -> bool {
    after_entry(path, dir).is_some_and(|rest| !rest.is_empty())
}

/// Whether a rename from `src` to `dest` would land on another entry. On a
/// case-insensitive volume, the default on macOS and Windows, a case-only
/// rename's destination already "exists" because it is `src` itself.
fn occupied(src: &Path, dest: &Path) -> bool {
    fs::symlink_metadata(dest).is_ok() && !same_entry(src, dest)
}

pub fn rename_entry(root: &Path, from: &str, to: &str) -> Result<RenameResult, CoreError> {
    let src = safe_path(root, from)?;
    let dest = safe_write_path(root, to)?;
    // Only compared with the main file, never passed to a tool, so a name
    // starting with "-" is as renameable here as create_entry made it.
    let from_rel = rel_key(from)?;
    let to_rel = rel_key(to)?;
    if fs::symlink_metadata(&src).is_err() {
        return Err(CoreError::not_found("Not found"));
    }
    if occupied(&src, &dest) {
        return Err(CoreError::conflict("Destination already exists"));
    }
    if is_under(&to_rel, &from_rel) {
        return Err(CoreError::bad_request(
            "A folder can't be moved into itself",
        ));
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }

    let main_file = read_settings(root).main_file;
    // Each project path's new one, None for one the rename leaves.
    let moved = |path: &str| after_entry(path, &from_rel).map(|rest| format!("{to_rel}{rest}"));
    let moved_main = moved(&main_file);
    fs::rename(&src, &dest)?;
    if let Some(main_file) = &moved_main
        && let Err(settings_err) = write_settings(root, &json!({ "mainFile": main_file }))
    {
        if let Err(rollback_err) = fs::rename(&dest, &src) {
            return Err(CoreError::internal(format!(
                "{}; rename rollback failed: {}",
                settings_err.message, rollback_err
            )));
        }
        return Err(settings_err);
    }
    move_ui(root, moved);

    Ok(RenameResult {
        from: from_rel,
        to: to_rel,
        main_file: moved_main.unwrap_or(main_file),
    })
}

/// How an entry is discarded: to the platform's Trash, or in a test, wherever
/// the test says.
pub(crate) type Trash = fn(&Path) -> Result<(), CoreError>;

/// Delete to the platform's trash, so a mis-click is recoverable. A trash
/// failure is reported and the original is left in place; it must never become
/// an implicit permanent-delete request.
pub(crate) fn discard(path: &Path) -> Result<(), CoreError> {
    trash::delete(path)
        .map_err(|err| CoreError::internal(format!("Could not move the item to Trash: {err}")))
}

/// Discard, by `trash`, an entry an incoming file of its name replaces. The
/// main file may go, since the file taking its place keeps it valid; a folder
/// holding it may not, however the upload spells its name.
pub(crate) fn discard_replaced(root: &Path, rel: &str, trash: Trash) -> Result<(), CoreError> {
    if is_under(&read_settings(root).main_file, rel) {
        return Err(CoreError::conflict(
            "Choose a different main file before replacing this folder",
        ));
    }
    trash(&safe_path(root, rel)?)
}

/// The paths an entry's copies take in turn in its folder, as Finder numbers
/// them: `rel`, then "main 2.tex", "main 3.tex"… or "figures 2", "figures 3"…
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
    use crate::settings::{UiPatch, UiState, read_ui, write_ui};

    #[test]
    fn a_new_entry_takes_the_next_free_name() {
        let (_dir, root) = project();
        let made: Vec<_> = (0..3)
            .map(|_| create_free(&root, "notes/untitled.tex", false).unwrap())
            .collect();
        assert_eq!(
            made,
            [
                "notes/untitled.tex",
                "notes/untitled 2.tex",
                "notes/untitled 3.tex"
            ]
        );
        let folders: Vec<_> = (0..2)
            .map(|_| create_free(&root, "untitled folder", true).unwrap())
            .collect();
        assert_eq!(folders, ["untitled folder", "untitled folder 2"]);
        assert!(root.join("untitled folder 2").is_dir());
        // Names the path rules refuse are refused, not numbered.
        for bad in [".texlocal.json", "../x.tex"] {
            assert_eq!(create_free(&root, bad, false).unwrap_err().status, 400);
        }
        // So is a folder where the path wants a file's: not numbered past.
        fs::write(root.join("plain"), "a file").unwrap();
        assert!(create_free(&root, "plain/x.tex", false).is_err());
    }

    #[test]
    fn a_renamed_entry_takes_its_saved_interface_state_along() {
        let (_dir, root) = project();
        create_file(&root, "chapters/a.tex", false).unwrap();
        let list = |names: &[&str]| names.iter().map(ToString::to_string).collect::<Vec<_>>();
        write_ui(
            &root,
            UiPatch {
                expanded_folders: Some(list(&["other", "chapters/deep", "chapters"])),
                folded_headings: Some(list(&["main.tex\t1:Intro#1", "chapters/a.tex\t1:Intro#1"])),
            },
        )
        .unwrap();
        rename_entry(&root, "chapters", "content").unwrap();
        assert_eq!(
            read_ui(&root),
            UiState {
                expanded_folders: list(&["content", "content/deep", "other"]),
                folded_headings: list(&["content/a.tex\t1:Intro#1", "main.tex\t1:Intro#1"]),
            }
        );
        // A file's fold follows it alone.
        rename_entry(&root, "content/a.tex", "content/b.tex").unwrap();
        let folds = read_ui(&root).folded_headings;
        assert_eq!(
            folds,
            list(&["content/b.tex\t1:Intro#1", "main.tex\t1:Intro#1"])
        );
    }
}
