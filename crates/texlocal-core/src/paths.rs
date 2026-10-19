//! Path safety — the security boundary, and the only one. User paths are
//! normalized lexically first, then the nearest existing ancestor is resolved
//! so symlinked files and directories cannot redirect an operation outside the
//! project.

use std::fs;
use std::io::ErrorKind::{NotADirectory, NotFound};
use std::path::{Component, Path, PathBuf};

use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

/// Split a relative path into normalized segments.
/// `.` segments drop out; `..` pops — popping past the start is an escape.
/// Returns an empty vec for inputs that normalize to the base itself.
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
            Component::Normal(segment) => {
                // Components of a UTF-8 input are themselves UTF-8.
                let segment = segment.to_str().unwrap();
                if cfg!(windows) && windows_refuses(segment) {
                    return Err(CoreError::bad_request(format!(
                        "“{segment}” isn't a name Windows allows"
                    )));
                }
                segments.push(segment);
            }
            _ => return Err(CoreError::bad_request(escape_err)),
        }
    }
    Ok(segments)
}

/// Whether Windows would not take `segment` as a name, or would take it for
/// another: it drops trailing dots and spaces ("build." is "build"), reads
/// ':' as a data stream and refuses `<>"|?*` and controls, and keeps the
/// device names (CON, NUL, COM1…) whatever extension follows. Held on every
/// platform so it can be tested anywhere; only Windows applies it.
pub(crate) fn windows_refuses(segment: &str) -> bool {
    let stem = segment.split('.').next().unwrap_or_default();
    let device = stem.trim_end().to_ascii_uppercase();
    let numbered = |prefix: &str| {
        device
            .strip_prefix(prefix)
            .is_some_and(|n| matches!(n.as_bytes(), [b'1'..=b'9']))
    };
    segment.ends_with(['.', ' '])
        || segment.contains(|c: char| c.is_control() || "<>:\"|?*".contains(c))
        || matches!(device.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || numbered("COM")
        || numbered("LPT")
}

/// Resolve only the closest path component that already exists. This retains
/// lexical path semantics for new files while preventing an existing symlink
/// from redirecting the final operation outside `root`.
/// Returns where `target` leads inside `root`: its physical path relative to the
/// canonical root, the not-yet-existing suffix kept as written.
fn ensure_existing_ancestor_within(
    root: &Path,
    target: &Path,
    escape_err: &str,
) -> Result<PathBuf, CoreError> {
    let canonical_root = dunce::canonicalize(root)?;
    let mut existing = target;
    loop {
        match fs::symlink_metadata(existing) {
            Ok(_) => break,
            // A file where the path wants a folder ends the path there too.
            Err(err) if matches!(err.kind(), NotFound | NotADirectory) => {
                existing = existing
                    .parent()
                    .ok_or_else(|| CoreError::bad_request(escape_err))?;
            }
            Err(err) => return Err(err.into()),
        }
    }

    let resolved = dunce::canonicalize(existing).map_err(|_| CoreError::bad_request(escape_err))?;
    let inside =
        (resolved.strip_prefix(&canonical_root)).map_err(|_| CoreError::bad_request(escape_err))?;
    let suffix = target.strip_prefix(existing).unwrap_or(Path::new(""));
    // Collected, so a whole existing path keeps no trailing slash.
    Ok(inside.join(suffix).components().collect())
}

/// Resolve a project id to its directory under `data_dir`, rejecting escapes, symlink
/// aliases outside it and missing projects. A project is one folder directly under
/// `data_dir`, as list_projects reports it: a nested id would let project commands
/// rename, trash or compile a folder inside another project.
pub fn project_root(data_dir: &Path, id: &str) -> Result<PathBuf, CoreError> {
    let root = data_dir.join(project_name(id)?);
    if !root.is_dir() {
        return Err(CoreError::not_found(format!("No such project: {id}")));
    }
    ensure_existing_ancestor_within(data_dir, &root, "Bad project id")?;
    Ok(root)
}

/// A project id's one folder name, read without the disk.
pub(crate) fn project_name(id: &str) -> Result<&str, CoreError> {
    match normalize_segments(id, "Bad project id")?[..] {
        [name] => Ok(name),
        _ => Err(CoreError::bad_request("Bad project id")),
    }
}

/// Normalized project-relative segments for a user-supplied path, with the
/// reserved-settings-file rule: `.texlocal.json` at the project root is only
/// writable through write_settings, which validates each key. Its case
/// aliases are reserved since macOS volumes are usually case-insensitive and
/// the boundary must not depend on the volume.
fn safe_segments(rel: &str) -> Result<Vec<&str>, CoreError> {
    if rel.is_empty() {
        return Err(CoreError::bad_request("Missing path"));
    }
    let segments = normalize_segments(rel, "Path escapes project")?;
    if segments.is_empty() {
        return Err(CoreError::bad_request("Path escapes project"));
    }
    if is_settings_file(&segments) {
        return Err(CoreError::bad_request("Reserved file"));
    }
    Ok(segments)
}

fn is_settings_file(segments: &[&str]) -> bool {
    matches!(segments, [name] if name.eq_ignore_ascii_case(SETTINGS_FILE))
}

fn is_in_build_dir(segments: &[&str]) -> bool {
    segments
        .first()
        .is_some_and(|first| first.eq_ignore_ascii_case(BUILD_DIR))
}

/// Segments of a path relative to the project root, as `ensure_existing_ancestor_within` gives it.
fn physical_segments(path: &Path) -> Vec<&str> {
    path.components()
        .filter_map(|c| match c {
            Component::Normal(s) => s.to_str(),
            _ => None,
        })
        .collect()
}

/// `segments` joined onto `root`, provided no existing link leads out of it, nor to the
/// settings file, nor, for a write, into the build folder: a link inside the project is
/// held to the rules its target's own path is. Also where the path physically leads,
/// relative to the resolved root.
fn join_within(
    root: &Path,
    segments: &[&str],
    write: bool,
) -> Result<(PathBuf, PathBuf), CoreError> {
    let mut abs = root.to_path_buf();
    abs.extend(segments);
    let physical = ensure_existing_ancestor_within(root, &abs, "Path escapes project")?;
    let physical_segments = physical_segments(&physical);
    if is_settings_file(&physical_segments) {
        return Err(CoreError::bad_request("Reserved file"));
    }
    if write && is_in_build_dir(&physical_segments) {
        return Err(build_dir_err());
    }
    Ok((abs, physical))
}

fn build_dir_err() -> CoreError {
    CoreError::bad_request("“build” holds the compiled PDF. Choose another name.")
}

/// Absolute path for a user-supplied relative path inside a project.
pub fn safe_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(join_within(root, &safe_segments(rel)?, false)?.0)
}

