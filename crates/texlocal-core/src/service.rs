//! The commands outside a project session, which every host forwards here, and the lock that
//! takes a project's edits one at a time.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::compile::CompileManager;
use crate::paths::Project;
use crate::projects;
use crate::settings::{self, AppSettings, Engine};
use crate::synctex;
use crate::tex::{self, TexStatus};
use crate::texpresso::{self, Preview};
use crate::{CoreError, import, lock, packages, templates, tinytex, wordmatch, zipexport};

const NO_LATEXMK: &str = "That folder doesn't contain latexmk. Choose the folder with TeX's programs, such as /Library/TeX/texbin.";
const NO_TEXPRESSO: &str =
    "That folder doesn't contain the texpresso program. Choose the folder it's in.";

pub struct Service {
    pub data_dir: PathBuf,
    pub compile: CompileManager,
    pub texpresso: Arc<texpresso::Manager>,
    /// Edits, settings read/modify/write, renames, deletes and the list of opened folders change
    /// one at a time.
    pub(crate) edits: Mutex<()>,
    /// Whether the last look for TeX (`status`) found it: sessions build by themselves only
    /// then, and one waiting builds once it is. None found before the first look.
    pub(crate) tex_found: tokio::sync::watch::Sender<bool>,
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            texpresso: Arc::default(),
            edits: Mutex::default(),
            tex_found: tokio::sync::watch::Sender::new(false),
        }
    }

    /// Stop every compile and live preview, as a host does when it quits.
    /// Compiles run in their own process groups, so nothing else stops them.
    pub fn kill_all(&self) {
        self.compile.kill_all();
        self.texpresso.kill_all();
    }

    pub fn project(&self, id: &str) -> Result<Project, CoreError> {
        Project::find(&self.data_dir, id)
    }

    /// With `live`, the live preview of the client's project session (`session`) syncs, not
    /// the build: its PDF is the one shown.
    fn live_pdf(&self, args: &Value) -> Result<Option<PathBuf>, CoreError> {
        if !arg::<Option<bool>>(args, "live")?.unwrap_or(false) {
            return Ok(None);
        }
        let session = arg::<Option<u64>>(args, "session")?
            .ok_or_else(|| CoreError::bad_request("Live sync needs the project session"))?;
        self.texpresso.live_pdf(session).map(Some)
    }

    /// Finds the project once the lock is held, so a rename or delete that held it first is seen.
    pub(crate) fn with_project<T>(
        &self,
        id: &str,
        use_project: impl FnOnce(&Project) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let _guard = lock(&self.edits);
        use_project(&self.project(id)?)
    }

    async fn status(&self) -> TexStatus {
        let app = AppSettings::read(&self.data_dir);
        let (tex_path, texpresso_path) = tex::tool_paths(&app);
        let shown = |dir: Option<PathBuf>| dir.map(|d| d.to_string_lossy().into_owned());
        let mut found = tex::tex_available(&tex_path).await;
        found.texpresso = shown(texpresso::discover(&texpresso_path));
        found.tex_dir = shown(app.tex_dir);
        found.texpresso_dir = shown(app.texpresso_dir);
        self.tex_found.send_replace(found.available);
        found
    }

    pub(crate) fn tool_paths(&self) -> (String, String) {
        tex::tool_paths(&AppSettings::read(&self.data_dir))
    }

    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let s = |key: &str| string_arg(args, key);
        let project = || self.project(s("id")?);
        let folder = || arg::<Option<String>>(args, "dir");
        // A build or live preview would go on in a folder moved or taken off the list, and
        // report back from the old path.
        let stop = |root: &Path| {
            self.compile.stop(root);
            self.texpresso.stop(root)
        };
        match command {
            "status" => out(self.status().await),
            "set_texpresso_dir" => {
                let dir = folder()?.map(PathBuf::from);
                if let Some(dir) = &dir
                    && tex::program_at(&dir.join("texpresso")).is_none()
                {
                    return Err(CoreError::bad_request(NO_TEXPRESSO));
                }
                AppSettings::update(&self.data_dir, |app| app.texpresso_dir = dir)?;
                out(self.status().await)
            }
            "set_tex_dir" => {
                let no_latexmk = || CoreError::bad_request(NO_LATEXMK);
                let dir =
                    folder()?.map(|dir| tex::tex_bin_dir(Path::new(&dir)).ok_or_else(no_latexmk));
                let dir = dir.transpose()?;
                AppSettings::update(&self.data_dir, |app| app.tex_dir = dir)?;
                out(self.status().await)
            }
            "catalogue" => Ok(json!({
                "templates": templates::TEMPLATES.map(|(id, title)| json!({ "id": id, "title": title })),
                "engines": Engine::ALL.map(|engine| json!({
                    "id": engine,
                    "title": engine.title(),
                    "default": engine == Engine::default(),
                })),
            })),
            "list_projects" => out(projects::list_projects(&self.data_dir)?),
            // The project made is answered, so its `id` is the name it got.
            "create_project" => {
                let template = arg::<Option<String>>(args, "template")?;
                let engine = arg::<Option<String>>(args, "engine")?;
                out(projects::create_project(
                    &self.data_dir,
                    s("name")?,
                    template.as_deref().unwrap_or("article"),
                    engine.as_deref(),
                )?)
            }
            "duplicate_project" => out(import::duplicate_project(self, s("id")?, s("name")?)?),
            "free_project_name" => {
                Ok(json!({ "name": projects::free_project_name(&self.data_dir)? }))
            }
            "rename_project" => {
                let (id, name) = (s("id")?, s("name")?);
                out(self.with_project(id, |_| {
                    projects::rename_project(&self.data_dir, id, name, stop)
                })?)
            }
            "file_tree" => out(projects::file_tree(&project()?)?),
            "create_entry" => {
                let path = s("path")?;
                let dir = arg::<Option<bool>>(args, "dir")?.unwrap_or(false);
                out(self.with_project(s("id")?, |project| {
                    Ok(json!({ "path": projects::create_free(&project.root, path, dir)? }))
                })?)
            }
            "synctex_forward" => out(synctex::synctex_forward_at(
                &project()?,
                s("file")?,
                arg(args, "line")?,
                arg(args, "column")?,
                self.live_pdf(args)?.as_deref(),
                &self.tool_paths().0,
            )
            .await?),
            "synctex_inverse" => {
                let project = project()?;
                let click =
                    arg::<Option<String>>(args, "text")?.zip(arg::<Option<usize>>(args, "at")?);
                out(synctex::synctex_inverse(
                    &project,
                    arg(args, "page")?,
                    arg(args, "x")?,
                    arg(args, "y")?,
                    click.as_ref().map(|(text, at)| (text.as_str(), *at)),
                    self.live_pdf(args)?.as_deref(),
                    &self.tool_paths().0,
                )
                .await?)
            }
            "synctex_match" => out(synctex::match_forward(
                &project()?.root,
                s("file")?,
                arg(args, "line")?,
                arg(args, "column")?,
                &arg::<Vec<wordmatch::PdfPage>>(args, "pages")?,
            )?),
            "locate" => out(projects::locate(&self.data_dir, Path::new(s("path")?))?),
            "pdf_path" => {
                let project = project()?;
                let pdf =
                    settings::read_settings(&project.settings).output(&project.build, "pdf")?;
                Ok(json!(pdf.to_string_lossy()))
            }
            "export_zip" => {
                let project = project()?;
                let added = match arg::<Option<bool>>(args, "forArxiv")? {
                    Some(true) => zipexport::for_arxiv(&project)?,
                    _ => Vec::new(),
                };
                let dest = Path::new(s("dest")?);
                out(zipexport::export_zip(&project.root, dest, &added)?)
            }
            // On quit, while a compile may be in flight, stop the latexmk trees that would outlive the app.
            "kill_all" => {
                self.kill_all();
                Ok(Value::Null)
            }
            "install_package" => Ok(json!({
                "package": packages::install_package(s("file")?, &self.tool_paths().0).await?
            })),
            "install_tex" => {
                tinytex::install(&self.tool_paths().0).await?;
                out(self.status().await)
            }
            "import_files" => out(import::import_files(
                self,
                s("id")?,
                &folder()?.unwrap_or_default(),
                &arg::<Option<Vec<PathBuf>>>(args, "paths")?.unwrap_or_default(),
                arg(args, "conflict")?,
                projects::discard,
            )?),
            "open_path" => out(projects::open_path(self, Path::new(s("path")?))?),
            "forget_folder" => {
                let _edits = lock(&self.edits);
                projects::forget_folder(&self.data_dir, s("id")?, stop)?;
                Ok(Value::Null)
            }
            "set_ui_state" => out(self.with_project(s("id")?, |project| {
                settings::write_ui(&project.ui, &arg(args, "patch")?)
            })?),
            _ => Err(CoreError::not_found(format!("Unknown command: {command}"))),
        }
    }
}

pub(crate) fn arg<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T, CoreError> {
    T::deserialize(args.get(key).unwrap_or(&Value::Null))
        .map_err(|err| CoreError::bad_request(format!("Invalid argument `{key}`: {err}")))
}

pub(crate) fn string_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, CoreError> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| arg::<String>(args, key).unwrap_err())
}

pub(crate) fn out<T: Serialize>(value: T) -> Result<Value, CoreError> {
    serde_json::to_value(value).map_err(|err| CoreError::internal(err.to_string()))
}

#[cfg(test)]
mod tests;
