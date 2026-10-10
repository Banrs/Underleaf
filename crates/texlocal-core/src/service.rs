// Shared command surface: hosts forward here so path checks and edit
// serialization have one implementation.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::analyze;
use crate::compile::{self, CompileManager, CompileOverrides, CompileResult, TexStatus};
use crate::paths::fold_case;
use crate::projects::{self, Symbols};
use crate::settings;
use crate::synctex;
use crate::{atomic, paths, CoreError};

pub const UPLOAD_MAX_BYTES: usize = 100 * 1024 * 1024;
const SEARCH_LIMIT: usize = 100;
/// Shared TeX folder choice, stored beside projects as a file so it never
/// appears in the project list.
pub const APP_SETTINGS_FILE: &str = ".texlocal-app.json";
const NO_LATEXMK: &str = "That folder doesn't contain latexmk. Choose the folder with TeX's programs, such as /Library/TeX/texbin.";
const NO_TEXPRESSO: &str =
    "That folder doesn't contain the texpresso program. Choose the folder it's in.";

/// TeX folder listing: names only, never file contents.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirListing {
    pub path: String,
    pub parent: Option<String>,
    pub dirs: Vec<String>,
    pub has_latexmk: bool,
    pub roots: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadSpec {
    pub path: String,
    pub size: usize,
}

/// An upload's occupied path or blocking parent file, relative to its target
/// folder. `keep_both` names a free sibling.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Clash {
    pub path: String,
    pub keep_both: String,
}

#[derive(Debug, Serialize)]
pub struct UploadCheck {
    pub existing: Vec<Clash>,
}

/// An upload file's path once Keep Both has renamed the clash it lies under.
pub fn keep_both(path: &str, clashes: &[Clash]) -> String {
    clashes
        .iter()
        .find_map(|c| {
            let rest = path.strip_prefix(&c.path)?;
            (rest.is_empty() || rest.starts_with('/')).then(|| format!("{}{rest}", c.keep_both))
        })
        .unwrap_or_else(|| path.to_string())
}

/// The first entry in `rel`'s way under `base`: the file itself if it
/// exists, or a folder on its path that exists as something else.
fn clash(base: &Path, rel: &str) -> Option<String> {
    let mut end = 0;
    loop {
        end = rel[end..].find('/').map_or(rel.len(), |i| end + i);
        let abs = base.join(&rel[..end]);
        let meta = fs::symlink_metadata(&abs).ok()?;
        // A link to a folder is a folder on the way: the path checks have
        // already kept it inside the project.
        if end == rel.len() || !(meta.is_dir() || abs.is_dir()) {
            return Some(rel[..end].to_string());
        }
        end += 1;
    }
}

pub struct Service {
    pub data_dir: PathBuf,
    pub compile: CompileManager,
    pub texpresso: crate::texpresso::Manager,
    /// One lock per project, keyed by its folder's identity (device and
    /// inode), so a project's edits, settings read/modify/write, renames and
    /// deletes run one at a time while other projects go on. The identity
    /// follows the folder through a rename and does not depend on how an id
    /// spells it on a case-insensitive volume.
    edits: Mutex<HashMap<FolderId, Arc<Mutex<()>>>>,
    /// Held by a project rename too, so two projects can't take one name.
    library: Mutex<()>,
}

/// The guards protect no data, so a panic under one leaves nothing half-made:
/// a poisoned lock is still good, and must not stop every later edit.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A folder's device and inode.
type FolderId = (u64, u64);

/// A project folder's identity, which a rename keeps.
fn identity(root: &Path) -> Result<FolderId, CoreError> {
    let meta = fs::metadata(root)?;
    Ok((meta.dev(), meta.ino()))
}

fn upload_rel(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    }
}

