//! Project and file management. Every project is a directory under the data
//! dir; all returned paths use forward slashes.

use std::fmt::Display;
use std::fs;
use std::path::Path;
use std::time::{Duration, UNIX_EPOCH};

use serde::Serialize;
use serde_json::json;

use crate::error::CoreError;
use crate::paths::{project_root, safe_path, sanitize_name};
use crate::settings::{read_settings, write_settings};
use crate::templates;
use crate::BUILD_DIR;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectInfo {
    pub id: String,
    pub name: String,
    pub mtime: u64,
    pub main_file: String,
}

#[derive(Debug, Serialize)]
pub struct TreeNode {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub name: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<TreeNode>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenameResult {
    pub ok: bool,
    pub from: String,
    pub to: String,
    pub main_file: String,
}

#[derive(Debug, Serialize)]
pub struct SearchHit {
    pub file: String,
    pub line: u32,
    pub before: String,
    #[serde(rename = "match")]
    pub matched: String,
    pub after: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Symbols {
    pub citations: Vec<String>,
    pub labels: Vec<String>,
}

/// One scannable file's identity for cache invalidation: (rel path, mtime ns, len).
pub type FileStamp = (String, u64, u64);

fn since_epoch(meta: &fs::Metadata) -> Option<Duration> {
    meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()
}

fn mtime_ms(meta: &fs::Metadata) -> u64 {
    since_epoch(meta).map_or(0, |d| d.as_millis() as u64)
}

fn mtime_ns(meta: &fs::Metadata) -> u64 {
    since_epoch(meta).map_or(0, |d| u64::try_from(d.as_nanos()).unwrap_or(0))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum EntryKind {
    File,
    Dir,
    Skip,
}

// Directory symlinks are skipped to prevent cycles. File symlinks are retained
// only when their resolved target remains inside the canonical project root.
fn classify_entry(root_canonical: &Path, entry: &fs::DirEntry) -> Result<EntryKind, CoreError> {
    let file_type = entry.file_type()?;
    if file_type.is_dir() {
        return Ok(EntryKind::Dir);
    }
    if file_type.is_file() {
        return Ok(EntryKind::File);
    }
    if !file_type.is_symlink() {
        return Ok(EntryKind::Skip);
    }

    let target = match fs::canonicalize(entry.path()) {
        Ok(target) => target,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(EntryKind::Skip),
        Err(err) => return Err(err.into()),
    };
    if target != root_canonical && !target.starts_with(root_canonical) {
        return Ok(EntryKind::Skip);
    }
    Ok(if fs::metadata(entry.path())?.is_file() {
        EntryKind::File
    } else {
        // Following a directory link can duplicate trees or recurse forever.
        EntryKind::Skip
    })
}

/// Every content file in the project, depth-first, with its project-relative
/// path. Search, symbol scanning and fingerprinting all walk through here, so
/// they cannot disagree about what a project contains: dotfiles are hidden,
/// the top-level `build/` is compile output rather than content, and links are
/// followed only while they stay inside the project.
///
/// The visitor returns false to stop the walk — search uses that to stop
/// reading files once it has the hits it was asked for.
fn visit_files(
    root: &Path,
    visit: &mut dyn FnMut(&Path, String) -> Result<bool, CoreError>,
) -> Result<(), CoreError> {
    fn walk(
        root_canonical: &Path,
        dir: &Path,
        prefix: &str,
        visit: &mut dyn FnMut(&Path, String) -> Result<bool, CoreError>,
    ) -> Result<bool, CoreError> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let rel = if prefix.is_empty() {
                name
            } else {
                format!("{prefix}/{name}")
            };
            // Only the project's own build directory holds compile output. A
            // `build` deeper in the tree is the author's, and both the file
            // tree and the ZIP export keep it, so the scans must too.
            if rel == BUILD_DIR {
                continue;
            }
            match classify_entry(root_canonical, &entry)? {
                EntryKind::Dir => {
                    if !walk(root_canonical, &entry.path(), &rel, visit)? {
                        return Ok(false);
                    }
                }
                EntryKind::File => {
                    if !visit(&entry.path(), rel)? {
                        return Ok(false);
                    }
                }
                EntryKind::Skip => {}
            }
        }
        Ok(true)
    }

