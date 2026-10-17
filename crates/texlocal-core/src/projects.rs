//! Project and file management. Every project is a directory under the data
//! dir; all returned paths use forward slashes.

use std::cmp::Reverse;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::ErrorKind::{AlreadyExists, NotFound, PermissionDenied};
use std::io::Read;
use std::iter::once;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;
use std::time::UNIX_EPOCH;

use memchr::{memchr, memmem};
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
use crate::syntax::headings::uncommented;
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
    pub children: Option<Vec<Self>>,
}

/// Where an absolute path lies in the library: its project, and its path in it
/// ("" for the project's folder).
#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Located {
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
pub(crate) struct SearchHit {
    pub file: String,
    pub line: u32,
    /// Where the match starts in its line and how long it is, in UTF-16 units
    /// of the line's own text, as an editor counts them.
    pub column: u32,
    pub length: u32,
    pub before: String,
    #[serde(rename = "match")]
    pub matched: String,
    pub after: String,
}

/// A file's search hits, in the order found.
#[derive(Debug, Serialize)]
pub(crate) struct SearchGroup {
    pub file: String,
    pub hits: Vec<SearchHit>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Symbols {
    pub citations: Vec<String>,
    pub labels: Vec<String>,
}

fn mtime_ms(meta: &fs::Metadata) -> u64 {
    let since = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok());
    since.map_or(0, |since| since.as_millis() as u64)
}

/// A vanished or unreadable entry is skipped without failing a project scan.
fn skip_unreadable<T>(result: std::io::Result<T>) -> Result<Option<T>, CoreError> {
    match result {
        Err(err) if matches!(err.kind(), NotFound | PermissionDenied) => Ok(None),
        result => Ok(Some(result?)),
    }
}

/// Folders first, then by name ignoring case. Every walk of a project's files
/// (listing, search, symbols, its date) keeps its rules: hide dotfiles and
/// top-level build output, and follow only links to files within the
/// project. An entry that can't be read, or vanishes while the walk passes
/// (a build's or an editor's temporary file), is left out, and so an
/// unreadable subfolder is empty; the project root must be readable.
pub fn file_tree(root: &Path) -> Result<Vec<TreeNode>, CoreError> {
    let root = dunce::canonicalize(root)?;
    tree(&root, &root, "")
}