fn too_large() -> CoreError {
    CoreError::bad_request(format!(
        "File exceeds the {} MB upload limit",
        UPLOAD_MAX_BYTES / 1024 / 1024
    ))
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            texpresso: crate::texpresso::Manager::default(),
            edits: Mutex::default(),
            library: Mutex::default(),
        }
    }

    pub fn project_root(&self, id: &str) -> Result<PathBuf, CoreError> {
        paths::project_root(&self.data_dir, id)
    }

    /// With `live`, the TeXpresso session the client owns (`session`) syncs, not the build:
    /// its PDF is the one shown.
    fn live_pdf(&self, root: &Path, args: &Value) -> Result<Option<PathBuf>, CoreError> {
        if !arg::<Option<bool>>(args, "live")?.unwrap_or(false) {
            return Ok(None);
        }
        let token = arg::<Option<String>>(args, "session")?
            .ok_or_else(|| CoreError::bad_request("Live sync needs the TeXpresso session"))?;
        self.texpresso.live_pdf(root, &token).map(Some)
    }

    /// The lock for the project folder `key` names; locks no one holds are
    /// dropped on the way.
    fn project_lock(&self, key: FolderId) -> Arc<Mutex<()>> {
        let mut locks = lock(&self.edits);
        locks.retain(|_, held| Arc::strong_count(held) > 1);
        Arc::clone(locks.entry(key).or_default())
    }

    /// Run `use_project` holding the project's lock.
    fn with_project<T>(
        &self,
        id: &str,
        use_project: impl FnOnce(&Path) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        loop {
            let root = self.project_root(id)?;
            let key = identity(&root)?;
            let project = self.project_lock(key);
            let _edit = lock(&project);
            // While this waited, the holder may have renamed or deleted the
            // project, and another taken its name: look again.
            if identity(&root).ok() == Some(key) {
                return use_project(&root);
            }
        }
    }

    // ---------- status ----------

    /// Probe the current TeX choice, including installs made while the app is open.
    pub async fn status(&self) -> TexStatus {
        let tex_dir = self.tex_dir();
        let mut found = compile::tex_available(&compile::tex_path(tex_dir.as_deref())).await;
        found.tex_dir = tex_dir.map(|d| d.to_string_lossy().into_owned());
        found.texpresso = crate::texpresso::discover(&self.texpresso_path())
            .map(|p| p.to_string_lossy().into_owned());
        found.texpresso_dir = self
            .texpresso_dir()
            .map(|d| d.to_string_lossy().into_owned());
        found
    }

    // ---------- TeX folder ----------

    /// The TeX programs folder the user chose, or None to find TeX
    /// automatically. Read per use, so a choice made in another host applies.
    pub fn tex_dir(&self) -> Option<PathBuf> {
        self.app_folder("texDir")
    }

    /// The folder with TeXpresso the user chose, searched before the TeX path.
    pub fn texpresso_dir(&self) -> Option<PathBuf> {
        self.app_folder("texpressoDir")
    }

    fn app_settings(&self) -> serde_json::Map<String, Value> {
        std::fs::read(self.data_dir.join(APP_SETTINGS_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn app_folder(&self, key: &str) -> Option<PathBuf> {
        let dir = self.app_settings().get(key)?.as_str()?.to_owned();
        (!dir.is_empty()).then(|| PathBuf::from(dir))
    }

    /// Writes one folder, keeping the other settings.
    fn set_app_folder(&self, key: &str, dir: Option<&Path>) -> Result<(), CoreError> {
        let mut settings = self.app_settings();
        settings.insert(key.into(), json!(dir.map(|d| d.to_string_lossy())));
        atomic::write(
            &self.data_dir.join(APP_SETTINGS_FILE),
            Value::Object(settings).to_string().as_bytes(),
        )?;
        Ok(())
    }

    fn tex_path(&self) -> String {
        compile::tex_path(self.tex_dir().as_deref())
    }

    fn texpresso_path(&self) -> String {
        match self.texpresso_dir() {
            Some(dir) => format!("{}:{}", dir.to_string_lossy(), self.tex_path()),
            None => self.tex_path(),
        }
    }

    /// Choose TeXpresso's folder; None or empty goes back to the TeX path.
    pub async fn set_texpresso_dir(&self, dir: Option<&str>) -> Result<TexStatus, CoreError> {
        let chosen = dir.map(str::trim).filter(|d| !d.is_empty()).map(Path::new);
        if let Some(dir) = chosen {
            if !dir.is_absolute() || !crate::texpresso::executable_file(&dir.join("texpresso")) {
                return Err(CoreError::bad_request(NO_TEXPRESSO));
            }
        }
        self.set_app_folder("texpressoDir", chosen)?;
        Ok(self.status().await)
    }

    /// Choose the TeX folder; None or empty goes back to automatic. A TeX Live
    /// root is accepted and saved as its bin folder.
    pub async fn set_tex_dir(&self, dir: Option<&str>) -> Result<TexStatus, CoreError> {
        let chosen = match dir.map(str::trim).filter(|d| !d.is_empty()) {
            None => None,
            Some(dir) => {
                let dir = Path::new(dir);
                if !dir.is_absolute() {
                    return Err(CoreError::bad_request(NO_LATEXMK));
                }
                Some(compile::tex_bin_dir(dir).ok_or_else(|| CoreError::bad_request(NO_LATEXMK))?)
            }
        };
        self.set_app_folder("texDir", chosen.as_deref())?;
        Ok(self.status().await)
    }

    /// A folder's subfolders, for the browser version's TeX folder picker.
    /// None starts at the TeX folder in use, else the home folder.
    pub fn list_dirs(&self, path: Option<&str>) -> Result<DirListing, CoreError> {
        let dir = match path.map(str::trim).filter(|p| !p.is_empty()) {
            Some(path) => PathBuf::from(path),
            None => self
                .tex_dir()
                .or_else(|| compile::latexmk_dir(&self.tex_path()))
                .or_else(std::env::home_dir)
                .unwrap_or_default(),
        };
        let unreadable = || CoreError::bad_request("Couldn't open that folder.");
        if !dir.is_absolute() {
            return Err(unreadable());
        }
        let mut dirs: Vec<String> = std::fs::read_dir(&dir)
            .map_err(|_| unreadable())?
            .filter_map(|e| e.ok())
            .filter(|e| !e.file_name().to_string_lossy().starts_with('.') && e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        dirs.sort_by_key(|name| name.to_lowercase());
        Ok(DirListing {
            path: dir.to_string_lossy().into_owned(),
            parent: dir.parent().map(|p| p.to_string_lossy().into_owned()),
            dirs,
            has_latexmk: compile::has_latexmk(&dir),
            roots: vec!["/".into()],
        })
    }

    // ---------- files ----------

    /// Without the project's lock: every write replaces a file in one
    /// rename, so a scan reads each file whole, old or new, and an autosave
    /// need not wait for it.
    pub fn scan_symbols(&self, id: &str) -> Result<Symbols, CoreError> {
        projects::scan_symbols(&self.project_root(id)?)
    }

    /// Validate the whole batch before writing, so a late unsafe or oversize
    /// entry cannot cause a predictable partial import. Return clashes and free Keep Both
    /// names for the host's Replace, Keep Both or Stop choice.
    pub fn validate_uploads(
        &self,
        id: &str,
        dir: &str,
        files: &[UploadSpec],
    ) -> Result<UploadCheck, CoreError> {
        let root = self.project_root(id)?;
        let base = root.join(paths::rel_key(dir).unwrap_or_default());
        let mut seen = HashSet::new();
        let mut folders = HashSet::new();
        let mut rels = Vec::new();
        for file in files {
            if file.size > UPLOAD_MAX_BYTES {
                return Err(too_large());
            }
            paths::safe_write_path(&root, &upload_rel(dir, &file.path))?;
            // Relative to `dir`, as the host names the files.
            let rel = paths::rel_key(&file.path)?;
            let key = fold_case(&rel);
            if seen.contains(&key) {
                return Err(CoreError::bad_request(
                    "The upload contains duplicate paths",
                ));
            }
            if folders.contains(&key)
                || key
                    .match_indices('/')
                    .any(|(i, _)| seen.contains(&key[..i]))
            {
                return Err(CoreError::bad_request(
                    "The upload contains conflicting paths",
                ));
            }
            folders.extend(key.match_indices('/').map(|(i, _)| key[..i].to_string()));
            seen.insert(key);
            rels.push(rel);
        }
        // Names a Keep Both may not take: every path the upload creates.
        seen.extend(folders);
        let mut taken = seen;
        let mut existing: Vec<Clash> = Vec::new();
        for rel in &rels {
            let Some(path) = clash(&base, rel) else {
                continue;
            };
            if existing.iter().any(|c| c.path == path) {
                continue;
            }
            let (parent, name) = path.rsplit_once('/').unwrap_or(("", &path));
            let keep_both = (2..)
                .map(|n| upload_rel(parent, &projects::numbered(name, n)))
                .find(|free| {
                    fs::symlink_metadata(base.join(free)).is_err() && taken.insert(fold_case(free))
                })
                .expect("a free name");
            existing.push(Clash { path, keep_both });
        }
        Ok(UploadCheck { existing })
    }

    /// Write one validated upload, rechecking its path and size. An occupied
    /// path conflicts unless `replace` first moves it to Trash.
    pub fn upload_file(
        &self,
        id: &str,
        dir: &str,
        path: &str,
        bytes: &[u8],
        replace: bool,
    ) -> Result<String, CoreError> {
        if bytes.len() > UPLOAD_MAX_BYTES {
            return Err(too_large());
        }
        let rel = upload_rel(dir, path);
        self.with_project(id, |root| {
            let abs = paths::safe_write_path(root, &rel)?;
            if let Some(taken) = clash(root, &paths::rel_key(&rel)?) {
                if !replace {
                    return Err(CoreError::conflict(format!("“{taken}” already exists")));
                }
                projects::discard_replaced(root, &taken)?;
            }
            projects::write_creating(&abs, bytes)
        })?;
        Ok(rel)
    }

    /// The compiled PDF's location; it may not exist yet.
    pub fn pdf_path(&self, id: &str) -> Result<PathBuf, CoreError> {
        settings::compiled_pdf_path(&self.project_root(id)?)
    }

    /// A project file's location, through the path boundary.
    pub fn raw_path(&self, id: &str, rel: &str) -> Result<PathBuf, CoreError> {
        paths::safe_path(&self.project_root(id)?, rel)
    }

    // ---------- compile ----------

    pub async fn compile(
        &self,
        id: &str,
        overrides: &CompileOverrides,
    ) -> Result<CompileResult, CoreError> {
        self.compile
            .compile(
                &self.project_root(id)?,
                overrides,
                self.tex_dir().as_deref(),
            )
            .await
    }

    // ---------- dispatch ----------

    /// Shared JSON command table for browser and native hosts. Raw bytes and
    /// host-chosen absolute paths stay in direct methods outside this table.
    ///
    /// Browser TeX-folder picking needs absolute paths in `set_tex_dir` and
    /// `list_dirs`. Its server binds 127.0.0.1 with token and Host/Origin checks;
    /// `list_dirs` returns names only, and compiling already permits choosing TeX.
    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let s = |key: &str| string_arg(args, key);
        let root = || self.project_root(s("id")?);
        match command {
            "status" => out(self.status().await),
            "texpresso_status" => out(self.texpresso.status(
                &root()?,
                arg::<Option<String>>(args, "session")?.as_deref(),
                &self.texpresso_path(),
            )?),
            "texpresso_pdf" => out(self.texpresso.pdf_state(&root()?, s("session")?)?),
            "texpresso_start" => out(self
                .texpresso
                .start(
                    &root()?,
                    &arg::<Option<Vec<crate::texpresso::FileBuffer>>>(args, "files")?
                        .unwrap_or_default(),
                    arg::<Option<String>>(args, "session")?.as_deref(),
                    &self.texpresso_path(),
                    // The Mac app shows the document in its PDF pane.
                    arg::<Option<bool>>(args, "pdf")?.unwrap_or(false),
                )
                .await?),
            "texpresso_update" => out(self
                .texpresso
                .update(
                    &root()?,
                    s("path")?,
                    s("text")?,
                    s("session")?,
                    &self.texpresso_path(),
                )
                .await?),
            "texpresso_stop" => {
                let token = if arg::<Option<bool>>(args, "global")?.unwrap_or(false) {
                    None
                } else {
                    Some(s("session")?)
                };
                out(self
                    .texpresso
                    .stop_request(&root()?, token, &self.texpresso_path())
                    .await?)
            }
            "texpresso_rescan" => out(self
                .texpresso
                .rescan(&root()?, s("session")?, &self.texpresso_path())
                .await?),
            "set_texpresso_dir" => out(self
                .set_texpresso_dir(arg::<Option<String>>(args, "dir")?.as_deref())
                .await?),
            "set_tex_dir" => out(self
                .set_tex_dir(arg::<Option<String>>(args, "dir")?.as_deref())
                .await?),
            "list_dirs" => out(self.list_dirs(arg::<Option<String>>(args, "path")?.as_deref())?),
            "list_projects" => out(projects::list_projects(&self.data_dir)?),
            "create_project" => out(projects::create_project(
                &self.data_dir,
                s("name")?,
                arg::<Option<String>>(args, "template")?
                    .as_deref()
                    .unwrap_or("article"),
            )?),
            // A build or live preview left running would go on in the moved
            // folder, and report back from the old path.
            "rename_project" => out(self.with_project(s("id")?, |root| {
                let _library = lock(&self.library);
                self.texpresso.stop(root)?;
                self.compile.stop(root);
                projects::rename_project(&self.data_dir, s("id")?, s("name")?)
            })?),
            "delete_project" => out(self.with_project(s("id")?, |root| {
                self.texpresso.stop(root)?;
                self.compile.stop(root);
                projects::delete_project(&self.data_dir, s("id")?)
            })?),
            "get_settings" => out(settings::read_settings(&root()?)),
            // A rename also rewrites mainFile; serialize read/modify/write.
            "set_settings" => out(self.with_project(s("id")?, |root| {
                let patch: Value = arg(args, "patch")?;
                let previous = settings::read_settings(root).main_file;
                let updated = settings::write_settings(root, &patch)?;
                if updated.main_file != previous {
                    self.texpresso.stop(root)?;
                }
                Ok(updated)
            })?),
            "file_tree" => out(projects::file_tree(&root()?)?),
            "scan_symbols" => out(self.scan_symbols(s("id")?)?),
            "analyze_project" => {
                let root = root()?;
                let main = settings::read_settings(&root).main_file;
                out(analyze::analyze_project(&root, &main, s("file")?))
            }
            "search_project" => out(projects::search_project(
                &root()?,
                s("query")?,
                SEARCH_LIMIT,
            )?),
            // Already a Value: out() would serialize it again, copying the
            // whole document.
            "read_file" => {
                let bytes = fs::read(paths::safe_path(&root()?, s("path")?)?)?;
                Ok(json!({ "text": crate::lossy_string(bytes) }))
            }
            // `text` is required: a call that lost it must fail, not empty
            // the file.
            "write_file" => {
                let (path, text) = (s("path")?, s("text")?);
                out(self.with_project(s("id")?, |root| {
                    let abs = paths::safe_write_path(root, path)?;
                    projects::write_creating(&abs, text.as_bytes())
                })?)
            }
            "create_entry" => {
                let (path, dir) = (s("path")?, arg::<Option<bool>>(args, "dir")?);
                out(self.with_project(s("id")?, |root| {
                    projects::create_file(root, path, dir.unwrap_or(false))
                })?)
            }
            "rename_entry" => {
                let (from, to) = (s("from")?, s("to")?);
                out(self.with_project(s("id")?, |root| {
                    let result = projects::rename_entry(root, from, to)?;
                    self.texpresso.stop(root)?;
                    Ok(result)
                })?)
            }
            "delete_entry" => {
                let path = s("path")?;
                out(self.with_project(s("id")?, |root| {
                    projects::delete_entry(root, path)?;
                    self.texpresso.stop(root)?;
                    Ok(())
                })?)
            }
            "validate_uploads" => out(self.validate_uploads(
                s("id")?,
                &arg::<Option<String>>(args, "dir")?.unwrap_or_default(),
                &arg::<Vec<UploadSpec>>(args, "files")?,
            )?),
            "compile" => out(self
                .compile(
                    s("id")?,
                    &arg::<Option<CompileOverrides>>(args, "options")?.unwrap_or_default(),
                )
                .await?),
            // Reports whether a build was running.
            "stop_compile" => out(self.compile.stop(&root()?)),
            "synctex_forward" => out(synctex::synctex_forward_at(
                &root()?,
                s("file")?,
                arg(args, "line")?,
                arg(args, "column")?,
                self.live_pdf(&root()?, args)?.as_deref(),
                &self.tex_path(),
            )
            .await?),
            "synctex_inverse" => out(synctex::synctex_inverse_with_context(
                &root()?,
                arg(args, "page")?,
                arg(args, "x")?,
                arg(args, "y")?,
                arg::<Option<String>>(args, "word")?.as_deref(),
                arg(args, "offset")?,
                arg::<Option<String>>(args, "context")?.as_deref(),
                arg(args, "contextOffset")?,
                self.live_pdf(&root()?, args)?.as_deref(),
                &self.tex_path(),
            )
            .await?),
            _ => Err(CoreError::not_found(format!("Unknown command: {command}"))),
        }
    }
}

/// Argument `key` of a JSON command, which a missing key reads as null.
pub fn arg<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T, CoreError> {
    // Straight from the borrowed Value, with no intermediate clone of it.
    T::deserialize(args.get(key).unwrap_or(&Value::Null))
        .map_err(|err| CoreError::bad_request(format!("Invalid argument `{key}`: {err}")))
}

/// Borrow a required string while keeping the typed argument errors.
pub fn string_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, CoreError> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| arg::<String>(args, key).unwrap_err())
}

