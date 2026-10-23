//! The commands outside a project session, which every host forwards here, and the lock that
//! takes a project's edits one at a time.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::compile::CompileManager;
use crate::import::Conflict;
use crate::paths::Project;
use crate::projects::{self, History};
use crate::settings::{self, AppSettings, Engine};
use crate::synctex;
use crate::tex::{self, TexStatus};
use crate::texpresso::{self, Preview};
use crate::wordmatch::PdfPage;
use crate::{CoreError, import, inprocess, lock, templates, tinytex, zipexport};

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
    /// One for each store, so two sessions of a project take turns with it: one's pruning would
    /// remove what the other has stored for a snapshot not yet written.
    histories: Mutex<HashMap<PathBuf, Arc<Mutex<History>>>>,
}

/// The commands outside a session, by the name a host sends (docs/core-api.md), with their
/// arguments.
#[derive(Deserialize)]
#[serde(
    tag = "call",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
enum Command {
    Status,
    SetTexpressoDir {
        dir: Option<PathBuf>,
    },
    SetTexDir {
        dir: Option<PathBuf>,
    },
    Catalogue,
    ListProjects,
    CreateProject {
        name: String,
        template: Option<String>,
        engine: Option<String>,
    },
    DuplicateProject {
        id: String,
        name: String,
    },
    FreeProjectName,
    RenameProject {
        id: String,
        name: String,
    },
    FileTree {
        id: String,
    },
    CreateEntry {
        id: String,
        path: String,
        #[serde(default)]
        dir: bool,
    },
    SynctexForward {
        id: String,
        file: String,
        line: u32,
        #[serde(flatten)]
        live: Live,
    },
    SynctexInverse {
        id: String,
        page: f64,
        x: f64,
        y: f64,
        text: Option<String>,
        at: Option<usize>,
        #[serde(flatten)]
        live: Live,
    },
    SynctexMatch {
        id: String,
        file: String,
        line: u32,
        column: usize,
        pages: Vec<PdfPage>,
    },
    Locate {
        path: PathBuf,
    },
    PdfPath {
        id: String,
    },
    ExportZip {
        id: String,
        dest: PathBuf,
        #[serde(default)]
        for_arxiv: bool,
    },
    KillAll,
    InstallTex,
    ImportFiles {
        id: String,
        #[serde(default)]
        dir: String,
        #[serde(default)]
        paths: Vec<PathBuf>,
        conflict: Option<Conflict>,
    },
    OpenPath {
        path: PathBuf,
    },
    ForgetFolder {
        id: String,
    },
    SetUiState {
        id: String,
        patch: Value,
    },
    #[serde(other)]
    Unknown,
}

