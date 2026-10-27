use std::fs;
use std::io::ErrorKind::{NotFound, PermissionDenied};
use std::path::{Path, PathBuf};

use serde::Serialize;
use texlocal_latex::file_kind;

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
    pub rel: String,
    pub name: String,
    pub dir: bool,
    pub link: bool,
}

pub(crate) fn listed(rel: &str) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    !name.starts_with('.') && !rel.eq_ignore_ascii_case(BUILD_DIR)
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
                kind: if entry.dir { "dir" } else { "file" },
                main: !entry.dir && fold_case(&entry.rel) == main,
                path: entry.rel,
                file_kind: (!entry.dir).then(|| file_kind(&entry.name)),
                name: entry.name,
                children,
            });
        }
        Ok(found)
    }
    let main = read_settings(&project.settings).main_file;
    nodes(&project.root, &project.root, &fold_case(&main))
}
