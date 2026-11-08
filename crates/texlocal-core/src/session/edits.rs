use std::fs;
use std::sync::{Arc, PoisonError};

use schemars::JsonSchema;
use serde::Serialize;

use texlocal_latex::facts::{Facts, Place};
use texlocal_latex::logparse::Fix;
use texlocal_latex::message::Message;
use texlocal_latex::search::Query;
use texlocal_latex::syntax::{self, SymbolKind, Text, TextEdit};
use texlocal_latex::{FileKind, cite, file_kind, project, utf16};

use super::Pending;
use super::actor::Actor;
use super::documents::Doc;
use super::history::Then;
use super::scans::usages_in;
use crate::messages;
use crate::projects::{self, Reason, Written};
use crate::settings::{Engine, SettingsPatch};
use crate::{CoreError, lf, lossy_string, packages, paths};

type Said = fn(&str) -> Message;

#[derive(Serialize, JsonSchema)]
pub(crate) struct ProjectEdits {
    pub edits: Option<DocumentEdits>,
    pub written: Vec<Written>,
    pub snapshot: Option<String>,
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

#[derive(Serialize, JsonSchema)]
pub(crate) struct AddedCitation {
    key: String,
    file: String,
    // None when the bibliography had the entry already.
    edits: Option<ProjectEdits>,
}

impl Actor {
    pub fn replace(&mut self, query: Query, to: String) -> Result<Then<ProjectEdits>, CoreError> {
        let found = move |_: &str, text: &str| query.places(text);
        self.edit_project(texlocal_latex::is_text, found, to)
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
        let open = self.text_to_edit()?;
        let texts = open.map(|open| (open.path, open.text));
        let read = projects::scan_facts(
            &self.core.project,
            &self.tree.facts,
            &texts.into_iter().collect(),
        )?;
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
        let found = move |rel: &str, text: &str| usages_in(rel, text, kind, &from, |_| None);
        self.edit_project(texlocal_latex::is_source, found, to)
    }

