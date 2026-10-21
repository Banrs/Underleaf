//! The library: the projects under the data dir, made, listed, named, renamed and found again by
//! their paths.

use std::collections::HashSet;
use std::fs;
use std::io::{self, ErrorKind};
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::Serialize;
use serde_json::json;

use super::files::occupied;
use super::skip_unreadable;
use super::tree::{entries, file_kind};
use crate::error::CoreError;
use crate::paths::{fold_case, project_root, sanitize_name};
use crate::settings::{read_settings, write_settings};
use crate::syntax::SourceDocument;
use crate::templates;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectInfo {
    pub id: String,
    pub name: String,
    pub mtime: u64,
    pub main_file: String,
}

impl ProjectInfo {
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

/// A project's date: the newest of its folders' and top-level files', without a stat of every
/// file. The app's saves rename into place and so move the folder's date; another app's in-place
/// save moves only the file's.
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

pub fn list_projects(data_dir: &Path) -> Result<Vec<ProjectInfo>, CoreError> {
    let mut projects = Vec::new();
    for entry in fs::read_dir(data_dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with('.') && entry.file_type()?.is_dir() {
            projects.extend(skip_unreadable(ProjectInfo::read(data_dir, &name))?);
        }
    }
    projects.sort_by(|a, b| b.mtime.cmp(&a.mtime).then_with(|| a.id.cmp(&b.id)));
    Ok(projects)
}

pub fn create_project(
    data_dir: &Path,
    name: &str,
    template: &str,
    engine: Option<&str>,
) -> Result<ProjectInfo, CoreError> {
    new_project(data_dir, name, |root| {
        for (file, content) in templates::files(template) {
            fs::write(root.join(file), content)?;
        }
        let settings = engine.map_or_else(|| json!({}), |engine| json!({ "engine": engine }));
        write_settings(root, &settings)?;
        Ok(())
    })
}

/// A project in a new folder named `name`, or "name 2" and so on when that is taken, as Finder
/// numbers copies, filled by `fill`; removed if that fails.
pub(crate) fn new_project(
    data_dir: &Path,
    name: &str,
    fill: impl FnOnce(&Path) -> Result<(), CoreError>,
) -> Result<ProjectInfo, CoreError> {
    let name = sanitize_name(name)?;
    fs::create_dir_all(data_dir)?;
    for id in project_names(&name) {
        let root = data_dir.join(&id);
        // One create, passing over anything there, a dangling link or case alias too.
        match fs::create_dir(&root) {
            Err(err) if err.kind() == ErrorKind::AlreadyExists => continue,
            created => created?,
        }
        if let Err(err) = fill(&root) {
            let _ = fs::remove_dir_all(&root);
            return Err(err);
        }
        return Ok(ProjectInfo::read(data_dir, &id)?);
    }
    unreachable!("a free name")
}

/// The first free name in the series "Untitled", "Untitled 2", …, however the volume spells
/// case; creates nothing, so a host can offer it as the name to edit.
pub fn free_project_name(data_dir: &Path, base: Option<&str>) -> Result<String, CoreError> {
    let clean = sanitize_name(base.unwrap_or("Untitled"))?;
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

fn project_names(clean: &str) -> impl Iterator<Item = String> {
    std::iter::once(clean.to_owned()).chain((2..).map(move |n| format!("{clean} {n}")))
}

pub(crate) fn guess_main_file(root: &Path) -> Result<Option<String>, CoreError> {
    let mut tex = Vec::new();
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
        let bytes = fs::read(root.join(name.as_str()));
        bytes.is_ok_and(|bytes| {
            let text = String::from_utf8_lossy(&bytes);
            SourceDocument::new(&text).document_class().is_some()
        })
    };
    Ok(tex
        .iter()
        .find(|name| name.eq_ignore_ascii_case("main.tex"))
        .or_else(|| tex.iter().find(starts_document))
        .or(tex.first())
        .cloned())
}

pub fn rename_project(
    data_dir: &Path,
    id: &str,
    new_name: &str,
    before_move: impl FnOnce(&Path) -> Result<(), CoreError>,
) -> Result<ProjectInfo, CoreError> {
    let root = project_root(data_dir, id)?;
    let clean = sanitize_name(new_name)?;
    let dest = data_dir.join(&clean);
    if occupied(&root, &dest) {
        return Err(CoreError::conflict(
            "A project with that name already exists",
        ));
    }
    before_move(&root)?;
    fs::rename(&root, &dest)?;
    Ok(ProjectInfo::read(data_dir, &clean)?)
}

/// `path` with its links resolved as far as it exists, so one not yet made or just trashed
/// still compares with the library.
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
    use std::time::{Duration, SystemTime};

