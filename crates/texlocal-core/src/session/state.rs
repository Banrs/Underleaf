use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::FileKind;
use texlocal_latex::message::Message;
use texlocal_latex::project::Analysis;

use super::actor::Actor;
use super::build::{BuildState, ShownPdf};
use super::documents::DiskConflict;
use super::live::LiveState;
use crate::projects::TreeNode;
use crate::settings::ProjectSettings;

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
    pub name: String,
    pub root: String,
    pub settings: ProjectSettings,
    pub problem: Option<Message>,
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
    pub path: String,
    pub kind: FileKind,
    pub text: bool,
}

impl Actor {
    pub fn publish_all(&mut self, tree: Vec<TreeNode>) {
        self.core
            .publish(SessionSection::Lifecycle(Lifecycle::Open));
        self.show_tree(tree);
        self.docs.publish(&mut self.core);
        self.core.publish(SessionSection::Outline(None));
        self.builds.publish(&mut self.core, &self.docs);
        self.core.publish(SessionSection::BuildLog(String::new()));
        self.core.publish_pdf();
        self.live.publish(&mut self.core, &self.docs, false);
        self.core.publish(SessionSection::LiveLog(String::new()));
    }

    pub fn show_tree(&mut self, tree: Vec<TreeNode>) -> bool {
        let changed = self.tree.show(&mut self.core, tree);
        self.docs.publish_open(&mut self.core, &self.tree);
        changed
    }
}
