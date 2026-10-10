//! Project and file management. Every project is a directory under the data
//! dir; all returned paths use forward slashes.

use std::cmp::Reverse;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{Duration, UNIX_EPOCH};

use regex::Regex;
use serde::Serialize;
use serde_json::json;

use crate::atomic;
use crate::error::CoreError;
use crate::paths::{fold_case, project_root, rel_key, safe_path, safe_write_path, sanitize_name};
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

fn since_epoch(meta: &fs::Metadata) -> Option<Duration> {
    meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()
}

fn mtime_ms(meta: &fs::Metadata) -> u64 {
    since_epoch(meta).map_or(0, |d| d.as_millis() as u64)
}

/// A vanished or unreadable entry is skipped without failing a project scan.
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

/// An entry the project walks show, and its path from the project root.
struct Entry {
    path: PathBuf,
    name: String,
    dir: bool,
}

impl Entry {
    fn rel<'a>(&'a self, root: &Path) -> std::borrow::Cow<'a, str> {
        self.path.strip_prefix(root).unwrap().to_string_lossy()
    }
}

/// Shared tree rules for file listing, search and symbols: hide dotfiles and
/// top-level build output, and follow only links to files within the
/// project. An entry that can't be read, or vanishes while the walk passes
/// (a build's or an editor's temporary file), is left out, and so an
/// unreadable subfolder is empty; the project root must be readable.
fn entries(root: &Path, dir: &Path) -> Result<Vec<Entry>, CoreError> {
    let read = if dir == root {
        fs::read_dir(dir)?
    } else {
        match skip_unreadable(fs::read_dir(dir))? {
            Some(read) => read,
            None => return Ok(Vec::new()),
        }
    };
    let mut out = Vec::new();
    for entry in read {
        let Some(entry) = skip_unreadable(entry)? else {
            continue;
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        // Only top-level build/ is output; a nested build belongs to the author.
        if name.starts_with('.') || (dir == root && name.eq_ignore_ascii_case(BUILD_DIR)) {
            continue;
        }
        let Some(kind) = skip_unreadable(entry.file_type())? else {
            continue;
        };
        let path = entry.path();
        // No directory links (cycles), nor any without a proven in-project target.
        let shown = if kind.is_symlink() {
            fs::canonicalize(&path).is_ok_and(|t| t.starts_with(root) && t.is_file())
        } else {
            kind.is_file() || kind.is_dir()
        };
        if shown {
            let dir = kind.is_dir();
            out.push(Entry { path, name, dir });
        }
    }
    Ok(out)
}

/// Every content file in the project, depth-first, with its project-relative
/// path. The visitor returns false to stop the walk.
pub(crate) fn visit_files(
    root: &Path,
    visit: &mut dyn FnMut(&Path, &str) -> Result<bool, CoreError>,
) -> Result<(), CoreError> {
    fn walk(
        root: &Path,
        dir: &Path,
        visit: &mut dyn FnMut(&Path, &str) -> Result<bool, CoreError>,
    ) -> Result<bool, CoreError> {
        for entry in entries(root, dir)? {
            let go_on = if entry.dir {
                walk(root, &entry.path, visit)?
            } else {
                visit(&entry.path, &entry.rel(root))?
            };
            if !go_on {
                return Ok(false);
            }
        }
        Ok(true)
    }

    let root = fs::canonicalize(root)?;
    walk(&root, &root, visit)?;
    Ok(())
}

fn ext_of(rel: &str) -> String {
    Path::new(rel)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

fn project_info(name: String, mtime: u64, main_file: String) -> ProjectInfo {
    ProjectInfo {
        id: name.clone(),
        name,
        mtime,
        main_file,
    }
}

/// A project's date as the library shows it: the newest of its folder's and
/// its content files', as a folder's own date moves only when entries come
/// or go directly in it, not when a file in it is saved or compiled.
fn newest(root: &Path, meta: &fs::Metadata) -> u64 {
    let mut mtime = mtime_ms(meta);
    let _ = visit_files(root, &mut |abs, _| {
        if let Ok(meta) = fs::metadata(abs) {
            mtime = mtime.max(mtime_ms(&meta));
        }
        Ok(true)
    });
    mtime
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
        projects.push(project_info(name, newest(&root, &meta), main_file));
    }
    projects.sort_by_key(|p| Reverse(p.mtime));
    Ok(projects)
}

pub fn create_project(
    data_dir: &Path,
    name: &str,
    template: &str,
) -> Result<ProjectInfo, CoreError> {
    let (clean, root) = new_project_dir(data_dir, name)?;
    for (file, content) in templates::files(template) {
        fs::write(root.join(file), content)?;
    }
    let main_file = write_settings(&root, &json!({}))?.main_file;
    finish_project(clean, &root, main_file)
}

/// A new, empty project folder for `name`, or "name 2" and so on when that
/// is taken, as Finder numbers copies; and the name it got.
pub(crate) fn new_project_dir(data_dir: &Path, name: &str) -> Result<(String, PathBuf), CoreError> {
    let clean = sanitize_name(name)?;
    fs::create_dir_all(data_dir)?;
    for n in 1.. {
        let name = match n {
            1 => clean.clone(),
            n => format!("{clean} {n}"),
        };
        let root = data_dir.join(&name);
        // One create rather than a check and then a create: it cannot race,
        // and it passes over anything already there, a dangling link or case
        // alias too.
        match fs::create_dir(&root) {
            Err(err) if err.kind() == ErrorKind::AlreadyExists => {}
            created => return Ok(created.map(|()| (name, root))?),
        }
    }
    unreachable!("a free name")
}

/// A project just made, dated by its folder: its settings, written last,
/// date the folder after every file in it.
pub(crate) fn finish_project(
    name: String,
    root: &Path,
    main_file: String,
) -> Result<ProjectInfo, CoreError> {
    Ok(project_info(
        name,
        mtime_ms(&fs::metadata(root)?),
        main_file,
    ))
}

/// The likely main file among a project's top-level .tex files: main.tex,
/// else the first by name that starts a document, else the first by name.
pub(crate) fn guess_main_file(root: &Path) -> Result<Option<String>, CoreError> {
    let mut tex: Vec<String> = Vec::new();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        // A name latexmk would read as an option can't be the main file.
        if entry.file_type()?.is_file() && ext_of(&name) == "tex" && !name.starts_with('-') {
            tex.push(name);
        }
    }
    tex.sort();
    let starts_document = |name: &&String| {
        fs::read(root.join(name.as_str()))
            .is_ok_and(|bytes| String::from_utf8_lossy(&bytes).contains("\\documentclass"))
    };
    Ok(tex
        .iter()
        .find(|name| name.eq_ignore_ascii_case("main.tex"))
        .or_else(|| tex.iter().find(starts_document))
        .or(tex.first())
        .cloned())
}

