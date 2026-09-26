//! Project and file management. Every project is a directory under the data
//! dir; all returned paths use forward slashes.

use std::cmp::Reverse;
use std::collections::HashSet;
use std::fmt::Display;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{Duration, UNIX_EPOCH};

use regex::Regex;
use serde::Serialize;
use serde_json::json;

use crate::error::CoreError;
use crate::paths::{project_root, rel_key, safe_path, sanitize_name};
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
}

// Directory symlinks are skipped to prevent cycles. File symlinks are retained
// only when their resolved target remains inside the canonical project root.
fn classify_entry(
    root_canonical: &Path,
    entry: &fs::DirEntry,
) -> Result<Option<EntryKind>, CoreError> {
    let file_type = entry.file_type()?;
    if file_type.is_dir() {
        return Ok(Some(EntryKind::Dir));
    }
    if file_type.is_file() {
        return Ok(Some(EntryKind::File));
    }
    if !file_type.is_symlink() {
        return Ok(None);
    }

    // A link that does not resolve (dangling, a loop, an unreadable target)
    // cannot be shown to stay inside the project, so it is not content, and
    // must not fail the whole walk.
    let Ok(target) = fs::canonicalize(entry.path()) else {
        return Ok(None);
    };
    if !target.starts_with(root_canonical) {
        return Ok(None);
    }
    // Following a directory link can duplicate trees or recurse forever.
    Ok(fs::metadata(entry.path())?
        .is_file()
        .then_some(EntryKind::File))
}

/// The result of reading one entry during a scan, or None when it vanished or
/// may not be read: a folder of root-owned output, a file deleted mid-walk.
/// One such entry must not fail the whole tree, search or library listing.
fn skip_unreadable<T>(result: std::io::Result<T>) -> Result<Option<T>, CoreError> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(err)
            if matches!(
                err.kind(),
                ErrorKind::NotFound | ErrorKind::PermissionDenied
            ) =>
        {
            Ok(None)
        }
        Err(err) => Err(err.into()),
    }
}

/// One entry of a project folder that a walk descends into or reports.
struct Entry {
    path: PathBuf,
    name: String,
    /// Project-relative, forward slashes.
    rel: String,
    kind: EntryKind,
}

/// A folder's content entries, in directory order. The file tree, search,
/// symbol scanning and fingerprinting all walk through here, so they cannot
/// disagree about what a project contains: dotfiles are hidden, the top-level
/// `build/` is compile output rather than content, and links are followed only
/// while they stay inside the project. The project root itself must be
/// readable; a subfolder that is not reads as empty.
fn entries(root_canonical: &Path, dir: &Path, prefix: &str) -> Result<Vec<Entry>, CoreError> {
    let read = if prefix.is_empty() {
        fs::read_dir(dir)?
    } else {
        match skip_unreadable(fs::read_dir(dir))? {
            Some(read) => read,
            None => return Ok(Vec::new()),
        }
    };
    let mut out = Vec::new();
    for entry in read {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let rel = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        // Only the project's own build directory holds compile output. A
        // `build` deeper in the tree is the author's, and the ZIP export keeps
        // it, so every walk here must too.
        if rel == BUILD_DIR {
            continue;
        }
        if let Some(kind) = classify_entry(root_canonical, &entry)? {
            out.push(Entry {
                path: entry.path(),
                name,
                rel,
                kind,
            });
        }
    }
    Ok(out)
}