/// `safe_path` for a path about to be created or written. The project's
/// top-level `build` folder holds compile output, so no file or folder of the
/// author's may take that name, in any case: on a case-insensitive volume
/// `Build` is the same folder, and the tree hides it.
pub fn safe_write_path(root: &Path, rel: &str) -> Result<PathBuf, CoreError> {
    Ok(write_paths(root, rel)?.0)
}

/// `safe_write_path`, and where the write physically lands, through any link
/// on its way, relative to the resolved root.
pub(crate) fn write_paths(root: &Path, rel: &str) -> Result<(PathBuf, PathBuf), CoreError> {
    let segments = safe_segments(rel)?;
    if is_in_build_dir(&segments) {
        return Err(build_dir_err());
    }
    join_within(root, &segments, true)
}

/// A path as the volume compares it: macOS and Windows volumes usually
/// ignore case.
pub(crate) fn fold_case(path: &str) -> String {
    path.to_lowercase()
}

/// What follows the entry `entry` in `path`, both forward-slash project
/// paths, with names compared as the volume compares them (`fold_case`), for a
/// path as a user or the settings file spells it, such as the main file: ""
/// for the entry itself, "/…" for a path inside it, None for any other.
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

/// Whether `path` is the entry `entry` or inside it, as `after_entry` compares:
/// open documents' paths, and the paths a rename or delete names.
pub(crate) fn within(path: &str, entry: &str) -> bool {
    after_entry(path, entry).is_some()
}

/// Whether two paths name one entry, a link itself rather than its target.
#[cfg(unix)]
pub(crate) fn same_entry(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    matches!((fs::symlink_metadata(a), fs::symlink_metadata(b)),
        (Ok(a), Ok(b)) if a.dev() == b.dev() && a.ino() == b.ino())
}

/// Whether two paths name one entry. Windows' file identity is had only by
/// opening the file, which follows a link, so a link is only ever itself.
#[cfg(windows)]
pub(crate) fn same_entry(a: &Path, b: &Path) -> bool {
    let link = |path| fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink());
    !link(a) && !link(b) && same_file::is_same_file(a, b).unwrap_or(false)
}