    use super::*;
    use crate::projects::create_free;
    use crate::projects::testing::{fails_with, names_in, project};
    use crate::settings::Engine;

    #[test]
    fn a_path_in_the_library_is_found_in_its_project() {
        let (_dir, root) = project();
        let data = root.parent().unwrap();
        create_free(&root, "a/b.tex", false).unwrap();
        let at = |path: &Path| locate(data, path).unwrap();
        let found = |path: &str| {
            let (id, path) = ("P".into(), path.into());
            Some(Located { id, path })
        };
        assert_eq!(at(&root.join("a/b.tex")), found("a/b.tex"));
        assert_eq!(at(&root), found(""));
        assert_eq!(at(&root.join("a/gone.tex")), found("a/gone.tex"));
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
    fn a_project_is_made_named_sanitised_from_its_template_with_its_engine_or_not_at_all() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path();
        let made = create_project(data, "  Thesis  ", "report", Some("lualatex")).unwrap();
        let shown = [&made.id, &made.name, &made.main_file];
        assert_eq!(shown, ["Thesis", "Thesis", "main.tex"]);
        let root = data.join("Thesis");
        let files = [".texlocal.json", "main.tex", "references.bib"];
        assert_eq!(names_in(&root), files);
        let main = fs::read_to_string(root.join("main.tex")).unwrap();
        assert!(main.contains("{report}"));
        assert_eq!(read_settings(&root).engine, Engine::Lualatex);

        let refused = create_project(data, "Other", "blank", Some("word"));
        assert_eq!(refused.unwrap_err().status, 400);
        for bad in ["   ", ".hidden"] {
            fails_with(create_project(data, bad, "blank", None), "Invalid name");
        }

        assert_eq!(names_in(data), ["Thesis"]);
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(data.join("gone"), data.join("linked")).unwrap();
            let made = create_project(data, "linked", "blank", None).unwrap();
            assert_eq!(made.id, "linked 2");
            assert!(!data.join("gone").exists());
        }
    }

    #[test]
    fn a_project_is_dated_by_its_newest_file() {
        let (_dir, root) = project();
        let later = SystemTime::now() + Duration::from_secs(3600);
        let main = fs::File::options().write(true).open(root.join("main.tex"));
        main.unwrap().set_modified(later).unwrap();
        let since = later.duration_since(UNIX_EPOCH).unwrap();
        let mtime = list_projects(root.parent().unwrap()).unwrap()[0].mtime;
        assert_eq!(mtime, since.as_millis() as u64);
    }

    // Windows opens a folder only for its backup semantics, so its date is set here alone.
    #[cfg(unix)]
    #[test]
    fn projects_of_one_date_are_listed_by_name() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path();
        let date = SystemTime::now() - Duration::from_secs(3600);
        for name in ["b", "c", "a"] {
            create_project(data, name, "blank", None).unwrap();
            for entry in [".", "main.tex", ".texlocal.json"] {
                let file = fs::File::open(data.join(name).join(entry)).unwrap();
                file.set_modified(date).unwrap();
            }
        }
        let listed = list_projects(data).unwrap().into_iter().map(|p| p.id);
        assert_eq!(listed.collect::<Vec<_>>(), ["a", "b", "c"]);
    }
}