/// Every content file in the project, depth-first, with its project-relative
/// path. The visitor returns false to stop the walk — search uses that to stop
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
        for entry in entries(root_canonical, dir, prefix)? {
            let go_on = match entry.kind {
                EntryKind::Dir => walk(root_canonical, &entry.path, &entry.rel, visit)?,
                EntryKind::File => visit(&entry.path, entry.rel)?,
            };
            if !go_on {
                return Ok(false);
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

fn project_info(name: String, meta: &fs::Metadata, main_file: String) -> ProjectInfo {
    ProjectInfo {
        id: name.clone(),
        name,
        mtime: mtime_ms(meta),
        main_file,
    }
}

fn name_taken() -> CoreError {
    CoreError::conflict("A project with that name already exists")
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
        let Some(meta) = skip_unreadable(fs::metadata(&root))? else {
            continue;
        };
        let main_file = read_settings(&root).main_file;
        projects.push(project_info(name, &meta, main_file));
    }
    projects.sort_by_key(|p| Reverse(p.mtime));
    Ok(projects)
}

pub fn create_project(
    data_dir: &Path,
    name: &str,
    template: &str,
) -> Result<ProjectInfo, CoreError> {
    let clean = sanitize_name(name)?;
    let root = data_dir.join(&clean);
    fs::create_dir_all(data_dir)?;
    // One create rather than a check and then a create: it cannot race, and
    // it refuses anything already there, a dangling link or case alias too.
    match fs::create_dir(&root) {
        Err(err) if err.kind() == ErrorKind::AlreadyExists => return Err(name_taken()),
        created => created?,
    }
    // Template paths are plain file names, fixed at build time.
    for (file, content) in templates::files(template) {
        fs::write(root.join(file), content)?;
    }
    let settings = write_settings(&root, &json!({}))?;
    Ok(project_info(
        clean,
        &fs::metadata(&root)?,
        settings.main_file,
    ))
}

pub fn rename_project(data_dir: &Path, id: &str, new_name: &str) -> Result<ProjectInfo, CoreError> {
    let root = project_root(data_dir, id)?;
    let clean = sanitize_name(new_name)?;
    let dest = data_dir.join(&clean);
    if occupied(&root, &dest) {
        return Err(name_taken());
    }
    fs::rename(&root, &dest)?;
    let main_file = read_settings(&dest).main_file;
    Ok(project_info(clean, &fs::metadata(&dest)?, main_file))
}

/// Whether a rename from `src` to `dest` would land on another entry. On a
/// case-insensitive volume, the default on macOS and Windows, a case-only
/// rename's destination already "exists" because it is `src` itself.
fn occupied(src: &Path, dest: &Path) -> bool {
    fs::symlink_metadata(dest).is_ok() && !same_entry(src, dest)
}

#[cfg(unix)]
fn same_entry(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::symlink_metadata(a), fs::symlink_metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

// std has no file identity on Windows, so there it is two spellings that
// differ only in case and resolve to one final path.
#[cfg(not(unix))]
fn same_entry(a: &Path, b: &Path) -> bool {
    a.to_string_lossy().to_lowercase() == b.to_string_lossy().to_lowercase()
        && matches!((fs::canonicalize(a), fs::canonicalize(b)), (Ok(x), Ok(y)) if x == y)
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
    fn walk(root_canonical: &Path, dir: &Path, prefix: &str) -> Result<Vec<TreeNode>, CoreError> {
        let mut nodes = Vec::new();
        for entry in entries(root_canonical, dir, prefix)? {
            let (kind, children) = match entry.kind {
                EntryKind::Dir => ("dir", Some(walk(root_canonical, &entry.path, &entry.rel)?)),
                EntryKind::File => ("file", None),
            };
            nodes.push(TreeNode {
                kind,
                name: entry.name,
                path: entry.rel,
                children,
            });
        }
        // Folders first, then by name ignoring case. The key is built once per
        // entry, not twice per comparison.
        nodes.sort_by_cached_key(|n| {
            (
                n.kind != "dir",
                n.name.to_lowercase(),
                Reverse(n.name.clone()),
            )
        });
        Ok(nodes)
    }

    walk(&fs::canonicalize(root)?, root, "")
}

const TEXT_EXT: &[&str] = &[
    "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
    "py", "r", "dat", "def", "clo", "tikz", "svg",
];

pub fn is_text_file(rel: &str) -> bool {
    TEXT_EXT.contains(&ext_of(rel).as_str())
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

/// Whether `path` lies strictly inside the folder `dir`; both are
/// forward-slash project paths.
fn is_under(path: &str, dir: &str) -> bool {
    path.strip_prefix(dir)
        .is_some_and(|rest| rest.starts_with('/'))
}

/// The stored main file in the forward-slash form `rel_key` produces. An
/// older build could store it with backslashes.
fn main_file_key(root: &Path) -> String {
    read_settings(root).main_file.replace('\\', "/")
}

pub fn rename_entry(root: &Path, from: &str, to: &str) -> Result<RenameResult, CoreError> {
    let src = safe_path(root, from)?;
    let dest = safe_path(root, to)?;
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

    let mut main_file = main_file_key(root);
    let updates_main = main_file == from_rel || is_under(&main_file, &from_rel);
    if updates_main {
        main_file = format!("{to_rel}{}", &main_file[from_rel.len()..]);
    }

    fs::rename(&src, &dest)?;
    if updates_main {
        if let Err(settings_err) = write_settings(root, &json!({ "mainFile": &main_file })) {
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
    delete_entry_using(root, rel, discard)
}

fn delete_entry_using(
    root: &Path,
    rel: &str,
    move_to_trash: impl FnOnce(&Path) -> Result<(), CoreError>,
) -> Result<(), CoreError> {
    let abs = safe_path(root, rel)?;
    let target = rel_key(rel)?;
    let main_file = main_file_key(root);
    if main_file == target || is_under(&main_file, &target) {
        return Err(CoreError::conflict(
            "Choose a different main file before deleting this entry",
        ));
    }
    if fs::symlink_metadata(&abs).is_ok() {
        move_to_trash(&abs)?;
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

fn find_chars(haystack: &[char], needle: &[char]) -> Option<usize> {
    if needle.is_empty() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
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
        let Some(bytes) = skip_unreadable(fs::read(abs))? else {
            return Ok(true);
        };
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
            // The same reasoning holds per line: an ASCII line needs no char
            // decode, and its byte offsets are its char offsets. A file that
            // passed the prefilter is otherwise decoded line by line in full.
            let found = match &q_ascii {
                Some(needle) if line.is_ascii() => find_ci_ascii(line.as_bytes(), needle),
                _ => {
                    lower_into(line, &mut lower);
                    find_chars(&lower, &q)
                }
            };
            let Some(col) = found else {
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
// `from_utf8_lossy` borrows when the file is already valid UTF-8, the
// normal case, so then nothing is copied.
static BIB_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@[0-9A-Za-z_]+\s*\{\s*([^,\s]+)\s*,").unwrap());
static LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\label\{([^}]+)\}").unwrap());

pub fn scan_symbols(root: &Path) -> Result<Symbols, CoreError> {
    let mut keys: Vec<String> = Vec::new();
    let mut labels: Vec<String> = Vec::new();
    visit_files(root, &mut |abs, rel| {
        let (re, out) = match ext_of(&rel).as_str() {
            "bib" => (&*BIB_KEY, &mut keys),
            "tex" => (&*LABEL, &mut labels),
            _ => return Ok(true),
        };
        let Some(bytes) = skip_unreadable(fs::read(abs))? else {
            return Ok(true);
        };
        for m in re.captures_iter(&String::from_utf8_lossy(&bytes)) {
            out.push(m[1].to_string());
        }
        Ok(true)
    })?;

    fn dedup(mut v: Vec<String>) -> Vec<String> {
        let mut seen = HashSet::new();
        v.retain(|s| seen.insert(s.clone()));
        v
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
        let Some(meta) = skip_unreadable(fs::metadata(abs))? else {
            return Ok(true);
        };
        out.push((rel, mtime_ns(&meta), meta.len()));
        Ok(true)
    })?;
    out.sort();
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::{create_file, create_project, delete_entry_using, discard_using};
    use crate::error::CoreError;
    use crate::paths::project_root;
    use crate::settings::write_settings;
    use serde_json::json;
    use std::path::{Path, PathBuf};

    fn project() -> (tempfile::TempDir, PathBuf) {
        let data = tempfile::tempdir().unwrap();
        create_project(data.path(), "P", "blank").unwrap();
        let root = project_root(data.path(), "P").unwrap();
        (data, root)
    }

    fn unavailable(path: &Path) -> Result<(), CoreError> {
        discard_using(path, |_| Err::<(), _>("trash unavailable"))
    }

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

    // These go through a stand-in for the platform trash: the real one is slow
    // or unavailable under test, and must not fill the user's Trash either.

    #[test]
    fn deleting_an_entry_never_turns_a_trash_failure_into_permanent_deletion() {
        let (_data, root) = project();
        create_file(&root, "notes/scratch.tex", false).unwrap();
        let err = delete_entry_using(&root, "notes/scratch.tex", unavailable).unwrap_err();
        assert_eq!(err.status, 500);
        assert!(root.join("notes/scratch.tex").is_file());
    }

    #[test]
    fn an_entry_named_with_a_leading_dash_reaches_the_trash() {
        // create_entry and uploads accept such a name; only the main file,
        // which reaches latexmk's command line, may not start with "-".
        let (_data, root) = project();
        create_file(&root, "-notes/-draft.tex", false).unwrap();
        let mut trashed = None;
        delete_entry_using(&root, "-notes", |path| {
            trashed = Some(path.to_path_buf());
            Ok(())
        })
        .unwrap();
        assert_eq!(trashed, Some(root.join("-notes")));
    }

    #[test]
    fn the_main_file_guard_runs_before_the_trash() {
        let (_data, root) = project();
        create_file(&root, "chapters/main.tex", false).unwrap();
        write_settings(&root, &json!({ "mainFile": "chapters/main.tex" })).unwrap();
        for path in ["chapters", "chapters/main.tex", r"chapters\main.tex"] {
            let err =
                delete_entry_using(&root, path, |_| panic!("{path} was trashed")).unwrap_err();
            assert_eq!(err.status, 409, "{path}");
        }
        // A sibling that merely shares the name's prefix is not the main file.
        create_file(&root, "chapters2/x.tex", false).unwrap();
        let mut trashed = false;
        delete_entry_using(&root, "chapters2", |_| {
            trashed = true;
            Ok(())
        })
        .unwrap();
        assert!(trashed);
    }
}
