use std::fs;
use std::io::ErrorKind::{NotFound, PermissionDenied};
use std::path::{Path, PathBuf};

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::{FileKind, file_kind};

use super::skip_unreadable;
use crate::BUILD_DIR;
use crate::error::CoreError;
use crate::messages;
use crate::paths::{Project, fold_case, relative};
use crate::settings::read_settings;

#[derive(Serialize, JsonSchema)]
pub struct TreeNode {
    pub name: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<FileKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<Self>>,
    pub main: bool,
}

pub(crate) struct Entry {
    pub path: PathBuf,
    pub rel: String,
    pub name: String,
    pub dir: bool,
    pub link: bool,
}

pub(crate) fn listed(rel: &str) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    !name.starts_with('.') && fold_case(rel) != BUILD_DIR
}

fn entries(
    root: &Path,
    dir: &Path,
    keep: &dyn Fn(&str) -> bool,
    whole: bool,
) -> Result<Vec<Entry>, CoreError> {
    let read = match fs::read_dir(dir) {
        Err(err) if dir == root => return Err(err.into()),
        Err(err) if err.kind() == NotFound || !whole && err.kind() == PermissionDenied => {
            return Ok(Vec::new());
        }
        read => read.map_err(CoreError::at(dir))?,
    };
    let mut out = Vec::new();
    for entry in read {
        let Some(entry) = skip_unreadable(entry)? else {
            continue;
        };
        let path = entry.path();
        let Some(rel) = relative(root, &path) else {
            if whole {
                return Err(CoreError::bad_request(messages::not_utf8_name(
                    path.display(),
                )));
            }
            continue;
        };
        let Some(kind) = skip_unreadable(entry.file_type())? else {
            continue;
        };
        let link = kind.is_symlink();
        if keep(&rel) && (kind.is_dir() || kind.is_file() || link && path.is_file()) {
            let name = rel.rsplit('/').next().unwrap_or(&rel).to_owned();
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

pub(crate) fn walk(
    root: &Path,
    keep: &dyn Fn(&str) -> bool,
    whole: bool,
    visit: &mut dyn FnMut(&Entry) -> Result<bool, CoreError>,
) -> Result<(), CoreError> {
    fn walk_in(
        root: &Path,
        dir: &Path,
        keep: &dyn Fn(&str) -> bool,
        whole: bool,
        visit: &mut dyn FnMut(&Entry) -> Result<bool, CoreError>,
    ) -> Result<bool, CoreError> {
        for entry in entries(root, dir, keep, whole)? {
            if !visit(&entry)? || entry.dir && !walk_in(root, &entry.path, keep, whole, visit)? {
                return Ok(false);
            }
        }
        Ok(true)
    }
    walk_in(root, root, keep, whole, visit).map(drop)
}

pub(super) fn visit_files(
    root: &Path,
    visit: &mut dyn FnMut(&Path, &str) -> Result<bool, CoreError>,
) -> Result<(), CoreError> {
    walk(root, &listed, false, &mut |entry| {
        if entry.dir {
            return Ok(true);
        }
        visit(&entry.path, &entry.rel)
    })
}

pub fn file_tree(project: &Project) -> Result<Vec<TreeNode>, CoreError> {
    fn nodes(root: &Path, dir: &Path, main: &str) -> Result<Vec<TreeNode>, CoreError> {
        let mut found = Vec::new();
        for entry in entries(root, dir, &listed, false)? {
            let children = if entry.dir {
                Some(nodes(root, &entry.path, main)?)
            } else {
                None
            };
            found.push(TreeNode {
                main: !entry.dir && fold_case(&entry.rel) == main,
                path: entry.rel,
                kind: (!entry.dir).then(|| file_kind(&entry.name)),
                name: entry.name,
                children,
            });
        }
        Ok(found)
    }
    let main = read_settings(&project.settings).main_file;
    nodes(&project.root, &project.root, &fold_case(&main))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rels(root: &Path, whole: bool) -> Result<Vec<String>, CoreError> {
        let mut rels = Vec::new();
        walk(root, &listed, whole, &mut |entry| {
            rels.push(entry.rel.clone());
            Ok(true)
        })?;
        Ok(rels)
    }

    #[test]
    fn a_nested_files_rel_is_joined_with_slashes_and_a_hidden_folder_is_left_out() {
        let dir = tempfile::tempdir().unwrap();
        for file in ["a/b.tex", "a/.git/c.tex", "d.tex"] {
            let path = dir.path().join(file);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "").unwrap();
        }
        assert_eq!(rels(dir.path(), false).unwrap(), ["a", "a/b.tex", "d.tex"]);
    }
}
