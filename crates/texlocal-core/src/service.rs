use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak, mpsc};

use schemars::JsonSchema;
use serde::Serialize;
use serde_json::Value;
use texlocal_latex::message::Message;
use texlocal_latex::templates::ProjectTemplate;
use tokio::sync::oneshot;

use crate::events::{Log, LogLevel, Said, Sent};
use crate::messages;
use crate::paths::{self, Project};
use crate::process::Processes;
use crate::projects::{self, History, Job, Opening, ProjectInfo};
use crate::protocol::requests;
use crate::settings::{AppSettings, Engine};
use crate::tex::{self, TexStatus};
use crate::texpresso;
use crate::{CoreError, import, lock, tinytex};

pub struct Service {
    pub(crate) data_dir: PathBuf,
    pub(crate) state_dir: PathBuf,
    helpers: Option<PathBuf>,
    pub(crate) processes: Arc<Processes>,
    pub(crate) texpresso: Arc<texpresso::Manager>,
    pub(crate) library: Mutex<Vec<(String, PathBuf)>>,
    pub(crate) tex_found: tokio::sync::watch::Sender<bool>,
    tex_queue: Mutex<Option<oneshot::Receiver<()>>>,
    histories: Mutex<HashMap<PathBuf, Weak<mpsc::Sender<Job>>>>,
    pub(crate) hub: OnceLock<mpsc::Sender<Said>>,
    sent: Mutex<Sent<LibrarySection>>,
}

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum LibrarySection {
    Projects(Vec<ProjectInfo>),
    Tex(TexStatus),
}

pub(crate) struct InSession {
    service: Arc<Service>,
    id: String,
}

impl Drop for InSession {
    fn drop(&mut self) {
        let mut open = lock(&self.service.library);
        if let Some(at) = open.iter().position(|(id, _)| *id == self.id) {
            open.swap_remove(at);
        }
    }
}

requests! {
    Library(async service: Service) {
        CheckTex {} -> TexStatus = Ok(service.status().await),
        SetTexpressoDir { dir: Option<PathBuf> } -> TexStatus
            = service.set_bin_dir(dir, "texpresso", messages::no_texpresso_there, |app, bin| app.texpresso_dir = bin).await,
        SetTexDir { dir: Option<PathBuf> } -> TexStatus
            = service.set_bin_dir(dir, "latexmk", messages::no_latexmk, |app, bin| app.tex_dir = bin).await,
        InstallTex {} -> TexStatus = {
            let installed = tinytex::install(&service.processes, &service.tool_paths().0).await;
            let _turn = service.tex_turn().await;
            let status = service.status().await;
            installed.map(|()| status)
        },
        ReloadProjects {} -> () = service.publish_projects(),
        CreateProject { name: String, template: ProjectTemplate, engine: Option<Engine> } -> ProjectInfo
            = service.relisted(projects::create_project(service, &name, template, engine)),
        DuplicateProject { id: String, name: String } -> ProjectInfo
            = service.relisted(import::duplicate_project(service, &id, &name)),
        FreeProjectName {} -> String = projects::free_project_name(&service.data_dir),
        RenameProject { id: String, name: String } -> ProjectInfo = service.relisted(
            service
                .unless_open(&id, messages::close_before_renaming)
                .and_then(|_library| projects::rename_project(service, &id, &name)),
        ),
        TrashProject { id: String } -> PathBuf = service.relisted(
            service
                .unless_open(&id, messages::close_before_trashing)
                .and_then(|_library| projects::trash_project(service, &id)),
        ),
        PutBackProject { id: String, trashed: PathBuf } -> ()
            = service.relisted(projects::put_back_project(service, &id, &trashed)),
        KillAll {} -> () = Ok(service.kill_all()),
        OpenPath { path: PathBuf } -> Opening = service.relisted(projects::open_path(service, &path)),
        ForgetFolder { id: String } -> () = service.relisted(projects::forget_folder(service, &id)),
    }
}

impl Service {
    pub fn new(data_dir: PathBuf, state_dir: PathBuf, helpers: Option<PathBuf>) -> Self {
        paths::move_device_state(&data_dir, &state_dir);
        let processes = Arc::new(Processes::default());
        let cache = state_dir.join(".texpresso");
        Self {
            data_dir,
            state_dir,
            helpers,
            texpresso: Arc::new(texpresso::Manager::new(Arc::clone(&processes), cache)),
            processes,
            library: Mutex::default(),
            tex_found: tokio::sync::watch::Sender::new(false),
            tex_queue: Mutex::default(),
            histories: Mutex::default(),
            hub: OnceLock::new(),
            sent: Mutex::default(),
        }
    }

    pub fn projects(&self) -> Result<Vec<ProjectInfo>, CoreError> {
        projects::list_projects(self)
    }

    pub(crate) fn publish_projects(&self) -> Result<(), CoreError> {
        if self.hub.get().is_some() {
            let mut sent = lock(&self.sent);
            self.publish(&mut sent, LibrarySection::Projects(self.projects()?));
        }
        Ok(())
    }

