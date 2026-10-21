//! Folders opened where they are. The library lists each in its store, `.opened/<key>/`, which
//! holds where the folder is (`folder.json`), its ui state and the settings it has no
//! `.texlocal.json` of its own for (`project.json`), and its build output (`build/`): nothing is
//! written in the folder but the author's files. Its id is `.<key>`, which no project in the
//! library can have.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::library::{Located, ProjectInfo, locate};
use super::tree::{file_kind, visit_files};
use crate::error::CoreError;
use crate::paths::Project;
use crate::service::Service;
use crate::settings::write_settings;
use crate::{BUILD_DIR, SETTINGS_FILE, atomic, import, lock};

const STORE: &str = ".opened";
const FOLDER: &str = "folder.json";
const SIDECAR: &str = "project.json";
/// A whole repository or home folder, not a document's: the tree and the scans would walk it all
/// on each change.
const MAX_FILES: usize = 20_000;

/// Where an opened folder is, and which folder it is wherever it moves on its volume.
#[derive(Serialize, Deserialize)]
pub(super) struct Folder {
    pub path: PathBuf,
    identity: Option<(u64, u64)>,
}

/// The project a path opens, and the file in it to show.
#[derive(Debug, Serialize)]
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

/// Every opened folder, by its id; one whose record can't be read is left out.
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

/// Its own `.texlocal.json` holds its settings while it has one.
fn project(root: &Path, store: &Path) -> Project {
    let (own, sidecar) = (root.join(SETTINGS_FILE), store.join(SIDECAR));
    Project {
        settings: if own.is_file() { own } else { sidecar.clone() },
        ui: sidecar,
        build: store.join(BUILD_DIR),
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
        return Err(CoreError::not_found(format!("No such project: {id}")));
    };
    let project = project(&path, &store);
    if !path.is_dir() {
        return Err(CoreError::not_found(format!(
            "“{}” isn’t at {} any more. Open it where it is now, or remove it from the list.",
            project.name(),
            path.display()
        )));
    }
    Ok(project)
}

/// What `path` opens: the project it is in (a folder in an opened folder is a project of its
/// own); a folder where it is; a .tex's folder where it is, at the .tex, or the .tex alone where
/// its folder can't be opened; else a .zip's files or the file alone, imported.
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
    let real = dunce::canonicalize(path)?;
    let name = real.file_name().unwrap_or_default().to_string_lossy();
    let (project, file) = if meta.is_dir() {
        (open_folder(service, &real, None)?, None)
    } else if file_kind(&name) != "tex" {
        (import::import_project(service, path)?, None)
    } else {
        let folder = real.parent().expect("a file's folder");
        let project = match open_folder(service, folder, Some(&name)) {
            Err(refused) if refused.status == 400 => import::import_project(service, path)?,
            opened => opened?,
        };
        (project, Some(name.into_owned()))
    };
    Ok(Opening { project, file })
}

/// The folder at `root`, resolved, as listed before at that path or, moved, by its identity;
/// else listed anew, with the settings its sources name unless it has its own, `chosen` the
/// .tex opened in it.
fn open_folder(
    service: &Service,
    root: &Path,
    chosen: Option<&str>,
) -> Result<ProjectInfo, CoreError> {
    let data_dir = &service.data_dir;
    let name = root.file_name().unwrap_or(root.as_os_str()).display();
    let library = dunce::canonicalize(data_dir)?;
    if library.starts_with(root) || root.starts_with(&library) {
        return Err(CoreError::bad_request(format!(
            "“{name}” holds TeXLocal’s projects. Choose the folder that holds the document."
        )));
    }
    let mut files = 0;
    visit_files(root, &mut |_, _| {
        files += 1;
        Ok(files <= MAX_FILES)
    })?;
    if files > MAX_FILES {
        return Err(CoreError::bad_request(format!(
            "“{name}” has more than 20,000 files. Choose the folder that holds the document."
        )));
    }
    let _edits = lock(&service.edits);
    let folder = Folder {
        path: root.to_path_buf(),
        identity: identity(root),
    };
    let same = folders(data_dir).into_iter().find(|(_, known)| {
        known.path == folder.path || folder.identity.is_some() && known.identity == folder.identity
    });
    let (store, made) = match same {
        Some((id, _)) => (store(data_dir, &id), None),
        None => {
            let stores = data_dir.join(STORE);
            fs::create_dir_all(&stores)?;
            let made = tempfile::Builder::new()
                .prefix("")
                .rand_bytes(8)
                .tempdir_in(stores)?;
            if !root.join(SETTINGS_FILE).is_file() {
                let settings = import::guessed_settings(root, chosen)?;
                write_settings(&made.path().join(SIDECAR), &settings)?;
            }
            (made.path().to_path_buf(), Some(made))
        }
    };
    let record = serde_json::to_vec_pretty(&folder);
    let record = record.map_err(|err| CoreError::bad_request(err.to_string()))?;
    atomic::write(&store.join(FOLDER), &record)?;
    made.map(tempfile::TempDir::keep);
    let id = format!(".{}", store.file_name().unwrap_or_default().display());
    Ok(ProjectInfo::of(id, &project(root, &store)))
}

