//! Path safety — the security boundary, ported guard-for-guard from
//! server/projects.js. All user-supplied paths pass through here before any
//! filesystem access, and the normalization is purely lexical: canonicalize()
//! would resolve symlinks and demand existence, which the JS `path.resolve`
//! semantics being mirrored do not.

use std::path::{Path, PathBuf};

use crate::error::CoreError;
use crate::SETTINGS_FILE;

/// True for `/x`, `\x`, and `C:...` forms — anything that doesn't stay
/// relative to the base it's joined onto.
fn is_absolute_like(rel: &str) -> bool {
    let b = rel.as_bytes();
    rel.starts_with('/')
        || rel.starts_with('\\')
        || (b.len() >= 2 && b[1] == b':' && b[0].is_ascii_alphabetic())
}

/// Split a relative path into normalized segments, accepting either separator.
/// `.` segments drop out; `..` pops — popping past the start is an escape.
/// Returns an empty vec for inputs that normalize to the base itself.
fn normalize_segments(rel: &str, escape_err: &str) -> Result<Vec<String>, CoreError> {
    if is_absolute_like(rel) {
        return Err(CoreError::bad_request(escape_err));
    }
    let mut segments: Vec<String> = Vec::new();
    for seg in rel.split(['/', '\\']) {
        match seg {
            "" | "." => {}
            ".." => {
                if segments.pop().is_none() {
                    return Err(CoreError::bad_request(escape_err));
                }
            }
            _ => segments.push(seg.to_string()),
        }
    }
    Ok(segments)
}

/// Resolve a project id to its directory under `data_dir`, rejecting escapes
/// and missing projects. (projects.js `projectRoot`)
pub fn project_root(data_dir: &Path, id: &str) -> Result<PathBuf, CoreError> {
    let segments = normalize_segments(id, "Bad project id")?;
    if segments.is_empty() {
        return Err(CoreError::bad_request("Bad project id"));
    }
    let mut root = data_dir.to_path_buf();
    root.extend(&segments);
    if !root.is_dir() {
        return Err(CoreError::not_found(format!("No such project: {id}")));
    }
    Ok(root)
}

/// Normalized project-relative segments for a user-supplied path, with the
/// reserved-settings-file rule: `.texlocal.json` at the project root is only
/// writable through write_settings, which validates each key — a raw write
/// could flip shellEscape on. (projects.js `safePath`)
fn safe_segments(rel: &str) -> Result<Vec<String>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    if segments.is_empty() {
        return Err(CoreError::bad_request("Path escapes project"));
    }
    if segments.len() == 1 && segments[0] == SETTINGS_FILE {
        return Err(CoreError::bad_request("Reserved file"));
    }
    Ok(segments)
}

/// Absolute path for a user-supplied relative path inside a project.
pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    let mut abs = root.to_path_buf();
    abs.extend(safe_segments(rel)?);
    Ok(abs)
}

/// A path inside the project in a form safe to hand to a command line:
/// relative, no escape, forward slashes, and no segment a tool could read as
/// an option — the main file becomes an argv element for latexmk, where a
/// leading "-" would parse as a flag. (projects.js `safeRelFile`)
pub fn safe_rel_file(root: &Path, rel: &str) -> Result<String, CoreError> {
    let _ = root; // kept for signature parity with the JS original
    let segments = safe_segments(rel)?;
    if segments.iter().any(|s| s.starts_with('-')) {
        return Err(CoreError::bad_request(
            "Path segments cannot start with \"-\"",
        ));
    }
    Ok(segments.join("/"))
}

/// Project-name sanitization. (projects.js `sanitizeName`)
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
    Ok(clean)
}

/// Lexically normalize an absolute path (resolve `.` and `..` without touching
/// the filesystem), for mapping tool output back into a project.
pub fn normalize_abs(path: &Path) -> PathBuf {
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
/// outside. Both are normalized lexically first.
pub fn rel_to_root(root: &Path, abs: &Path) -> Option<String> {
    let abs = normalize_abs(abs);
    let root = normalize_abs(root);
    let rel = abs.strip_prefix(&root).ok()?;
    let parts: Vec<String> = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    if parts.is_empty() {
        return None;
    }
    Some(parts.join("/"))
}
