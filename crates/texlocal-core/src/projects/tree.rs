//! What a project shows of its folder: the entries the walks agree on, the file tree the sidebar
//! lists, and what kind of file each is.

use std::cmp::Reverse;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use super::skip_unreadable;
use crate::BUILD_DIR;
use crate::error::CoreError;
use crate::paths::{Project, fold_case};
use crate::settings::read_settings;

#[derive(Debug, Serialize)]
pub struct TreeNode {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub name: String,
    pub path: String,
    #[serde(rename = "kind", skip_serializing_if = "Option::is_none")]
    pub file_kind: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<Self>>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub main: bool,
}

pub(crate) struct Entry {
    pub path: PathBuf,
    /// Its path from the walk's root.
    pub rel: String,
    pub name: String,
    pub dir: bool,
    pub link: bool,
}

/// What the tree lists, and so what search, the scans, history and a session's watcher see: no
/// dotfiles, and no compile output, which is the top-level build folder alone (a nested build
/// is the author's).
pub(crate) fn listed(rel: &str) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    !name.starts_with('.') && !rel.eq_ignore_ascii_case(BUILD_DIR)
}

/// A folder's entries whose path `keep` takes, by name. Links are followed to files only, as
/// folder links can cycle; an entry gone or unreadable by the time it's read is left out, but
/// the root must be read.
fn entries(root: &Path, dir: &Path, keep: &dyn Fn(&str) -> bool) -> Result<Vec<Entry>, CoreError> {
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
        let path = entry.path();
        let rel = path
            .strip_prefix(root)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let Some(kind) = skip_unreadable(entry.file_type())? else {
            continue;
        };
        let link = kind.is_symlink();
        if keep(&rel) && (kind.is_dir() || kind.is_file() || link && path.is_file()) {
            let name = entry.file_name().to_string_lossy().into_owned();
            let dir = kind.is_dir();
            out.push(Entry {
                path,
                rel,
                name,
                dir,
                link,
            });
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// Each entry under `root` that `keep` takes, a folder before what's in it, until `visit`
/// answers false.
pub(crate) fn walk(
    root: &Path,
    keep: &dyn Fn(&str) -> bool,
    visit: &mut dyn FnMut(&Entry) -> Result<bool, CoreError>,
) -> Result<(), CoreError> {
    fn walk_in(
        root: &Path,
        dir: &Path,
        keep: &dyn Fn(&str) -> bool,
        visit: &mut dyn FnMut(&Entry) -> Result<bool, CoreError>,
    ) -> Result<bool, CoreError> {
        for entry in entries(root, dir, keep)? {
            if !visit(&entry)? || entry.dir && !walk_in(root, &entry.path, keep, visit)? {
                return Ok(false);
            }
        }
        Ok(true)
    }
    walk_in(root, root, keep, visit).map(drop)
}

/// Each file the tree lists, with its path from the root, until `visit` answers false.
pub(super) fn visit_files(
    root: &Path,
    visit: &mut dyn FnMut(&Path, &str) -> Result<bool, CoreError>,
) -> Result<(), CoreError> {
    walk(root, &listed, &mut |entry| {
        if entry.dir {
            return Ok(true);
        }
        visit(&entry.path, &entry.rel)
    })
}

/// The main file is marked however the settings spell it, as latexmk finds it.
pub fn file_tree(project: &Project) -> Result<Vec<TreeNode>, CoreError> {
    fn nodes(root: &Path, dir: &Path, main: &str) -> Result<Vec<TreeNode>, CoreError> {
        let mut found = Vec::new();
        for entry in entries(root, dir, &listed)? {
            let children = if entry.dir {
                Some(nodes(root, &entry.path, main)?)
            } else {
                None
            };
            found.push(TreeNode {
                kind: if entry.dir { "dir" } else { "file" },
                main: !entry.dir && fold_case(&entry.rel) == main,
                path: entry.rel,
                file_kind: (!entry.dir).then(|| file_kind(&entry.name)),
                name: entry.name,
                children,
            });
        }
        found.sort_by_cached_key(|n| {
            (
                n.children.is_none(),
                n.name.to_lowercase(),
                Reverse(n.name.clone()),
            )
        });
        Ok(found)
    }
    let main = read_settings(&project.settings).main_file;
    nodes(&project.root, &project.root, &fold_case(&main))
}

/// What the editor edits as text besides .tex and .bib, by extension.
const TEXT_EXTENSIONS: &[&str] = &[
    "ltx", "cls", "sty", "clo", "def", "cfg", "bst", "bbx", "cbx", "lbx", "dtx", "ins", "ist",
    "lco", "tikz", "pgf", "mf", "mp", "asy", "rnw", "rmd", "qmd", "md", "txt", "csv", "tsv", "dat",
    "json", "yaml", "yml", "toml", "ini", "xml", "lua", "py", "r", "sh",
];

const TEXT_NAMES: &[&str] = &["latexmkrc", "makefile", "license", "readme"];

/// What a host does with a file, by its extension in any case: "tex", "bib", "image", "pdf",
/// "text" (any other the editor edits: `TEXT_EXTENSIONS`, and a few extensionless names) or
/// "other", which it previews.
pub fn file_kind(name: &str) -> &'static str {
    let path = Path::new(name);
    let lower = |part: Option<&OsStr>| part.unwrap_or_default().to_string_lossy().to_lowercase();
    match lower(path.extension()).as_str() {
        "tex" => "tex",
        "bib" => "bib",
        "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "bmp" => "image",
        "pdf" => "pdf",
        ext if TEXT_EXTENSIONS.contains(&ext) => "text",
        "" if TEXT_NAMES.contains(&lower(path.file_name()).as_str()) => "text",
        _ => "other",
    }
}

pub(crate) fn is_text(name: &str) -> bool {
    matches!(file_kind(name), "tex" | "bib" | "text")
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::projects::create_free;
    use crate::projects::testing::project;

    /// The TeX ecosystem's own files are text the editor edits and search reads.
    #[test]
    fn files_have_a_kind_by_extension_in_any_case_or_by_a_known_name() {
        let kinds = [
            ("a.TEX", "tex"),
            ("r.bib", "bib"),
            ("p.JPG", "image"),
            ("f.pdf", "pdf"),
            ("s.sty", "text"),
            ("d.csv", "text"),
            ("paper.ltx", "text"),
            ("refs.bbx", "text"),
            ("pkg.dtx", "text"),
            ("letter.lco", "text"),
            ("chapters/a.CLO", "text"),
            ("latexmkrc", "text"),
            ("Makefile", "text"),
            ("LICENSE", "text"),
            ("z.zip", "other"),
            ("a.aux", "other"),
            ("noextension", "other"),
        ];
        for (name, kind) in kinds {
            assert_eq!(file_kind(name), kind, "{name}");
        }
    }

    #[test]
    fn the_file_tree_lists_folders_first_then_names_ignoring_case() {
        let (_dir, root) = project();
        for file in ["c.tex", "B.tex", "Zeta/z.png", "beta/y.tex", ".hidden.tex"] {
            create_free(&root, file, false).unwrap();
        }
        let tree = file_tree(&Project::in_folder(&root)).unwrap();
        let names: Vec<&str> = tree.iter().map(|n| n.name.as_str()).collect();
        assert_eq!(names, ["beta", "Zeta", "B.tex", "c.tex", "main.tex"]);
        let json = serde_json::to_value(&tree[1]).unwrap();
        let child =
            json!({ "type": "file", "name": "z.png", "path": "Zeta/z.png", "kind": "image" });
        assert_eq!(
            json,
            json!({ "type": "dir", "name": "Zeta", "path": "Zeta", "children": [child] })
        );
        let main = serde_json::to_value(&tree[4]).unwrap();
        assert_eq!(main["main"], true);
    }
}