/// The tree of `dir`, whose project path is `prefix`, under the canonical `root`.
fn tree(root: &Path, dir: &Path, prefix: &str) -> Result<Vec<TreeNode>, CoreError> {
    let top = prefix.is_empty();
    let read = if top { Some(fs::read_dir(dir)?) } else { skip_unreadable(fs::read_dir(dir))? };
    let mut nodes = Vec::new();
    for entry in read.into_iter().flatten() {
        let Some(entry) = skip_unreadable(entry)? else {
            continue;
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        // Only top-level build/ is output; a nested build belongs to the author.
        if name.starts_with('.') || (top && name.eq_ignore_ascii_case(BUILD_DIR)) {
            continue;
        }
        let Some(kind) = skip_unreadable(entry.file_type())? else {
            continue;
        };
        let path = if top { name.clone() } else { format!("{prefix}/{name}") };
        // No directory links (cycles), nor any without a proven in-project target.
        let linked = |t: PathBuf| t.starts_with(root) && t.is_file();
        let children = if kind.is_dir() {
            Some(tree(root, &entry.path(), &path)?)
        } else if kind.is_file()
            || kind.is_symlink() && dunce::canonicalize(entry.path()).is_ok_and(linked)
        {
            None
        } else {
            continue;
        };
        nodes.push(TreeNode {
            kind: if children.is_some() { "dir" } else { "file" },
            file_kind: children.is_none().then(|| file_kind(&name)),
            name,
            path,
            children,
        });
    }
    nodes.sort_by_cached_key(|n| {
        (n.children.is_none(), n.name.to_lowercase(), Reverse(n.name.clone()))
    });
    Ok(nodes)
}

impl TreeNode {
    /// Every node of a tree, folders and files, at every depth.
    fn all(tree: &[Self]) -> impl Iterator<Item = &Self> {
        let mut stack: Vec<&Self> = tree.iter().collect();
        std::iter::from_fn(move || {
            let node = stack.pop()?;
            stack.extend(node.children.iter().flatten());
            Some(node)
        })
    }
}

/// The canonical root and the project paths of its content files.
fn content_files(root: &Path) -> Result<(PathBuf, Vec<String>), CoreError> {
    let root = dunce::canonicalize(root)?;
    let nodes = tree(&root, &root, "")?;
    let files = TreeNode::all(&nodes).filter(|node| node.children.is_none());
    let files = files.map(|node| node.path.clone()).collect();
    Ok((root, files))
}

/// A project's date as the library shows it: the newest of its folders' and top-level
/// files', without a stat of every file. Every save the app makes renames a file into
/// place and so moves its folder's date; a file saved in place by another app moves only
/// its own, and in a subfolder shows once anything else moves a folder's date.
pub(crate) fn project_info(name: String, root: &Path, meta: &fs::Metadata) -> ProjectInfo {
    let below = dunce::canonicalize(root).ok().and_then(|real| {
        let nodes = tree(&real, &real, "").ok()?;
        let dated = TreeNode::all(&nodes).filter(|n| n.children.is_some() || !n.path.contains('/'));
        let date =
            |node: &TreeNode| fs::metadata(real.join(&node.path)).map_or(0, |m| mtime_ms(&m));
        dated.map(date).max()
    });
    ProjectInfo {
        id: name.clone(),
        name,
        mtime: mtime_ms(meta).max(below.unwrap_or(0)),
        main_file: read_settings(root).main_file,
    }
}

pub(crate) fn list_projects(data_dir: &Path) -> Result<Vec<ProjectInfo>, CoreError> {
    let mut projects = Vec::new();
    for entry in fs::read_dir(data_dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || !entry.file_type()?.is_dir() {
            continue;
        }
        let root = data_dir.join(&name);
        if let Some(meta) = skip_unreadable(fs::metadata(&root))? {
            projects.push(project_info(name, &root, &meta));
        }
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
    write_settings(&root, &json!({}))?;
    Ok(project_info(clean, &root, &fs::metadata(&root)?))
}

/// The first free name in the series "Untitled", "Untitled 2", … (from
/// `base`, if given): one no entry of the library has, however it is spelled
/// where the volume ignores case. It creates nothing, so a host can offer it
/// as the name to edit; `create_project` numbers past anything taken since.
pub(crate) fn free_project_name(data_dir: &Path, base: Option<&str>) -> Result<String, CoreError> {
    let clean = sanitize_name(base.unwrap_or("Untitled"))?;
    let taken: HashSet<String> = match fs::read_dir(data_dir) {
        Ok(entries) => entries
            .map(|entry| entry.map(|e| fold_case(&e.file_name().to_string_lossy())))
            .collect::<Result<_, _>>()?,
        Err(err) if err.kind() == NotFound => HashSet::new(),
        Err(err) => return Err(err.into()),
    };
    let mut names = numbered(clean, String::new());
    Ok(names.find(|name| !taken.contains(&fold_case(name))).expect("a free name"))
}

/// `stem` + `ext`, then the copies Finder would number: "stem 2" + `ext`,
/// "stem 3" + `ext`…
fn numbered(stem: String, ext: String) -> impl Iterator<Item = String> {
    once(format!("{stem}{ext}")).chain((2..).map(move |n| format!("{stem} {n}{ext}")))
}

/// A new, empty project folder for `name`, or "name 2" and so on when that
/// is taken, as Finder numbers copies; and the name it got.
pub(crate) fn new_project_dir(data_dir: &Path, name: &str) -> Result<(String, PathBuf), CoreError> {
    let clean = sanitize_name(name)?;
    fs::create_dir_all(data_dir)?;
    for name in numbered(clean, String::new()) {
        let root = data_dir.join(&name);
        // One create rather than a check and then a create: it cannot race,
        // and it passes over anything already there, a dangling link or case
        // alias too.
        match fs::create_dir(&root) {
            Err(err) if err.kind() == AlreadyExists => {}
            created => return Ok(created.map(|()| (name, root))?),
        }
    }
    unreachable!("a free name")
}

/// The likely main file among a project's top-level .tex files: main.tex,
/// else the first by name that starts a document, else the first by name.
pub(crate) fn guess_main_file(root: &Path) -> Result<Option<String>, CoreError> {
    let mut tex: Vec<String> = Vec::new();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        // A name latexmk would read as an option can't be the main file.
        if entry.file_type()?.is_file() && file_kind(&name) == "tex" && !name.starts_with('-') {
            tex.push(name);
        }
    }
    tex.sort();
    let starts_document = |name: &&String| {
        fs::read(root.join(name.as_str()))
            .is_ok_and(|bytes| String::from_utf8_lossy(&bytes).contains("\\documentclass"))
    };
    let main = tex.iter().find(|name| name.eq_ignore_ascii_case("main.tex"));
    Ok(main.or_else(|| tex.iter().find(starts_document)).or(tex.first()).cloned())
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
            Err(err) if err.kind() == AlreadyExists => {
                return Err(CoreError::conflict("A project with that name already exists"));
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
    Ok(project_info(clean, &dest, &fs::metadata(&dest)?))
}

/// Whether two paths name one entry, a link itself rather than its target.
/// On a case-insensitive volume, the default on macOS and Windows, a
/// case-only rename's destination already "exists" because it is the source.
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

// ---------- files ----------

/// What a host does with a file, by its extension in any case: "tex", "bib",
/// "image", "pdf", "text" (any other the editor edits) or "other", which it
/// previews.
pub(crate) fn file_kind(name: &str) -> &'static str {
    let ext = Path::new(name).extension().unwrap_or_default();
    match ext.to_string_lossy().to_lowercase().as_str() {
        "tex" => "tex",
        "bib" => "bib",
        "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "bmp" => "image",
        "pdf" => "pdf",
        "cls" | "sty" | "bst" | "txt" | "md" | "csv" | "tsv" | "json" | "yaml" | "yml" | "lua"
        | "py" | "r" | "dat" | "def" | "clo" | "tikz" => "text",
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
pub(crate) fn create_free(root: &Path, rel: &str, dir: bool) -> Result<String, CoreError> {
    for path in copy_paths(rel) {
        match create_file(root, &path, dir) {
            Err(err) if err.status == 409 => {}
            made => return made.map(|()| path),
        }
    }
    unreachable!("a free name")
}

/// The paths an entry's copies take in turn in its folder, as Finder numbers
/// them: `rel`, then "main 2.tex", "main 3.tex"… or "figures 2", "figures 3"…
pub(crate) fn copy_paths(rel: &str) -> impl Iterator<Item = String> + use<> {
    let name_at = rel.rfind('/').map_or(0, |i| i + 1);
    match rel[name_at..].rfind('.').filter(|&dot| dot > 0) {
        Some(dot) => numbered(rel[..name_at + dot].into(), rel[name_at + dot..].into()),
        None => numbered(rel.into(), String::new()),
    }
}

/// The project and the path in it of an absolute path in the library, or None
/// outside every project. A project's id is its folder's name. The path's
/// links are resolved as far as it exists, so one not yet made or just
/// trashed still compares with the library.
pub(crate) fn locate(data_dir: &Path, path: &Path) -> Result<Option<Located>, CoreError> {
    let library = fs::canonicalize(data_dir)?;
    let real = path
        .ancestors()
        .find_map(|head| Some(fs::canonicalize(head).ok()?.join(path.strip_prefix(head).ok()?)));
    let rest = real.as_deref().and_then(|real| real.strip_prefix(&library).ok());
    let Some(rest) = rest.filter(|_| path.is_absolute()) else {
        return Ok(None);
    };
    let names: Option<Vec<_>> = rest
        .components()
        .map(|part| match part {
            Component::Normal(name) => Some(name.to_string_lossy()),
            _ => None,
        })
        .collect();
    let Some([id, inside @ ..]) = names.as_deref() else {
        return Ok(None);
    };
    // The folders list_projects shows.
    let shown = !id.starts_with('.') && data_dir.join(&**id).is_dir();
    Ok(shown.then(|| Located { id: id.to_string(), path: inside.join("/") }))
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
    if fs::symlink_metadata(&dest).is_ok() && !same_entry(&src, &dest) {
        return Err(CoreError::conflict("Destination already exists"));
    }
    if is_under(&to_rel, &from_rel) {
        return Err(CoreError::bad_request("A folder can't be moved into itself"));
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }

    let main_file = read_settings(root).main_file;
    // Each project path's new one, None for one the rename leaves.
    let moved = |path: &str| after_entry(path, &from_rel).map(|rest| format!("{to_rel}{rest}"));
    let moved_main = moved(&main_file);
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
    move_ui(root, moved);
    let main_file = moved_main.unwrap_or(main_file);
    Ok(RenameResult { from: from_rel, to: to_rel, main_file })
}

/// Move to the Trash an entry an incoming file of its name replaces, so a
/// mis-click is recoverable; a Trash failure is reported and the entry left,
/// never made a permanent delete. The main file may go, since the file taking
/// its place keeps it valid; a folder holding it may not, however the upload
/// spells its name.
pub(crate) fn discard_replaced(root: &Path, rel: &str) -> Result<(), CoreError> {
    if is_under(&read_settings(root).main_file, rel) {
        return Err(CoreError::conflict(
            "Choose a different main file before replacing this folder",
        ));
    }
    trash::delete(safe_path(root, rel)?)
        .map_err(|err| CoreError::internal(format!("Could not move the item to Trash: {err}")))
}

// ---------- search ----------

/// `search_project`'s hits, which come in path order, by file.
pub(crate) fn search_groups(hits: Vec<SearchHit>) -> Vec<SearchGroup> {
    let mut groups: Vec<SearchGroup> = Vec::new();
    for hit in hits {
        match groups.last_mut() {
            Some(group) if group.file == hit.file => group.hits.push(hit),
            _ => groups.push(SearchGroup { file: hit.file.clone(), hits: vec![hit] }),
        }
    }
    groups
}

/// `text` lowercased one character for one, so a match's place in it is its
/// place in `text` in characters.
fn fold_into(text: &str, out: &mut String) {
    out.clear();
    if text.is_ascii() {
        out.push_str(text);
        out.make_ascii_lowercase();
    } else {
        out.extend(text.chars().map(|c| c.to_lowercase().next().unwrap_or(c)));
    }
}

/// The first `limit` lines that hold `query`, in any case, of the project's
/// text files in path order. Each file is read and lowercased once, and the
/// search jumps from match to match, never visiting a line without one.
pub(crate) fn search_project(
    root: &Path,
    query: &str,
    limit: usize,
) -> Result<Vec<SearchHit>, CoreError> {
    let mut needle = String::new();
    fold_into(query, &mut needle);
    let mut hits = Vec::new();
    // No line holds a line break.
    if needle.is_empty() || needle.contains('\n') {
        return Ok(hits);
    }
    let finder = memmem::Finder::new(&needle);
    let needle_chars = needle.chars().count();
    let (root, mut files) = content_files(root)?;
    files.retain(|file| matches!(file_kind(file), "tex" | "bib" | "text"));
    files.sort_unstable();
    let line_end = |s: &str, from: usize| memchr(b'\n', &s.as_bytes()[from..]).map(|i| from + i);
    let (mut bytes, mut folded) = (Vec::new(), String::new());
    for file in files {
        if hits.len() >= limit {
            break;
        }
        bytes.clear();
        let read = fs::File::open(root.join(&file)).and_then(|mut f| f.read_to_end(&mut bytes));
        if skip_unreadable(read)?.is_none() {
            continue;
        }
        let text = String::from_utf8_lossy(&bytes);
        fold_into(&text, &mut folded);
        // The line being looked at: its number and its starts in `folded`
        // and in `text`, whose lines are as many.
        let (mut line, mut at, mut start) = (0, 0, 0);
        while hits.len() < limit {
            let Some(found) = finder.find(&folded.as_bytes()[at..]).map(|i| at + i) else {
                break;
            };
            while let Some(end) = line_end(&folded, at).filter(|&end| end < found) {
                (line, at) = (line + 1, end + 1);
                start = line_end(&text, start).map_or(text.len(), |end| end + 1);
            }
            let text_line = &text[start..line_end(&text, start).unwrap_or(text.len())];
            let column = folded[at..found].chars().count();
            hits.push(hit(&file, line + 1, text_line, column, needle_chars));
            // On to the next line: a hit is a line's first match.
            let Some(end) = line_end(&folded, found) else {
                break;
            };
            (line, at, start) = (line + 1, end + 1, start + text_line.len() + 1);
        }
    }
    Ok(hits)
}

/// The hit of `chars` characters at character `column` of `text`, a line,
/// with up to 24 characters before it and 60 after.
fn hit(file: &str, line: usize, text: &str, column: usize, chars: usize) -> SearchHit {
    let skip =
        |from: usize, n| text[from..].char_indices().nth(n).map_or(text.len(), |(i, _)| from + i);
    let (from, cut) = (skip(0, column), skip(0, column.saturating_sub(24)));
    let to = skip(from, chars);
    let units = |s: &str| s.encode_utf16().count() as u32;
    let ellipsis = if cut > 0 { "…" } else { "" };
    SearchHit {
        file: file.to_owned(),
        line: line as u32,
        column: units(&text[..from]),
        length: units(&text[from..to]),
        before: format!("{ellipsis}{}", &text[cut..from]).trim_start().to_owned(),
        matched: text[from..to].to_owned(),
        after: text[to..skip(to, 60)].trim_end().to_owned(),
    }
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

fn parse_symbols(bytes: &[u8], bib: bool) -> Symbols {
    let keys =
        |re: &Regex, text| re.captures_iter(text).map(|m| m[1].to_owned()).collect::<Vec<_>>();
    let text = String::from_utf8_lossy(bytes);
    let mut found = Symbols::default();
    if bib {
        found.citations = keys(&BIB_KEY, &text);
    } else {
        for line in text.lines().map(uncommented) {
            found.labels.extend(keys(&LABEL, line));
            found.citations.extend(keys(&BIBITEM, line));
        }
    }
    found
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
        let (root, files) = content_files(root)?;
        for file in files {
            let bib = match file_kind(&file) {
                "bib" => true,
                "tex" => false,
                _ => continue,
            };
            // The stamp before the read: a write between them reads again.
            let abs = root.join(&file);
            let Some(meta) = skip_unreadable(fs::metadata(&abs))? else {
                continue;
            };
            let stamp = Stamp::of(&meta);
            let symbols = match known.remove(&file) {
                Some((seen, symbols)) if seen == stamp => symbols,
                _ => match skip_unreadable(fs::read(&abs))? {
                    Some(bytes) => parse_symbols(&bytes, bib),
                    None => continue,
                },
            };
            self.0.insert(file, (stamp, symbols));
        }
        fn dedup<'a>(symbols: impl Iterator<Item = &'a String>) -> Vec<String> {
            let mut seen = HashSet::new();
            symbols.filter(|s| seen.insert(*s)).cloned().collect()
        }
        // File-name order keeps completions stable, retaining the first occurrence.
        Ok(Symbols {
            citations: dedup(self.0.values().flat_map(|(_, s)| &s.citations)),
            labels: dedup(self.0.values().flat_map(|(_, s)| &s.labels)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{UiPatch, read_ui, write_ui};

    /// A library's blank project and its folder.
    fn project() -> (tempfile::TempDir, PathBuf) {
        let (dir, service) = crate::testing::library(&["P"]);
        (dir, service.project_root("P").unwrap())
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
        assert_eq!([found.labels, found.citations], [["one"], ["key"]]);
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
        let date = UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        for target in [&first, &second] {
            fs::File::open(target).unwrap().set_modified(date).unwrap();
        }
        std::os::unix::fs::symlink(&first, &link).unwrap();
        let mut cache = SymbolScan::default();
        assert_eq!(cache.scan(root).unwrap().labels, ["one"]);
        fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&second, &link).unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["two"]);
        // A save of the file it names, as the app writes it, shows through it.
        atomic::write(&second, b"\\label{six}").unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["six"]);
    }

    #[test]
    fn search_takes_each_lines_first_match_in_path_order_up_to_the_limit() {
        let (_data, root) = project();
        let files = [
            ("main.tex", "x\r\nNeedle needle\r\n\nné needle\n"),
            ("a/z.tex", "needle"),
            ("a.txt", "needle\n"),
            ("a.png", "needle\n"),
        ];
        for (file, text) in files {
            write_creating(&root.join(file), text.as_bytes()).unwrap();
        }
        let hits = search_project(&root, "NEEDLE", 10).unwrap();
        let found: Vec<_> =
            hits.iter().map(|h| (h.file.as_str(), h.line, h.column, h.after.as_str())).collect();
        let want = [
            ("a.txt", 1, 0, ""),
            ("a/z.tex", 1, 0, ""),
            ("main.tex", 2, 0, " needle"),
            ("main.tex", 4, 3, ""),
        ];
        assert_eq!(found, want);
        let groups = search_groups(search_project(&root, "needle", 3).unwrap());
        let files: Vec<_> = groups.iter().map(|g| (g.file.as_str(), g.hits.len())).collect();
        assert_eq!(files, [("a.txt", 1), ("a/z.tex", 1), ("main.tex", 1)]);
        // A long line's snippet is cut, and marked so, before the match.
        let long = format!("{}needle{}", "é".repeat(30), "b".repeat(70));
        fs::write(root.join("a.txt"), long).unwrap();
        let hit = &search_project(&root, "needle", 1).unwrap()[0];
        assert_eq!(hit.before, format!("…{}", "é".repeat(24)));
        assert_eq!((hit.column, hit.after.len()), (30, 60));
        for nothing in ["", "x\nN"] {
            assert!(search_project(&root, nothing, 10).unwrap().is_empty());
        }
    }

    #[test]
    fn a_new_entry_takes_the_next_free_name() {
        let (_data, root) = project();
        let made: Vec<_> =
            (0..3).map(|_| create_free(&root, "notes/untitled.tex", false).unwrap()).collect();
        assert_eq!(made, ["notes/untitled.tex", "notes/untitled 2.tex", "notes/untitled 3.tex"]);
        let folders: Vec<_> =
            (0..2).map(|_| create_free(&root, "untitled folder", true).unwrap()).collect();
        assert_eq!(folders, ["untitled folder", "untitled folder 2"]);
        assert!(root.join("untitled folder 2").is_dir());
        let copies: Vec<_> =
            copy_paths("a.b/.rc").take(2).chain(copy_paths("a.b/c").skip(1).take(1)).collect();
        assert_eq!(copies, ["a.b/.rc", "a.b/.rc 2", "a.b/c 2"]);
        // Names the path rules refuse are refused, not numbered.
        for bad in [".texlocal.json", "../x.tex"] {
            assert_eq!(create_free(&root, bad, false).unwrap_err().status, 400);
        }
    }

    #[test]
    fn files_have_a_kind_in_any_case() {
        let names = ["a.TEX", "r.bib", "p.JPG", "f.pdf", "s.sty", "d.csv", "z.zip", "x"];
        let kinds = ["tex", "bib", "image", "pdf", "text", "text", "other", "other"];
        assert_eq!(names.map(file_kind), kinds);
    }

    /// As root (CI's containers) no permission locks a file, so the scans'
    /// tests reach this only by a race.
    #[test]
    fn a_vanished_or_locked_entry_is_skipped_and_nothing_else() {
        for kind in [NotFound, PermissionDenied] {
            assert!(skip_unreadable::<()>(Err(kind.into())).unwrap().is_none());
        }
        assert!(skip_unreadable::<()>(Err(std::io::ErrorKind::Other.into())).is_err());
    }

    #[test]
    fn a_path_in_the_library_is_found_in_its_project() {
        let (_dir, root) = project();
        let library = root.parent().unwrap();
        create_file(&root, "a/b.tex", false).unwrap();
        let at = |path: &Path| locate(library, path).unwrap().map(|l| l.path);
        assert_eq!(at(&root.join("a/b.tex")).as_deref(), Some("a/b.tex"));
        assert_eq!(at(&root).as_deref(), Some(""));
        // One not made yet, or just trashed, is where it was.
        assert_eq!(at(&root.join("a/gone/x.tex")).as_deref(), Some("a/gone/x.tex"));
        // Not in a project: the library, a hidden folder, a missing one, a path
        // that leaves, a relative one.
        for outside in [
            library,
            &library.join(".hidden/x"),
            &library.join("Nope/x"),
            &root.join("a/../../x"),
            Path::new("P/a/b.tex"),
        ] {
            assert_eq!(at(outside), None, "{outside:?}");
        }
    }

    #[test]
    fn a_renamed_entry_takes_its_saved_interface_state_along() {
        let (_data, root) = project();
        create_file(&root, "chapters/a.tex", false).unwrap();
        let strings = |names: &[&str]| names.iter().map(ToString::to_string).collect::<Vec<_>>();
        let patch = UiPatch {
            expanded_folders: Some(strings(&["other", "chapters/deep", "chapters"])),
            folded_headings: Some(strings(&["main.tex\t1:Intro#1", "chapters/a.tex\t1:Intro#1"])),
        };
        write_ui(&root, patch).unwrap();
        rename_entry(&root, "chapters", "content").unwrap();
        let ui = read_ui(&root);
        assert_eq!(ui.expanded_folders, ["content", "content/deep", "other"]);
        assert_eq!(ui.folded_headings, ["content/a.tex\t1:Intro#1", "main.tex\t1:Intro#1"]);
        // A file's fold follows it alone.
        rename_entry(&root, "content/a.tex", "content/b.tex").unwrap();
        let folds = read_ui(&root).folded_headings;
        assert_eq!(folds, ["content/b.tex\t1:Intro#1", "main.tex\t1:Intro#1"]);
    }
}
