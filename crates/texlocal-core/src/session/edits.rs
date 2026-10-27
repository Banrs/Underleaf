use std::sync::Arc;

use serde_json::{Value, json};
use texlocal_latex::analyze::{Facts, Place};
use texlocal_latex::logparse::Fix;
use texlocal_latex::search::Query;
use texlocal_latex::syntax::{self, SymbolKind, Text, TextEdit};
use texlocal_latex::{FileKind, file_kind};

use super::Reply;
use super::actor::Actor;
use super::documents::Doc;
use super::scans::tex;
use crate::paths::Project;
use crate::projects;
use crate::settings;
use crate::{CoreError, packages};

pub(super) const ONE_DOCUMENT: &str =
    "Only one open document can be edited at once: close the others first.";

impl Actor {
    pub fn replace(&self, query: &Query, to: &str) -> Result<Value, CoreError> {
        let open = self.texts_to_edit("replaced")?;
        let found = |_: &str, text: &str| query.places(text);
        self.edit_project(
            "Before Replace All",
            &open,
            &texlocal_latex::is_text,
            &found,
            to,
        )
    }

    pub fn rename_symbol(
        &self,
        kind: SymbolKind,
        from: &str,
        to: &str,
    ) -> Result<Value, CoreError> {
        let noun = match kind {
            SymbolKind::Label => "label",
            SymbolKind::Citation => "citation",
            _ => {
                return Err(CoreError::bad_request(
                    "Only a label or a citation is renamed",
                ));
            }
        };
        if to.is_empty() || to.contains(|c: char| "{}%\\,".contains(c) || c.is_whitespace()) {
            return Err(CoreError::bad_request(format!(
                "A {noun} can't be empty or have spaces, commas, braces, % or \\ in it."
            )));
        }
        let open = self.texts_to_edit("renamed")?;
        let texts = open
            .iter()
            .map(|(path, text, _)| (path.clone(), text.clone()));
        let symbols = projects::scan_symbols(&self.project.root, &self.facts, &texts.collect())?;
        let defines = |name: &str| {
            let mut files = symbols.by_file.values();
            files.any(|facts| !syntax::definitions(facts, kind, name).is_empty())
        };
        if !defines(from) {
            return Err(CoreError::not_found(format!(
                "No {noun} “{from}” is defined."
            )));
        }
        if defines(to) {
            return Err(CoreError::conflict(format!(
                "A {noun} “{to}” exists already."
            )));
        }
        let found = |rel: &str, text: &str| {
            let facts = Facts::read(text, file_kind(rel));
            syntax::usages(&facts, rel, kind, from, |_| None)
        };
        self.edit_project("Before Rename", &open, &tex, &found, to)
    }

    pub fn fix(&mut self, fix: Fix, reply: Reply) {
        let edits = match fix {
            Fix::Install(file) => {
                let (service, project) = (Arc::clone(&self.service), self.project.clone());
                tokio::spawn(async move {
                    let installed = packages::install_package(&file, &service.tool_paths().0).await;
                    reply.send(match installed {
                        Err(err) if err.kind == crate::ErrorKind::Denied => Ok(Value::Null),
                        installed => installed.map(|_| fixed(Value::Null, &project)),
                    });
                });
                return;
            }
            Fix::AddPackage(name) => self
                .add_package(&name)
                .map(|mut added| added["edits"].take()),
            Fix::Xelatex => self
                .set_settings(&json!({ "engine": "xelatex" }), false)
                .map(|_| Value::Null),
            Fix::ShellEscape => self
                .set_settings(&json!({ "shellEscape": true }), false)
                .map(|_| Value::Null),
        };
        reply.send(edits.map(|edits| fixed(edits, &self.project)));
    }

    fn add_package(&self, name: &str) -> Result<Value, CoreError> {
        let main = self.tree.main.as_deref();
        let open = self.texts_to_edit("added")?;
        let found = |_: &str, text: &str| {
            let facts = Facts::read(text, FileKind::Tex);
            let loaded = facts.packages.iter().any(|package| package == name);
            facts.new_package.filter(|_| !loaded).into_iter().collect()
        };
        let line = format!("\n\\usepackage{{{name}}}");
        let main = |rel: &str| Some(rel) == main;
        self.edit_project("Before Adding a Package", &open, &main, &found, &line)
    }

    pub fn texts_to_edit(&self, done: &str) -> Result<Vec<(String, String, u64)>, CoreError> {
        let docs = self.docs.values();
        let unsettled =
            |doc: &&Doc| doc.conflict.is_some() || doc.asking.is_some() || !doc.reloads.is_empty();
        if let Some(doc) = docs.clone().find(unsettled) {
            return Err(CoreError::conflict(format!(
                "“{}” changed on disk, so nothing was {done}. Keep your edits or the disk’s first, then try again.",
                doc.path
            )));
        }
        let text = |doc: &Doc| {
            let (text, version) = doc.doc.snapshot();
            (doc.path.clone(), text, version)
        };
        Ok(docs.map(text).collect())
    }

    fn edit_project(
        &self,
        reason: &'static str,
        open: &[(String, String, u64)],
        chosen: &dyn Fn(&str) -> bool,
        found: &dyn Fn(&str, &str) -> Vec<Place>,
        to: &str,
    ) -> Result<Value, CoreError> {
        let open = open.iter().filter(|(path, ..)| chosen(path));
        let mut edits: Vec<Value> = open
            .filter_map(|(path, text, version)| {
                let lines = Text::new(text).lines;
                let edit = |place: Place| TextEdit {
                    start: lines[place.line as usize - 1] + place.column,
                    length: place.length,
                    text: to.to_owned(),
                };
                let edits: Vec<TextEdit> = found(path, text).into_iter().map(edit).collect();
                (!edits.is_empty())
                    .then(|| json!({ "path": path, "version": version, "edits": edits }))
            })
            .collect();
        if edits.len() > 1 {
            return Err(CoreError::conflict(ONE_DOCUMENT));
        }
        let snapshot = self.snapshot_before(reason)?;
        let others = |rel: &str| chosen(rel) && !self.docs.contains_key(rel) && !self.deleting(rel);
        let written = self.service.with_project(&self.project_id, |project| {
            projects::replace_in_files(&project.root, &others, found, to)
        })?;
        Ok(json!({ "edits": edits.pop(), "written": written, "snapshot": snapshot }))
    }
}

fn fixed(edits: Value, project: &Project) -> Value {
    json!({ "edits": edits, "settings": settings::shown(project) })
}
