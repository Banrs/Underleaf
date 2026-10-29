use std::collections::HashMap;
use std::mem::{Discriminant, discriminant};

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::analyze::Analysis;

use super::actor::Actor;
use super::documents::{DiskConflict, Doc};
use super::watch::TreeIndex;
use crate::events::Event;
use crate::projects::TreeNode;
use crate::settings::{self, ProjectSettings};

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum SessionSection {
    Project(ProjectState),
    Tree(Vec<TreeNode>),
    Documents(Vec<DocumentState>),
    Outline(Option<Analysis>),
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct ProjectState {
    name: String,
    root: String,
    settings: ProjectSettings,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct DocumentState {
    pub path: String,
    pub error: Option<String>,
    pub held: Option<DiskConflict>,
}

pub(crate) type Sent = HashMap<Discriminant<SessionSection>, String>;

impl Actor {
    pub fn publish(&mut self, section: SessionSection) -> bool {
        let said = serde_json::to_string(&section).expect("a section serialises");
        let kind = discriminant(&section);
        if self.sent.get(&kind) == Some(&said) {
            return false;
        }
        self.sent.insert(kind, said);
        self.emit(Event::Section(section));
        true
    }

    pub fn publish_all(&mut self, tree: Vec<TreeNode>) {
        self.show_tree(tree);
        self.publish_documents();
        self.publish(SessionSection::Outline(None));
    }

    pub fn show_tree(&mut self, tree: Vec<TreeNode>) -> bool {
        self.tree = TreeIndex::of(&tree);
        let changed = self.publish(SessionSection::Tree(tree));
        self.publish_project();
        changed
    }

    pub fn publish_project(&mut self) {
        let project = ProjectState {
            name: self.project.name(),
            root: self.project.root.to_string_lossy().into_owned(),
            settings: settings::shown(&self.project, self.tree.main.clone()),
        };
        self.publish(SessionSection::Project(project));
    }

    pub fn publish_documents(&mut self) {
        let documents = self.docs.values().map(Doc::state).collect();
        self.publish(SessionSection::Documents(documents));
    }
}