/// The normalized forward-slash spelling of a user-supplied project path, for
/// comparing it with a stored one such as the main file. It checks nothing on
/// disk: pair it with `safe_path`, and use `safe_rel_file` for anything that
/// reaches a command line.
pub fn rel_key(rel: &str) -> Result<String, CoreError> {
    Ok(safe_segments(rel)?.join("/"))
}

/// A path inside the project in a form safe to hand to a command line:
/// relative, no escape, forward slashes, no symlink escape, and no segment a
/// tool could read as an option.
pub fn safe_rel_file(root: &Path, rel: &str) -> Result<String, CoreError> {
    let segments = safe_segments(rel)?;
    if segments.iter().any(|s| s.starts_with('-')) {
        return Err(CoreError::bad_request(
            "Path segments cannot start with \"-\"",
        ));
    }
    join_within(root, &segments, false)?;
    Ok(segments.join("/"))
}

/// A name for a new folder in the library: one name, without the characters
/// the volume refuses in it (on Windows, also `<>:"|?*` and controls, and
/// the dots and spaces at the end it drops).
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
    if clean.is_empty() || clean.starts_with('.') || (cfg!(windows) && windows_refuses(&clean)) {
        return Err(CoreError::bad_request("Invalid name"));
    }
    Ok(clean)
}

/// The project file a tool names `input`, as TeX recorded it: relative to the
/// project, or absolute under its folder as spelt or as resolved (TeX records
/// the physical working directory, even if the root is a link), or under a
/// folder it was built in before a move ("<old>/./<file>"). None for anything
/// that is not one of the author's sources: outside the project, the settings
/// file, generated output in the build folder however it is reached, a name a
/// tool would read as an option, or no file.
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
    let (abs, physical) = join_within(root, &segments, false).ok()?;
    let physical = physical_segments(&physical);
    let unsafe_name = |segments: &[&str]| {
        is_in_build_dir(segments) || segments.iter().any(|s| s.starts_with('-'))
    };
    (abs.is_file() && !unsafe_name(&segments) && !unsafe_name(&physical))
        .then(|| segments.join("/"))
}