/// Rename a project, calling `before_move` once the rename is sure to go
/// ahead and before its folder moves.
pub fn rename_project(
    data_dir: &Path,
    id: &str,
    new_name: &str,
    before_move: impl FnOnce(&Path) -> Result<(), CoreError>,
) -> Result<ProjectInfo, CoreError> {
    let root = project_root(data_dir, id)?;
    let clean = sanitize_name(new_name)?;
    let dest = data_dir.join(&clean);
    if occupied(&root, &dest) {
        return Err(CoreError::conflict(
            "A project with that name already exists",
        ));
    }
    before_move(&root)?;
    fs::rename(&root, &dest)?;
    let main_file = read_settings(&dest).main_file;
    Ok(project_info(
        clean,
        newest(&dest, &fs::metadata(&dest)?),
        main_file,
    ))
}

/// Whether a rename from `src` to `dest` would land on another entry. On a
/// case-insensitive volume, the default on macOS, a case-only
/// rename's destination already "exists" because it is `src` itself.
fn occupied(src: &Path, dest: &Path) -> bool {
    fs::symlink_metadata(dest).is_ok() && !same_entry(src, dest)
}

fn same_entry(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::symlink_metadata(a), fs::symlink_metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

/// Delete to the platform's trash, so a mis-click is recoverable. A trash
/// failure is reported and the original is left in place; it must never become
/// an implicit permanent-delete request.
fn discard(path: &Path) -> Result<(), CoreError> {
    trash::delete(path)
        .map_err(|err| CoreError::internal(format!("Could not move the item to Trash: {err}")))
}

pub fn delete_project(data_dir: &Path, id: &str) -> Result<(), CoreError> {
    discard(&project_root(data_dir, id)?)
}

// ---------- files ----------

pub fn file_tree(root: &Path) -> Result<Vec<TreeNode>, CoreError> {
    fn walk(root: &Path, dir: &Path) -> Result<Vec<TreeNode>, CoreError> {
        let mut nodes = Vec::new();
        for entry in entries(root, dir)? {
            let (kind, children) = if entry.dir {
                ("dir", Some(walk(root, &entry.path)?))
            } else {
                ("file", None)
            };
            nodes.push(TreeNode {
                kind,
                path: entry.rel(root).into_owned(),
                name: entry.name,
                children,
            });
        }
        // Folders first, then by name ignoring case.
        nodes.sort_by_cached_key(|n| {
            (
                n.kind != "dir",
                n.name.to_lowercase(),
                Reverse(n.name.clone()),
            )
        });
        Ok(nodes)
    }

    let root = fs::canonicalize(root)?;
    walk(&root, &root)
}

const TEXT_EXT: &[&str] = &[
    "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
    "py", "r", "dat", "def", "clo", "tikz",
];

pub fn create_file(root: &Path, rel: &str, dir: bool) -> Result<(), CoreError> {
    let abs = safe_write_path(root, rel)?;
    if abs.exists() {
        return Err(CoreError::conflict("Already exists"));
    }
    if dir {
        Ok(fs::create_dir_all(&abs)?)
    } else {
        write_creating(&abs, b"")
    }
}

pub(crate) fn write_creating(abs: &Path, contents: &[u8]) -> Result<(), CoreError> {
    if let Some(parent) = abs.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(atomic::write(abs, contents)?)
}

/// What follows the entry `entry` in `path`, both forward-slash project
/// paths, with names compared as the volume compares them: "" for the entry
/// itself, "/…" for a path inside it, None for any other.
fn after_entry<'a>(path: &'a str, entry: &str) -> Option<&'a str> {
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