    walk(&fs::canonicalize(root)?, root, "", visit)?;
    Ok(())
}

/// A project-relative path's extension, lowercased.
fn ext_of(rel: &str) -> String {
    Path::new(rel)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

pub fn list_projects(data_dir: &Path) -> Result<Vec<ProjectInfo>, CoreError> {
    let mut projects = Vec::new();
    for entry in fs::read_dir(data_dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || !entry.file_type()?.is_dir() {
            continue;
        }
        let root = data_dir.join(&name);
        let meta = fs::metadata(&root)?;
        let settings = read_settings(&root);
        projects.push(ProjectInfo {
            id: name.clone(),
            name,
            mtime: mtime_ms(&meta),
            main_file: settings.main_file,
        });
    }
    projects.sort_by_key(|p| std::cmp::Reverse(p.mtime));
    Ok(projects)
}

pub fn create_project(
    data_dir: &Path,
    name: &str,
    template: &str,
) -> Result<ProjectInfo, CoreError> {
    let clean = sanitize_name(name)?;
    let root = data_dir.join(&clean);
    if root.exists() {
        return Err(CoreError::conflict(
            "A project with that name already exists",
        ));
    }
    let files = templates::files(template);
    fs::create_dir_all(&root)?;
    for (rel, content) in files {
        let abs = safe_path(&root, rel)?;
        if let Some(parent) = abs.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(abs, content)?;
    }
    write_settings(&root, &json!({}))?;
    let meta = fs::metadata(&root)?;
    let settings = read_settings(&root);
    Ok(ProjectInfo {
        id: clean.clone(),
        name: clean,
        mtime: mtime_ms(&meta),
        main_file: settings.main_file,
    })
}

pub fn rename_project(data_dir: &Path, id: &str, new_name: &str) -> Result<ProjectInfo, CoreError> {
    let root = project_root(data_dir, id)?;
    let clean = sanitize_name(new_name)?;
    let dest = data_dir.join(&clean);
    if dest.exists() {
        return Err(CoreError::conflict(
            "A project with that name already exists",
        ));
    }
    fs::rename(&root, &dest)?;
    let meta = fs::metadata(&dest)?;
    let settings = read_settings(&dest);
    Ok(ProjectInfo {
        id: clean.clone(),
        name: clean,
        mtime: mtime_ms(&meta),
        main_file: settings.main_file,
    })
}

fn discard_using<E, F>(path: &Path, move_to_trash: F) -> Result<(), CoreError>
where
    E: Display,
    F: FnOnce(&Path) -> Result<(), E>,
{
    move_to_trash(path).map_err(|err| {
        CoreError::internal(format!(
            "Could not move the item to Trash or Recycle Bin: {err}"
        ))
    })
}

/// Delete to the platform's trash, so a mis-click is recoverable. A trash
/// failure is reported and the original is left in place; it must never become
/// an implicit permanent-delete request.
fn discard(path: &Path) -> Result<(), CoreError> {
    discard_using(path, |candidate| trash::delete(candidate))
}

pub fn delete_project(data_dir: &Path, id: &str) -> Result<(), CoreError> {
    let root = project_root(data_dir, id)?;
    discard(&root)?;
    Ok(())
}

// ---------- files ----------

pub fn file_tree(root: &Path) -> Result<Vec<TreeNode>, CoreError> {
    fn walk(
        root_canonical: &Path,
        dir: &Path,
        rel_prefix: &str,
    ) -> Result<Vec<TreeNode>, CoreError> {
        let mut nodes = Vec::new();
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let rel = if rel_prefix.is_empty() {
                name.clone()
            } else {
                format!("{rel_prefix}/{name}")
            };
            if rel == BUILD_DIR {
                continue;
            }
            match classify_entry(root_canonical, &entry)? {
                EntryKind::Dir => {
                    let children = walk(root_canonical, &entry.path(), &rel)?;
                    nodes.push(TreeNode {
                        kind: "dir",
                        name,
                        path: rel,
                        children: Some(children),
                    });
                }
                EntryKind::File => nodes.push(TreeNode {
                    kind: "file",
                    name,
                    path: rel,
                    children: None,
                }),
                EntryKind::Skip => {}
            }
        }
        nodes.sort_by(|a, b| {
            if a.kind != b.kind {
                return if a.kind == "dir" {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Greater
                };
            }
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then_with(|| b.name.cmp(&a.name))
        });
        Ok(nodes)
    }

    let root_canonical = fs::canonicalize(root)?;
    walk(&root_canonical, root, "")
}

const TEXT_EXT: &[&str] = &[
    "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
    "py", "r", "dat", "def", "clo", "tikz", "svg",
];

pub fn is_text_file(rel: &str) -> bool {
    Path::new(rel)
        .extension()
        .map(|e| TEXT_EXT.contains(&e.to_string_lossy().to_lowercase().as_str()))
        .unwrap_or(false)
}

pub fn create_file(root: &Path, rel: &str, dir: bool) -> Result<(), CoreError> {
    let abs = safe_path(root, rel)?;
    if abs.exists() {
        return Err(CoreError::conflict("Already exists"));
    }
    if dir {
        fs::create_dir_all(&abs)?;
    } else {
        if let Some(parent) = abs.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&abs, "")?;
    }
    Ok(())
}

