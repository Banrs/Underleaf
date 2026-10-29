use std::fs;
use std::path::{Path, PathBuf};

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use texlocal_latex::{FileKind, file_kind};

use super::MAX_FILES;
use super::library::{Located, ProjectInfo, locate};
use super::tree::visit_files;
use crate::error::{CoreError, ErrorKind};
use crate::messages;
use crate::paths::{Project, identity};
use crate::service::Service;
use crate::settings::write_settings;
use crate::{BUILD_DIR, SETTINGS_FILE, atomic, import, lock};

const STORE: &str = ".opened";
const FOLDER: &str = "folder.json";
const SIDECAR: &str = "project.json";

#[derive(Serialize, Deserialize)]
pub(super) struct Folder {
    pub path: PathBuf,
    identity: Option<(u64, u64)>,
}

#[derive(Serialize, JsonSchema)]
pub struct Opening {
    pub project: ProjectInfo,
    pub file: Option<String>,
}

pub(crate) fn is_opened(id: &str) -> bool {
    id.starts_with('.')
}

fn store(data_dir: &Path, id: &str) -> PathBuf {
    data_dir.join(STORE).join(&id[1..])
}

fn read(store: &Path) -> Option<Folder> {
    serde_json::from_slice(&fs::read(store.join(FOLDER)).ok()?).ok()
}

pub(super) fn folders(data_dir: &Path) -> Vec<(String, Folder)> {
    let Ok(stores) = fs::read_dir(data_dir.join(STORE)) else {
        return Vec::new();
    };
    let folder = |store: fs::DirEntry| {
        let id = format!(".{}", store.file_name().display());
        Some((id, read(&store.path())?))
    };
    stores.flatten().filter_map(folder).collect()
}

fn own_settings(root: &Path) -> bool {
    fs::symlink_metadata(root.join(SETTINGS_FILE)).is_ok_and(|meta| meta.is_file())
}

fn project(root: &Path, store: &Path) -> Project {
    let (own, sidecar) = (root.join(SETTINGS_FILE), store.join(SIDECAR));
    Project {
        settings: if own_settings(root) {
            own
        } else {
            sidecar.clone()
        },
        ui: sidecar,
        build: store.join(BUILD_DIR),
        history: store.join("history"),
        root: root.to_path_buf(),
    }
}

pub(super) fn list(data_dir: &Path) -> Vec<ProjectInfo> {
    let info = |(id, folder): (String, Folder)| {
        let project = project(&folder.path, &store(data_dir, &id));
        ProjectInfo::of(id, &project)
    };
    folders(data_dir).into_iter().map(info).collect()
}

pub(crate) fn find(data_dir: &Path, id: &str) -> Result<Project, CoreError> {
    let store = store(data_dir, id);
    let Some(Folder { path, .. }) = read(&store) else {
        return Err(CoreError::not_found(messages::no_such_project(id)));
    };
    let project = project(&path, &store);
    if !path.is_dir() {
        let moved = messages::folder_moved(project.name(), path.display());
        return Err(CoreError::not_found(moved));
    }
    Ok(project)
}

pub fn open_path(service: &Service, path: &Path) -> Result<Opening, CoreError> {
    let meta = fs::metadata(path).map_err(CoreError::at(path))?;
    let data_dir = &service.data_dir;
    fs::create_dir_all(data_dir)?;
    let found = locate(data_dir, path)?;
    if let Some(Located { id, path: inside }) =
        found.filter(|found| !meta.is_dir() || found.path.is_empty() || !is_opened(&found.id))
    {
        let project = ProjectInfo::of(id.clone(), &Project::find(data_dir, &id)?);
        let file = meta.is_file().then_some(inside);
        return Ok(Opening { project, file });
    }
    let real = fs::canonicalize(path)?;
    let name = real.file_name().unwrap_or_default().to_string_lossy();
    let (project, file) = if meta.is_dir() {
        (open_folder(service, &real, None)?, None)
    } else if file_kind(&name) != FileKind::Tex {
        (import::import_project(service, path)?, None)
    } else {
        let folder = real.parent().expect("a file's folder");
        let project = match open_folder(service, folder, Some(&name)) {
            Err(refused) if refused.kind == ErrorKind::Invalid => {
                import::import_project(service, path)?
            }
            opened => opened?,
        };
        (project, Some(name.into_owned()))
    };
    Ok(Opening { project, file })
}

fn open_folder(
    service: &Service,
    root: &Path,
    chosen: Option<&str>,
) -> Result<ProjectInfo, CoreError> {
    let data_dir = &service.data_dir;
    let name = root.file_name().unwrap_or(root.as_os_str()).display();
    let library = fs::canonicalize(data_dir)?;
    if library.starts_with(root) || root.starts_with(&library) {
        return Err(CoreError::bad_request(messages::holds_library(name)));
    }
    let (mut files, mut tex) = (0, false);
    visit_files(root, &mut |_, rel| {
        files += 1;
        tex |= file_kind(rel) == FileKind::Tex;
        Ok(files <= MAX_FILES)
    })?;
    if files > MAX_FILES {
        return Err(CoreError::bad_request(messages::too_many_files(name)));
    }
    let _library = lock(&service.library);
    let folder = Folder {
        path: root.to_path_buf(),
        identity: identity(root),
    };
    let same = folders(data_dir).into_iter().find(|(_, known)| {
        known.path == folder.path || folder.identity.is_some() && known.identity == folder.identity
    });
    let (store, made) = match same {
        Some((id, _)) => (store(data_dir, &id), None),
        None if !tex => return Err(CoreError::bad_request(messages::no_tex(name))),
        None => {
            let stores = data_dir.join(STORE);
            fs::create_dir_all(&stores)?;
            let made = tempfile::Builder::new()
                .prefix("")
                .rand_bytes(8)
                .tempdir_in(stores)?;
            if !own_settings(root) {
                let settings = import::guessed_settings(root, chosen)?;
                write_settings(&made.path().join(SIDECAR), &settings)?;
            }
            (made.path().to_path_buf(), Some(made))
        }
    };
    let record = serde_json::to_vec_pretty(&folder);
    let record = record.map_err(|err| CoreError::bad_request(messages::unexpected(err)))?;
    atomic::write(&store.join(FOLDER), &record)?;
    made.map(tempfile::TempDir::keep);
    let id = format!(".{}", store.file_name().unwrap_or_default().display());
    Ok(ProjectInfo::of(id, &project(root, &store)))
}

pub fn forget_folder(service: &Service, id: &str) -> Result<(), CoreError> {
    if !is_opened(id) {
        return Err(CoreError::bad_request(messages::only_opened_forgotten()));
    }
    let store = store(&service.data_dir, id);
    let library = service.unless_open(id, messages::close_before_forgetting)?;
    let known = folders(&service.data_dir);
    if !known.iter().any(|(known, _)| known == id) {
        return Err(CoreError::not_found(messages::no_such_project(id)));
    }
    fs::remove_file(store.join(FOLDER))?;
    drop(library);
    Ok(fs::remove_dir_all(store)?)
}
