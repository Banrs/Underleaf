//! Path safety — the security boundary, ported guard-for-guard from
//! server/projects.js. User paths are normalized lexically first, then the
//! nearest existing ancestor is resolved so symlinked files and directories
//! cannot redirect an operation outside the project.

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
    ) || stem.strip_prefix("COM").is_some_and(|n| {
        matches!(
            n,
            "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
        )
    }) || stem.strip_prefix("LPT").is_some_and(|n| {
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

fn component_eq(a: &str, b: &str) -> bool {
    // The protected settings name is ASCII and commonly lives on
    // case-insensitive Windows and macOS volumes. Reserving its case aliases on
    // every platform is conservative and keeps the boundary independent of the
    // host volume's case-sensitivity setting.
    a.eq_ignore_ascii_case(b)
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
            _ => {
                validate_platform_segment(seg, escape_err)?;
                segments.push(seg.to_string());
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
    if resolved != canonical_root && !resolved.starts_with(&canonical_root) {
        return Err(CoreError::bad_request(escape_err));
    }
    Ok(())
}

/// Resolve a project id to its directory under `data_dir`, rejecting escapes,
/// symlink aliases outside the data directory, and missing projects.
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
    ensure_existing_ancestor_within(data_dir, &root, "Bad project id")?;
    Ok(root)
}

/// Normalized project-relative segments for a user-supplied path, with the
/// reserved-settings-file rule: `.texlocal.json` at the project root is only
/// writable through write_settings, which validates each key. Windows path
/// aliases are compared case-insensitively.
fn safe_segments(rel: &str) -> Result<Vec<String>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    if segments.is_empty() {
        return Err(CoreError::bad_request("Path escapes project"));
    }
    if segments.len() == 1 && component_eq(&segments[0], SETTINGS_FILE) {
        return Err(CoreError::bad_request("Reserved file"));
    }
    Ok(segments)
}

/// Absolute path for a user-supplied relative path inside a project.
pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    let mut abs = root.to_path_buf();
    abs.extend(safe_segments(rel)?);
    ensure_existing_ancestor_within(root, &abs, "Path escapes project")?;
    Ok(abs)
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
    let mut abs = root.to_path_buf();
    abs.extend(&segments);
    ensure_existing_ancestor_within(root, &abs, "Path escapes project")?;
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
    validate_platform_segment(&clean, "Invalid name")?;
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
