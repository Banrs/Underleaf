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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::{fails_with, with_project};
    use crate::projects::{create_free, create_project};

    #[test]
    fn escapes_the_settings_file_and_the_build_folder_are_refused() {
        let (_dir, service) = with_project();
        let (data, root) = (&service.data_dir, service.project("P").unwrap().root);
        fails_with(Project::find(data, "../etc"), "Bad project id");
        create_free(&root, "chapters/intro.tex", false).unwrap();
        fails_with(Project::find(data, "P/chapters"), "Bad project id");
        assert_eq!(Project::find(data, "./P/").unwrap().root, root);
        let rel = safe_rel_file("./chapters/../chapters//intro.tex");
        assert_eq!(rel.unwrap(), "chapters/intro.tex");
        fails_with(safe_rel_file("a/-x.tex"), "cannot start");
        for path in ["../x", "a/../../b", ".", "/x"] {
            fails_with(safe_path(&root, path), "Path escapes project");
        }
        fails_with(safe_path(&root, ""), "Missing path");
        for alias in [".TexLocal.Json", ".texlocal.j\u{17f}on"] {
            fails_with(safe_path(&root, alias), "Reserved file");
        }
        assert!(safe_path(&root, "sub/.texlocal.json").is_ok());
        fails_with(safe_write_path(&root, "Build/x.tex"), "compiled PDF");
        assert!(safe_path(&root, "build/main.pdf").is_ok());
    }

    #[test]
    fn a_tools_input_path_maps_back_to_the_project_file() {
        let (_dir, service) = with_project();
        create_project(&service.data_dir, "PQ", "blank", None).unwrap();
        let root = service.project("P").unwrap().root;
        create_free(&root, "ch/intro.tex", false).unwrap();
        fs::create_dir(root.join("build")).unwrap();
        fs::write(root.join("build/generated.tex"), "").unwrap();
        let linked = service.data_dir.with_file_name("linked");
        std::os::unix::fs::symlink(&service.data_dir, &linked).unwrap();
        let real = std::fs::canonicalize(&root).unwrap();
        let input = format!("{}/./ch/intro.tex", real.display());
        let rel = source_rel(&linked.join("P"), &input);
        assert_eq!(rel.as_deref(), Some("ch/intro.tex"));
        let under = |path: &str| format!("{}{path}", root.display());
        let old = std::env::temp_dir().join("old").join("Paper");
        for (input, rel) in [
            (under("/./ch/../ch/intro.tex"), Some("ch/intro.tex")),
            (
                format!("{}/./ch/intro.tex", old.display()),
                Some("ch/intro.tex"),
            ),
            (under(""), None),
            (under("/../PQ/main.tex"), None),
            (".texlocal.json".into(), None),
            ("Build/generated.tex".into(), None),
        ] {
            assert_eq!(source_rel(&root, &input).as_deref(), rel, "{input}");
        }
    }

    #[test]
    fn main_file_guards_compare_names_as_the_volume_does() {
        for (path, entry, after) in [
            ("chapters/main.tex", "chapters", Some("/main.tex")),
            ("chapters/main.tex", "chapters/main.tex", Some("")),
            ("chapters2/main.tex", "chapters", None),
            ("chapters", "chapters/main.tex", None),
            ("Chapters/a.tex", "chapters", Some("/a.tex")),
        ] {
            assert_eq!(after_entry(path, entry), after, "{path} in {entry}");
        }
    }
}