/// Takes an opened folder off the list, with its settings and build output, after `stop` ends
/// what runs in it; the folder stays as it is.
pub fn forget_folder(
    data_dir: &Path,
    id: &str,
    stop: impl FnOnce(&Path) -> Result<(), CoreError>,
) -> Result<(), CoreError> {
    if !is_opened(id) {
        return Err(CoreError::bad_request(
            "Only a folder opened where it is can be removed from the list.",
        ));
    }
    let known = folders(data_dir);
    let Some((_, folder)) = known.iter().find(|(known, _)| known == id) else {
        return Err(CoreError::not_found(format!("No such project: {id}")));
    };
    if folder.path.is_dir() {
        stop(&folder.path)?;
    }
    Ok(fs::remove_dir_all(store(data_dir, id))?)
}

#[cfg(unix)]
fn identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let meta = fs::metadata(path).ok()?;
    Some((meta.dev(), meta.ino()))
}

/// The volume's serial number and the folder's index on it, which `std` keeps unstable.
#[cfg(windows)]
fn identity(path: &Path) -> Option<(u64, u64)> {
    let handle = winapi_util::Handle::from_path_any(path).ok()?;
    let info = winapi_util::file::information(&handle).ok()?;
    Some((info.volume_serial_number(), info.file_index()))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::projects::testing::{fails_with, names_in, with_project};
    use crate::projects::{list_projects, rename_project};
    use crate::settings::{read_settings, read_ui};

    fn write(dir: &Path, files: &[(&str, &str)]) -> PathBuf {
        for (path, text) in files {
            fs::create_dir_all(dir.join(path).parent().unwrap()).unwrap();
            fs::write(dir.join(path), text).unwrap();
        }
        dunce::canonicalize(dir).unwrap()
    }

    #[tokio::test]
    async fn a_folder_opens_where_it_is_and_keeps_its_settings_and_state_beside_the_library() {
        let (dir, service) = with_project();
        let main = "\\documentclass{article}\\input{chapters/a}";
        let files = [
            ("main.tex", main),
            ("chapters/a.tex", "A"),
            (".git/HEAD", "ref"),
        ];
        let folder = write(&dir.path().join("Thesis"), &files);
        let opening = open_path(&service, &folder).unwrap();
        let (project, id) = (&opening.project, opening.project.id.clone());
        assert!(id.starts_with('.') && project.opened && !project.missing);
        assert_eq!(opening.file, None);
        assert_eq!([&project.name, &project.main_file], ["Thesis", "main.tex"]);
        assert_eq!(Path::new(&project.path), folder);

        let patch = json!({ "id": id, "patch": { "expandedFolders": ["chapters"] } });
        service.call("set_ui_state", &patch).await.unwrap();
        let found = service.project(&id).unwrap();
        assert_eq!(found.settings, found.ui);
        assert_eq!(read_ui(&found.ui).expanded_folders, ["chapters"]);
        assert!(found.build.starts_with(service.data_dir.join(STORE)));
        assert_eq!(names_in(&folder), [".git", "chapters", "main.tex"]);

        // Opened again it is the same; a folder in it is a project of its own, and a path is
        // in the innermost one that has it.
        assert_eq!(open_path(&service, &folder).unwrap().project.id, id);
        let inner = open_path(&service, &folder.join("chapters")).unwrap();
        let inner = inner.project.id;
        assert_ne!(inner, id);
        let shown = |path: &str| {
            let opened = open_path(&service, &folder.join(path)).unwrap();
            (opened.project.id, opened.file.unwrap())
        };
        assert_eq!(shown("chapters/a.tex"), (inner, "a.tex".into()));
        assert_eq!(shown("main.tex"), (id.clone(), "main.tex".into()));
        let listed = list_projects(&service.data_dir).unwrap();
        assert_eq!(listed.iter().filter(|p| p.opened).count(), 2);
        assert!(
            listed
                .iter()
                .any(|p| p.id == "P" && !p.opened && !p.missing)
        );
        fails_with(
            rename_project(&service.data_dir, &id, "X", |_| Ok(())),
            "renamed",
        );
    }

    #[test]
    fn its_own_settings_file_keeps_its_settings_but_not_its_state() {
        // Into a library that doesn't exist yet, as on a first open.
        let dir = tempfile::tempdir().unwrap();
        let service = Service::new(dir.path().join("data"));
        let own = r#"{ "mainFile": "paper.tex" }"#;
        let files = [("paper.tex", ""), (".texlocal.json", own)];
        let folder = write(&dir.path().join("Paper"), &files);
        let id = open_path(&service, &folder).unwrap().project.id;
        let project = service.project(&id).unwrap();
        assert_eq!(project.settings, folder.join(SETTINGS_FILE));
        assert_eq!(read_settings(&project.settings).main_file, "paper.tex");
        let patch = serde_json::from_value(json!({ "foldedHeadings": ["x"] })).unwrap();
        crate::settings::write_ui(&project.ui, patch).unwrap();
        assert_eq!(fs::read_to_string(folder.join(SETTINGS_FILE)).unwrap(), own);
        assert!(project.ui.starts_with(service.data_dir.join(STORE)));
    }

    #[test]
    fn a_folder_moved_keeps_its_id_and_one_gone_is_listed_until_taken_off_the_list() {
        let (dir, service) = with_project();
        let folder = write(&dir.path().join("Thesis"), &[("main.tex", "")]);
        let id = open_path(&service, &folder).unwrap().project.id;
        let moved = folder.with_file_name("Thesis 2");
        fs::rename(&folder, &moved).unwrap();
        let listed = list_projects(&service.data_dir).unwrap();
        let gone = listed.last().unwrap();
        assert_eq!((&gone.id, gone.missing, gone.mtime), (&id, true, 0));
        fails_with(service.project(&id), "isn’t at");

        let found = open_path(&service, &moved).unwrap().project;
        assert_eq!((&found.id, found.name.as_str()), (&id, "Thesis 2"));
        assert!(!found.missing);
        fails_with(
            forget_folder(&service.data_dir, "P", |_| Ok(())),
            "Only a folder",
        );
        forget_folder(&service.data_dir, &id, |_| Ok(())).unwrap();
        assert_eq!(names_in(&moved), ["main.tex"]);
        assert_eq!(
            names_in(&service.data_dir.join(STORE)),
            Vec::<String>::new()
        );
        let again = forget_folder(&service.data_dir, &id, |_| Ok(()));
        assert_eq!(again.unwrap_err().status, 404);
    }

    #[test]
    fn a_tex_opens_its_folder_unless_that_is_refused_and_a_path_in_the_library_its_project() {
        let (dir, service) = with_project();
        let paper = write(
            &dir.path().join("Paper"),
            &[("main.tex", ""), ("notes.tex", "")],
        );
        let opened = open_path(&service, &paper.join("notes.tex")).unwrap();
        assert!(opened.project.opened);
        assert_eq!(opened.project.main_file, "notes.tex");
        assert_eq!(opened.file.as_deref(), Some("notes.tex"));

        let library = service.project("P").unwrap().root;
        let opened = open_path(&service, &library.join("main.tex")).unwrap();
        assert_eq!(
            (opened.project.id.as_str(), opened.file.as_deref()),
            ("P", Some("main.tex"))
        );
        // The folder that holds the library, or the library itself, isn't a project's.
        for folder in [dir.path(), &service.data_dir] {
            fails_with(open_path(&service, folder), "holds TeXLocal’s projects");
        }
        let big = dir.path().join("Big");
        fs::create_dir(&big).unwrap();
        for n in 0..=MAX_FILES {
            fs::File::create(big.join(format!("{n}.txt"))).unwrap();
        }
        fails_with(open_path(&service, &big), "more than 20,000 files");
        fs::write(big.join("alone.tex"), "").unwrap();
        let alone = open_path(&service, &big.join("alone.tex")).unwrap();
        assert_eq!(
            (alone.project.id.as_str(), alone.project.opened),
            ("alone", false)
        );
        assert_eq!(alone.file.as_deref(), Some("alone.tex"));
        assert_eq!(
            open_path(&service, &dir.path().join("gone"))
                .unwrap_err()
                .status,
            404
        );
    }
}
