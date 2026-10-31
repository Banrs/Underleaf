use std::sync::Arc;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::facts::{Facts, Place};
use texlocal_latex::logparse::Fix;
use texlocal_latex::message::Message;
use texlocal_latex::search::Query;
use texlocal_latex::syntax::{self, SymbolKind, Text, TextEdit};
use texlocal_latex::{FileKind, file_kind};

use super::Pending;
use super::actor::Actor;
use super::documents::Doc;
use super::history::Then;
use super::scans::tex;
use crate::messages;
use crate::projects::{self, Reason, Written};
use crate::settings::{Engine, SettingsPatch};
use crate::{CoreError, packages};

type Said = fn(&str) -> Message;

#[derive(Serialize, JsonSchema)]
pub(crate) struct ProjectEdits {
    edits: Option<DocumentEdits>,
    written: Vec<Written>,
    snapshot: Option<String>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct DocumentEdits {
    pub path: String,
    pub version: u64,
    pub edits: Vec<TextEdit>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Fixed {
    edits: Option<DocumentEdits>,
}

impl Actor {
    pub fn replace(&mut self, query: Query, to: String) -> Result<Then<ProjectEdits>, CoreError> {
        let open = self.texts_to_edit()?;
        let found = move |_: &str, text: &str| query.places(text);
        edit_project(&open, texlocal_latex::is_text, found, to)
    }

    pub fn rename_symbol(
        &mut self,
        kind: SymbolKind,
        from: String,
        to: String,
    ) -> Result<Then<ProjectEdits>, CoreError> {
        let (bad_name, undefined, exists): (fn() -> Message, Said, Said) = match kind {
            SymbolKind::Label => (
                messages::bad_label_name,
                |name| texlocal_latex::messages::no_label(name),
                |name| messages::label_exists(name),
            ),
            SymbolKind::Citation => (
                messages::bad_citation_name,
                |name| texlocal_latex::messages::no_citation(name),
                |name| messages::citation_exists(name),
            ),
            _ => return Err(CoreError::bad_request(messages::renamed_symbol_unfit())),
        };
        if to.is_empty() || to.contains(|c: char| "{}%\\,".contains(c) || c.is_whitespace()) {
            return Err(CoreError::bad_request(bad_name()));
        }
        let open = self.texts_to_edit()?;
        let texts = open
            .iter()
            .map(|(path, text, _)| (path.clone(), text.clone()));
        let read = projects::scan_facts(&self.project.root, &self.facts, &texts.collect())?;
        let defines = |name: &str| {
            let mut files = read.values();
            files.any(|facts| !syntax::definitions(&facts.defined, kind, name).is_empty())
        };
        if !defines(&from) {
            return Err(CoreError::not_found(undefined(&from)));
        }
        if defines(&to) {
            return Err(CoreError::conflict(exists(&to)));
        }
        let found = move |rel: &str, text: &str| {
            let facts = Facts::read(text, file_kind(rel));
            syntax::usages(&facts, rel, kind, &from, |_| None)
        };
        edit_project(&open, tex, found, to)
    }

    pub fn fix(&mut self, fix: Fix, reply: Pending<Option<Fixed>>) {
        let edits = match fix {
            Fix::Install(file) => {
                let (service, children) = (Arc::clone(&self.service), self.children);
                tokio::spawn(async move {
                    let path = service.tool_paths().0;
                    let installed =
                        packages::install_package(&service.processes, children, &file, &path).await;
                    reply.send(match installed {
                        Err(err) if err.kind == crate::ErrorKind::Denied => Ok(None),
                        installed => installed.map(|_| Some(Fixed { edits: None })),
                    });
                });
                return;
            }
            Fix::AddPackage(name) => {
                let added = self.add_package(name).map(|add| -> Then<Option<Fixed>> {
                    Box::new(|actor, snapshot| {
                        add(actor, snapshot).map(|added| Some(Fixed { edits: added.edits }))
                    })
                });
                return self.before(Reason::AddPackage, added, reply);
            }
            Fix::Xelatex => self.patch_settings(SettingsPatch {
                engine: Some(Engine::Xelatex),
                ..SettingsPatch::default()
            }),
            Fix::ShellEscape => self.patch_settings(SettingsPatch {
                shell_escape: Some(true),
                ..SettingsPatch::default()
            }),
        };
        reply.send(edits.map(|edits| Some(Fixed { edits })));
    }

    fn patch_settings(&mut self, patch: SettingsPatch) -> Result<Option<DocumentEdits>, CoreError> {
        self.set_settings(&patch, false).map(|()| None)
    }

    fn add_package(&mut self, name: String) -> Result<Then<ProjectEdits>, CoreError> {
        let open = self.texts_to_edit()?;
        let main = self.tree.main.clone();
        let line = format!("\n\\usepackage{{{name}}}");
        let found = move |_: &str, text: &str| {
            let facts = Facts::read(text, FileKind::Tex);
            let loaded = facts.packages.contains(&name);
            facts.new_package.filter(|_| !loaded).into_iter().collect()
        };
        let main = move |rel: &str| Some(rel) == main.as_deref();
        edit_project(&open, main, found, line)
    }

    pub fn texts_to_edit(&mut self) -> Result<Vec<(String, String, u64)>, CoreError> {
        let unsettled = |doc: &&Doc| doc.conflict.is_some() || doc.asking.is_some();
        if let Some(doc) = self.docs.values().find(unsettled) {
            return Err(CoreError::conflict(messages::changed_on_disk(&doc.path)));
        }
        self.save_first()?;
        let text = |doc: &Doc| {
            let (text, version) = doc.doc.snapshot();
            (doc.path.clone(), text, version)
        };
        Ok(self.docs.values().map(text).collect())
    }
}

fn edit_project(
    open: &[(String, String, u64)],
    chosen: impl Fn(&str) -> bool + Send + 'static,
    found: impl Fn(&str, &str) -> Vec<Place> + Send + 'static,
    to: String,
) -> Result<Then<ProjectEdits>, CoreError> {
    let mut edits: Vec<DocumentEdits> = open
        .iter()
        .filter(|(path, ..)| chosen(path))
        .filter_map(|(path, text, version)| {
            let lines = Text::new(text).lines;
            let edit = |place: Place| TextEdit {
                start: lines[place.line as usize - 1] + place.column,
                length: place.length,
                text: to.clone(),
            };
            let edits: Vec<TextEdit> = found(path, text).into_iter().map(edit).collect();
            (!edits.is_empty()).then(|| DocumentEdits {
                path: path.clone(),
                version: *version,
                edits,
            })
        })
        .collect();
    if edits.len() > 1 {
        return Err(CoreError::conflict(messages::one_document()));
    }
    let edits = edits.pop();
    let open: Vec<String> = open.iter().map(|(path, ..)| path.clone()).collect();
    Ok(Box::new(move |actor, snapshot| {
        let others =
            |rel: &str| chosen(rel) && !open.iter().any(|path| path == rel) && !actor.deleting(rel);
        let written = projects::replace_in_files(&actor.project.root, &others, &found, &to)?;
        Ok(ProjectEdits {
            edits,
            written,
            snapshot,
        })
    }))
}
