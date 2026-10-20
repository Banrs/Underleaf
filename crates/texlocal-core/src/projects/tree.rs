//! What a project shows of its folder: the entries the walks agree on, the
//! file tree the sidebar lists, and what kind of file each is.

use std::borrow::Cow;
use std::cmp::Reverse;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use super::skip_unreadable;
use crate::BUILD_DIR;
use crate::error::CoreError;

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

pub(super) struct Entry {
    pub path: PathBuf,
    pub name: String,
    pub dir: bool,
}

impl Entry {
    /// Its path from the root, in forward slashes on Windows too, where no
    /// name holds a backslash.
    fn rel<'a>(&'a self, root: &Path) -> Cow<'a, str> {
        let rel = self.path.strip_prefix(root).unwrap().to_string_lossy();
        if cfg!(windows) {
            rel.replace('\\', "/").into()
        } else {
            rel
        }
    }
}

/// Shared tree rules for file listing, search and symbols: hide dotfiles and
/// top-level build output, and follow links to files only, as folder links
/// can cycle. An entry that can't be read, or vanishes while the walk passes
/// (a build's or an editor's temporary file), is left out, and so an
/// unreadable subfolder is empty; the project root must be readable.
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

/// Every content file in the project, depth-first, with its project-relative
/// path. The visitor returns false to stop the walk.
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

    walk(root, root, visit)?;
    Ok(())
}

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

    walk(root, root)
}

/// What the editor edits as text, besides .tex and .bib, by extension: the
/// rest of TeX's own files (classes, styles, bibliography and citation styles,
/// letter classes, docstrip sources), figure sources, documents that compile
/// to TeX, and the data and scripts that sit beside a document.
const TEXT_EXTENSIONS: &[&str] = &[
    "ltx", "cls", "sty", "clo", "def", "cfg", "bst", "bbx", "cbx", "lbx", "dtx", "ins", "ist",
    "lco", "tikz", "pgf", "mf", "mp", "asy", "rnw", "rmd", "qmd", "md", "txt", "csv", "tsv", "dat",
    "json", "yaml", "yml", "toml", "ini", "xml", "lua", "py", "r", "sh",
];

/// Files with no extension that are text all the same.
const TEXT_NAMES: &[&str] = &["latexmkrc", "makefile", "license", "readme"];

/// What a host does with a file, by its extension in any case: "tex", "bib",
/// "image", "pdf", "text" (any other the editor edits: `TEXT_EXTENSIONS`, and
/// a few extensionless names) or "other", which it previews.
pub fn file_kind(name: &str) -> &'static str {
    let path = Path::new(name);
    let lower = |part: Option<&OsStr>| {
        part.map(|part| part.to_string_lossy().to_lowercase())
            .unwrap_or_default()
    };
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

/// Whether a file is one the editor edits, and a search reads.
pub(crate) fn is_text(name: &str) -> bool {
    matches!(file_kind(name), "tex" | "bib" | "text")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::create_free;
    use crate::projects::testing::project;

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
        let (_dir, root) = project();
        create_free(&root, "figs/a.png", false).unwrap();
        let tree = serde_json::to_value(file_tree(&root).unwrap()).unwrap();
        // Folders first.
        let folder = &tree[0];
        assert_eq!(folder["children"][0]["kind"], "image");
        assert!(folder["name"] == "figs" && folder.get("kind").is_none());
    }

    #[test]
    fn the_tex_ecosystems_own_files_are_text_the_editor_edits_and_search_reads() {
        for name in [
            "paper.ltx",
            "local.cfg",
            "refs.bbx",
            "refs.cbx",
            "pkg.dtx",
            "pkg.ins",
            "my.ist",
            "letter.lco",
            "chapters/a.CLO",
            "latexmkrc",
            "Makefile",
            "LICENSE",
        ] {
            assert!(is_text(name), "{name}");
        }
        for name in [
            "a.zip",
            "a.aux",
            "a.log",
            "noextension",
            "photo.png",
            "a.pdf",
        ] {
            assert!(!is_text(name), "{name}");
        }
    }

    #[test]
    fn the_file_tree_lists_folders_first_then_names_ignoring_case() {
        let (_dir, root) = project();
        for file in ["c.tex", "B.tex", "Zeta/z.tex", "beta/y.tex", ".hidden.tex"] {
            create_free(&root, file, false).unwrap();
        }
        let tree = file_tree(&root).unwrap();
        let names: Vec<&str> = tree.iter().map(|n| n.name.as_str()).collect();
        assert_eq!(names, ["beta", "Zeta", "B.tex", "c.tex", "main.tex"]);
        assert_eq!(tree[1].kind, "dir");
        assert_eq!(tree[1].children.as_ref().unwrap()[0].path, "Zeta/z.tex");
        assert!(tree[2].children.is_none());
    }
}
