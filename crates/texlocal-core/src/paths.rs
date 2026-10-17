//! Path safety — the security boundary, and the only one. User paths are
//! normalized lexically first, then the nearest existing ancestor is resolved
//! so symlinked files and directories cannot redirect an operation outside the
//! project.

use std::fs;
use std::io::ErrorKind::{NotADirectory, NotFound};
use std::path::{Component, Path, PathBuf};

use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

/// Split a relative path into normalized segments: `.` drops out, `..` pops,
/// and popping past the start (or any root or prefix) is an escape. Empty for
/// inputs that normalize to the base itself.
pub(crate) fn normalize_segments<'a>(
    rel: &'a str,
    escape_err: &str,
) -> Result<Vec<&'a str>, CoreError> {
    let mut segments = Vec::new();
    for component in Path::new(rel).components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir if segments.pop().is_some() => {}
            // Components of a UTF-8 input are themselves UTF-8.
            Component::Normal(segment) => segments.push(segment.to_str().unwrap()),
            _ => return Err(CoreError::bad_request(escape_err)),
        }
    }
    Ok(segments)
}

/// Where `target` leads inside `root`: its physical path relative to the
/// canonical root, the not-yet-existing suffix kept as written. Only the
/// closest component that exists is resolved, which keeps lexical semantics
/// for new files while an existing symlink cannot redirect the operation
/// outside `root`.
fn physical_within(root: &Path, target: &Path, escape_err: &str) -> Result<PathBuf, CoreError> {
    let escape = || CoreError::bad_request(escape_err);
    let canonical_root = dunce::canonicalize(root)?;
    let mut existing = target;
    while let Err(err) = fs::symlink_metadata(existing) {
        // A file where the path wants a folder ends the path there too.
        if !matches!(err.kind(), NotFound | NotADirectory) {
            return Err(err.into());
        }
        existing = existing.parent().ok_or_else(escape)?;
    }
    let resolved = dunce::canonicalize(existing).map_err(|_| escape())?;
    let inside = resolved
        .strip_prefix(&canonical_root)
        .map_err(|_| escape())?;
    let suffix = target.strip_prefix(existing).unwrap_or(Path::new(""));
    // Collected, so a whole existing path keeps no trailing slash.
    Ok(inside.join(suffix).components().collect())
}

/// Resolve a project id to its directory under `data_dir`, rejecting escapes, symlink
/// aliases outside it and missing projects. A project is one folder directly under
/// `data_dir`, as list_projects reports it: a nested id would let project commands
/// rename, trash or compile a folder inside another project.
pub fn project_root(data_dir: &Path, id: &str) -> Result<PathBuf, CoreError> {
    let root = data_dir.join(project_name(id)?);
    if !root.is_dir() {
        return Err(CoreError::not_found(format!("No such project: {id}")));
    }
    physical_within(data_dir, &root, "Bad project id")?;
    Ok(root)
}

/// A project id's one folder name, read without the disk.
pub(crate) fn project_name(id: &str) -> Result<&str, CoreError> {
    match normalize_segments(id, "Bad project id")?[..] {
        [name] => Ok(name),
        _ => Err(CoreError::bad_request("Bad project id")),
    }
}

/// The names a user path may not take. `.texlocal.json` at the project root is
/// only writable through write_settings, which validates each key; its case
/// aliases are reserved since macOS volumes are usually case-insensitive and
/// the boundary must not depend on the volume. The top-level `build` folder
/// holds compile output, so nothing the author writes may take that name, in
/// any case: on a case-insensitive volume `Build` is the same folder.
fn check_reserved<S: AsRef<str>>(segments: &[S], write: bool) -> Result<(), CoreError> {
    let first = segments.first().map(AsRef::as_ref).unwrap_or_default();
    if segments.len() == 1 && first.eq_ignore_ascii_case(SETTINGS_FILE) {
        return Err(CoreError::bad_request("Reserved file"));
    }
    if write && first.eq_ignore_ascii_case(BUILD_DIR) {
        return Err(CoreError::bad_request(
            "“build” holds the compiled PDF. Choose another name.",
        ));
    }
    Ok(())
}

/// The normalized segments of a user path, which name something in the
/// project other than a reserved name.
fn user_segments(rel: &str, write: bool) -> Result<Vec<&str>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    if segments.is_empty() {
        return Err(CoreError::bad_request("Path escapes project"));
    }
    check_reserved(&segments, write)?;
    Ok(segments)
}

/// `rel` joined onto `root`, provided no existing link leads out of it, nor
/// to a reserved name: a link inside the project is held to the rules its
/// target's own path is. Also where the path physically leads, relative to
/// the resolved root.
fn join_within(root: &Path, rel: &str, write: bool) -> Result<(PathBuf, PathBuf), CoreError> {
    let segments = user_segments(rel, write)?;
    let mut abs = root.to_path_buf();
    abs.extend(&segments);
    let physical = physical_within(root, &abs, "Path escapes project")?;
    let names: Vec<_> = physical.iter().map(|name| name.to_string_lossy()).collect();
    check_reserved(&names, write)?;
    Ok((abs, physical))
}

/// Absolute path for a user-supplied relative path inside a project.
pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(join_within(root, rel, false)?.0)
}

/// `safe_path` for a path about to be created or written, which may not be
/// in the top-level `build` folder, nor lead into it through a link.
pub fn safe_write_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(join_within(root, rel, true)?.0)
}

