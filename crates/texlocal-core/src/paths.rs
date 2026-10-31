use std::path::{Path, PathBuf};
use std::{fs, io};

use schemars::JsonSchema;
use serde::Deserialize;
pub(crate) use texlocal_latex::fold_case;
use texlocal_latex::message::Message;

use crate::error::CoreError;
use crate::messages;
use crate::projects::{self, OPENED_DIR, is_opened};
use crate::service::Service;
use crate::settings::APP_SETTINGS_FILE;
use crate::{BUILD_DIR, HISTORY_DIR, SETTINGS_FILE, atomic, sys};

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
    pub fn find(service: &Service, id: &str) -> Result<Self, CoreError> {
        let [name] = normalize_segments(id, messages::bad_project_id)?[..] else {
            return Err(CoreError::bad_request(messages::bad_project_id()));
        };
        if is_opened(name) {
            return projects::find_opened(&service.state_dir, name);
        }
        if !service.data_dir.join(name).is_dir() {
            return Err(CoreError::not_found(messages::no_such_project(id)));
        }
        Ok(Self::in_library(service, name)?)
    }

    pub fn name(&self) -> String {
        let name = self.root.file_name().unwrap_or(self.root.as_os_str());
        name.to_string_lossy().into_owned()
    }

    pub(crate) fn in_library(service: &Service, name: &str) -> io::Result<Self> {
        let root = fs::canonicalize(service.data_dir.join(name))?;
        Ok(Self {
            settings: root.join(SETTINGS_FILE),
            ui: ui_file(&service.state_dir, name),
            build: root.join(BUILD_DIR),
            history: root.join(HISTORY_DIR),
            root,
        })
    }
}

pub(crate) const UI_DIR: &str = ".ui";

pub(crate) fn ui_file(state_dir: &Path, name: &str) -> PathBuf {
    state_dir.join(UI_DIR).join(format!("{name}.json"))
}

pub(crate) fn move_device_state(data_dir: &Path, state_dir: &Path) {
    for name in [UI_DIR, OPENED_DIR, APP_SETTINGS_FILE] {
        let (from, to) = (data_dir.join(name), state_dir.join(name));
        if !to.exists()
            && let Err(err) = atomic::rename_exclusive(&from, &to)
            && err.kind() == io::ErrorKind::CrossesDevices
        {
            let _ = copy_over(&from, &to);
        }
    }
}

fn copy_over(from: &Path, to: &Path) -> io::Result<()> {
    let temp = atomic::temp_builder().tempdir_in(to.parent().expect("in the state folder"))?;
    let copy = temp.path().join("copy");
    copy_all(from, &copy)?;
    atomic::rename_exclusive(&copy, to)?;
    if from.is_dir() {
        fs::remove_dir_all(from)
    } else {
        fs::remove_file(from)
    }
}

fn copy_all(from: &Path, to: &Path) -> io::Result<()> {
    if !fs::symlink_metadata(from)?.is_dir() {
        return fs::copy(from, to).map(drop);
    }
    fs::create_dir(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        copy_all(&entry.path(), &to.join(entry.file_name()))?;
    }
    Ok(())
}

pub(crate) fn identity(path: &Path) -> Option<(u64, u64)> {
    sys::identity(path, &fs::metadata(path).ok()?).ok()
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

pub(crate) fn relative(root: &Path, path: &Path) -> Option<String> {
    let rest = path.strip_prefix(root).ok()?;
    let parts: Option<Vec<&str>> = rest.components().map(|c| c.as_os_str().to_str()).collect();
    Some(parts?.join("/"))
}

pub(crate) fn utf8_name(path: &Path) -> Result<&str, CoreError> {
    let name = path.file_name().unwrap_or_default();
    name.to_str()
        .ok_or_else(|| CoreError::bad_request(messages::not_utf8_name(path.display())))
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
    let entry = |path: &Path| sys::identity(path, &fs::symlink_metadata(path).ok()?).ok();
    entry(a).is_some_and(|a| entry(b) == Some(a))
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

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn a_path_inside_the_root_is_joined_with_slashes_and_one_that_isnt_utf8_is_refused() {
        let root = Path::new("/project");
        let nested = root.join("a").join("b.tex");
        assert_eq!(relative(root, &nested).as_deref(), Some("a/b.tex"));
        assert_eq!(relative(root, root).as_deref(), Some(""));
        assert_eq!(relative(root, Path::new("/elsewhere/b.tex")), None);
        let latin1 = root.join(OsStr::from_bytes(b"caf\xe9")).join("b.tex");
        assert_eq!(relative(root, &latin1), None);
        let refused = utf8_name(latin1.parent().unwrap()).unwrap_err();
        assert_eq!(refused.kind, crate::ErrorKind::Invalid);
        assert_eq!(utf8_name(&nested).unwrap(), "b.tex");
    }

    #[test]
    fn a_copy_lands_whole_or_not_at_all_and_its_source_goes_only_once_it_has() {
        let dir = tempfile::tempdir().unwrap();
        let (data, state) = (dir.path().join("data"), dir.path().join("state"));
        let (from, to) = (data.join(".opened"), state.join(".opened"));
        let read = |path: &Path| fs::read_to_string(path).unwrap();
        fs::create_dir_all(from.join("a/history")).unwrap();
        fs::create_dir(&state).unwrap();
        let unreadable = from.join("a/history/1.json");
        fs::write(&unreadable, "[]").unwrap();
        let mode = |mode| fs::set_permissions(&unreadable, fs::Permissions::from_mode(mode));
        mode(0).unwrap();
        assert!(copy_over(&from, &to).is_err());
        assert!(fs::read_dir(&state).unwrap().next().is_none());
        mode(0o644).unwrap();
        copy_over(&from, &to).unwrap();
        assert!(!from.exists());
        assert_eq!(read(&to.join("a/history/1.json")), "[]");
        let (settings, copied) = (data.join("app.json"), state.join("app.json"));
        fs::write(&settings, "old").unwrap();
        copy_over(&settings, &copied).unwrap();
        fs::write(&settings, "new").unwrap();
        let refused = copy_over(&settings, &copied).unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!([read(&settings), read(&copied)], ["new", "old"]);
        assert_eq!(fs::read_dir(&state).unwrap().count(), 2);
    }
}
