//! Project and file management. Every project is a directory under the data
//! dir; all returned paths use forward slashes.

use std::cmp::Reverse;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;
use std::time::UNIX_EPOCH;

use regex::Regex;
use serde::Serialize;
use serde_json::json;

use crate::BUILD_DIR;
use crate::atomic::{self, Stamp};
use crate::error::CoreError;
use crate::paths::{
    after_entry, fold_case, project_root, rel_key, safe_path, safe_write_path, sanitize_name,
};
use crate::settings::{move_ui, read_settings, write_settings};
use crate::templates;

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
    /// A file's `file_kind`; folders have none.
    #[serde(rename = "kind", skip_serializing_if = "Option::is_none")]
    pub file_kind: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<TreeNode>>,
}

/// Where an absolute path lies in the library: its project, and its path in it
/// ("" for the project's folder).
#[derive(Debug, PartialEq, Serialize)]
pub struct Located {
    pub id: String,
    pub path: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenameResult {
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Symbols {
    pub citations: Vec<String>,
    pub labels: Vec<String>,
}

fn mtime_ms(meta: &fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since| since.as_millis() as u64)
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

struct Entry {
    path: PathBuf,
    name: String,
    dir: bool,
}

impl Entry {
    /// Its path from the root, in forward slashes on Windows too, where no
    /// name holds a backslash.
    fn rel<'a>(&'a self, root: &Path) -> std::borrow::Cow<'a, str> {
        let rel = self.path.strip_prefix(root).unwrap().to_string_lossy();
        if cfg!(windows) {
            rel.replace('\\', "/").into()
        } else {
            rel
        }
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
            dunce::canonicalize(&path).is_ok_and(|t| t.starts_with(root) && t.is_file())
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

    let root = dunce::canonicalize(root)?;
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

/// A project's date as the library shows it: the newest of its folders' and top-level
/// files', without a stat of every file. Every save the app makes renames a file into
/// place and so moves its folder's date; a file saved in place by another app moves only
/// its own, and in a subfolder shows once anything else moves a folder's date.
fn newest(root: &Path, meta: &fs::Metadata) -> u64 {
    fn walk(root: &Path, dir: &Path, newest: &mut u64) {
        for entry in entries(root, dir).into_iter().flatten() {
            if (entry.dir || dir == root)
                && let Ok(meta) = fs::metadata(&entry.path)
            {
                *newest = (*newest).max(mtime_ms(&meta));
            }
            if entry.dir {
                walk(root, &entry.path, newest);
            }
        }
    }
    let mut newest = mtime_ms(meta);
    if let Ok(root) = dunce::canonicalize(root) {
        walk(&root, &root, &mut newest);
    }
    newest
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

/// What a new project is called when the user has not said.
pub const UNTITLED: &str = "Untitled";

/// The first free name in the series "Untitled", "Untitled 2", … (from
/// `base`, if given): one no entry of the library has, however it is spelled
/// where the volume ignores case. It creates nothing, so a host can offer it
/// as the name to edit; `create_project` numbers past anything taken since.
pub fn free_project_name(data_dir: &Path, base: Option<&str>) -> Result<String, CoreError> {
    let clean = sanitize_name(base.unwrap_or(UNTITLED))?;
    let taken: HashSet<String> = match fs::read_dir(data_dir) {
        Ok(entries) => entries
            .map(|entry| entry.map(|e| fold_case(&e.file_name().to_string_lossy())))
            .collect::<Result<_, _>>()?,
        Err(err) if err.kind() == ErrorKind::NotFound => HashSet::new(),
        Err(err) => return Err(err.into()),
    };
    Ok((1..)
        .map(|n| match n {
            1 => clean.clone(),
            n => format!("{clean} {n}"),
        })
        .find(|name| !taken.contains(&fold_case(name)))
        .expect("a free name"))
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
    // The new name is taken as a new project's is, by making its folder, and
    // the project moves onto that empty folder: after a check alone, a new
    // project could take the name before the move and then fill the renamed
    // project with its own files. A case-only rename's destination is the
    // project itself.
    let reserved = !same_entry(&root, &dest);
    if reserved {
        match fs::create_dir(&dest) {
            Err(err) if err.kind() == ErrorKind::AlreadyExists => {
                return Err(CoreError::conflict(
                    "A project with that name already exists",
                ));
            }
            made => made?,
        }
    }
    let moved = before_move(&root).and_then(|()| Ok(fs::rename(&root, &dest)?));
    if let Err(err) = moved {
        if reserved {
            let _ = fs::remove_dir(&dest);
        }
        return Err(err);
    }
    let main_file = read_settings(&dest).main_file;
    Ok(project_info(
        clean,
        newest(&dest, &fs::metadata(&dest)?),
        main_file,
    ))
}

/// Whether a rename from `src` to `dest` would land on another entry. On a
/// case-insensitive volume, the default on macOS and Windows, a case-only
/// rename's destination already "exists" because it is `src` itself.
fn occupied(src: &Path, dest: &Path) -> bool {
    fs::symlink_metadata(dest).is_ok() && !same_entry(src, dest)
}

/// Whether two paths name one entry, a link itself rather than its target.
#[cfg(unix)]
fn same_entry(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::symlink_metadata(a), fs::symlink_metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

/// Whether two paths name one entry. Windows' file identity is had only by
/// opening the file, which follows a link, so a link is only ever itself.
#[cfg(windows)]
fn same_entry(a: &Path, b: &Path) -> bool {
    let link = |path| fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink());
    !link(a) && !link(b) && same_file::is_same_file(a, b).unwrap_or(false)
}

/// Delete to the platform's trash, so a mis-click is recoverable. A trash
/// failure is reported and the original is left in place; it must never become
/// an implicit permanent-delete request.
pub(crate) fn discard(path: &Path) -> Result<(), CoreError> {
    trash::delete(path)
        .map_err(|err| CoreError::internal(format!("Could not move the item to Trash: {err}")))
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
                file_kind: children.is_none().then(|| file_kind(&entry.name)),
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

    let root = dunce::canonicalize(root)?;
    walk(&root, &root)
}

const TEXT_EXT: &[&str] = &[
    "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
    "py", "r", "dat", "def", "clo", "tikz",
];

/// What a host does with a file, by its extension in any case: "tex", "bib",
/// "image", "pdf", "text" (any other the editor edits: `TEXT_EXT`) or "other",
/// which it previews.
pub fn file_kind(name: &str) -> &'static str {
    match ext_of(name).as_str() {
        "tex" => "tex",
        "bib" => "bib",
        "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "bmp" => "image",
        "pdf" => "pdf",
        ext if TEXT_EXT.contains(&ext) => "text",
        _ => "other",
    }
}

pub fn create_file(root: &Path, rel: &str, dir: bool) -> Result<(), CoreError> {
    let abs = safe_write_path(root, rel)?;
    if abs.exists() {
        return Err(CoreError::conflict("Already exists"));
    }
    if dir {
        fs::create_dir_all(&abs)?;
    } else {
        write_creating(&abs, b"")?;
    }
    Ok(())
}

/// `create_file`, numbered past the names taken as Finder numbers copies
/// ("untitled.tex", "untitled 2.tex"); the path made.
pub fn create_free(root: &Path, rel: &str, dir: bool) -> Result<String, CoreError> {
    let (parent, name) = rel.rsplit_once('/').unwrap_or(("", rel));
    for n in 1.. {
        let free = if n == 1 {
            name.to_owned()
        } else {
            numbered(name, n)
        };
        let path = if parent.is_empty() {
            free
        } else {
            format!("{parent}/{free}")
        };
        match create_file(root, &path, dir) {
            Err(err) if err.status == 409 => {}
            made => return made.map(|()| path),
        }
    }
    unreachable!("a free name")
}

/// `path` with its links resolved as far as it exists, so one not yet made
/// or just trashed still compares with the library.
fn real_path(path: &Path) -> PathBuf {
    let (mut head, mut tail) = (path, Vec::new());
    loop {
        if let Ok(real) = fs::canonicalize(head) {
            return tail.iter().rev().fold(real, |real, name| real.join(name));
        }
        let (Some(parent), Some(name)) = (head.parent(), head.file_name()) else {
            return path.to_path_buf();
        };
        tail.push(name);
        head = parent;
    }
}

/// The project and the path in it of an absolute path in the library, or None
/// outside every project. A project's id is its folder's name.
pub fn locate(data_dir: &Path, path: &Path) -> Result<Option<Located>, CoreError> {
    let library = fs::canonicalize(data_dir)?;
    let real = real_path(path);
    let Some(rest) = path
        .is_absolute()
        .then(|| real.strip_prefix(&library).ok())
        .flatten()
    else {
        return Ok(None);
    };
    let names: Option<Vec<String>> = rest
        .components()
        .map(|part| match part {
            Component::Normal(name) => Some(name.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect();
    let Some([id, inside @ ..]) = names.as_deref() else {
        return Ok(None);
    };
    // The folders list_projects shows.
    if id.starts_with('.') || !data_dir.join(id).is_dir() {
        return Ok(None);
    }
    Ok(Some(Located {
        id: id.clone(),
        path: inside.join("/"),
    }))
}

pub(crate) fn write_creating(abs: &Path, contents: &[u8]) -> Result<atomic::Stamp, CoreError> {
    if let Some(parent) = abs.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(atomic::write(abs, contents)?)
}

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
    move_ui(root, |path| {
        after_entry(path, &from_rel).map(|rest| format!("{to_rel}{rest}"))
    });

    Ok(RenameResult {
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

// ---------- search ----------

// Keep one folded character per original character so snippet offsets agree.
// ASCII, most of a TeX file, folds without Unicode's tables.
fn lower_into(s: &str, out: &mut String) {
    out.clear();
    out.extend(s.chars().map(|c| {
        if c.is_ascii() {
            c.to_ascii_lowercase()
        } else {
            c.to_lowercase().next().unwrap_or(c)
        }
    }));
}

pub fn search_project(root: &Path, query: &str, limit: usize) -> Result<Vec<SearchHit>, CoreError> {
    let mut q = String::new();
    lower_into(query, &mut q);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let q_len = q.chars().count();
    let mut hits: Vec<SearchHit> = Vec::new();
    let mut lower = String::new();
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
            let Some(at) = lower.find(&q) else {
                continue;
            };
            let col = lower[..at].chars().count();
            let chars: Vec<char> = line.chars().collect();
            let start = col.saturating_sub(24);
            let ellipsis = if start > 0 { "…" } else { "" };
            let before: String = chars[start..col].iter().collect();
            let matched: String = chars[col..col + q_len].iter().collect();
            let after_end = (col + q_len + 60).min(chars.len());
            let after: String = chars[col + q_len..after_end].iter().collect();
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

/// A project's labels and citations, and the symbols of each .tex and .bib
/// file by project path, with the file's stamp when it was read: a scan reads
/// again only the files changed since the last, where every save would
/// otherwise read the whole project.
#[derive(Default)]
pub struct SymbolScan(BTreeMap<String, (Stamp, Symbols)>);

impl SymbolScan {
    /// The project's labels and citations. A scan that fails forgets what the
    /// last one read, and the next reads every file.
    pub fn scan(&mut self, root: &Path) -> Result<Symbols, CoreError> {
        let mut known = std::mem::take(&mut self.0);
        let mut files = BTreeMap::new();
        visit_files(root, &mut |abs, rel| {
            let ext = ext_of(rel);
            if ext != "bib" && ext != "tex" {
                return Ok(true);
            }
            // The stamp before the read: a write between them reads again.
            let Some(meta) = skip_unreadable(fs::metadata(abs))? else {
                return Ok(true);
            };
            let stamp = Stamp::of(&meta);
            let symbols = match known.remove(rel) {
                Some((seen, symbols)) if seen == stamp => symbols,
                _ => match skip_unreadable(fs::read(abs))? {
                    Some(bytes) => parse_symbols(&bytes, &ext),
                    None => return Ok(true),
                },
            };
            files.insert(rel.to_owned(), (stamp, symbols));
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
        let found = Symbols {
            citations: dedup(files.values().flat_map(|(_, s)| &s.citations)),
            labels: dedup(files.values().flat_map(|(_, s)| &s.labels)),
        };
        self.0 = files;
        Ok(found)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Located, SymbolScan, create_file, create_free, create_project, file_kind, locate,
        rename_entry,
    };
    use crate::paths::{after_entry, project_root};
    use crate::settings::{UiPatch, UiState, read_ui, write_ui};
    use std::fs;
    use std::path::{Path, PathBuf};

    fn project() -> (tempfile::TempDir, PathBuf) {
        let data = tempfile::tempdir().unwrap();
        create_project(data.path(), "P", "blank").unwrap();
        let root = project_root(data.path(), "P").unwrap();
        (data, root)
    }

    #[test]
    fn a_scan_reads_again_only_the_files_changed_since() {
        let dir = tempfile::tempdir().unwrap();
        let (root, a) = (dir.path(), dir.path().join("a.tex"));
        fs::write(&a, "\\label{one}").unwrap();
        fs::write(root.join("b.tex"), "\\label{two}").unwrap();
        let mut cache = SymbolScan::default();
        assert_eq!(cache.scan(root).unwrap().labels, ["one", "two"]);
        // Of the same length and date, it is as it was, and isn't read.
        let date = fs::metadata(&a).unwrap().modified().unwrap();
        fs::write(&a, "\\label{uno}").unwrap();
        let file = fs::File::options().write(true).open(&a).unwrap();
        file.set_modified(date).unwrap();
        drop(file);
        fs::write(root.join("b.tex"), "\\label{three}").unwrap();
        fs::write(root.join("c.bib"), "@book{key,").unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["one", "three"]);
        fs::remove_file(root.join("b.tex")).unwrap();
        let found = cache.scan(root).unwrap();
        assert_eq!(
            (found.labels, found.citations),
            (vec!["one".into()], vec!["key".into()])
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_scan_reads_through_a_link_whatever_file_it_names() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let (first, second) = (root.join("first.txt"), root.join("second.txt"));
        let link = root.join("link.tex");
        fs::write(&first, "\\label{one}").unwrap();
        fs::write(&second, "\\label{two}").unwrap();
        // Of one length and date: only which file it is tells them apart.
        let date = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        for target in [&first, &second] {
            let file = fs::File::open(target).unwrap();
            file.set_modified(date).unwrap();
        }
        std::os::unix::fs::symlink(&first, &link).unwrap();
        let mut cache = SymbolScan::default();
        assert_eq!(cache.scan(root).unwrap().labels, ["one"]);
        fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&second, &link).unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["two"]);
        // A save of the file it names, as the app writes it, shows through it.
        crate::atomic::write(&second, b"\\label{six}").unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["six"]);
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
        // On a Mac's or Windows' case-insensitive volume, Main.tex is main.tex.
        let insensitive = cfg!(any(target_os = "macos", windows));
        assert_eq!(after_entry("main.tex", "Main.tex").is_some(), insensitive);
        assert_eq!(
            after_entry("Chapters/a.tex", "chapters"),
            insensitive.then_some("/a.tex")
        );
    }

    #[test]
    fn a_new_entry_takes_the_next_free_name() {
        let (_data, root) = project();
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
        // Names the path rules refuse are refused, not numbered.
        for bad in [".texlocal.json", "../x.tex"] {
            assert_eq!(create_free(&root, bad, false).unwrap_err().status, 400);
        }
    }

    #[test]
    fn files_have_a_kind_in_any_case_and_folders_none() {
        let names = [
            "a.TEX", "r.bib", "p.JPG", "f.pdf", "s.sty", "d.csv", "z.zip", "x",
        ];
        let kinds: Vec<_> = names.map(file_kind).into();
        assert_eq!(
            kinds,
            [
                "tex", "bib", "image", "pdf", "text", "text", "other", "other"
            ]
        );
        let (_data, root) = project();
        create_file(&root, "figs/a.png", false).unwrap();
        let tree = serde_json::to_value(super::file_tree(&root).unwrap()).unwrap();
        let folder = tree
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["name"] == "figs");
        assert_eq!(folder.unwrap()["children"][0]["kind"], "image");
        assert!(folder.unwrap().get("kind").is_none());
    }

    #[test]
    fn a_path_in_the_library_is_found_in_its_project() {
        let (data, root) = project();
        create_file(&root, "a/b.tex", false).unwrap();
        let at = |path: &Path| locate(data.path(), path).unwrap();
        let found = |path: &str| {
            Some(Located {
                id: "P".into(),
                path: path.into(),
            })
        };
        assert_eq!(at(&root.join("a/b.tex")), found("a/b.tex"));
        assert_eq!(at(&root), found(""));
        // One not made yet, or just trashed, is where it was.
        assert_eq!(at(&root.join("a/gone.tex")), found("a/gone.tex"));
        // Not in a project: the library, a hidden folder, a missing one, a path
        // that leaves, a relative one.
        for outside in [
            data.path().to_path_buf(),
            data.path().join(".hidden/x"),
            data.path().join("Nope/x"),
            root.join("a/../../x"),
            PathBuf::from("P/a/b.tex"),
        ] {
            assert_eq!(at(&outside), None, "{outside:?}");
        }
    }

    #[test]
    fn a_renamed_entry_takes_its_saved_interface_state_along() {
        let (_data, root) = project();
        create_file(&root, "chapters/a.tex", false).unwrap();
        let list = |names: &[&str]| names.iter().map(|n| n.to_string()).collect::<Vec<_>>();
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
        // A file's fold follows it alone.
        rename_entry(&root, "content/a.tex", "content/b.tex").unwrap();
        let folds = read_ui(&root).folded_headings;
        assert_eq!(
            folds,
            list(&["content/b.tex\t1:Intro#1", "main.tex\t1:Intro#1"])
        );
    }
}