fn out<T: Serialize>(value: T) -> Result<Value, CoreError> {
    serde_json::to_value(value).map_err(|err| CoreError::internal(err.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn service() -> (tempfile::TempDir, Service) {
        let data = tempfile::tempdir().unwrap();
        let service = Service::new(data.path().to_path_buf());
        for name in ["P", "Q"] {
            projects::create_project(data.path(), name, "blank").unwrap();
        }
        (data, service)
    }

    #[tokio::test]
    async fn a_panic_during_an_edit_does_not_stop_later_edits() {
        let (data, service) = service();
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            service.with_project("P", |_| -> Result<(), CoreError> { panic!("a bug") })
        }));
        assert!(panicked.is_err());
        let args = json!({ "id": "P", "path": "main.tex", "text": "saved" });
        service.call("write_file", &args).await.unwrap();
        let saved = fs::read_to_string(data.path().join("P/main.tex")).unwrap();
        assert_eq!(saved, "saved");
    }

    #[test]
    fn an_edit_waits_for_its_own_project_only_even_across_a_rename() {
        let (data, service) = service();
        let held = service.project_lock(identity(&data.path().join("P")).unwrap());
        let guard = lock(&held);
        std::thread::scope(|scope| {
            // Another project's edit goes ahead.
            service
                .with_project("Q", |root| {
                    projects::write_creating(&root.join("q.tex"), b"q")
                })
                .unwrap();
            // This project's waits, under its new name too.
            fs::rename(data.path().join("P"), data.path().join("R")).unwrap();
            let edit = scope.spawn(|| {
                service.with_project("R", |root| {
                    projects::write_creating(&root.join("r.tex"), b"r")
                })
            });
            std::thread::sleep(Duration::from_millis(100));
            assert!(!data.path().join("R/r.tex").exists());
            drop(guard);
            edit.join().unwrap().unwrap();
        });
        assert!(data.path().join("R/r.tex").is_file());
    }
}