    fn publish(&self, sent: &mut Sent<LibrarySection>, section: LibrarySection) {
        if let Some(hub) = self.hub.get()
            && let Some(said) = sent.changed(&section)
        {
            let _ = hub.send(Said::Library(said));
        }
    }

    pub(crate) fn relist(&self) {
        if let (Err(err), Some(hub)) = (self.publish_projects(), self.hub.get()) {
            let text = format!("The projects couldn’t be listed: {err}");
            let _ = hub.send(Said::Log(Log {
                level: LogLevel::Error,
                text,
            }));
        }
    }

    fn relisted<T>(&self, done: Result<T, CoreError>) -> Result<T, CoreError> {
        self.relist();
        done
    }

    pub(crate) fn in_session(
        self: &Arc<Self>,
        id: &str,
    ) -> Result<(Project, InSession), CoreError> {
        let mut library = lock(&self.library);
        let project = self.project(id)?;
        let root = &project.root;
        let overlaps = library
            .iter()
            .find(|(_, at)| at.starts_with(root) || root.starts_with(at));
        if let Some((open, at)) = overlaps {
            return Err(CoreError::conflict(if open == id {
                messages::project_open()
            } else {
                messages::shares_folder(at.file_name().unwrap_or_default().display())
            }));
        }
        library.push((id.to_owned(), root.clone()));
        let in_session = InSession {
            service: Arc::clone(self),
            id: id.to_owned(),
        };
        Ok((project, in_session))
    }

    pub(crate) fn unless_open(
        &self,
        id: &str,
        refused: fn() -> Message,
    ) -> Result<MutexGuard<'_, Vec<(String, PathBuf)>>, CoreError> {
        let library = lock(&self.library);
        if library.iter().any(|(open, _)| open == id) {
            return Err(CoreError::conflict(refused()));
        }
        Ok(library)
    }

    pub(crate) fn history(&self, project: &Project) -> Arc<mpsc::Sender<Job>> {
        let mut histories = lock(&self.histories);
        histories.retain(|_, history| history.strong_count() > 0);
        if let Some(history) = histories.get(&project.history).and_then(Weak::upgrade) {
            return history;
        }
        let history = Arc::new(History::queue(project));
        histories.insert(project.history.clone(), Arc::downgrade(&history));
        history
    }

    fn kill_all(&self) {
        self.processes.kill_all();
        self.texpresso.stop_all();
    }

    pub fn project(&self, id: &str) -> Result<Project, CoreError> {
        Project::find(self, id)
    }

    fn tex_turn(&self) -> impl Future<Output = oneshot::Sender<()>> + use<> {
        let (turn, next) = oneshot::channel();
        let before = lock(&self.tex_queue).replace(next);
        async move {
            if let Some(before) = before {
                let _ = before.await;
            }
            turn
        }
    }

    async fn status(&self) -> TexStatus {
        let app = AppSettings::read(&self.state_dir);
        let (tex_path, texpresso_path) = tex::tool_paths(&app, self.helpers.as_ref());
        let shown = |dir: Option<PathBuf>| dir.map(|d| d.to_string_lossy().into_owned());
        let mut found = tex::tex_available(&self.processes, &tex_path).await;
        found.texpresso = shown(texpresso::discover(&texpresso_path));
        found.tex_dir = shown(app.tex_dir);
        found.texpresso_dir = shown(app.texpresso_dir);
        self.tex_found.send_replace(found.available);
        self.publish(&mut lock(&self.sent), LibrarySection::Tex(found.clone()));
        found
    }

    async fn set_bin_dir(
        &self,
        dir: Option<PathBuf>,
        program: &str,
        missing: fn() -> Message,
        set: fn(&mut AppSettings, Option<PathBuf>),
    ) -> Result<TexStatus, CoreError> {
        let missing = || CoreError::bad_request(missing());
        let bin = dir.map(|dir| tex::bin_dir(&dir, program).ok_or_else(missing));
        let bin = bin.transpose()?;
        AppSettings::update(&self.state_dir, |app| set(app, bin))?;
        Ok(self.status().await)
    }

    pub(crate) fn tool_paths(&self) -> (String, String) {
        tex::tool_paths(&AppSettings::read(&self.state_dir), self.helpers.as_ref())
    }

    pub fn call(
        self: &Arc<Self>,
        name: &str,
        args: Value,
    ) -> impl Future<Output = Result<Value, CoreError>> + Send + use<> {
        let request = Library::parse(name, args);
        let tex = matches!(
            request,
            Ok(Library::CheckTex(..) | Library::SetTexpressoDir(..) | Library::SetTexDir(..))
        );
        let turn = tex.then(|| self.tex_turn());
        let service = Arc::clone(self);
        async move {
            let _turn = match turn {
                Some(turn) => Some(turn.await),
                None => None,
            };
            request?.run(&service).await
        }
    }
}
