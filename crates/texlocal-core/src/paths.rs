//! Path safety — the security boundary, and the only one. User paths are
//! normalized lexically first, then the nearest existing ancestor is resolved
//! so symlinked files and directories cannot redirect an operation outside the
//! project.

use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

/// Split a relative path into normalized segments.
/// `.` segments drop out; `..` pops — popping past the start is an escape.
/// Returns an empty vec for inputs that normalize to the base itself.
pub(crate) fn normalize_segments<'a>(
    rel: &'a str,
    escape_err: &str,
) -> Result<Vec<&'a str>, CoreError> {
    let mut segments = Vec::new();
    for component in Path::new(rel).components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if segments.pop().is_none() {
                    return Err(CoreError::bad_request(escape_err));
                }
            }
            // Components of a UTF-8 input are themselves UTF-8.
            Component::Normal(segment) => segments.push(segment.to_str().unwrap()),
            _ => return Err(CoreError::bad_request(escape_err)),
        }
    }
    Ok(segments)
}

/// Resolve only the closest path component that already exists. This retains
/// lexical path semantics for new files while preventing an existing symlink
/// from redirecting the final operation outside `root`.
/// Returns where `target` leads inside `root`: its physical path relative to the
/// canonical root, the not-yet-existing suffix kept as written.
fn ensure_existing_ancestor_within(
    root: &Path,
    target: &Path,
    escape_err: &str,
) -> Result<PathBuf, CoreError> {
    let canonical_root = fs::canonicalize(root)?;
    let mut existing = target;
    loop {
        match fs::symlink_metadata(existing) {
            Ok(_) => break,
            // A file where the path wants a folder ends the path there too.
            Err(err)
                if matches!(
                    err.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                existing = existing
                    .parent()
                    .ok_or_else(|| CoreError::bad_request(escape_err))?;
            }
            Err(err) => return Err(err.into()),
        }
    }

    let resolved = fs::canonicalize(existing).map_err(|_| CoreError::bad_request(escape_err))?;
    let Ok(inside) = resolved.strip_prefix(&canonical_root) else {
        return Err(CoreError::bad_request(escape_err));
    };
    let suffix = target.strip_prefix(existing).unwrap_or(Path::new(""));
    // Collected, so a whole existing path keeps no trailing slash.
    Ok(inside.join(suffix).components().collect())
}

/// Resolve a project id to its directory under `data_dir`, rejecting escapes,
/// symlink aliases outside the data directory, and missing projects. A project
/// is one folder directly under `data_dir`, as list_projects reports it: a
/// nested id would let the project commands rename, trash or compile a folder
/// inside another project, past delete_entry's main-file guard.
pub fn project_root(data_dir: &Path, id: &str) -> Result<PathBuf, CoreError> {
    let root = data_dir.join(project_name(id)?);
    if !root.is_dir() {
        return Err(CoreError::not_found(format!("No such project: {id}")));
    }
    ensure_existing_ancestor_within(data_dir, &root, "Bad project id")?;
    Ok(root)
}

/// A project id's one folder name, read without the disk.
pub(crate) fn project_name(id: &str) -> Result<&str, CoreError> {
    match normalize_segments(id, "Bad project id")?[..] {
        [name] => Ok(name),
        _ => Err(CoreError::bad_request("Bad project id")),
    }
}

/// Normalized project-relative segments for a user-supplied path, with the
/// reserved-settings-file rule: `.texlocal.json` at the project root is only
/// writable through write_settings, which validates each key. Its case
/// aliases are reserved since macOS volumes are usually case-insensitive and
/// the boundary must not depend on the volume.
fn safe_segments(rel: &str) -> Result<Vec<&str>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    if segments.is_empty() {
        return Err(CoreError::bad_request("Path escapes project"));
    }
    if is_settings_file(&segments) {
        return Err(CoreError::bad_request("Reserved file"));
    }
    Ok(segments)
}

fn is_settings_file(segments: &[&str]) -> bool {
    segments.len() == 1 && segments[0].eq_ignore_ascii_case(SETTINGS_FILE)
}

