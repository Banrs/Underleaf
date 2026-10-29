use std::fs;
use std::path::{Path, PathBuf};

use schemars::JsonSchema;
use serde::Deserialize;
pub(crate) use texlocal_latex::fold_case;
use texlocal_latex::message::Message;

use crate::error::CoreError;
use crate::messages;
use crate::projects::{self, is_opened};
use crate::{BUILD_DIR, HISTORY_DIR, SETTINGS_FILE, sys};

pub(crate) fn normalize_segments(
    rel: &str,
    escape: fn() -> Message,
) -> Result<Vec<&str>, CoreError> {
    texlocal_latex::segments(rel).ok_or_else(|| CoreError::bad_request(escape()))
}

#[derive(Clone)]
pub struct Project {
    pub root: PathBuf,
    pub settings: PathBuf,
    pub ui: PathBuf,
    pub build: PathBuf,
    pub history: PathBuf,
}

impl Project {
    pub fn find(data_dir: &Path, id: &str) -> Result<Self, CoreError> {
        let [name] = normalize_segments(id, messages::bad_project_id)?[..] else {
            return Err(CoreError::bad_request(messages::bad_project_id()));
        };
        if is_opened(name) {
            return projects::find_opened(data_dir, name);
        }
        let root = data_dir.join(name);
        if !root.is_dir() {
            return Err(CoreError::not_found(messages::no_such_project(id)));
        }
        Ok(Self::in_folder(&fs::canonicalize(root)?))
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
    fs::metadata(path).ok().map(|meta| sys::identity(&meta))
}

fn safe_segments(rel: &str) -> Result<Vec<&str>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request(messages::missing_path()));
    }
    let segments = normalize_segments(rel, messages::path_escapes)?;
    match segments[..] {
        [] => Err(CoreError::bad_request(messages::path_escapes())),
        [name] if fold_case(name) == SETTINGS_FILE => {
            Err(CoreError::bad_request(messages::reserved_file()))
        }
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
        return Err(CoreError::bad_request(messages::build_folder()));
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
    matches!((fs::symlink_metadata(a), fs::symlink_metadata(b)),
        (Ok(a), Ok(b)) if sys::identity(&a) == sys::identity(&b))
}

pub fn rel_key(rel: &str) -> Result<String, CoreError> {
    Ok(safe_segments(rel)?.join("/"))
}

#[derive(Deserialize, JsonSchema)]
#[serde(try_from = "String")]
#[schemars(inline)]
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
        return Err(CoreError::bad_request(messages::dash_segment()));
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
        return Err(CoreError::bad_request(messages::invalid_name()));
    }
    Ok(clean)
}

pub fn source_rel(root: &Path, input: &str) -> Option<String> {
    let input_path = Path::new(input);
    let rel = if input_path.is_absolute() {
        let canonical = fs::canonicalize(root).ok()?;
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

pub(crate) fn disk_spelling(root: &Path, rel: &str) -> Option<String> {
    let mut path = root.to_path_buf();
    let mut spelt = Vec::new();
    for name in rel.split('/') {
        let folded = fold_case(name);
        let found = fs::read_dir(&path)
            .ok()?
            .flatten()
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|entry| fold_case(entry) == folded)
            .max_by_key(|entry| entry == name)?;
        path.push(&found);
        spelt.push(found);
    }
    path.is_file().then(|| spelt.join("/"))
}