/// `safe_write_path`, and where the write physically lands, through any link
/// on its way, relative to the resolved root.
pub(crate) fn write_paths(root: &Path, rel: &str) -> Result<(PathBuf, PathBuf), CoreError> {
    join_within(root, rel, true)
}

/// A path as the volume compares it: macOS and Windows volumes usually
/// ignore case.
pub(crate) fn fold_case(path: &str) -> String {
    if cfg!(any(target_os = "macos", windows)) {
        path.to_lowercase()
    } else {
        path.to_owned()
    }
}

/// Whether `path` is the entry `entry` or inside it, both forward-slash project
/// paths with names spelt as the core listed or made them: open documents'
/// paths, and the paths a rename or delete names.
pub(crate) fn within(path: &str, entry: &str) -> bool {
    path.strip_prefix(entry)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

/// What follows the entry `entry` in `path`, both forward-slash project
/// paths, with names compared as the volume compares them (`fold_case`), for a
/// path as a user or the settings file spells it, such as the main file: ""
/// for the entry itself, "/…" for a path inside it, None for any other.
pub(crate) fn after_entry<'a>(path: &'a str, entry: &str) -> Option<&'a str> {
    let mut rest = path;
    for (i, name) in entry.split('/').enumerate() {
        if i > 0 {
            rest = rest.strip_prefix('/')?;
        }
        let end = rest.find('/').unwrap_or(rest.len());
        if fold_case(&rest[..end]) != fold_case(name) {
            return None;
        }
        rest = &rest[end..];
    }
    Some(rest)
}

/// The normalized forward-slash spelling of a user-supplied project path, for
/// comparing it with a stored one such as the main file. It checks nothing on
/// disk: pair it with `safe_path`, and use `safe_rel_file` for anything that
/// reaches a command line.
pub fn rel_key(rel: &str) -> Result<String, CoreError> {
    Ok(user_segments(rel, false)?.join("/"))
}

/// A path inside the project in a form safe to hand to a command line:
/// relative, no escape, forward slashes, no symlink escape, and no segment a
/// tool could read as an option.
pub fn safe_rel_file(root: &Path, rel: &str) -> Result<String, CoreError> {
    let key = rel_key(rel)?;
    if key.split('/').any(|segment| segment.starts_with('-')) {
        return Err(CoreError::bad_request(
            "Path segments cannot start with \"-\"",
        ));
    }
    join_within(root, &key, false)?;
    Ok(key)
}

/// A name for a new folder in the library: one name, without the characters
/// the volume refuses in it (on Windows, also `<>:"|?*` and controls, and
/// the dots and spaces at the end it drops).
pub fn sanitize_name(name: &str) -> Result<String, CoreError> {
    let refused = |c: char| {
        std::path::is_separator(c) || (cfg!(windows) && (c.is_control() || "<>:\"|?*".contains(c)))
    };
    let mut clean: String = name
        .trim()
        .chars()
        .filter(|&c| !refused(c))
        .take(80)
        .collect();
    if cfg!(windows) {
        clean.truncate(clean.trim_end_matches(['.', ' ']).len());
    }
    if clean.is_empty() || clean.starts_with('.') {
        return Err(CoreError::bad_request("Invalid name"));
    }
    Ok(clean)
}

/// `path` with `.` and `..` resolved without touching the filesystem, for
/// mapping tool output back into a project.
fn normalize_abs(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// The forward-slash relative path of `abs` inside `root`, or None if it lies
/// outside or is the root itself. Both are normalized lexically first.
pub fn rel_to_root(root: &Path, abs: &Path) -> Option<String> {
    let abs = normalize_abs(abs);
    let rel = abs.strip_prefix(normalize_abs(root)).ok()?;
    let parts: Vec<_> = rel.iter().map(|part| part.to_string_lossy()).collect();
    (!parts.is_empty()).then(|| parts.join("/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_compare_as_the_project_lists_them() {
        assert!(within("a/b", "a") && within("a", "a") && !within("ab", "a"));
        assert_eq!(after_entry("a/b/c", "a/b"), Some("/c"));
        assert_eq!(after_entry("a/b", "a/b"), Some(""));
        assert_eq!(after_entry("ab", "a"), None);
        let folds = cfg!(any(target_os = "macos", windows));
        assert_eq!(after_entry("A/B.tex", "a").is_some(), folds);
    }

    #[test]
    fn a_folder_name_is_one_clean_name() {
        assert_eq!(sanitize_name("  My paper ").unwrap(), "My paper");
        assert_eq!(sanitize_name("a/b").unwrap(), "ab");
        assert_eq!(sanitize_name(&"x".repeat(100)).unwrap().len(), 80);
        for bad in ["", "  ", ".hidden", "/"] {
            assert_eq!(sanitize_name(bad).unwrap_err().status, 400, "{bad}");
        }
    }

    #[test]
    fn reserved_names_are_refused_in_any_case_and_build_only_for_writes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        assert_eq!(
            rel_key("./a/../.TeXLocal.JSON").unwrap_err().message,
            "Reserved file"
        );
        assert!(safe_path(root, "Build/main.pdf").is_ok());
        assert!(safe_write_path(root, "BUILD/main.pdf").is_err());
        assert!(safe_write_path(root, "sub/build/main.tex").is_ok());
    }
}