/// With `live`, the live preview of the host's project session (`session`) syncs, not the build.
#[derive(Deserialize)]
struct Live {
    #[serde(default)]
    live: bool,
    session: Option<u64>,
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            texpresso: Arc::default(),
            edits: Mutex::default(),
            tex_found: tokio::sync::watch::Sender::new(false),
            histories: Mutex::default(),
        }
    }

    pub(crate) fn history(&self, project: &Project) -> Arc<Mutex<History>> {
        let mut histories = lock(&self.histories);
        let history = histories.entry(project.history.clone());
        Arc::clone(history.or_insert_with(|| Arc::new(Mutex::new(History::of(project)))))
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

    /// The live session's number and its PDF, the one shown, when the live preview syncs.
    fn live(&self, live: Live) -> Result<Option<(u64, PathBuf)>, CoreError> {
        if !live.live {
            return Ok(None);
        }
        let session = live
            .session
            .ok_or_else(|| CoreError::bad_request("Live sync needs the project session"))?;
        Ok(Some((session, self.texpresso.live_pdf(session)?)))
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
        if inprocess::IN_PROCESS {
            let found = inprocess::status();
            self.tex_found.send_replace(found.available);
            return found;
        }
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

    pub async fn call(&self, name: &str, args: Value) -> Result<Value, CoreError> {
        // A build or live preview would go on in a folder moved or taken off the list, and
        // report back from the old path.
        let stop = |root: &Path| {
            self.compile.stop(root);
            self.texpresso.stop(root)
        };
        match parse(name, args)? {
            Command::Status => out(self.status().await),
            Command::SetTexpressoDir { dir } => {
                let texpresso = dir
                    .as_ref()
                    .map(|dir| tex::program_at(&dir.join("texpresso")));
                if texpresso.is_some_and(|found| found.is_none()) {
                    return Err(CoreError::bad_request(NO_TEXPRESSO));
                }
                AppSettings::update(&self.data_dir, |app| app.texpresso_dir = dir)?;
                out(self.status().await)
            }
            Command::SetTexDir { dir } => {
                let bin = dir.map(|dir| tex::tex_bin_dir(&dir).ok_or(()));
                let bin = bin
                    .transpose()
                    .map_err(|()| CoreError::bad_request(NO_LATEXMK))?;
                AppSettings::update(&self.data_dir, |app| app.tex_dir = bin)?;
                out(self.status().await)
            }
            Command::Catalogue => Ok(json!({
                "templates": templates::TEMPLATES.map(|(id, title)| json!({ "id": id, "title": title })),
                "engines": Engine::ALL.map(|engine| json!({
                    "id": engine,
                    "title": engine.title(),
                    "default": engine == Engine::default(),
                })),
            })),
            Command::ListProjects => projects::list_projects(&self.data_dir).and_then(out),
            // The project made is answered, so its `id` is the name it got.
            Command::CreateProject {
                name,
                template,
                engine,
            } => {
                let template = template.as_deref().unwrap_or("article");
                projects::create_project(&self.data_dir, &name, template, engine.as_deref())
                    .and_then(out)
            }
            Command::DuplicateProject { id, name } => {
                import::duplicate_project(self, &id, &name).and_then(out)
            }
            Command::FreeProjectName => {
                Ok(json!({ "name": projects::free_project_name(&self.data_dir)? }))
            }
            Command::RenameProject { id, name } => self
                .with_project(&id, |_| {
                    projects::rename_project(&self.data_dir, &id, &name, stop)
                })
                .and_then(out),
            Command::FileTree { id } => projects::file_tree(&self.project(&id)?).and_then(out),
            Command::CreateEntry { id, path, dir } => self.with_project(&id, |project| {
                Ok(json!({ "path": projects::create_free(&project.root, &path, dir)? }))
            }),
            Command::SynctexForward {
                id,
                file,
                line,
                live,
            } => {
                let pdf = self.live(live)?.map(|(_, pdf)| pdf);
                synctex::synctex_forward_at(&self.project(&id)?, &file, line, pdf.as_deref())
                    .and_then(out)
            }
            Command::SynctexInverse {
                id,
                page,
                x,
                y,
                text,
                at,
                live,
            } => {
                let live = self.live(live)?;
                let typeset = |rel: &str| self.texpresso.live_text(live.as_ref()?.0, rel);
                let pdf = live.as_ref().map(|(_, pdf)| pdf.as_path());
                let click = text.as_deref().zip(at);
                let project = self.project(&id)?;
                synctex::synctex_inverse(&project, page, x, y, click, pdf, &typeset).and_then(out)
            }
            Command::SynctexMatch {
                id,
                file,
                line,
                column,
                pages,
            } => synctex::match_forward(&self.project(&id)?.root, &file, line, column, &pages)
                .and_then(out),
            Command::Locate { path } => projects::locate(&self.data_dir, &path).and_then(out),
            Command::PdfPath { id } => {
                let project = self.project(&id)?;
                let pdf = settings::read_settings(&project.settings).output(&project.build, "pdf");
                Ok(json!(pdf?.to_string_lossy()))
            }
            Command::ExportZip {
                id,
                dest,
                for_arxiv,
            } => {
                let project = self.project(&id)?;
                let added = match for_arxiv {
                    true => zipexport::for_arxiv(&project)?,
                    false => Vec::new(),
                };
                zipexport::export_zip(&project.root, &dest, &added).and_then(out)
            }
            // On quit, while a compile may be in flight, stop the latexmk trees that would outlive the app.
            Command::KillAll => {
                self.kill_all();
                Ok(Value::Null)
            }
            Command::InstallTex if inprocess::IN_PROCESS => Err(inprocess::no_installs()),
            Command::InstallTex => {
                tinytex::install(&self.tool_paths().0).await?;
                out(self.status().await)
            }
            Command::ImportFiles {
                id,
                dir,
                paths,
                conflict,
            } => import::import_files(self, &id, &dir, &paths, conflict, projects::discard)
                .and_then(out),
            Command::OpenPath { path } => projects::open_path(self, &path).and_then(out),
            Command::ForgetFolder { id } => projects::forget_folder(self, &id, stop).and_then(out),
            Command::SetUiState { id, patch } => self
                .with_project(&id, |project| settings::write_ui(&project.ui, &patch))
                .and_then(out),
            Command::Unknown => Err(unknown()),
        }
    }
}

pub(crate) fn unknown() -> CoreError {
    CoreError::not_found("Unknown command")
}

/// A command's arguments as the type that takes them; with `name` as their `call`, an enum of
/// commands tagged by it reads which it is (`command` is some commands' argument).
pub(crate) fn parse<T: DeserializeOwned>(name: &str, mut args: Value) -> Result<T, CoreError> {
    let object = args
        .as_object_mut()
        .ok_or_else(|| CoreError::bad_request("The arguments aren't a JSON object"))?;
    object.insert("call".into(), name.into());
    T::deserialize(args).map_err(|err| CoreError::bad_request(format!("Invalid arguments: {err}")))
}

/// A command's answer as JSON, which every answer of the core's serializes to.
pub(crate) fn out(value: impl Serialize) -> Result<Value, CoreError> {
    Ok(json!(value))
}

#[cfg(test)]
mod tests;
