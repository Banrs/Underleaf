use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::CoreError;
use crate::projects::{self, is_opened};
use crate::{BUILD_DIR, HISTORY_DIR, SETTINGS_FILE};

pub(crate) fn normalize_segments<'a>(
    rel: &'a str,
    escape_err: &str,
) -> Result<Vec<&'a str>, CoreError> {
    let mut segments = Vec::new();
    for component in Path::new(rel).components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if segments.pop().is_none() {
                    return Err(CoreError::bad_request(escape_err));
                }
            }
            Component::Normal(segment) => segments.push(segment.to_str().unwrap()),
            _ => return Err(CoreError::bad_request(escape_err)),
        }
    }
    Ok(segments)
}

#[derive(Debug, Clone)]
pub struct Project {
    pub root: PathBuf,
    pub settings: PathBuf,
    pub ui: PathBuf,
    pub build: PathBuf,
    pub history: PathBuf,
}

impl Project {
    pub fn find(data_dir: &Path, id: &str) -> Result<Self, CoreError> {
        let [name] = normalize_segments(id, "Bad project id")?[..] else {
            return Err(CoreError::bad_request("Bad project id"));
        };
        if is_opened(name) {
            return projects::find_opened(data_dir, name);
        }
        let root = data_dir.join(name);
        if !root.is_dir() {
            return Err(CoreError::not_found(format!("No such project: {id}")));
        }
        Ok(Self::in_folder(&std::fs::canonicalize(root)?))
    }

    pub fn name(&self) -> String {
        let name = self.root.file_name().unwrap_or(self.root.as_os_str());
        name.to_string_lossy().into_owned()
    }

    pub(crate) fn in_folder(root: &Path) -> Self {
        let settings = root.join(SETTINGS_FILE);
        Self {
            ui: settings.clone(),
            settings,
            build: root.join(BUILD_DIR),
            history: root.join(HISTORY_DIR),
            root: root.to_path_buf(),
        }
    }
}

pub(crate) fn identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let meta = fs::metadata(path).ok()?;
    Some((meta.dev(), meta.ino()))
}

fn safe_segments(rel: &str) -> Result<Vec<&str>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    match segments[..] {
        [] => Err(CoreError::bad_request("Path escapes project")),
        [name] if fold_case(name) == SETTINGS_FILE => Err(CoreError::bad_request("Reserved file")),
        _ => Ok(segments),
    }
}

pub(crate) fn in_build_dir(rel: &str) -> bool {
    rel.split('/')
        .next()
        .is_some_and(|top| fold_case(top) == BUILD_DIR)
}

pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(root.join(rel_key(rel)?))
}

pub fn safe_write_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    let rel = rel_key(rel)?;
    if in_build_dir(&rel) {
        return Err(CoreError::bad_request(
            "“build” holds the compiled PDF. Choose another name.",
        ));
    }
    Ok(root.join(rel))
}

pub(crate) fn in_folder(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    }
}

pub(crate) fn fold_case(path: &str) -> String {
    path.to_uppercase().to_lowercase()
}

pub(crate) fn after_entry<'a>(path: &'a str, entry: &str) -> Option<&'a str> {
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

pub(crate) fn within(path: &str, entry: &str) -> bool {
    after_entry(path, entry).is_some()
}

pub(crate) fn same_entry(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    matches!((fs::symlink_metadata(a), fs::symlink_metadata(b)),
        (Ok(a), Ok(b)) if a.dev() == b.dev() && a.ino() == b.ino())
}

pub fn rel_key(rel: &str) -> Result<String, CoreError> {
    Ok(safe_segments(rel)?.join("/"))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub(crate) struct RelPath(pub String);

impl TryFrom<String> for RelPath {
    type Error = CoreError;

    fn try_from(path: String) -> Result<Self, CoreError> {
        rel_key(&path).map(Self)
    }
}

pub fn safe_rel_file(rel: &str) -> Result<String, CoreError> {
    let segments = safe_segments(rel)?;
    if segments.iter().any(|s| s.starts_with('-')) {
        return Err(CoreError::bad_request(
            "Path segments cannot start with \"-\"",
        ));
    }
    Ok(segments.join("/"))
}

pub fn sanitize_name(name: &str) -> Result<String, CoreError> {
    let clean: String = name
        .trim()
        .chars()
        .filter(|&c| !std::path::is_separator(c))
        .take(80)
        .collect();
    if clean.is_empty() || clean.starts_with('.') {
        return Err(CoreError::bad_request("Invalid name"));
    }
    Ok(clean)
}

pub fn source_rel(root: &Path, input: &str) -> Option<String> {
    let canonical = std::fs::canonicalize(root).ok()?;
    let input_path = Path::new(input);
    let rel = if input_path.is_absolute() {
        let inside = [root, &canonical]
            .into_iter()
            .find_map(|base| input_path.strip_prefix(base).ok());
        match inside {
            Some(rel) => rel.to_str()?,
            None => input.split_once("/./")?.1,
        }
    } else {
        input
    };
    let rel = safe_rel_file(rel).ok()?;
    (!in_build_dir(&rel) && root.join(&rel).is_file()).then_some(rel)
}