pub fn rename_entry(root: &Path, from: &str, to: &str) -> Result<RenameResult, CoreError> {
    let src = safe_path(root, from)?;
    let dest = safe_path(root, to)?;
    if !src.exists() {
        return Err(CoreError::not_found("Not found"));
    }
    if dest.exists() {
        return Err(CoreError::conflict("Destination already exists"));
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }

    let from_rel = crate::paths::safe_rel_file(root, from)?;
    let to_rel = crate::paths::safe_rel_file(root, to)?;
    let settings = read_settings(root);
    let mut main_file = settings.main_file.replace('\\', "/");
    let prefix = format!("{from_rel}/");
    let updates_main = main_file == from_rel || main_file.starts_with(&prefix);
    if updates_main {
        main_file = format!("{to_rel}{}", &main_file[from_rel.len()..]);
    }

    fs::rename(&src, &dest)?;
    if updates_main {
        if let Err(settings_err) = write_settings(root, &json!({ "mainFile": main_file.clone() })) {
            if let Err(rollback_err) = fs::rename(&dest, &src) {
                return Err(CoreError::internal(format!(
                    "{}; rename rollback failed: {}",
                    settings_err.message, rollback_err
                )));
            }
            return Err(settings_err);
        }
    }

    Ok(RenameResult {
        ok: true,
        from: from_rel,
        to: to_rel,
        main_file,
    })
}

pub fn delete_entry(root: &Path, rel: &str) -> Result<(), CoreError> {
    let abs = safe_path(root, rel)?;
    let target = crate::paths::safe_rel_file(root, rel)?;
    let main_file = read_settings(root).main_file.replace('\\', "/");
    if main_file == target || main_file.starts_with(&format!("{target}/")) {
        return Err(CoreError::conflict(
            "Choose a different main file before deleting this entry",
        ));
    }
    if fs::symlink_metadata(&abs).is_ok() {
        discard(&abs)?;
    }
    Ok(())
}

// ---------- search ----------

fn lower_into(s: &str, out: &mut Vec<char>) {
    out.clear();
    out.extend(s.chars().map(|c| {
        if c.is_ascii() {
            c.to_ascii_lowercase()
        } else {
            c.to_lowercase().next().unwrap_or(c)
        }
    }));
}

fn find_from(haystack: &[char], needle: &[char], from: usize) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    (from..=haystack.len() - needle.len()).find(|&i| &haystack[i..i + needle.len()] == needle)
}

pub fn search_project(root: &Path, query: &str, limit: usize) -> Result<Vec<SearchHit>, CoreError> {
    let mut q = Vec::new();
    lower_into(query, &mut q);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    // The ASCII spelling of the query, when it has one, for the whole-file
    // prefilter below.
    let q_ascii: Option<Vec<u8>> = q
        .iter()
        .all(|c| c.is_ascii())
        .then(|| q.iter().map(|c| *c as u8).collect());

    let mut hits: Vec<SearchHit> = Vec::new();
    let mut lower = Vec::new();
    visit_files(root, &mut |abs, rel| {
        if !is_text_file(&rel) {
            return Ok(true);
        }
        let bytes = fs::read(abs)?;
        // One case-insensitive pass over the raw bytes rules a file out without
        // splitting a single line. Sound only when both sides are ASCII: there
        // the byte fold and `lower_into`'s char fold agree by definition, while
        // a character like 'İ' lowercases into an ASCII 'i' that no byte
        // comparison would find.
        if let Some(needle) = &q_ascii {
            if bytes.is_ascii() && find_ci_ascii(&bytes, needle).is_none() {
                return Ok(true);
            }
        }
        let text = String::from_utf8_lossy(&bytes);
        for (i, line) in text.split('\n').enumerate() {
            if hits.len() >= limit {
                break;
            }
            lower_into(line, &mut lower);
            let Some(col) = find_from(&lower, &q, 0) else {
                continue;
            };
            let chars: Vec<char> = line.chars().collect();
            let start = col.saturating_sub(24);
            let ellipsis = if start > 0 { "…" } else { "" };
            let before: String = chars[start..col].iter().collect();
            let matched: String = chars[col..col + q.len()].iter().collect();
            let after_end = (col + q.len() + 60).min(chars.len());
            let after: String = chars[col + q.len()..after_end].iter().collect();
            hits.push(SearchHit {
                file: rel.clone(),
                line: (i + 1) as u32,
                before: format!("{ellipsis}{before}").trim_start().to_string(),
                matched,
                after: after.trim_end().to_string(),
            });
        }
        Ok(hits.len() < limit)
    })?;
    Ok(hits)
}

