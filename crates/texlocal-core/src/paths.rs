//! Project paths, normalised lexically. Links may lead anywhere: the rules are
//! no escape by `..`, the settings file, and the build folder for writes.

use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

/// A relative path's segments, `.` dropped and `..` popped; popping past the
/// start is an escape. Empty for the base itself.
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

/// A project is one folder directly under `data_dir`, resolved so a build stops by the root it started with.
pub fn project_root(data_dir: &Path, id: &str) -> Result<PathBuf, CoreError> {
    let [name] = normalize_segments(id, "Bad project id")?[..] else {
        return Err(CoreError::bad_request("Bad project id"));
    };
    let root = data_dir.join(name);
    if !root.is_dir() {
        return Err(CoreError::not_found(format!("No such project: {id}")));
    }
    Ok(dunce::canonicalize(root)?)
}

/// `.texlocal.json` at the root is written only through write_settings; its
/// case aliases too, as macOS and Windows volumes ignore case.
fn safe_segments(rel: &str) -> Result<Vec<&str>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    match segments[..] {
        [] => Err(CoreError::bad_request("Path escapes project")),
        [name] if name.eq_ignore_ascii_case(SETTINGS_FILE) => {
            Err(CoreError::bad_request("Reserved file"))
        }
        _ => Ok(segments),
    }
}

fn in_build_dir(segments: &[&str]) -> bool {
    segments
        .first()
        .is_some_and(|first| first.eq_ignore_ascii_case(BUILD_DIR))
}

pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(root.join(safe_segments(rel)?.join("/")))
}

/// The top-level `build` folder, in any case, holds compile output and the
/// tree hides it, so nothing of the author's is written there.
pub fn safe_write_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    let segments = safe_segments(rel)?;
    if in_build_dir(&segments) {
        return Err(CoreError::bad_request(
            "“build” holds the compiled PDF. Choose another name.",
        ));
    }
    Ok(root.join(segments.join("/")))
}

pub(crate) fn fold_case(path: &str) -> String {
    path.to_lowercase()
}

/// What follows the entry `entry` in `path`, names compared as the volume
/// compares them: "" for the entry itself, "/…" inside it, None otherwise.
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

#[cfg(unix)]
pub(crate) fn same_entry(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    matches!((fs::symlink_metadata(a), fs::symlink_metadata(b)),
        (Ok(a), Ok(b)) if a.dev() == b.dev() && a.ino() == b.ino())
}

/// Windows' file identity is had only by opening the file, which follows a
/// link, so a link is only ever itself.
#[cfg(windows)]
pub(crate) fn same_entry(a: &Path, b: &Path) -> bool {
    let link = |path| fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink());
    !link(a) && !link(b) && same_file::is_same_file(a, b).unwrap_or(false)
}

pub fn rel_key(rel: &str) -> Result<String, CoreError> {
    Ok(safe_segments(rel)?.join("/"))
}

/// A project path for a command line: no segment a tool could read as an option.
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
    let refused = |c: char| {
        std::path::is_separator(c) || (cfg!(windows) && (c.is_control() || "<>:\"|?*".contains(c)))
    };
    let mut clean: String = name
        .trim()
        .chars()
        .filter(|&c| !refused(c))
        .take(80)
        .collect();
    if cfg!(windows) {
        clean.truncate(clean.trim_end_matches(['.', ' ']).len());
    }
    if clean.is_empty() || clean.starts_with('.') {
        return Err(CoreError::bad_request("Invalid name"));
    }
    Ok(clean)
}

/// The project file a tool names `input`: relative, or absolute under the root
/// as spelt or resolved (TeX records the physical folder), or under a folder it
/// was built in before a move ("<old>/./<file>"). None for anything but the
/// author's sources.
pub fn source_rel(root: &Path, input: &str) -> Option<String> {
    let canonical = dunce::canonicalize(root).ok()?;
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
    let segments = safe_segments(rel).ok()?;
    let source = !in_build_dir(&segments) && !segments.iter().any(|s| s.starts_with('-'));
    let rel = segments.join("/");
    (source && root.join(&rel).is_file()).then_some(rel)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::{fails_with, with_project};
    use crate::projects::{create_free, create_project};

    #[test]
    fn escapes_the_settings_file_and_the_build_folder_are_refused() {
        let (_dir, service) = with_project();
        let (data, root) = (&service.data_dir, service.project_root("P").unwrap());
        fails_with(project_root(data, "../etc"), "Bad project id");
        create_free(&root, "chapters/intro.tex", false).unwrap();
        fails_with(project_root(data, "P/chapters"), "Bad project id");
        assert_eq!(project_root(data, "./P/").unwrap(), root);
        let rel = safe_rel_file("./chapters/../chapters//intro.tex");
        assert_eq!(rel.unwrap(), "chapters/intro.tex");
        fails_with(safe_rel_file("a/-x.tex"), "cannot start");
        for path in ["../x", "a/../../b", ".", "/x"] {
            fails_with(safe_path(&root, path), "Path escapes project");
        }
        fails_with(safe_path(&root, ""), "Missing path");
        fails_with(safe_path(&root, ".TexLocal.Json"), "Reserved file");
        assert!(safe_path(&root, "sub/.texlocal.json").is_ok());
        fails_with(safe_write_path(&root, "Build/x.tex"), "compiled PDF");
        assert!(safe_path(&root, "build/main.pdf").is_ok());
    }

    #[test]
    fn a_tools_input_path_maps_back_to_the_project_file() {
        let (_dir, service) = with_project();
        create_project(&service.data_dir, "PQ", "blank", None).unwrap();
        let root = service.project_root("P").unwrap();
        create_free(&root, "ch/intro.tex", false).unwrap();
        fs::create_dir(root.join("build")).unwrap();
        fs::write(root.join("build/generated.tex"), "").unwrap();
        #[cfg(unix)]
        {
            let linked = service.data_dir.with_file_name("linked");
            std::os::unix::fs::symlink(&service.data_dir, &linked).unwrap();
            let real = dunce::canonicalize(&root).unwrap();
            let input = format!("{}/./ch/intro.tex", real.display());
            let rel = source_rel(&linked.join("P"), &input);
            assert_eq!(rel.as_deref(), Some("ch/intro.tex"));
        }
        let under = |path: &str| format!("{}{path}", root.display());
        // A folder it was built in before a move, absolute as the system spells it.
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
