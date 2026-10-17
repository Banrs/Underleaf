//! The library: the projects under the data dir, made, listed, named, renamed
//! and found again by their paths.

use std::collections::HashSet;
use std::fs;
use std::io::{self, ErrorKind};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use serde::Serialize;
use serde_json::json;

use super::skip_unreadable;
use super::tree::{entries, file_kind};
use crate::error::CoreError;
use crate::paths::{fold_case, project_root, same_entry, sanitize_name};
use crate::settings::{read_settings, write_settings};
use crate::templates;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectInfo {
    pub id: String,
    pub name: String,
    pub mtime: u64,
    pub main_file: String,
}

impl ProjectInfo {
    /// The project in folder `id` of the library, as the folder says: dated by
    /// `newest`, its main file from its settings. A project's id is its
    /// folder's name, and so is its name.
    fn read(data_dir: &Path, id: &str) -> io::Result<Self> {
        let root = data_dir.join(id);
        let meta = fs::metadata(&root)?;
        Ok(Self {
            id: id.to_owned(),
            name: id.to_owned(),
            mtime: newest(&root, &meta),
            main_file: read_settings(&root).main_file,
        })
    }
}

/// Where an absolute path lies in the library: its project, and its path in it
/// ("" for the project's folder).
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct Located {
    pub id: String,
    pub path: String,
}

fn mtime_ms(meta: &fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since| since.as_millis() as u64)
}

/// A project's date as the library shows it: the newest of its folders' and top-level
/// files', without a stat of every file. Every save the app makes renames a file into
/// place and so moves its folder's date; a file saved in place by another app moves only
/// its own, and in a subfolder shows once anything else moves a folder's date.
fn newest(root: &Path, meta: &fs::Metadata) -> u64 {
    fn walk(root: &Path, dir: &Path, newest: &mut u64) {
        for entry in entries(root, dir).into_iter().flatten() {
            if (entry.dir || dir == root)
                && let Ok(meta) = fs::metadata(&entry.path)
            {
                *newest = (*newest).max(mtime_ms(&meta));
            }
            if entry.dir {
                walk(root, &entry.path, newest);
            }
        }
    }
    let mut newest = mtime_ms(meta);
    if let Ok(root) = dunce::canonicalize(root) {
        walk(&root, &root, &mut newest);
    }
    newest
}

/// The projects, newest first, and by name among those of one date.
pub fn list_projects(data_dir: &Path) -> Result<Vec<ProjectInfo>, CoreError> {
    let mut projects = Vec::new();
    for entry in fs::read_dir(data_dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || !entry.file_type()?.is_dir() {
            continue;
        }
        projects.extend(skip_unreadable(ProjectInfo::read(data_dir, &name))?);
    }
    projects.sort_by(|a, b| b.mtime.cmp(&a.mtime).then_with(|| a.id.cmp(&b.id)));
    Ok(projects)
}

pub fn create_project(
    data_dir: &Path,
    name: &str,
    template: &str,
) -> Result<ProjectInfo, CoreError> {
    create_project_with_engine(data_dir, name, template, None)
}

/// `create_project`, set to build with `engine` (a bad one is a 400). The
/// project is made whole or not at all: its files and settings are written in
/// a hidden folder and moved into the library in one step.
pub fn create_project_with_engine(
    data_dir: &Path,
    name: &str,
    template: &str,
    engine: Option<&str>,
) -> Result<ProjectInfo, CoreError> {
    let staging = Staging::new(data_dir, name)?;
    for (file, content) in templates::files(template) {
        fs::write(staging.path().join(file), content)?;
    }
    let settings = engine.map_or_else(|| json!({}), |engine| json!({ "engine": engine }));
    write_settings(staging.path(), &settings)?;
    staging.publish()
}

/// What a new project is called when the user has not said.
pub const UNTITLED: &str = "Untitled";