/// Whether `path` lies strictly inside the folder `dir`.
fn is_under(path: &str, dir: &str) -> bool {
    after_entry(path, dir).is_some_and(|rest| !rest.is_empty())
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
    let moved_main = after_entry(&main_file, &from_rel).map(|rest| format!("{to_rel}{rest}"));
    fs::rename(&src, &dest)?;
    if let Some(main_file) = &moved_main {
        if let Err(settings_err) = write_settings(root, &json!({ "mainFile": main_file })) {
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
        main_file: moved_main.unwrap_or(main_file),
    })
}

/// Move to the Trash an entry an incoming file of its name replaces. The main
/// file may go, since the file taking its place keeps it valid; a folder
/// holding it may not, however the upload spells its name.
pub(crate) fn discard_replaced(root: &Path, rel: &str) -> Result<(), CoreError> {
    if is_under(&read_settings(root).main_file, rel) {
        return Err(CoreError::conflict(
            "Choose a different main file before replacing this folder",
        ));
    }
    discard(&safe_path(root, rel)?)
}

/// `name` with a copy's number, as Finder numbers them: "main 2.tex",
/// "figures 2".
pub(crate) fn numbered(name: &str, n: u32) -> String {
    match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => format!("{stem} {n}.{ext}"),
        _ => format!("{name} {n}"),
    }
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
    // However the request spells the main file or a folder holding it.
    if after_entry(&read_settings(root).main_file, &rel_key(rel)?).is_some() {
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

// Keep one folded character per original character so snippet offsets agree.
fn lower_into(s: &str, out: &mut Vec<char>) {
    out.clear();
    out.extend(s.chars().map(|c| c.to_lowercase().next().unwrap_or(c)));
}

pub fn search_project(root: &Path, query: &str, limit: usize) -> Result<Vec<SearchHit>, CoreError> {
    let mut q = Vec::new();
    lower_into(query, &mut q);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let mut hits: Vec<SearchHit> = Vec::new();
    let mut lower = Vec::new();
    visit_files(root, &mut |abs, rel| {
        if !TEXT_EXT.contains(&ext_of(rel).as_str()) {
            return Ok(true);
        }
        let Some(bytes) = skip_unreadable(fs::read(abs))? else {
            return Ok(true);
        };
        let text = String::from_utf8_lossy(&bytes);
        for (i, line) in text.split('\n').enumerate() {
            if hits.len() >= limit {
                break;
            }
            lower_into(line, &mut lower);
            let Some(col) = lower.windows(q.len()).position(|w| w == q) else {
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
                file: rel.to_owned(),
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

// ---------- symbols ----------

// Matched on the decoded text, not the raw bytes: in Unicode mode a byte that
// isn't UTF-8 (a Latin-1 umlaut) drops its entry, and `(?-u)` narrows `\s` to
// ASCII, which swallows a non-breaking space into the key.
static BIB_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@[0-9A-Za-z_]+\s*\{\s*([^,\s]+)\s*,").unwrap());
/// Not a bare prefix, as an inserted block's `fig:` is until it's filled in.
static LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\label\{([^}]*[^}:])\}").unwrap());
/// A thebibliography entry's key, which \cite takes as a .bib key.
static BIBITEM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\bibitem\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}").unwrap());

/// A line of TeX without its comment, which starts at the first % that no
/// backslash escapes.
fn uncommented(line: &str) -> &str {
    let mut escaped = false;
    for (i, c) in line.char_indices() {
        match c {
            '%' if !escaped => return &line[..i],
            '\\' => escaped = !escaped,
            _ => escaped = false,
        }
    }
    line
}

fn parse_symbols(bytes: &[u8], ext: &str) -> Symbols {
    let mut citations = Vec::new();
    let mut labels = Vec::new();
    let text = String::from_utf8_lossy(bytes);
    let found = |re: &Regex, text: &str, out: &mut Vec<String>| {
        out.extend(re.captures_iter(text).map(|m| m[1].to_string()));
    };
    if ext == "bib" {
        found(&BIB_KEY, &text, &mut citations);
    } else {
        for line in text.lines().map(uncommented) {
            found(&LABEL, line, &mut labels);
            found(&BIBITEM, line, &mut citations);
        }
    }
    Symbols { citations, labels }
}

pub fn scan_symbols(root: &Path) -> Result<Symbols, CoreError> {
    let mut files = BTreeMap::new();
    visit_files(root, &mut |abs, rel| {
        let ext = ext_of(rel);
        if ext == "bib" || ext == "tex" {
            if let Some(bytes) = skip_unreadable(fs::read(abs))? {
                files.insert(rel.to_owned(), parse_symbols(&bytes, &ext));
            }
        }
        Ok(true)
    })?;

    fn dedup<'a>(symbols: impl Iterator<Item = &'a String>) -> Vec<String> {
        let mut seen = HashSet::new();
        symbols
            .filter(|symbol| seen.insert(*symbol))
            .cloned()
            .collect()
    }
    // File-name order keeps completions stable, retaining the first occurrence.
    Ok(Symbols {
        citations: dedup(files.values().flat_map(|s| &s.citations)),
        labels: dedup(files.values().flat_map(|s| &s.labels)),
    })
}

#[cfg(test)]
mod tests {
    use super::{after_entry, create_file, create_project, delete_entry_using};
    use crate::paths::project_root;
    use crate::settings::write_settings;
    use crate::CoreError;
    use serde_json::json;
    use std::path::PathBuf;

    fn project() -> (tempfile::TempDir, PathBuf) {
        let data = tempfile::tempdir().unwrap();
        create_project(data.path(), "P", "blank").unwrap();
        let root = project_root(data.path(), "P").unwrap();
        (data, root)
    }

    // These go through a stand-in for the platform trash: the real one is slow
    // or unavailable under test, and must not fill the user's Trash either.

    #[test]
    fn deleting_an_entry_never_turns_a_trash_failure_into_permanent_deletion() {
        let (_data, root) = project();
        create_file(&root, "notes/scratch.tex", false).unwrap();
        let unavailable = |_: &_| Err(CoreError::internal("trash unavailable"));
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
    fn main_file_guards_compare_names_as_the_volume_does() {
        assert_eq!(
            after_entry("chapters/main.tex", "chapters"),
            Some("/main.tex")
        );
        assert_eq!(
            after_entry("chapters/main.tex", "chapters/main.tex"),
            Some("")
        );
        assert_eq!(after_entry("chapters2/main.tex", "chapters"), None);
        assert_eq!(after_entry("chapters", "chapters/main.tex"), None);
        // On a Mac's case-insensitive volume, Main.tex is main.tex.
        let insensitive = cfg!(target_os = "macos");
        assert_eq!(after_entry("main.tex", "Main.tex").is_some(), insensitive);
        assert_eq!(
            after_entry("Chapters/a.tex", "chapters"),
            insensitive.then_some("/a.tex")
        );
    }

    #[test]
    fn the_main_file_guard_runs_before_the_trash() {
        let (_data, root) = project();
        create_file(&root, "chapters/main.tex", false).unwrap();
        write_settings(&root, &json!({ "mainFile": "chapters/main.tex" })).unwrap();
        for path in ["chapters", "chapters/main.tex"] {
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