    pub fn fix(&mut self, fix: Fix, reply: Pending<Option<Fixed>>) {
        let edits = match fix {
            Fix::Install(file) => {
                let (service, children) = (Arc::clone(&self.core.service), self.core.children);
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
        let main = self.tree.main.clone();
        let line = format!("\n\\usepackage{{{name}}}");
        let found = move |_: &str, text: &str| {
            let facts = Facts::read(text, FileKind::Tex);
            let loaded = facts.packages.contains(&name);
            facts.new_package.filter(|_| !loaded).into_iter().collect()
        };
        let main = move |rel: &str| Some(rel) == main.as_deref();
        self.edit_project(main, found, line)
    }

    /// Adds fetched BibTeX to the bibliography the main file names, else the project's first `.bib`, else a new
    /// `references.bib`, unless one of them has an entry with its DOI or arXiv identifier already.
    pub fn add_citation(&mut self, fetched: String, reply: Pending<AddedCitation>) {
        let added = self.citation(&fetched);
        let (key, file, new, add) = match added {
            Ok(Ok(found)) => return reply.send(Ok(found)),
            Ok(Err(add)) => add,
            Err(err) => return reply.send(Err(err)),
        };
        let then = add.map(|add| -> Then<AddedCitation> {
            // Made only once the version before is taken and the edit goes ahead.
            Box::new(move |actor, snapshot| {
                let root = &actor.core.project.root;
                if new && paths::safe_path(root, &file).is_ok_and(|path| !path.exists()) {
                    actor.create_entry("", &file, false)?;
                }
                add(actor, snapshot).map(|edits| AddedCitation {
                    key,
                    file,
                    edits: Some(edits),
                })
            })
        });
        self.before(Reason::AddCitation, then, reply);
    }

    #[allow(clippy::type_complexity)]
    fn citation(
        &mut self,
        fetched: &str,
    ) -> Result<
        Result<AddedCitation, (String, String, bool, Result<Then<ProjectEdits>, CoreError>)>,
        CoreError,
    > {
        self.text_to_edit()?;
        let scan = Arc::clone(
            &self
                .tree
                .scan
                .read()
                .unwrap_or_else(PoisonError::into_inner),
        );
        let taken = |key: &str| {
            let mut files = scan.facts.values();
            files.any(|facts| {
                !syntax::definitions(&facts.defined, SymbolKind::Citation, key).is_empty()
            })
        };
        let tidied = cite::tidy(fetched, taken)
            .ok_or_else(|| CoreError::bad_request(messages::no_bibtex()))?;
        let mut bibs = (self.tree.main.as_deref())
            .map_or_else(Vec::new, |main| project::bibliographies(&scan, main));
        if bibs.is_empty() {
            let mut own: Vec<&String> = self
                .tree
                .files
                .iter()
                .filter(|file| file_kind(file) == FileKind::Bib)
                .collect();
            own.sort();
            bibs.extend(own.into_iter().take(1).cloned());
        }
        let (root, docs) = (self.core.project.root.clone(), self.docs.handles());
        let text = |rel: &str| match docs.get(rel) {
            Some(doc) => Some(doc.snapshot().0),
            None => fs::read(paths::safe_path(&root, rel).ok()?)
                .ok()
                .map(|bytes| lf(lossy_string(bytes))),
        };
        for bib in &bibs {
            let had = text(bib).and_then(|text| {
                cite::find_entry(&text, tidied.doi.as_deref(), tidied.eprint.as_deref())
            });
            if let Some(key) = had {
                return Ok(Ok(AddedCitation {
                    key,
                    file: bib.clone(),
                    edits: None,
                }));
            }
        }
        let new = bibs.is_empty();
        let file = bibs
            .into_iter()
            .next()
            .unwrap_or_else(|| "references.bib".to_owned());
        let before = text(&file).unwrap_or_default();
        let gap = match () {
            () if before.is_empty() || before.ends_with("\n\n") => "",
            () if before.ends_with('\n') => "\n",
            () => "\n\n",
        };
        let target = file.clone();
        let end = |_: &str, text: &str| {
            let lines = Text::new(text).lines;
            let start = lines.last().copied().unwrap_or_default();
            let column = utf16::len(text) as u32 - start;
            vec![Place {
                line: lines.len() as u32,
                column,
                length: 0,
            }]
        };
        let add = self.edit_project(
            move |rel| rel == target,
            end,
            format!("{gap}{}", tidied.entry),
        );
        Ok(Err((tidied.key, file, new, add)))
    }

    /// The shown document's text, after saving every edit and closing documents a failed save had kept open, so every
    /// other file's text is on disk.
    pub fn text_to_edit(&mut self) -> Result<Option<OpenText>, CoreError> {
        let unsettled = |doc: &&Doc| doc.conflict.is_some();
        if let Some(doc) = self.docs.values().find(unsettled) {
            return Err(CoreError::conflict(messages::changed_on_disk(&doc.path)));
        }
        self.docs.save_first(&mut self.core)?;
        self.close_hidden();
        let shown = self.docs.open.as_ref().and_then(|path| self.docs.get(path));
        Ok(shown.map(|doc| {
            let (text, version) = doc.doc.snapshot();
            OpenText {
                path: doc.path.clone(),
                text,
                version,
            }
        }))
    }

    /// Saves first, so the version taken before the edits has every change, and plans the edits once it's taken,
    /// against what's open then.
    fn edit_project(
        &mut self,
        chosen: impl Fn(&str) -> bool + Send + 'static,
        found: impl Fn(&str, &str) -> Vec<Place> + Send + 'static,
        to: String,
    ) -> Result<Then<ProjectEdits>, CoreError> {
        self.text_to_edit()?;
        Ok(Box::new(move |actor, snapshot| {
            let open = actor.text_to_edit()?;
            let edits = open
                .as_ref()
                .filter(|open| chosen(&open.path))
                .and_then(|open| {
                    let lines = Text::new(&open.text).lines;
                    let edit = |place: Place| TextEdit {
                        start: lines[place.line as usize - 1] + place.column,
                        length: place.length,
                        text: to.clone(),
                    };
                    let edits: Vec<TextEdit> = found(&open.path, &open.text)
                        .into_iter()
                        .map(edit)
                        .collect();
                    (!edits.is_empty()).then(|| DocumentEdits {
                        path: open.path.clone(),
                        version: open.version,
                        edits,
                    })
                });
            let open_path = open.as_ref().map(|open| open.path.as_str());
            let written =
                projects::replace_in_files(&actor.core.project, open_path, &chosen, &found, &to)?;
            Ok(ProjectEdits {
                edits,
                written,
                snapshot,
            })
        }))
    }
}

pub(crate) struct OpenText {
    pub path: String,
    pub text: String,
    pub version: u64,
}