/// The first free name in the series "Untitled", "Untitled 2", … (from
/// `base`, if given): one no entry of the library has, however it is spelled
/// where the volume ignores case. It creates nothing, so a host can offer it
/// as the name to edit; `create_project` numbers past anything taken since.
pub fn free_project_name(data_dir: &Path, base: Option<&str>) -> Result<String, CoreError> {
    let clean = sanitize_name(base.unwrap_or(UNTITLED))?;
    let taken: HashSet<String> = match fs::read_dir(data_dir) {
        Ok(entries) => entries
            .map(|entry| entry.map(|e| fold_case(&e.file_name().to_string_lossy())))
            .collect::<Result<_, _>>()?,
        Err(err) if err.kind() == ErrorKind::NotFound => HashSet::new(),
        Err(err) => return Err(err.into()),
    };
    Ok(project_names(&clean)
        .find(|name| !taken.contains(&fold_case(name)))
        .expect("a free name"))
}

/// The names a new project takes in turn: `clean`, then "clean 2", "clean 3"…
fn project_names(clean: &str) -> impl Iterator<Item = String> {
    std::iter::once(clean.to_owned()).chain((2..).map(move |n| format!("{clean} {n}")))
}

/// A new, empty project folder for the clean name `name`, or "name 2" and so
/// on when that is taken, as Finder numbers copies; and the name it got.
fn new_project_dir(data_dir: &Path, name: &str) -> Result<(String, PathBuf), CoreError> {
    fs::create_dir_all(data_dir)?;
    for name in project_names(name) {
        let root = data_dir.join(&name);
        // One create rather than a check and then a create: it cannot race,
        // and it passes over anything already there, a dangling link or case
        // alias too.
        match fs::create_dir(&root) {
            Err(err) if err.kind() == ErrorKind::AlreadyExists => {}
            created => return Ok(created.map(|()| (name, root))?),
        }
    }
    unreachable!("a free name")
}

const STAGING: &str = ".texlocal-staging-";

/// A project being made, in a hidden folder beside the projects, which no
/// listing or scan shows. `publish` moves it into the library whole, so a
/// failure or panic, which drops the folder, leaves no project behind. A
/// crash leaves a hidden folder only, which a later one sweeps away.
pub(crate) struct Staging<'a> {
    folder: tempfile::TempDir,
    data_dir: &'a Path,
    name: String,
}

impl<'a> Staging<'a> {
    /// A folder for a project that will be called `name`, or numbered past
    /// it; a bad name fails now, before the project is made.
    pub(crate) fn new(data_dir: &'a Path, name: &str) -> Result<Self, CoreError> {
        let name = sanitize_name(name)?;
        fs::create_dir_all(data_dir)?;
        sweep_staging(data_dir);
        let mut folder = tempfile::Builder::new();
        folder.prefix(STAGING);
        // A new folder's usual mode, not tempfile's private one.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            folder.permissions(fs::Permissions::from_mode(0o777));
        }
        Ok(Self {
            folder: folder.tempdir_in(data_dir)?,
            data_dir,
            name,
        })
    }

    pub(crate) fn path(&self) -> &Path {
        self.folder.path()
    }

    /// Move the project into the library: the name is held by an empty
    /// folder, which the project takes the place of in one rename.
    pub(crate) fn publish(self) -> Result<ProjectInfo, CoreError> {
        let (id, root) = new_project_dir(self.data_dir, &self.name)?;
        if let Err(err) = fs::rename(self.path(), &root) {
            let _ = fs::remove_dir(&root);
            return Err(err.into());
        }
        Ok(ProjectInfo::read(self.data_dir, &id)?)
    }
}

