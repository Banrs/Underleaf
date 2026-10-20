//! Making, moving and discarding the files and folders of a project.

use std::borrow::Cow;
use std::fs;
use std::io::ErrorKind;
use std::path::Path;

use serde::Serialize;
use serde_json::json;

use crate::error::CoreError;
use crate::paths::{after_entry, rel_key, safe_path, safe_write_path, same_entry};
use crate::settings::{move_ui, read_settings, write_settings};
use crate::stamp::Stamp;
use crate::{atomic, lf};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenameResult {
    pub from: String,
    pub to: String,
    pub main_file: String,
}

/// One create that fails on anything there, so an entry another app makes meanwhile is kept.
fn make(root: &Path, rel: &str, dir: bool) -> Result<bool, CoreError> {
    let abs = safe_write_path(root, rel)?;
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
        Err(err) if err.kind() == ErrorKind::AlreadyExists => Ok(false),
        made => made.map(|()| true).map_err(error),
    }
}

pub fn create_free(root: &Path, rel: &str, dir: bool) -> Result<String, CoreError> {
    for path in copy_paths(rel) {
        if make(root, &path, dir)? {
            return Ok(path);
        }
    }
    unreachable!("a free name")
}

/// A document holds `\n` alone, as an editor needs; a write keeps the file's own ending.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Newline {
    Lf,
    CrLf,
    Cr,
}

impl Newline {
    pub fn of(text: &str) -> Self {
        let Some(at) = text.find(['\r', '\n']) else {
            return Self::Lf;
        };
        match &text.as_bytes()[at..] {
            [b'\r', b'\n', ..] => Self::CrLf,
            [b'\r', ..] => Self::Cr,
            _ => Self::Lf,
        }
    }

    pub fn written(self, text: &str) -> Cow<'_, str> {
        let ending = match self {
            Self::Lf if !text.contains('\r') => return Cow::Borrowed(text),
            Self::Lf => return Cow::Owned(lf(text.to_owned())),
            Self::CrLf => "\r\n",
            Self::Cr => "\r",
        };
        Cow::Owned(lf(text.to_owned()).replace('\n', ending))
    }
}

pub(crate) fn write_creating(abs: &Path, contents: &[u8]) -> Result<Stamp, CoreError> {
    abs.parent()
        .map_or(Ok(()), fs::create_dir_all)
        .and_then(|()| atomic::write(abs, contents))
        .map_err(|err| write_error(abs, err))
}

/// A failed write in Foundation's words, as the hosts show it in an alert
/// whose title already says the file wasn't saved; its status is the file
/// system's, as any other.
fn write_error(abs: &Path, err: std::io::Error) -> CoreError {
    let name = |path: &Path| {
        path.file_name()
            .map(|name| name.to_string_lossy().into_owned())
    };
    let file = name(abs).unwrap_or_default();
    let kind = err.kind();
    let fallback = CoreError::from(err);
    let message = match kind {
        ErrorKind::PermissionDenied => {
            let folder = abs.parent().and_then(name).unwrap_or_default();
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

/// Whether a rename from `src` to `dest` would land on another entry. On a
/// case-insensitive volume, the default on macOS and Windows, a case-only
/// rename's destination already "exists" because it is `src` itself.
fn occupied(src: &Path, dest: &Path) -> bool {
    fs::symlink_metadata(dest).is_ok() && !same_entry(src, dest)
}

pub fn rename_entry(root: &Path, from: &str, to: &str) -> Result<RenameResult, CoreError> {
    let src = safe_path(root, from)?;
    let dest = safe_write_path(root, to)?;
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

pub(crate) type Trash = fn(&Path) -> Result<(), CoreError>;

/// Delete to the platform's trash, so a mis-click is recoverable; a trash failure is reported and never becomes a permanent delete.
pub(crate) fn discard(path: &Path) -> Result<(), CoreError> {
    // The system's file manager moves it, as the Mac app does; the crate's Finder-over-Apple-Events default needs the Automation permission.
    #[cfg(target_os = "macos")]
    let trashed = {
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        let mut context = trash::TrashContext::default();
        context.set_delete_method(DeleteMethod::NsFileManager);
        context.delete(path)
    };
    #[cfg(not(target_os = "macos"))]
    let trashed = trash::delete(path);
    trashed.map_err(|err| CoreError::internal(format!("Could not move the item to Trash: {err}")))
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
    fn a_file_ends_its_lines_as_its_first_line_break_does() {
        assert_eq!(Newline::of("a\r\nb\nc"), Newline::CrLf);
        assert_eq!(Newline::of("a\rb"), Newline::Cr);
        assert_eq!(Newline::of("a\nb\r\n"), Newline::Lf);
        assert_eq!(Newline::of("a"), Newline::Lf);
        assert_eq!(Newline::CrLf.written("a\nb\r\nc\rd"), "a\r\nb\r\nc\r\nd");
        assert_eq!(Newline::Cr.written("a\nb"), "a\rb");
        assert_eq!(Newline::Lf.written("a\r\nb"), "a\nb");
        assert!(matches!(Newline::Lf.written("a\nb"), Cow::Borrowed(_)));
    }

    #[cfg(unix)]
    #[test]
    fn a_write_refused_says_so_in_a_sentence_naming_the_file_and_folder() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().join("Thesis");
        fs::create_dir(&folder).unwrap();
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o555)).unwrap();
        let err = write_creating(&folder.join("main.tex"), b"x").unwrap_err();
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            (err.status, err.message.as_str()),
            (
                403,
                "You don’t have permission to save the file “main.tex” in the folder “Thesis”."
            )
        );
    }

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
        for bad in [".texlocal.json", "../x.tex"] {
            assert_eq!(create_free(&root, bad, false).unwrap_err().status, 400);
        }
        fs::write(root.join("plain"), "a file").unwrap();
        assert!(create_free(&root, "plain/x.tex", false).is_err());
    }

    #[test]
    fn a_renamed_entry_takes_its_saved_interface_state_along() {
        let (_dir, root) = project();
        create_free(&root, "chapters/a.tex", false).unwrap();
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
        rename_entry(&root, "content/a.tex", "content/b.tex").unwrap();
        let folds = read_ui(&root).folded_headings;
        assert_eq!(
            folds,
            list(&["content/b.tex\t1:Intro#1", "main.tex\t1:Intro#1"])
        );
    }
}
