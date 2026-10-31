use std::cmp::Reverse;
use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, ErrorKind};
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::syntax::SourceDocument;
use texlocal_latex::templates::ProjectTemplate;
use texlocal_latex::{FileKind, file_kind};

use super::files::occupied;
use super::opened::{self, is_opened};
use super::skip_unreadable;
use super::tree::{listed, walk};
use crate::error::CoreError;
use crate::messages;
use crate::paths::{Project, UI_DIR, fold_case, sanitize_name, ui_file};
use crate::service::Service;
use crate::settings::{Engine, SettingsPatch, new_settings, read_settings};
use crate::{SETTINGS_FILE, atomic, lock};

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProjectInfo {
    pub id: String,
    pub name: String,
    pub mtime: u64,
    pub main_file: String,
    pub path: String,
    pub opened: bool,
    pub missing: bool,
}

impl ProjectInfo {
    fn read(data_dir: &Path, id: &str) -> io::Result<Self> {
        Ok(Self::of(id.to_owned(), &Project::in_library(data_dir, id)?))
    }

    pub(super) fn of(id: String, project: &Project) -> Self {
        Self {
            opened: is_opened(&id),
            id,
            name: project.name(),
            mtime: newest(&project.root),
            main_file: read_settings(&project.settings).main_file,
            path: project.root.to_string_lossy().into_owned(),
            missing: !project.root.is_dir(),
        }
    }
}

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

fn newest(root: &Path) -> u64 {
    let mut newest = fs::metadata(root).map_or(0, |meta| mtime_ms(&meta));
    let _ = walk(root, &listed, false, &mut |entry| {
        if (entry.dir || !entry.rel.contains('/'))
            && let Ok(meta) = fs::metadata(&entry.path)
        {
            newest = newest.max(mtime_ms(&meta));
        }
        Ok(true)
    });
    newest
}

pub fn list_projects(data_dir: &Path) -> Result<Vec<ProjectInfo>, CoreError> {
    let mut projects = Vec::new();
    for entry in fs::read_dir(data_dir)? {
        let entry = entry?;
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if !name.starts_with('.') && entry.file_type()?.is_dir() {
            projects.extend(skip_unreadable(ProjectInfo::read(data_dir, &name))?);
        }
    }
    projects.extend(opened::list(data_dir));
    projects.sort_by(|a, b| b.mtime.cmp(&a.mtime).then_with(|| a.id.cmp(&b.id)));
    Ok(projects)
}

pub fn create_project(
    data_dir: &Path,
    name: &str,
    template: ProjectTemplate,
    engine: Option<Engine>,
) -> Result<ProjectInfo, CoreError> {
    new_project(data_dir, name, |root| {
        for (file, content) in template.files() {
            fs::write(root.join(file), content)?;
        }
        let settings = SettingsPatch {
            engine,
            ..SettingsPatch::default()
        };
        new_settings(&root.join(SETTINGS_FILE), &settings)
    })
}

pub(crate) fn new_project(
    data_dir: &Path,
    name: &str,
    fill: impl FnOnce(&Path) -> Result<(), CoreError>,
) -> Result<ProjectInfo, CoreError> {
    let name = sanitize_name(name)?;
    fs::create_dir_all(data_dir)?;
    let temp = atomic::temp_builder().tempdir_in(data_dir)?;
    fill(temp.path())?;
    let id: String = project_names(&name)
        .find_map(
            |id| match atomic::rename_exclusive(temp.path(), &data_dir.join(&id)) {
                Err(err) if err.kind() == ErrorKind::AlreadyExists => None,
                moved => Some(moved.map(|()| id)),
            },
        )
        .expect("a free name")?;
    Ok(ProjectInfo::read(data_dir, &id)?)
}

pub fn free_project_name(data_dir: &Path) -> Result<String, CoreError> {
    let taken: HashSet<String> = match fs::read_dir(data_dir) {
        Ok(entries) => entries
            .map(|entry| entry.map(|e| fold_case(&e.file_name().to_string_lossy())))
            .collect::<Result<_, _>>()?,
        Err(err) if err.kind() == ErrorKind::NotFound => HashSet::new(),
        Err(err) => return Err(err.into()),
    };
    Ok(project_names("Untitled")
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
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if entry.file_type()?.is_file()
            && file_kind(&name) == FileKind::Tex
            && !name.starts_with('-')
        {
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
        .find(|name| fold_case(name) == "main.tex")
        .or_else(|| tex.iter().find(starts_document))
        .or(tex.first())
        .cloned())
}

pub fn rename_project(data_dir: &Path, id: &str, new_name: &str) -> Result<ProjectInfo, CoreError> {
    if is_opened(id) {
        return Err(CoreError::bad_request(messages::opened_elsewhere()));
    }
    let project = Project::find(data_dir, id)?;
    let clean = sanitize_name(new_name)?;
    let dest = data_dir.join(&clean);
    if occupied(&project.root, &dest) {
        return Err(CoreError::conflict(messages::project_exists()));
    }
    atomic::rename_exclusive(&project.root, &dest)?;
    let _ = fs::rename(&project.ui, ui_file(data_dir, &clean));
    Ok(ProjectInfo::read(data_dir, &clean)?)
}

pub(crate) fn sweep_ui(service: &Service) {
    let _library = lock(&service.library);
    let Ok(files) = fs::read_dir(service.data_dir.join(UI_DIR)) else {
        return;
    };
    let gone = |name: &OsStr| !service.data_dir.join(name).is_dir();
    for file in files.flatten() {
        let path = file.path();
        if path.extension().is_some_and(|ext| ext == "json") && path.file_stem().is_some_and(gone) {
            let _ = fs::remove_file(path);
        }
    }
}

fn real_path(path: &Path) -> PathBuf {
    let (mut head, mut tail) = (path, Vec::new());
    loop {
        if let Ok(real) = std::fs::canonicalize(head) {
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
    if !path.is_absolute() {
        return Ok(None);
    }
    let real = real_path(path);
    let segments = |rest: &Path| -> Option<Vec<String>> {
        (rest.components())
            .map(|part| match part {
                Component::Normal(name) => name.to_str().map(str::to_owned),
                _ => None,
            })
            .collect()
    };
    if let Ok(rest) = real.strip_prefix(std::fs::canonicalize(data_dir)?) {
        let segments = segments(rest);
        let Some([id, inside @ ..]) = segments.as_deref() else {
            return Ok(None);
        };
        if id.starts_with('.') || !data_dir.join(id).is_dir() {
            return Ok(None);
        }
        let (id, path) = (id.clone(), inside.join("/"));
        return Ok(Some(Located { id, path }));
    }
    let mut folders = opened::folders(data_dir);
    folders.sort_by_key(|(_, folder)| Reverse(folder.path.as_os_str().len()));
    Ok(folders.into_iter().find_map(|(id, folder)| {
        let path = segments(real.strip_prefix(&folder.path).ok()?)?.join("/");
        Some(Located { id, path })
    }))
}