/// Removes the staging folders that crashed leave behind. A folder untouched
/// for a day is no running import's, whose allowance is minutes of writing.
fn sweep_staging(data_dir: &Path) {
    const STALE: Duration = Duration::from_secs(24 * 60 * 60);
    for entry in fs::read_dir(data_dir).into_iter().flatten().flatten() {
        let age = entry.metadata().and_then(|meta| meta.modified()).ok();
        if entry.file_name().to_string_lossy().starts_with(STAGING)
            && age.and_then(|time| time.elapsed().ok()) > Some(STALE)
        {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

/// The likely main file among a project's top-level .tex files: main.tex,
/// else the first by name that starts a document, else the first by name.
pub(crate) fn guess_main_file(root: &Path) -> Result<Option<String>, CoreError> {
    let mut tex: Vec<String> = Vec::new();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        // A name latexmk would read as an option can't be the main file.
        if entry.file_type()?.is_file() && file_kind(&name) == "tex" && !name.starts_with('-') {
            tex.push(name);
        }
    }
    tex.sort();
    let starts_document = |name: &&String| {
        fs::read(root.join(name.as_str()))
            .is_ok_and(|bytes| String::from_utf8_lossy(&bytes).contains("\\documentclass"))
    };
    Ok(tex
        .iter()
        .find(|name| name.eq_ignore_ascii_case("main.tex"))
        .or_else(|| tex.iter().find(starts_document))
        .or(tex.first())
        .cloned())
}

/// Rename a project, calling `before_move` once the rename is sure to go
/// ahead and before its folder moves.
pub fn rename_project(
    data_dir: &Path,
    id: &str,
    new_name: &str,
    before_move: impl FnOnce(&Path) -> Result<(), CoreError>,
) -> Result<ProjectInfo, CoreError> {
    let root = project_root(data_dir, id)?;
    let clean = sanitize_name(new_name)?;
    let dest = data_dir.join(&clean);
    // The new name is taken as a new project's is, by making its folder, and
    // the project moves onto that empty folder: after a check alone, a new
    // project could take the name before the move and then fill the renamed
    // project with its own files. A case-only rename's destination is the
    // project itself.
    let reserved = !same_entry(&root, &dest);
    if reserved {
        match fs::create_dir(&dest) {
            Err(err) if err.kind() == ErrorKind::AlreadyExists => {
                return Err(CoreError::conflict(
                    "A project with that name already exists",
                ));
            }
            made => made?,
        }
    }
    let moved = before_move(&root).and_then(|()| Ok(fs::rename(&root, &dest)?));
    if let Err(err) = moved {
        if reserved {
            let _ = fs::remove_dir(&dest);
        }
        return Err(err);
    }
    Ok(ProjectInfo::read(data_dir, &clean)?)
}

/// `path` with its links resolved as far as it exists, so one not yet made
/// or just trashed still compares with the library.
fn real_path(path: &Path) -> PathBuf {
    let (mut head, mut tail) = (path, Vec::new());
    loop {
        if let Ok(real) = fs::canonicalize(head) {
            return tail.iter().rev().fold(real, |real, name| real.join(name));
        }
        let (Some(parent), Some(name)) = (head.parent(), head.file_name()) else {
            return path.to_path_buf();
        };
        tail.push(name);
        head = parent;
    }
}

/// The project and the path in it of an absolute path in the library, or None
/// outside every project. A project's id is its folder's name.
pub fn locate(data_dir: &Path, path: &Path) -> Result<Option<Located>, CoreError> {
    let library = fs::canonicalize(data_dir)?;
    let real = real_path(path);
    let rest = match real.strip_prefix(&library) {
        Ok(rest) if path.is_absolute() => rest,
        _ => return Ok(None),
    };
    let names: Option<Vec<String>> = rest
        .components()
        .map(|part| match part {
            Component::Normal(name) => Some(name.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect();
    let Some([id, inside @ ..]) = names.as_deref() else {
        return Ok(None);
    };
    // The folders list_projects shows.
    if id.starts_with('.') || !data_dir.join(id).is_dir() {
        return Ok(None);
    }
    Ok(Some(Located {
        id: id.clone(),
        path: inside.join("/"),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::create_file;
    use crate::projects::testing::{names_in, project};

    #[test]
    fn a_path_in_the_library_is_found_in_its_project() {
        let (_dir, root) = project();
        let data = root.parent().unwrap();
        create_file(&root, "a/b.tex", false).unwrap();
        let at = |path: &Path| locate(data, path).unwrap();
        let found = |path: &str| {
            Some(Located {
                id: "P".into(),
                path: path.into(),
            })
        };
        assert_eq!(at(&root.join("a/b.tex")), found("a/b.tex"));
        assert_eq!(at(&root), found(""));
        // One not made yet, or just trashed, is where it was.
        assert_eq!(at(&root.join("a/gone.tex")), found("a/gone.tex"));
        // Not in a project: the library, a hidden folder, a missing one, a path
        // that leaves, a relative one.
        for outside in [
            data.to_path_buf(),
            data.join(".hidden/x"),
            data.join("Nope/x"),
            root.join("a/../../x"),
            PathBuf::from("P/a/b.tex"),
        ] {
            assert_eq!(at(&outside), None, "{outside:?}");
        }
    }

    #[test]
    fn a_project_is_made_with_its_engine_or_not_at_all() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path();
        let made = create_project_with_engine(data, "Thesis", "report", Some("lualatex"));
        let made = made.unwrap();
        assert_eq!(
            (made.id.as_str(), made.main_file.as_str()),
            ("Thesis", "main.tex")
        );
        assert_eq!(
            read_settings(&data.join("Thesis")).engine.as_str(),
            "lualatex"
        );

        // A refusal leaves nothing behind, not even the folder it was built in.
        let refused = create_project_with_engine(data, "Other", "blank", Some("word"));
        assert_eq!(refused.unwrap_err().status, 400);
        assert_eq!(names_in(data), ["Thesis"]);
        assert_eq!(
            create_project(data, ".hidden", "blank").unwrap_err().status,
            400
        );
        assert_eq!(names_in(data), ["Thesis"]);
    }

    #[test]
    fn a_stale_staging_folder_is_swept_and_a_fresh_one_is_left() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path();
        let staged = |name: &str, age: u64| {
            let folder = data.join(name);
            fs::create_dir_all(folder.join("sub")).unwrap();
            fs::write(folder.join("sub/main.tex"), "x").unwrap();
            let when = std::time::SystemTime::now() - Duration::from_secs(age);
            // Windows opens a folder only for its backup semantics, and to
            // date it, for its attributes.
            #[cfg(windows)]
            let handle = {
                use std::os::windows::fs::OpenOptionsExt;
                fs::OpenOptions::new()
                    .access_mode(0x100)
                    .custom_flags(0x0200_0000)
                    .open(&folder)
            };
            #[cfg(not(windows))]
            let handle = fs::File::open(&folder);
            handle.unwrap().set_modified(when).unwrap();
            folder
        };
        let crashed = staged(".texlocal-staging-crashed", 25 * 60 * 60);
        let running = staged(".texlocal-staging-running", 23 * 60 * 60);
        let other = staged(".hidden", 25 * 60 * 60);

        create_project(data, "P", "blank").unwrap();
        assert!(!crashed.exists());
        assert!(running.exists() && other.exists());
        assert!(data.join("P/main.tex").exists());
    }

    // Windows opens a folder only for its backup semantics, so its date is set here alone.
    #[cfg(unix)]
    #[test]
    fn projects_of_one_date_are_listed_by_name() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path();
        let date = std::time::SystemTime::now() - Duration::from_secs(3600);
        for name in ["b", "c", "a"] {
            create_project(data, name, "blank").unwrap();
            for entry in [".", "main.tex", ".texlocal.json"] {
                let file = fs::File::open(data.join(name).join(entry)).unwrap();
                file.set_modified(date).unwrap();
            }
        }
        let names: Vec<_> = list_projects(data)
            .unwrap()
            .into_iter()
            .map(|p| p.id)
            .collect();
        assert_eq!(names, ["a", "b", "c"]);
    }
}
