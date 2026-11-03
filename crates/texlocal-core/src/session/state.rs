use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::message::Message;
use texlocal_latex::project::Analysis;
use texlocal_latex::{FileKind, file_kind, is_text};

use super::actor::Actor;
use super::build::{BuildState, ShownPdf};
use super::documents::{DiskConflict, Doc};
use super::live::LiveState;
use super::watch::TreeIndex;
use crate::projects::TreeNode;
use crate::settings::{self, ProjectSettings};

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum SessionSection {
    Lifecycle(Lifecycle),
    Project(ProjectState),
    Tree(Vec<TreeNode>),
    Documents(Vec<DocumentState>),
    OpenFile(Option<OpenFile>),
    Outline(Option<Analysis>),
    Build(BuildState),
    BuildLog(String),
    ShownPdf(ShownPdf),
    Live(LiveState),
    LiveLog(String),
}

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum Lifecycle {
    Open,
    Closing,
    Closed,
    Stopped(Stopped),
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Stopped {
    pub unsaved: Vec<String>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct ProjectState {
    name: String,
    root: String,
    settings: ProjectSettings,
    problem: Option<Message>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct DocumentState {
    pub path: String,
    pub error: Option<Message>,
    pub conflict: Option<DiskConflict>,
    pub asking: bool,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct OpenFile {
    path: String,
    kind: FileKind,
}

impl Actor {
    pub fn publish_all(&mut self, tree: Vec<TreeNode>) {
        self.core
            .publish(SessionSection::Lifecycle(Lifecycle::Open));
        self.show_tree(tree);
        self.publish_documents();
        self.core.publish(SessionSection::Outline(None));
        self.builds.publish(&mut self.core, &self.docs);
        self.core.publish(SessionSection::BuildLog(String::new()));
        self.core.publish_pdf();
        self.publish_live(false);
        self.core.publish(SessionSection::LiveLog(String::new()));
    }

    pub fn show_tree(&mut self, tree: Vec<TreeNode>) -> bool {
        self.tree = TreeIndex::of(&tree);
        if let Some(watcher) = &mut self.watcher {
            watcher.refresh(&self.core.project, &self.tree);
        }
        let changed = self.core.publish(SessionSection::Tree(tree));
        self.publish_project();
        self.publish_open();
        changed
    }

    pub fn publish_project(&mut self) {
        let project = ProjectState {
            name: self.core.project.name(),
            root: self.core.project.root.to_string_lossy().into_owned(),
            settings: settings::shown(&self.core.project, self.tree.main.clone()),
            problem: settings::problem(&self.core.project),
        };
        self.core.publish(SessionSection::Project(project));
    }

    pub fn publish_documents(&mut self) {
        let documents = self.docs.values().map(Doc::state).collect();
        self.core.publish(SessionSection::Documents(documents));
    }

    pub fn publish_open(&mut self) {
        let gone = |open: &String| match is_text(open) {
            true => !self.docs.contains_key(open),
            false => !self.tree.files.contains(open),
        };
        if self.open.as_ref().is_some_and(gone) {
            self.open = None;
        }
        let open = self.open.clone().map(|path| OpenFile {
            kind: file_kind(&path),
            path,
        });
        self.core.publish(SessionSection::OpenFile(open));
    }
}
