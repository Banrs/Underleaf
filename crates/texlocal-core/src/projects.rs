//! Project and file management, ported from server/projects.js. Every project
//! is a directory under the data dir; all returned paths use forward slashes.

use std::fs;
use std::path::Path;
use std::time::UNIX_EPOCH;

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

/// One scannable file's identity for cache invalidation: (rel path, mtime, len).
pub type FileStamp = (String, u64, u64);

fn mtime_ms(meta: &fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
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
    projects.sort_by(|a, b| b.mtime.cmp(&a.mtime));
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

pub fn delete_project(data_dir: &Path, id: &str) -> Result<(), CoreError> {
    let root = project_root(data_dir, id)?;
    fs::remove_dir_all(root)?;
    Ok(())
}

// ---------- files ----------

pub fn file_tree(root: &Path) -> Result<Vec<TreeNode>, CoreError> {
    fn walk(dir: &Path, rel_prefix: &str) -> Result<Vec<TreeNode>, CoreError> {
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
            if entry.file_type()?.is_dir() {
                let children = walk(&entry.path(), &rel)?;
                nodes.push(TreeNode {
                    kind: "dir",
                    name,
                    path: rel,
                    children: Some(children),
                });
            } else {
                nodes.push(TreeNode {
                    kind: "file",
                    name,
                    path: rel,
                    children: None,
                });
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
            // Case-insensitive first, then lowercase before uppercase on a
            // tie, which is the order localeCompare produced for the sidebar.
            // Not a full collation: without ICU, non-ASCII names sort after
            // ASCII ones rather than beside their base letter.
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then_with(|| b.name.cmp(&a.name))
        });
        Ok(nodes)
    }
    walk(root, "")
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
    fs::rename(&src, &dest)?;
    let from_rel = crate::paths::safe_rel_file(root, from).unwrap_or_else(|_| from.to_string());
    let to_rel = crate::paths::safe_rel_file(root, to).unwrap_or_else(|_| to.to_string());
    let settings = read_settings(root);
    // The stored value may carry either separator (old files, hand edits);
    // compare in canonical slash form.
    let mut main_file = settings.main_file.replace('\\', "/");
    let prefix = format!("{from_rel}/");
    if main_file == from_rel || main_file.starts_with(&prefix) {
        main_file = format!("{to_rel}{}", &main_file[from_rel.len()..]);
        write_settings(root, &json!({ "mainFile": main_file }))?;
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
    let target = crate::paths::safe_rel_file(root, rel).unwrap_or_else(|_| rel.to_string());
    let main_file = read_settings(root).main_file.replace('\\', "/");
    if main_file == target || main_file.starts_with(&format!("{target}/")) {
        return Err(CoreError::conflict(
            "Choose a different main file before deleting this entry",
        ));
    }
    match fs::metadata(&abs) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(&abs)?,
        Ok(_) => fs::remove_file(&abs)?,
        Err(_) => {} // force: true — deleting a missing entry is fine
    }
    Ok(())
}

// ---------- search ----------

/// Lowercase with a 1:1 char mapping (first char of each lowering), so match
/// columns computed on the lowered text index the original safely.
fn lower_chars(s: &str) -> Vec<char> {
    s.chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect()
}

fn find_from(haystack: &[char], needle: &[char], from: usize) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    (from..=haystack.len() - needle.len()).find(|&i| &haystack[i..i + needle.len()] == needle)
}

