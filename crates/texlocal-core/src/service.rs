// The command surface every host shares. The desktop shells and the browser
// server are thin adapters over `Service`: a command's behaviour — which path
// check it runs, which cache it invalidates — lives here once, not per host.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::analyze;
use crate::compile::{self, CompileManager, CompileOverrides, CompileResult, TexStatus};
use crate::paths::fold_case;
use crate::projects::{self, FileStamp, Symbols};
use crate::settings;
use crate::synctex;
use crate::{atomic, paths, CoreError};

pub const UPLOAD_MAX_BYTES: usize = 100 * 1024 * 1024;
const TEX_MISSING_TTL: Duration = Duration::from_secs(5);
const SEARCH_LIMIT: usize = 100;
/// App-wide settings, beside the projects: every host shares the data dir, so
/// every host sees one TeX folder. A file, not a folder, so no project list
/// shows it.
pub const APP_SETTINGS_FILE: &str = ".texlocal-app.json";
const NO_LATEXMK: &str = if cfg!(windows) {
    r"That folder doesn't contain latexmk. Choose the folder with TeX's programs, such as C:\texlive\2026\bin\windows."
} else {
    "That folder doesn't contain latexmk. Choose the folder with TeX's programs, such as /Library/TeX/texbin."
};

/// One folder of the TeX folder browser: its subfolders' names, never file
/// contents.
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

/// An entry an upload would land on: an incoming file's own place, or a
/// folder on its path that is a file here. Both paths are relative to the
/// upload's folder, as the host names the files; `keep_both` is a free name
/// beside it.
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
    let path = path.replace('\\', "/");
    clashes
        .iter()
        .find_map(|c| {
            let rest = path.strip_prefix(&c.path)?;
            (rest.is_empty() || rest.starts_with('/')).then(|| format!("{}{rest}", c.keep_both))
        })
        .unwrap_or(path)
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
    /// The last TeX probe and when it ran.
    status: Mutex<Option<(TexStatus, Instant)>>,
    symbols: Mutex<HashMap<PathBuf, (Vec<FileStamp>, Symbols)>>,
}

fn upload_rel(dir: &str, name: &str) -> String {
    let name = name.replace('\\', "/");
    if dir.is_empty() {
        name
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

/// Dot-folders, and on Windows the protected system folders Explorer hides
/// ($Recycle.Bin, System Volume Information). Merely hidden ones such as
/// AppData stay: a per-user TeX install lives there.
fn hidden(entry: &std::fs::DirEntry) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const HIDDEN_SYSTEM: u32 = 0x2 | 0x4;
        if entry
            .metadata()
            .is_ok_and(|m| m.file_attributes() & HIDDEN_SYSTEM == HIDDEN_SYSTEM)
        {
            return true;
        }
    }
    entry.file_name().to_string_lossy().starts_with('.')
}

