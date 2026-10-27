use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::Value;
use texlocal_latex::templates::ProjectTemplate;
use texlocal_latex::wordmatch::{PdfHit, PdfPage};

use crate::compile::CompileManager;
use crate::import::{ImportConflict, Imported};
use crate::paths::Project;
use crate::projects::{self, History, Opening, ProjectInfo, TreeNode};
use crate::protocol::requests;
use crate::settings::{self, AppSettings, Engine, UiPatch};
use crate::synctex::{self, ForwardLoc, InverseLoc, PageClick};
use crate::tex::{self, TexStatus};
use crate::texpresso::{self, Preview};
use crate::{CoreError, import, lock, sys, tinytex, zipexport};

const NO_TEXPRESSO: &str =
    "That folder doesn't contain the texpresso program. Choose the folder it's in.";

pub struct Service {
    pub(crate) data_dir: PathBuf,
    pub(crate) compile: CompileManager,
    pub(crate) texpresso: Arc<texpresso::Manager>,
    pub(crate) edits: Mutex<()>,
    pub(crate) tex_found: tokio::sync::watch::Sender<bool>,
    histories: Mutex<HashMap<PathBuf, Arc<Mutex<History>>>>,
}

requests! {
    Library {
        CheckTex {} -> TexStatus,
        SetTexpressoDir { dir: Option<PathBuf> } -> TexStatus,
        SetTexDir { dir: Option<PathBuf> } -> TexStatus,
        InstallTex {} -> TexStatus,
        ListProjects {} -> Vec<ProjectInfo>,
        CreateProject { name: String, template: ProjectTemplate, engine: Option<Engine> } -> ProjectInfo,
        DuplicateProject { id: String, name: String } -> ProjectInfo,
        FreeProjectName {} -> String,
        RenameProject { id: String, name: String } -> ProjectInfo,
        ReadTree { id: String } -> Vec<TreeNode>,
        SynctexForward { id: String, file: String, line: u32, live: Option<u64> } -> ForwardLoc,
        SynctexInverse { id: String, page: f64, x: f64, y: f64, click: Option<PageClick>, live: Option<u64> } -> InverseLoc,
        SynctexMatch { id: String, file: String, line: u32, column: usize, pages: Vec<PdfPage> } -> Option<PdfHit>,
        PdfPath { id: String } -> String,
        ExportZip { id: String, dest: PathBuf, for_arxiv: bool } -> (),
        KillAll {} -> (),
        ImportFiles { id: String, dir: String, paths: Vec<PathBuf>, conflict: Option<ImportConflict> } -> Imported,
        OpenPath { path: PathBuf } -> Opening,
        ForgetFolder { id: String } -> (),
        SetUiState { id: String, patch: UiPatch } -> (),
    }
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

    fn kill_all(&self) {
        self.compile.kill_all();
        self.texpresso.kill_all();
    }

    pub fn project(&self, id: &str) -> Result<Project, CoreError> {
        Project::find(&self.data_dir, id)
    }

    fn live(&self, session: Option<u64>) -> Result<Option<(u64, PathBuf)>, CoreError> {
        let live = |session| Ok((session, self.texpresso.live_pdf(session)?));
        session.map(live).transpose()
    }

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

    #[expect(clippy::unit_arg)]
    pub async fn call(&self, name: &str, args: Value) -> Result<Value, CoreError> {
        let stop = |root: &Path| {
            self.compile.stop(root);
            self.texpresso.stop(root)
        };
        match Library::parse(name, args)? {
            Library::CheckTex(CheckTex {}, answer) => answer(Ok(self.status().await)),
            Library::SetTexpressoDir(SetTexpressoDir { dir }, answer) => {
                let texpresso = dir
                    .as_ref()
                    .map(|dir| tex::program_at(&dir.join("texpresso")));
                if texpresso.is_some_and(|found| found.is_none()) {
                    return Err(CoreError::bad_request(NO_TEXPRESSO));
                }
                AppSettings::update(&self.data_dir, |app| app.texpresso_dir = dir)?;
                answer(Ok(self.status().await))
            }
            Library::SetTexDir(SetTexDir { dir }, answer) => {
                let bin = dir.map(|dir| tex::tex_bin_dir(&dir).ok_or(()));
                let bin = bin
                    .transpose()
                    .map_err(|()| CoreError::bad_request(sys::NO_LATEXMK))?;
                AppSettings::update(&self.data_dir, |app| app.tex_dir = bin)?;
                answer(Ok(self.status().await))
            }
            Library::InstallTex(InstallTex {}, answer) => {
                tinytex::install(&self.tool_paths().0).await?;
                answer(Ok(self.status().await))
            }
            Library::ListProjects(ListProjects {}, answer) => {
                answer(projects::list_projects(&self.data_dir))
            }
            Library::CreateProject(
                CreateProject {
                    name,
                    template,
                    engine,
                },
                answer,
            ) => answer(projects::create_project(
                &self.data_dir,
                &name,
                template,
                engine,
            )),
            Library::DuplicateProject(DuplicateProject { id, name }, answer) => {
                answer(import::duplicate_project(self, &id, &name))
            }
            Library::FreeProjectName(FreeProjectName {}, answer) => {
                answer(projects::free_project_name(&self.data_dir))
            }
            Library::RenameProject(RenameProject { id, name }, answer) => {
                answer(self.with_project(&id, |_| {
                    projects::rename_project(&self.data_dir, &id, &name, stop)
                }))
            }
            Library::ReadTree(ReadTree { id }, answer) => {
                answer(projects::file_tree(&self.project(&id)?))
            }
            Library::SynctexForward(
                SynctexForward {
                    id,
                    file,
                    line,
                    live,
                },
                answer,
            ) => {
                let pdf = self.live(live)?.map(|(_, pdf)| pdf);
                let project = self.project(&id)?;
                answer(synctex::synctex_forward_at(
                    &project,
                    &file,
                    line,
                    pdf.as_deref(),
                ))
            }
            Library::SynctexInverse(
                SynctexInverse {
                    id,
                    page,
                    x,
                    y,
                    click,
                    live,
                },
                answer,
            ) => {
                let live = self.live(live)?;
                let typeset = |rel: &str| self.texpresso.live_text(live.as_ref()?.0, rel);
                let pdf = live.as_ref().map(|(_, pdf)| pdf.as_path());
                let project = self.project(&id)?;
                answer(synctex::synctex_inverse(
                    &project, page, x, y, click, pdf, &typeset,
                ))
            }
            Library::SynctexMatch(
                SynctexMatch {
                    id,
                    file,
                    line,
                    column,
                    pages,
                },
                answer,
            ) => {
                let root = self.project(&id)?.root;
                answer(synctex::match_forward(&root, &file, line, column, &pages))
            }
            Library::PdfPath(PdfPath { id }, answer) => {
                let project = self.project(&id)?;
                let pdf = settings::read_settings(&project.settings).output(&project.build, "pdf");
                answer(pdf.map(|pdf| pdf.to_string_lossy().into_owned()))
            }
            Library::ExportZip(
                ExportZip {
                    id,
                    dest,
                    for_arxiv,
                },
                answer,
            ) => {
                let project = self.project(&id)?;
                let added = match for_arxiv {
                    true => zipexport::for_arxiv(&project)?,
                    false => Vec::new(),
                };
                answer(zipexport::export_zip(&project.root, &dest, &added))
            }
            Library::KillAll(KillAll {}, answer) => answer(Ok(self.kill_all())),
            Library::ImportFiles(
                ImportFiles {
                    id,
                    dir,
                    paths,
                    conflict,
                },
                answer,
            ) => answer(import::import_files(
                self,
                &id,
                &dir,
                &paths,
                conflict,
                sys::trash,
            )),
            Library::OpenPath(OpenPath { path }, answer) => {
                answer(projects::open_path(self, &path))
            }
            Library::ForgetFolder(ForgetFolder { id }, answer) => {
                answer(projects::forget_folder(self, &id, stop))
            }
            Library::SetUiState(SetUiState { id, patch }, answer) => {
                answer(self.with_project(&id, |project| settings::write_ui(&project.ui, patch)))
            }
        }
    }
}
