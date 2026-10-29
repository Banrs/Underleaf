use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, mpsc};

use schemars::JsonSchema;
use serde::Serialize;
use serde_json::Value;
use texlocal_latex::message::Message;
use texlocal_latex::templates::ProjectTemplate;

use crate::compile::CompileManager;
use crate::events::{Queued, Sent};
use crate::messages;
use crate::paths::Project;
use crate::projects::{self, History, Opening, ProjectInfo};
use crate::protocol::requests;
use crate::settings::{AppSettings, Engine};
use crate::tex::{self, TexStatus};
use crate::texpresso;
use crate::{CoreError, import, lock, tinytex};

pub struct Service {
    pub(crate) data_dir: PathBuf,
    pub(crate) compile: CompileManager,
    pub(crate) texpresso: Arc<texpresso::Manager>,
    pub(crate) library: Mutex<Vec<(String, PathBuf)>>,
    pub(crate) tex_found: tokio::sync::watch::Sender<bool>,
    histories: Mutex<HashMap<PathBuf, Arc<Mutex<History>>>>,
    pub(crate) hub: OnceLock<mpsc::Sender<Queued>>,
    sent: Mutex<Sent<LibrarySection>>,
}

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum LibrarySection {
    Projects(Vec<ProjectInfo>),
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
    Library {
        CheckTex {} -> TexStatus,
        SetTexpressoDir { dir: Option<PathBuf> } -> TexStatus,
        SetTexDir { dir: Option<PathBuf> } -> TexStatus,
        InstallTex {} -> TexStatus,
        ReloadProjects {} -> (),
        CreateProject { name: String, template: ProjectTemplate, engine: Option<Engine> } -> ProjectInfo,
        DuplicateProject { id: String, name: String } -> ProjectInfo,
        FreeProjectName {} -> String,
        RenameProject { id: String, name: String } -> ProjectInfo,
        KillAll {} -> (),
        OpenPath { path: PathBuf } -> Opening,
        ForgetFolder { id: String } -> (),
    }
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            texpresso: Arc::default(),
            library: Mutex::default(),
            tex_found: tokio::sync::watch::Sender::new(false),
            histories: Mutex::default(),
            hub: OnceLock::new(),
            sent: Mutex::default(),
        }
    }

    pub fn projects(&self) -> Result<Vec<ProjectInfo>, CoreError> {
        projects::list_projects(&self.data_dir)
    }

    pub(crate) fn publish_projects(&self) -> Result<(), CoreError> {
        let Some(hub) = self.hub.get() else {
            return Ok(());
        };
        let mut sent = lock(&self.sent);
        let section = LibrarySection::Projects(self.projects()?);
        if sent.changed(&section) {
            let _ = hub.send(Queued::Library(section));
        }
        Ok(())
    }

    fn relist<T>(&self, done: Result<T, CoreError>) -> Result<T, CoreError> {
        let _ = self.publish_projects();
        done
    }

    pub(crate) fn in_session(
        self: &Arc<Self>,
        id: &str,
        root: &Path,
    ) -> Result<InSession, CoreError> {
        let mut library = lock(&self.library);
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
        library.push((id.to_owned(), root.to_owned()));
        Ok(InSession {
            service: Arc::clone(self),
            id: id.to_owned(),
        })
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

    pub(crate) fn history(&self, project: &Project) -> Arc<Mutex<History>> {
        let mut histories = lock(&self.histories);
        let history = histories.entry(project.history.clone());
        Arc::clone(history.or_insert_with(|| Arc::new(Mutex::new(History::of(project)))))
    }

    fn kill_all(&self) {
        self.compile.kill_all();
        self.texpresso.kill_all();
    }

    pub fn project(&self, id: &str) -> Result<Project, CoreError> {
        Project::find(&self.data_dir, id)
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

    #[expect(clippy::unit_arg)]
    pub async fn call(&self, name: &str, args: Value) -> Result<Value, CoreError> {
        match Library::parse(name, args)? {
            Library::CheckTex(CheckTex {}, answer) => answer(Ok(self.status().await)),
            Library::SetTexpressoDir(SetTexpressoDir { dir }, answer) => {
                let none_there = || CoreError::bad_request(messages::no_texpresso_there());
                let bin = dir.map(|dir| tex::bin_dir(&dir, "texpresso").ok_or_else(none_there));
                let bin = bin.transpose()?;
                AppSettings::update(&self.data_dir, |app| app.texpresso_dir = bin)?;
                answer(Ok(self.status().await))
            }
            Library::SetTexDir(SetTexDir { dir }, answer) => {
                let no_latexmk = || CoreError::bad_request(messages::no_latexmk());
                let bin = dir.map(|dir| tex::bin_dir(&dir, "latexmk").ok_or_else(no_latexmk));
                let bin = bin.transpose()?;
                AppSettings::update(&self.data_dir, |app| app.tex_dir = bin)?;
                answer(Ok(self.status().await))
            }
            Library::InstallTex(InstallTex {}, answer) => {
                tinytex::install(&self.tool_paths().0).await?;
                answer(Ok(self.status().await))
            }
            Library::ReloadProjects(ReloadProjects {}, answer) => answer(self.publish_projects()),
            Library::CreateProject(
                CreateProject {
                    name,
                    template,
                    engine,
                },
                answer,
            ) => answer(self.relist(projects::create_project(
                &self.data_dir,
                &name,
                template,
                engine,
            ))),
            Library::DuplicateProject(DuplicateProject { id, name }, answer) => {
                answer(self.relist(import::duplicate_project(self, &id, &name)))
            }
            Library::FreeProjectName(FreeProjectName {}, answer) => {
                answer(projects::free_project_name(&self.data_dir))
            }
            Library::RenameProject(RenameProject { id, name }, answer) => {
                let renamed = self
                    .unless_open(&id, messages::close_before_renaming)
                    .and_then(|_library| projects::rename_project(&self.data_dir, &id, &name));
                answer(self.relist(renamed))
            }
            Library::KillAll(KillAll {}, answer) => answer(Ok(self.kill_all())),
            Library::OpenPath(OpenPath { path }, answer) => {
                answer(self.relist(projects::open_path(self, &path)))
            }
            Library::ForgetFolder(ForgetFolder { id }, answer) => {
                answer(self.relist(projects::forget_folder(self, &id)))
            }
        }
    }
}