fn is_in_build_dir(segments: &[&str]) -> bool {
    segments
        .first()
        .is_some_and(|first| first.eq_ignore_ascii_case(BUILD_DIR))
}

/// Segments of a path relative to the project root, as `ensure_existing_ancestor_within` gives it.
fn physical_segments(path: &Path) -> Vec<&str> {
    path.components()
        .filter_map(|c| match c {
            Component::Normal(s) => s.to_str(),
            _ => None,
        })
        .collect()
}

/// `segments` joined onto `root`, provided no existing link leads out of it, nor to the
/// settings file, nor, for a write, into the build folder: a link inside the project is
/// held to the rules its target's own path is. Also where the path physically leads,
/// relative to the resolved root.
fn join_within(
    root: &Path,
    segments: &[&str],
    write: bool,
) -> Result<(PathBuf, PathBuf), CoreError> {
    let mut abs = root.to_path_buf();
    abs.extend(segments);
    let physical = ensure_existing_ancestor_within(root, &abs, "Path escapes project")?;
    let physical_segments = physical_segments(&physical);
    if is_settings_file(&physical_segments) {
        return Err(CoreError::bad_request("Reserved file"));
    }
    if write && is_in_build_dir(&physical_segments) {
        return Err(build_dir_err());
    }
    Ok((abs, physical))
}

fn build_dir_err() -> CoreError {
    CoreError::bad_request("“build” holds the compiled PDF. Choose another name.")
}

/// Absolute path for a user-supplied relative path inside a project.
pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(join_within(root, &safe_segments(rel)?, false)?.0)
}

/// `safe_path` for a path about to be created or written. The project's
/// top-level `build` folder holds compile output, so no file or folder of the
/// author's may take that name, in any case: on a case-insensitive volume
/// `Build` is the same folder, and the tree hides it.
pub fn safe_write_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(write_paths(root, rel)?.0)
}

/// `safe_write_path`, and where the write physically lands, through any link
/// on its way, relative to the resolved root.
pub(crate) fn write_paths(root: &Path, rel: &str) -> Result<(PathBuf, PathBuf), CoreError> {
    let segments = safe_segments(rel)?;
    if is_in_build_dir(&segments) {
        return Err(build_dir_err());
    }
    join_within(root, &segments, true)
}

/// A path as the volume compares it: macOS volumes usually ignore case.
pub(crate) fn fold_case(path: &str) -> String {
    if cfg!(target_os = "macos") {
        path.to_lowercase()
    } else {
        path.to_owned()
    }
}

/// The normalized forward-slash spelling of a user-supplied project path, for
/// comparing it with a stored one such as the main file. It checks nothing on
/// disk: pair it with `safe_path`, and use `safe_rel_file` for anything that
/// reaches a command line.
pub fn rel_key(rel: &str) -> Result<String, CoreError> {
    Ok(safe_segments(rel)?.join("/"))
}

/// A path inside the project in a form safe to hand to a command line:
/// relative, no escape, forward slashes, no symlink escape, and no segment a
/// tool could read as an option.
pub fn safe_rel_file(root: &Path, rel: &str) -> Result<String, CoreError> {
    let segments = safe_segments(rel)?;
    if segments.iter().any(|s| s.starts_with('-')) {
        return Err(CoreError::bad_request(
            "Path segments cannot start with \"-\"",
        ));
    }
    join_within(root, &segments, false)?;
    Ok(segments.join("/"))
}

pub fn sanitize_name(name: &str) -> Result<String, CoreError> {
    let clean: String = name.trim().chars().filter(|&c| c != '/').take(80).collect();
    if clean.is_empty() || clean.starts_with('.') {
        return Err(CoreError::bad_request("Invalid name"));
    }
    Ok(clean)
}

/// Lexically normalize an absolute path (resolve `.` and `..` without touching
/// the filesystem), for mapping tool output back into a project.
fn normalize_abs(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
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