fn roots() -> Vec<String> {
    if cfg!(windows) {
        (b'A'..=b'Z')
            .map(|drive| format!(r"{}:\", drive as char))
            .filter(|root| Path::new(root).is_dir())
            .collect()
    } else {
        vec!["/".into()]
    }
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            status: Mutex::new(None),
            symbols: Mutex::new(HashMap::new()),
        }
    }

    pub fn project_root(&self, id: &str) -> Result<PathBuf, CoreError> {
        paths::project_root(&self.data_dir, id)
    }

    fn forget_project(&self, root: &Path) {
        self.symbols.lock().unwrap().remove(root);
    }

    /// Run `edit` on a project's folder, then drop its cached symbols.
    fn edit<T>(
        &self,
        id: &str,
        edit: impl FnOnce(&Path) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let root = self.project_root(id)?;
        let result = edit(&root)?;
        self.forget_project(&root);
        Ok(result)
    }

    // ---------- status ----------

    /// A found TeX is cached until the chosen TeX folder changes; a missing
    /// one only briefly, so the UI's install poll notices a new install.
    pub async fn status(&self) -> TexStatus {
        let tex_dir = self.tex_dir();
        let chosen = tex_dir.as_ref().map(|d| d.to_string_lossy().into_owned());
        if let Some((status, at)) = &*self.status.lock().unwrap() {
            if status.tex_dir == chosen && (status.available || at.elapsed() < TEX_MISSING_TTL) {
                return status.clone();
            }
        }
        let mut found = compile::tex_available(&compile::tex_path(tex_dir.as_deref())).await;
        found.tex_dir = chosen;
        *self.status.lock().unwrap() = Some((found.clone(), Instant::now()));
        found
    }

    // ---------- TeX folder ----------

    /// The TeX programs folder the user chose, or None to find TeX
    /// automatically. Read per use, so a choice made in another host applies.
    pub fn tex_dir(&self) -> Option<PathBuf> {
        let bytes = std::fs::read(self.data_dir.join(APP_SETTINGS_FILE)).ok()?;
        let value: Value = serde_json::from_slice(&bytes).ok()?;
        let dir = value.get("texDir")?.as_str()?;
        (!dir.is_empty()).then(|| PathBuf::from(dir))
    }

    fn tex_path(&self) -> String {
        compile::tex_path(self.tex_dir().as_deref())
    }

    /// Choose the TeX folder; None or empty goes back to automatic. A TeX Live
    /// or MiKTeX root is accepted and saved as its bin folder.
    pub async fn set_tex_dir(&self, dir: Option<&str>) -> Result<TexStatus, CoreError> {
        let chosen = match dir.map(str::trim).filter(|d| !d.is_empty()) {
            None => None,
            Some(dir) => {
                let dir = Path::new(dir);
                let bin = dir.is_absolute().then(|| compile::tex_bin_dir(dir));
                Some(
                    bin.flatten()
                        .ok_or_else(|| CoreError::bad_request(NO_LATEXMK))?,
                )
            }
        };
        let text = json!({ "texDir": chosen.map(|d| d.to_string_lossy().into_owned()) });
        atomic::write(
            &self.data_dir.join(APP_SETTINGS_FILE),
            text.to_string().as_bytes(),
        )?;
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
            .filter(|e| !hidden(e) && e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        dirs.sort_by_key(|name| name.to_lowercase());
        Ok(DirListing {
            path: dir.to_string_lossy().into_owned(),
            parent: dir.parent().map(|p| p.to_string_lossy().into_owned()),
            dirs,
            has_latexmk: compile::has_latexmk(&dir),
            roots: roots(),
        })
    }

    // ---------- files ----------

    pub fn scan_symbols(&self, id: &str) -> Result<Symbols, CoreError> {
        let root = self.project_root(id)?;
        let stamps = projects::symbols_fingerprint(&root)?;
        if let Some((cached_stamps, symbols)) = self.symbols.lock().unwrap().get(&root) {
            if *cached_stamps == stamps {
                return Ok(symbols.clone());
            }
        }
        let symbols = projects::scan_symbols(&root)?;
        self.symbols
            .lock()
            .unwrap()
            .insert(root, (stamps, symbols.clone()));
        Ok(symbols)
    }

    /// Validate a complete upload before the first write, so a late unsafe path
    /// or oversize file cannot produce a predictable half-import. Returns the
    /// entries the upload would land on, for the host to ask about as Finder
    /// does: Replace (upload with `replace`), Keep Both (rename the files
    /// under each clash's `path` to its `keepBoth`, as `keep_both` does) or
    /// Stop.
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

    /// One file of an upload the host has already passed to
    /// `validate_uploads`. Returns the project-relative path written. An
    /// entry in its place is an error, unless `replace` moves it to the
    /// Trash first.
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
        self.edit(id, |root| {
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

    /// Run a command by name with JSON arguments — the one table a host that
    /// speaks JSON (the browser server, the native FFI) forwards to.
    ///
    /// Only commands whose paths pass through the project boundary belong
    /// here. Anything that takes a host-chosen absolute path (export
    /// destinations) or raw bytes (uploads) is a direct method instead, so a
    /// remote caller cannot reach it by name.
    ///
    /// The exception is the TeX folder: `set_tex_dir` and `list_dirs` take an
    /// absolute path by name, because a browser page has no native folder
    /// picker. That grants nothing new. The browser server listens on
    /// 127.0.0.1 only, behind its token header and Host/Origin checks, and a
    /// caller that can compile can already run code as this user, so choosing
    /// which latexmk runs adds no power; `list_dirs` returns folder names, never
    /// file contents.
    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let s = |key: &str| arg::<String>(args, key);
        let root = || self.project_root(&s("id")?);
        match command {
            "status" => out(self.status().await),
            "set_tex_dir" => out(self
                .set_tex_dir(arg::<Option<String>>(args, "dir")?.as_deref())
                .await?),
            "list_dirs" => out(self.list_dirs(arg::<Option<String>>(args, "path")?.as_deref())?),
            "list_projects" => out(projects::list_projects(&self.data_dir)?),
            "create_project" => out(projects::create_project(
                &self.data_dir,
                &s("name")?,
                arg::<Option<String>>(args, "template")?
                    .as_deref()
                    .unwrap_or("article"),
            )?),
            "rename_project" => {
                let old = root()?;
                let info = projects::rename_project(&self.data_dir, &s("id")?, &s("name")?)?;
                self.forget_project(&old);
                out(info)
            }
            "delete_project" => {
                let old = root()?;
                projects::delete_project(&self.data_dir, &s("id")?)?;
                self.forget_project(&old);
                out(())
            }
            "get_settings" => out(settings::read_settings(&root()?)),
            "set_settings" => out(settings::write_settings(&root()?, &arg(args, "patch")?)?),
            "file_tree" => out(projects::file_tree(&root()?)?),
            "scan_symbols" => out(self.scan_symbols(&s("id")?)?),
            "analyze_project" => {
                let root = root()?;
                let main = settings::read_settings(&root).main_file;
                out(analyze::analyze_project(&root, &main, &s("file")?))
            }
            "search_project" => out(projects::search_project(
                &root()?,
                &s("query")?,
                SEARCH_LIMIT,
            )?),
            // Already a Value: out() would serialize it again, copying the
            // whole document.
            "read_file" => {
                let bytes = fs::read(paths::safe_path(&root()?, &s("path")?)?)?;
                Ok(json!({ "text": crate::lossy_string(bytes) }))
            }
            // `text` is required: a call that lost it must fail, not empty
            // the file.
            "write_file" => {
                let (path, text) = (s("path")?, s("text")?);
                out(self.edit(&s("id")?, |root| {
                    projects::write_creating(&paths::safe_write_path(root, &path)?, text.as_bytes())
                })?)
            }
            "create_entry" => {
                let (path, dir) = (s("path")?, arg::<Option<bool>>(args, "dir")?);
                out(self.edit(&s("id")?, |root| {
                    projects::create_file(root, &path, dir.unwrap_or(false))
                })?)
            }
            "rename_entry" => {
                let (from, to) = (s("from")?, s("to")?);
                out(self.edit(&s("id")?, |root| projects::rename_entry(root, &from, &to))?)
            }
            "delete_entry" => {
                let path = s("path")?;
                out(self.edit(&s("id")?, |root| projects::delete_entry(root, &path))?)
            }
            "validate_uploads" => out(self.validate_uploads(
                &s("id")?,
                &arg::<Option<String>>(args, "dir")?.unwrap_or_default(),
                &arg::<Vec<UploadSpec>>(args, "files")?,
            )?),
            "compile" => out(self
                .compile(
                    &s("id")?,
                    &arg::<Option<CompileOverrides>>(args, "options")?.unwrap_or_default(),
                )
                .await?),
            // The project's own build, which reports itself stopped; true
            // when one was running.
            "stop_compile" => out(self.compile.stop(&root()?).await),
            "synctex_forward" => out(synctex::synctex_forward(
                &root()?,
                &s("file")?,
                arg(args, "line")?,
                &self.tex_path(),
            )
            .await?),
            "synctex_inverse" => out(synctex::synctex_inverse(
                &root()?,
                arg(args, "page")?,
                arg(args, "x")?,
                arg(args, "y")?,
                arg::<Option<String>>(args, "word")?.as_deref(),
                arg(args, "offset")?,
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

fn out<T: Serialize>(value: T) -> Result<Value, CoreError> {
    serde_json::to_value(value).map_err(|err| CoreError::internal(err.to_string()))
}