/// Case-insensitive substring search over ASCII bytes.
fn find_ci_ascii(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    (0..=haystack.len() - needle.len()).find(|&i| {
        haystack[i..i + needle.len()]
            .iter()
            .zip(needle)
            .all(|(a, b)| a.eq_ignore_ascii_case(b))
    })
}

// ---------- symbols ----------

pub fn scan_symbols(root: &Path) -> Result<Symbols, CoreError> {
    // Both failure modes here are real and pull in opposite directions, so the
    // decode has to happen before the match, not after.
    //
    // Matching raw bytes in Unicode mode drops an entry outright when the file
    // carries a byte that is not valid UTF-8 — an umlaut in a Latin-1 .bib —
    // because a class like `[^,\s]` cannot step across it. Escaping that with
    // `(?-u)` narrows `\s` to ASCII instead, which swallows a non-breaking
    // space into the captured key (autocomplete then offers a key `\cite`
    // will never match) and drops the entry entirely when one sits between the
    // type and the brace. Reference managers and PDF copy-paste emit those.
    //
    // Decoding first and matching a str gets both right: invalid bytes become
    // U+FFFD and the entry survives, while `\s` keeps its Unicode meaning.
    // `from_utf8_lossy` borrows when the file is already valid UTF-8, which is
    // the normal case, so this does not copy the file the way an earlier
    // `.into_owned()` here did.
    use regex::Regex;
    use std::sync::OnceLock;
    static BIB_RE: OnceLock<Regex> = OnceLock::new();
    static LABEL_RE: OnceLock<Regex> = OnceLock::new();
    let bib_re = BIB_RE.get_or_init(|| Regex::new(r"@[0-9A-Za-z_]+\s*\{\s*([^,\s]+)\s*,").unwrap());
    let label_re = LABEL_RE.get_or_init(|| Regex::new(r"\\label\{([^}]+)\}").unwrap());

    let mut keys: Vec<String> = Vec::new();
    let mut labels: Vec<String> = Vec::new();
    visit_files(root, &mut |abs, rel| {
        let (re, out) = match ext_of(&rel).as_str() {
            "bib" => (bib_re, &mut keys),
            "tex" => (label_re, &mut labels),
            _ => return Ok(true),
        };
        let bytes = fs::read(abs)?;
        for m in re.captures_iter(&String::from_utf8_lossy(&bytes)) {
            out.push(m[1].to_string());
        }
        Ok(true)
    })?;

    fn dedup(v: Vec<String>) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        v.into_iter().filter(|s| seen.insert(s.clone())).collect()
    }
    Ok(Symbols {
        citations: dedup(keys),
        labels: dedup(labels),
    })
}

pub fn symbols_fingerprint(root: &Path) -> Result<Vec<FileStamp>, CoreError> {
    let mut out = Vec::new();
    visit_files(root, &mut |abs, rel| {
        let ext = ext_of(&rel);
        if ext != "bib" && ext != "tex" {
            return Ok(true);
        }
        // fs::metadata follows the link, so a symlinked source is stamped by
        // the bytes scan_symbols actually reads rather than by the link itself.
        let meta = fs::metadata(abs)?;
        out.push((rel, mtime_ns(&meta), meta.len()));
        Ok(true)
    })?;
    out.sort();
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::discard_using;

    #[test]
    fn failed_trash_operation_never_falls_back_to_permanent_deletion() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keep.tex");
        std::fs::write(&path, "important").unwrap();

        let result = discard_using(&path, |_| Err::<(), _>("trash unavailable"));

        assert!(result.is_err());
        assert!(
            path.exists(),
            "the original must remain after trash failure"
        );
    }
}
