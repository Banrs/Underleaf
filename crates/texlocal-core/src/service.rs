// The command surface every host shares. The desktop shells and the browser
// server are thin adapters over `Service`: a command's behaviour — which path
// check it runs, which cache it invalidates — lives here once, not per host.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::compile::{self, CompileManager, CompileOverrides, CompileResult, TexStatus};
use crate::projects::{self, FileStamp, ProjectInfo, RenameResult, SearchHit, Symbols, TreeNode};
use crate::settings::{self, Settings};
use crate::synctex::{self, ForwardLoc, InverseLoc};
use crate::{paths, CoreError};

pub const UPLOAD_MAX_BYTES: usize = 100 * 1024 * 1024;
const TEX_MISSING_TTL: Duration = Duration::from_secs(5);
const SEARCH_LIMIT: usize = 100;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadSpec {
    pub path: String,
    pub size: usize,
}

#[derive(Default)]
struct StatusCache {
    available: Option<TexStatus>,
    checked_at: Option<Instant>,
}

pub struct Service {
    pub data_dir: PathBuf,
    pub compile: CompileManager,
    status: Mutex<StatusCache>,
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

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::new(),
            status: Mutex::new(StatusCache::default()),
            symbols: Mutex::new(HashMap::new()),
        }
    }

    pub fn project_root(&self, id: &str) -> Result<PathBuf, CoreError> {
        paths::project_root(&self.data_dir, id)
    }

    fn forget_project(&self, root: &Path) {
        self.symbols.lock().unwrap().remove(root);
    }

    // ---------- status ----------

    /// A found TeX is cached for the process lifetime; a missing one only
    /// briefly, so the UI's install poll notices a new install.
    pub async fn status(&self) -> TexStatus {
        {
            let cache = self.status.lock().unwrap();
            if let Some(status) = &cache.available {
                let fresh = cache
                    .checked_at
                    .is_some_and(|at| at.elapsed() < TEX_MISSING_TTL);
                if status.available || fresh {
                    return status.clone();
                }
            }
        }
        let found = compile::tex_available(None).await;
        let mut cache = self.status.lock().unwrap();
        cache.available = Some(found.clone());
        cache.checked_at = Some(Instant::now());
        found
    }

    // ---------- projects ----------

    pub fn list_projects(&self) -> Result<Vec<ProjectInfo>, CoreError> {
        projects::list_projects(&self.data_dir)
    }

    pub fn create_project(
        &self,
        name: &str,
        template: Option<&str>,
    ) -> Result<ProjectInfo, CoreError> {
        projects::create_project(&self.data_dir, name, template.unwrap_or("article"))
    }

    pub fn rename_project(&self, id: &str, name: &str) -> Result<ProjectInfo, CoreError> {
        let old = self.project_root(id)?;
        let info = projects::rename_project(&self.data_dir, id, name)?;
        self.forget_project(&old);
        Ok(info)
    }

    pub fn delete_project(&self, id: &str) -> Result<(), CoreError> {
        let old = self.project_root(id)?;
        projects::delete_project(&self.data_dir, id)?;
        self.forget_project(&old);
        Ok(())
    }

    // ---------- settings ----------

    pub fn get_settings(&self, id: &str) -> Result<Settings, CoreError> {
        Ok(settings::read_settings(&self.project_root(id)?))
    }

    pub fn set_settings(&self, id: &str, patch: &Value) -> Result<Settings, CoreError> {
        settings::write_settings(&self.project_root(id)?, patch)
    }

    // ---------- files ----------

    pub fn file_tree(&self, id: &str) -> Result<Vec<TreeNode>, CoreError> {
        projects::file_tree(&self.project_root(id)?)
    }

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

    pub fn search_project(&self, id: &str, query: &str) -> Result<Vec<SearchHit>, CoreError> {
        projects::search_project(&self.project_root(id)?, query, SEARCH_LIMIT)
    }

    pub fn read_file(&self, id: &str, path: &str) -> Result<String, CoreError> {
        let bytes = std::fs::read(paths::safe_path(&self.project_root(id)?, path)?)?;
        // Valid UTF-8, the usual case, becomes the String without a second copy.
        Ok(String::from_utf8(bytes)
            .unwrap_or_else(|err| String::from_utf8_lossy(err.as_bytes()).into_owned()))
    }

    pub fn write_file(&self, id: &str, path: &str, text: &str) -> Result<(), CoreError> {
        let root = self.project_root(id)?;
        let abs = paths::safe_path(&root, path)?;
        if let Some(parent) = abs.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(abs, text)?;
        self.forget_project(&root);
        Ok(())
    }

    pub fn create_entry(&self, id: &str, path: &str, dir: bool) -> Result<(), CoreError> {
        let root = self.project_root(id)?;
        projects::create_file(&root, path, dir)?;
        self.forget_project(&root);
        Ok(())
    }

    pub fn rename_entry(&self, id: &str, from: &str, to: &str) -> Result<RenameResult, CoreError> {
        let root = self.project_root(id)?;
        let result = projects::rename_entry(&root, from, to)?;
        self.forget_project(&root);
        Ok(result)
    }

    pub fn delete_entry(&self, id: &str, path: &str) -> Result<(), CoreError> {
        let root = self.project_root(id)?;
        projects::delete_entry(&root, path)?;
        self.forget_project(&root);
        Ok(())
    }

    /// Validate a complete upload before the first write, so a late unsafe path
    /// or oversize file cannot produce a predictable half-import.
    pub fn validate_uploads(
        &self,
        id: &str,
        dir: &str,
        files: &[UploadSpec],
    ) -> Result<(), CoreError> {
        let root = self.project_root(id)?;
        let mut seen = HashSet::new();
        for file in files {
            if file.size > UPLOAD_MAX_BYTES {
                return Err(too_large());
            }
            let abs = paths::safe_path(&root, &upload_rel(dir, &file.path))?;
            let key = if cfg!(any(windows, target_os = "macos")) {
                abs.to_string_lossy().to_ascii_lowercase()
            } else {
                abs.to_string_lossy().into_owned()
            };
            if !seen.insert(key) {
                return Err(CoreError::bad_request(
                    "The upload contains duplicate paths",
                ));
            }
        }
        Ok(())
    }

    /// One file of an upload the host has already passed to
    /// `validate_uploads`. Returns the project-relative path written.
    pub fn upload_file(
        &self,
        id: &str,
        dir: &str,
        path: &str,
        bytes: &[u8],
    ) -> Result<String, CoreError> {
        if bytes.len() > UPLOAD_MAX_BYTES {
            return Err(too_large());
        }
        let root = self.project_root(id)?;
        let rel = upload_rel(dir, path);
        let abs = paths::safe_path(&root, &rel)?;
        if let Some(parent) = abs.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(abs, bytes)?;
        self.forget_project(&root);
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

    // ---------- compile / synctex ----------

    pub async fn compile(
        &self,
        id: &str,
        overrides: &CompileOverrides,
    ) -> Result<CompileResult, CoreError> {
        self.compile
            .compile(&self.project_root(id)?, overrides)
            .await
    }

    pub async fn synctex_forward(
        &self,
        id: &str,
        file: &str,
        line: u32,
    ) -> Result<ForwardLoc, CoreError> {
        synctex::synctex_forward(&self.project_root(id)?, file, line, compile::tex_path()).await
    }

    pub async fn synctex_inverse(
        &self,
        id: &str,
        page: f64,
        x: f64,
        y: f64,
    ) -> Result<InverseLoc, CoreError> {
        synctex::synctex_inverse(&self.project_root(id)?, page, x, y, compile::tex_path()).await
    }

    // ---------- dispatch ----------

    /// Run a command by name with JSON arguments — the one table a host that
    /// speaks JSON (the browser server, the native FFI) forwards to. Names and
    /// argument keys match the desktop commands, so one frontend API table
    /// serves every host.
    ///
    /// Only commands whose paths pass through the project boundary belong
    /// here. Anything that takes a host-chosen absolute path (export
    /// destinations) or raw bytes (uploads) is a direct method instead, so a
    /// remote caller cannot reach it by name.
    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let s = |key: &str| arg::<String>(args, key);
        match command {
            "status" => out(self.status().await),
            "list_projects" => out(self.list_projects()?),
            "create_project" => out(self.create_project(
                &s("name")?,
                arg::<Option<String>>(args, "template")?.as_deref(),
            )?),
            "rename_project" => out(self.rename_project(&s("id")?, &s("name")?)?),
            "delete_project" => out(self.delete_project(&s("id")?)?),
            "get_settings" => out(self.get_settings(&s("id")?)?),
            "set_settings" => out(self.set_settings(&s("id")?, &arg::<Value>(args, "patch")?)?),
            "file_tree" => out(self.file_tree(&s("id")?)?),
            "scan_symbols" => out(self.scan_symbols(&s("id")?)?),
            "search_project" => out(self.search_project(&s("id")?, &s("query")?)?),
            "read_file" => out(json!({ "text": self.read_file(&s("id")?, &s("path")?)? })),
            "write_file" => out(self.write_file(
                &s("id")?,
                &s("path")?,
                &arg::<Option<String>>(args, "text")?.unwrap_or_default(),
            )?),
            "create_entry" => out(self.create_entry(
                &s("id")?,
                &s("path")?,
                arg::<Option<bool>>(args, "dir")?.unwrap_or(false),
            )?),
            "rename_entry" => out(self.rename_entry(&s("id")?, &s("from")?, &s("to")?)?),
            "delete_entry" => out(self.delete_entry(&s("id")?, &s("path")?)?),
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
            "synctex_forward" => out(self
                .synctex_forward(&s("id")?, &s("file")?, arg(args, "line")?)
                .await?),
            "synctex_inverse" => out(self
                .synctex_inverse(
                    &s("id")?,
                    arg(args, "page")?,
                    arg(args, "x")?,
                    arg(args, "y")?,
                )
                .await?),
            _ => Err(CoreError::not_found(format!("Unknown command: {command}"))),
        }
    }
}

fn arg<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T, CoreError> {
    serde_json::from_value(args.get(key).cloned().unwrap_or(Value::Null))
        .map_err(|err| CoreError::bad_request(format!("Invalid argument `{key}`: {err}")))
}

fn out<T: Serialize>(value: T) -> Result<Value, CoreError> {
    serde_json::to_value(value).map_err(|err| CoreError::internal(err.to_string()))
}
