//! Path safety — the security boundary, and the only one. User paths are
//! normalized lexically first, then the nearest existing ancestor is resolved
//! so symlinked files and directories cannot redirect an operation outside the
//! project.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::CoreError;
use crate::SETTINGS_FILE;

/// True for `/x`, `\\x`, and `C:...` forms — anything that doesn't stay
/// relative to the base it's joined onto.
fn is_absolute_like(rel: &str) -> bool {
    let b = rel.as_bytes();
    rel.starts_with('/')
        || rel.starts_with('\\')
        || (b.len() >= 2 && b[1] == b':' && b[0].is_ascii_alphabetic())
}

#[cfg(windows)]
fn invalid_windows_segment(segment: &str) -> bool {
    if segment.ends_with(' ') || segment.ends_with('.') {
        return true;
    }
    if segment
        .chars()
        .any(|c| c <= '\u{1f}' || matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*'))
    {
        return true;
    }

    // Device names are reserved even when an extension is present (CON.tex,
    // LPT1.log, and so on).
    let stem = segment
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || stem
        .strip_prefix("COM")
        .or_else(|| stem.strip_prefix("LPT"))
        .is_some_and(|n| {
            matches!(
                n,
                "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            )
        })
}

fn validate_platform_segment(segment: &str, error: &str) -> Result<(), CoreError> {
    #[cfg(windows)]
    if invalid_windows_segment(segment) {
        return Err(CoreError::bad_request(error));
    }
    let _ = (segment, error);
    Ok(())
}

/// Split a relative path into normalized segments, accepting either separator.
/// `.` segments drop out; `..` pops — popping past the start is an escape.
/// Returns an empty vec for inputs that normalize to the base itself.
fn normalize_segments<'a>(rel: &'a str, escape_err: &str) -> Result<Vec<&'a str>, CoreError> {
    if is_absolute_like(rel) {
        return Err(CoreError::bad_request(escape_err));
    }
    let mut segments = Vec::new();
    for seg in rel.split(['/', '\\']) {
        match seg {
            "" | "." => {}
            ".." => {
                if segments.pop().is_none() {
                    return Err(CoreError::bad_request(escape_err));
                }
            }
            _ => {
                validate_platform_segment(seg, escape_err)?;
                segments.push(seg);
            }
        }
    }
    Ok(segments)
}

/// Resolve only the closest path component that already exists. This retains
/// lexical path semantics for new files while preventing an existing symlink or
/// junction from redirecting the final operation outside `root`.
fn ensure_existing_ancestor_within(
    root: &Path,
    target: &Path,
    escape_err: &str,
) -> Result<(), CoreError> {
    let canonical_root = fs::canonicalize(root)?;
    let mut existing = target;
    loop {
        match fs::symlink_metadata(existing) {
            Ok(_) => break,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                existing = existing
                    .parent()
                    .ok_or_else(|| CoreError::bad_request(escape_err))?;
            }
            Err(err) => return Err(err.into()),
        }
    }

    let resolved = fs::canonicalize(existing).map_err(|_| CoreError::bad_request(escape_err))?;
    if !resolved.starts_with(&canonical_root) {
        return Err(CoreError::bad_request(escape_err));
    }
    Ok(())
}

/// Resolve a project id to its directory under `data_dir`, rejecting escapes,
/// symlink aliases outside the data directory, and missing projects. A project
/// is one folder directly under `data_dir`, as list_projects reports it: a
/// nested id would let the project commands rename, trash or compile a folder
/// inside another project, past delete_entry's main-file guard.
pub fn project_root(data_dir: &Path, id: &str) -> Result<PathBuf, CoreError> {
    let segments = normalize_segments(id, "Bad project id")?;
    if segments.len() != 1 {
        return Err(CoreError::bad_request("Bad project id"));
    }
    let mut root = data_dir.to_path_buf();
    root.extend(&segments);
    if !root.is_dir() {
        return Err(CoreError::not_found(format!("No such project: {id}")));
    }
    ensure_existing_ancestor_within(data_dir, &root, "Bad project id")?;
    Ok(root)
}

/// Normalized project-relative segments for a user-supplied path, with the
/// reserved-settings-file rule: `.texlocal.json` at the project root is only
/// writable through write_settings, which validates each key. Its case
/// aliases are reserved on every platform, since Windows and macOS volumes are
/// usually case-insensitive and the boundary must not depend on the volume.
fn safe_segments(rel: &str) -> Result<Vec<&str>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    if segments.is_empty() {
        return Err(CoreError::bad_request("Path escapes project"));
    }
    if segments.len() == 1 && segments[0].eq_ignore_ascii_case(SETTINGS_FILE) {
        return Err(CoreError::bad_request("Reserved file"));
    }
    Ok(segments)
}

/// `segments` joined onto `root`, provided no existing link leads out of it.
fn join_within(root: &Path, segments: &[&str]) -> Result<PathBuf, CoreError> {
    let mut abs = root.to_path_buf();
    abs.extend(segments);
    ensure_existing_ancestor_within(root, &abs, "Path escapes project")?;
    Ok(abs)
}

/// Absolute path for a user-supplied relative path inside a project.
pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    join_within(root, &safe_segments(rel)?)
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
    join_within(root, &segments)?;
    Ok(segments.join("/"))
}

/// Project-name sanitization.
pub fn sanitize_name(name: &str) -> Result<String, CoreError> {
    const STRIP: &[char] = &['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
    let clean: String = name
        .trim()
        .chars()
        .filter(|c| !STRIP.contains(c))
        .take(80)
        .collect();
    if clean.is_empty() || clean.starts_with('.') {
        return Err(CoreError::bad_request("Invalid name"));
    }
    validate_platform_segment(&clean, "Invalid name")?;
    Ok(clean)
}

/// Lexically normalize an absolute path (resolve `.` and `..` without touching
/// the filesystem), for mapping tool output back into a project.
fn normalize_abs(path: &Path) -> PathBuf {
    use std::path::Component;
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
