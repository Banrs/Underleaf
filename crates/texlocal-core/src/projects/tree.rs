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

pub(super) struct Entry {
    pub path: PathBuf,
    pub name: String,
    pub dir: bool,
}

impl Entry {
    /// Its path from the root, in forward slashes on Windows too, where no name holds a
    /// backslash.
    fn rel(&self, root: &Path) -> String {
        let rel = self.path.strip_prefix(root).unwrap().to_string_lossy();
        if cfg!(windows) {
            rel.replace('\\', "/")
        } else {
            rel.into_owned()
        }
    }
}

/// Shared tree rules for listing, search and symbols: hide dotfiles and top-level build output,
/// follow links to files only (folder links can cycle), and leave out entries that vanish
/// mid-walk.
pub(super) fn entries(root: &Path, dir: &Path) -> Result<Vec<Entry>, CoreError> {
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
        let shown = if kind.is_symlink() {
            path.is_file()
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

/// Each file with its path from the root, until `visit` answers false.
pub(super) fn visit_files(
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
    walk(root, root, visit).map(drop)
}

/// The main file is marked however the settings spell it, as latexmk finds it.
pub fn file_tree(project: &Project) -> Result<Vec<TreeNode>, CoreError> {
    fn walk(root: &Path, dir: &Path, main: &str) -> Result<Vec<TreeNode>, CoreError> {
        let mut nodes = Vec::new();
        for entry in entries(root, dir)? {
            let children = if entry.dir {
                Some(walk(root, &entry.path, main)?)
            } else {
                None
            };
            let path = entry.rel(root);
            nodes.push(TreeNode {
                kind: if entry.dir { "dir" } else { "file" },
                main: !entry.dir && fold_case(&path) == main,
                path,
                file_kind: (!entry.dir).then(|| file_kind(&entry.name)),
                name: entry.name,
                children,
            });
        }
        nodes.sort_by_cached_key(|n| {
            (
                n.children.is_none(),
                n.name.to_lowercase(),
                Reverse(n.name.clone()),
            )
        });
        Ok(nodes)
    }
    let main = read_settings(&project.settings).main_file;
    walk(&project.root, &project.root, &fold_case(&main))
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