#[cfg(test)]
#[path = "projects/tests.rs"]
mod projects_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::with_project;
    use crate::projects::{create_file, create_project};

    #[track_caller]
    pub(super) fn fails_with<T: std::fmt::Debug>(result: Result<T, CoreError>, text: &str) {
        let message = result.unwrap_err().message;
        assert!(message.contains(text), "{message:?} lacks {text:?}");
    }

    /// Escapes and the settings file are refused at every boundary, and a link
    /// inside the project is held to the rules of where it leads (#26): one out
    /// of it leads nowhere, however much of the path exists.
    #[test]
    fn path_traversal_the_settings_file_and_links_out_are_rejected_at_every_boundary() {
        let (_dir, service) = with_project();
        let (data, root) = (&service.data_dir, service.project_root("P").unwrap());
        fails_with(project_root(data, "../etc"), "Bad project id");
        // A folder inside a project is not a project of its own.
        create_file(&root, "chapters/intro.tex", false).unwrap();
        fails_with(project_root(data, "P/chapters"), "Bad project id");
        assert_eq!(project_root(data, "./P/").unwrap(), root);
        let rel = safe_rel_file(&root, "./chapters/../chapters//intro.tex");
        assert_eq!(rel.unwrap(), "chapters/intro.tex");
        for path in ["../x", "a/../../b", ".", "/x"] {
            fails_with(safe_path(&root, path), "Path escapes project");
        }
        fails_with(safe_path(&root, ""), "Missing path");
        // The settings file's case aliases are reserved on every platform on
        // purpose, as macOS volumes are case-insensitive too.
        for name in [".texlocal.json", ".TEXLOCAL.JSON", ".TexLocal.Json"] {
            fails_with(safe_path(&root, name), "Reserved file");
        }
        assert!(safe_path(&root, "sub/.texlocal.json").is_ok());

        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = tempfile::tempdir().unwrap();
            fs::write(outside.path().join("secret.tex"), "secret").unwrap();
            symlink(outside.path(), root.join("outside")).unwrap();
            for path in ["outside/secret.tex", "outside/new/sub/file.tex"] {
                fails_with(safe_path(&root, path), "Path escapes project");
                fails_with(safe_rel_file(&root, path), "Path escapes project");
            }
            fs::create_dir_all(root.join("build")).unwrap();
            symlink(".texlocal.json", root.join("alias.json")).unwrap();
            symlink(".", root.join("here")).unwrap();
            symlink("build", root.join("output")).unwrap();
            symlink("main.tex", root.join("link.tex")).unwrap();
            fails_with(safe_write_path(&root, "alias.json"), "Reserved file");
            fails_with(safe_path(&root, "alias.json"), "Reserved file");
            fails_with(
                safe_write_path(&root, "here/.texlocal.json"),
                "Reserved file",
            );
            fails_with(safe_write_path(&root, "output/main.pdf"), "compiled PDF");
            fails_with(safe_write_path(&root, "here/build/x.tex"), "compiled PDF");
            // Reading the output through a link, and ordinary links, stay as they were.
            assert!(safe_path(&root, "output/main.pdf").is_ok());
            assert!(safe_write_path(&root, "link.tex").is_ok());
            assert!(safe_write_path(&root, "here/notes.tex").is_ok());
        }
    }

    /// What a tool such as synctex names as a source maps back into the
    /// project, and generated files, the settings and anything outside are
    /// no source, however the path reaches them.
    #[test]
    fn a_tools_input_path_maps_back_to_the_project_file() {
        let (_dir, service) = with_project();
        create_project(&service.data_dir, "PQ", "blank", None).unwrap();
        let root = service.project_root("P").unwrap();
        create_file(&root, "ch/intro.tex", false).unwrap();
        fs::create_dir(root.join("build")).unwrap();
        fs::write(root.join("build/generated.tex"), "").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = service.data_dir.with_file_name("outside.tex");
            fs::write(&outside, "").unwrap();
            symlink(&outside, root.join("linked.tex")).unwrap();
            symlink(root.join("build"), root.join("generated")).unwrap();
            // A build made before the project was renamed or moved names its
            // old folder; and TeX names inputs by the physical folder, a
            // library reached through a link resolved.
            let rel = source_rel(&root, "/old/Paper/./ch/intro.tex");
            assert_eq!(rel.as_deref(), Some("ch/intro.tex"));
            let linked = service.data_dir.with_file_name("linked");
            symlink(&service.data_dir, &linked).unwrap();
            let real = dunce::canonicalize(&root).unwrap();
            let input = format!("{}/./ch/intro.tex", real.display());
            let rel = source_rel(&linked.join("P"), &input);
            assert_eq!(rel.as_deref(), Some("ch/intro.tex"));
        }
        let under = |path: &str| format!("{}{path}", root.display());
        for (input, rel) in [
            (under("/./ch/../ch/intro.tex"), Some("ch/intro.tex")),
            ("./ch/intro.tex".into(), Some("ch/intro.tex")),
            (under(""), None),
            (under("/../PQ/main.tex"), None),
            (under("Q/main.tex"), None),
            (".texlocal.json".into(), None),
            ("build/generated.tex".into(), None),
            ("Build/generated.tex".into(), None),
            ("linked.tex".into(), None),
            ("generated/generated.tex".into(), None),
            ("/old/Paper/./../outside.tex".into(), None),
            ("/old/Paper/./linked.tex".into(), None),
            ("/old/Paper/./generated/generated.tex".into(), None),
            ("/old/Paper/./Build/generated.tex".into(), None),
        ] {
            assert_eq!(source_rel(&root, &input).as_deref(), rel, "{input}");
        }
    }

    #[test]
    fn main_file_guards_compare_names_as_the_volume_does() {
        // On a Mac's or Windows' case-insensitive volume, Main.tex is main.tex.
        for (path, entry, after) in [
            ("chapters/main.tex", "chapters", Some("/main.tex")),
            ("chapters/main.tex", "chapters/main.tex", Some("")),
            ("chapters2/main.tex", "chapters", None),
            ("chapters", "chapters/main.tex", None),
            ("main.tex", "Main.tex", Some("")),
            ("Chapters/a.tex", "chapters", Some("/a.tex")),
        ] {
            assert_eq!(after_entry(path, entry), after, "{path} in {entry}");
            assert_eq!(within(path, entry), after.is_some(), "{path} in {entry}");
        }
    }

    #[test]
    fn windows_names_that_alias_another_or_a_device_are_refused() {
        for name in [
            "build.",
            "build ",
            "a:b.tex",
            "a<b",
            "a\"b",
            "q?",
            "tab\there",
            "CON",
            "con.txt",
            "Nul.tar.gz",
            "aux",
            "COM1",
            "lpt9.log",
            "PRN ",
        ] {
            assert!(windows_refuses(name), "{name:?}");
        }
        for name in [
            "build",
            "main.tex",
            ".hidden",
            "a b.tex",
            "console",
            "COM0",
            "COM10",
            "LPT",
            "auxiliary",
            "comma.tex",
        ] {
            assert!(!windows_refuses(name), "{name:?}");
        }
    }
}