/// Case-insensitive full-text search across the project's text files.
pub fn search_project(root: &Path, query: &str, limit: usize) -> Result<Vec<SearchHit>, CoreError> {
    let q = lower_chars(query);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let mut hits: Vec<SearchHit> = Vec::new();

    fn walk(
        root: &Path,
        dir: &Path,
        q: &[char],
        limit: usize,
        hits: &mut Vec<SearchHit>,
    ) -> Result<(), CoreError> {
        for entry in fs::read_dir(dir)? {
            if hits.len() >= limit {
                return Ok(());
            }
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == BUILD_DIR {
                continue;
            }
            let abs = entry.path();
            if entry.file_type()?.is_dir() {
                walk(root, &abs, q, limit, hits)?;
                continue;
            }
            let rel = match crate::paths::rel_to_root(root, &abs) {
                Some(r) => r,
                None => continue,
            };
            if !is_text_file(&rel) {
                continue;
            }
            let text = String::from_utf8_lossy(&fs::read(&abs)?).into_owned();
            for (i, line) in text.split('\n').enumerate() {
                if hits.len() >= limit {
                    break;
                }
                let chars: Vec<char> = line.chars().collect();
                let lower = lower_chars(line);
                let col = match find_from(&lower, q, 0) {
                    Some(c) => c,
                    None => continue,
                };
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
        }
        Ok(())
    }

    walk(root, root, &q, limit, &mut hits)?;
    Ok(hits)
}

// ---------- symbols ----------

/// Collect citation keys and \label names across the project (autocomplete).
pub fn scan_symbols(root: &Path) -> Result<Symbols, CoreError> {
    use regex::Regex;
    use std::sync::OnceLock;
    static BIB_RE: OnceLock<Regex> = OnceLock::new();
    static LABEL_RE: OnceLock<Regex> = OnceLock::new();
    let bib_re = BIB_RE.get_or_init(|| Regex::new(r"@[0-9A-Za-z_]+\s*\{\s*([^,\s]+)\s*,").unwrap());
    let label_re = LABEL_RE.get_or_init(|| Regex::new(r"\\label\{([^}]+)\}").unwrap());

    let mut keys: Vec<String> = Vec::new();
    let mut labels: Vec<String> = Vec::new();

    fn walk(
        dir: &Path,
        bib_re: &regex::Regex,
        label_re: &regex::Regex,
        keys: &mut Vec<String>,
        labels: &mut Vec<String>,
    ) -> Result<(), CoreError> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == BUILD_DIR {
                continue;
            }
            let abs = entry.path();
            if entry.file_type()?.is_dir() {
                walk(&abs, bib_re, label_re, keys, labels)?;
                continue;
            }
            let ext = abs
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            if ext == "bib" {
                let src = String::from_utf8_lossy(&fs::read(&abs)?).into_owned();
                for m in bib_re.captures_iter(&src) {
                    keys.push(m[1].to_string());
                }
            } else if ext == "tex" {
                let src = String::from_utf8_lossy(&fs::read(&abs)?).into_owned();
                for m in label_re.captures_iter(&src) {
                    labels.push(m[1].to_string());
                }
            }
        }
        Ok(())
    }

    walk(root, bib_re, label_re, &mut keys, &mut labels)?;

    fn dedup(v: Vec<String>) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        v.into_iter().filter(|s| seen.insert(s.clone())).collect()
    }
    Ok(Symbols {
        citations: dedup(keys),
        labels: dedup(labels),
    })
}

/// Stat-only fingerprint of every file `scan_symbols` would read, sorted for a
/// stable comparison. Callers cache the scan against this: the walk plus a stat
/// per file is far cheaper than reading and regex-scanning each one, and the UI
/// re-scans after every save.
pub fn symbols_fingerprint(root: &Path) -> Result<Vec<FileStamp>, CoreError> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<FileStamp>) -> Result<(), CoreError> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == BUILD_DIR {
                continue;
            }
            let abs = entry.path();
            if entry.file_type()?.is_dir() {
                walk(root, &abs, out)?;
                continue;
            }
            let ext = abs
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            if ext != "bib" && ext != "tex" {
                continue;
            }
            let Some(rel) = crate::paths::rel_to_root(root, &abs) else {
                continue;
            };
            let meta = entry.metadata()?;
            out.push((rel, mtime_ms(&meta), meta.len()));
        }
        Ok(())
    }

    let mut out = Vec::new();
    walk(root, root, &mut out)?;
    // read_dir order is filesystem-defined; sort so an unchanged project always
    // produces an identical fingerprint.
    out.sort();
    Ok(out)
}
