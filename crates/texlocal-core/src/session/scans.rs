use std::collections::HashMap;
use std::sync::{Arc, PoisonError};

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::facts::Facts;
use texlocal_latex::logparse::LogItem;
use texlocal_latex::project::{self, Analysis, Scan};
use texlocal_latex::search::Query;
use texlocal_latex::syntax::{self, SymbolKind};
use texlocal_latex::{FileKind, file_kind};

use super::actor::Actor;
use super::documents::Shared;
use super::state::SessionSection;
use super::{Msg, Pending};
use crate::projects::{self, SearchGroup};
use crate::{CoreError, lock, tex};

#[derive(Serialize, JsonSchema)]
pub(crate) struct Usages {
    name: String,
    groups: Vec<SearchGroup>,
}

impl Actor {
    pub fn scan_symbols(&mut self) {
        self.symbols_seq += 1;
        let (seq, root, tx) = (self.symbols_seq, self.project.root.clone(), self.tx.clone());
        let (facts, docs) = (Arc::clone(&self.facts), self.docs.shared());
        let mut files: Vec<String> = self.tree.files.iter().cloned().collect();
        files.sort_unstable();
        let (service, main, edits) = (
            Arc::clone(&self.service),
            self.tree.main.clone(),
            self.edits,
        );
        let shown = self.open.clone();
        tokio::task::spawn_blocking(move || {
            let read = projects::scan_facts(&root, &facts, &texts(&docs));
            let installed = tex::installed(&service.tool_paths().0);
            let result = read.map(|read| {
                let scan = Scan::new(read, files, installed);
                let checks = main
                    .as_deref()
                    .map_or_else(Vec::new, |main| project::check(&scan, main));
                let analysis = project::analyze(&scan, main.as_deref(), shown.as_deref());
                Box::new((scan, checks, analysis))
            });
            let _ = tx.send(Msg::Symbols { seq, edits, result });
        });
    }

    pub fn symbols_done(
        &mut self,
        seq: u64,
        edits: u64,
        result: Result<Box<(Scan, Vec<LogItem>, Analysis)>, CoreError>,
    ) {
        if let Ok(scanned) = result
            && seq == self.symbols_seq
        {
            let (scan, checks, outline) = *scanned;
            *self.symbols.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(scan);
            self.checks_done(checks, edits);
            self.publish(SessionSection::Outline(Some(outline)));
        }
    }

    pub fn search(&self, query: Query, reply: Pending<Vec<SearchGroup>>) {
        let (root, docs) = (self.project.root.clone(), self.docs.shared());
        tokio::task::spawn_blocking(move || {
            let found = |_: &str, text: &str| query.places(text);
            let open = texts(&docs);
            let hits =
                projects::search_project(&root, &open, &texlocal_latex::is_text, &found, 100);
            reply.send(hits.map(projects::search_groups));
        });
    }

    pub fn usages(&self, path: &str, offset: u32, reply: Pending<Option<Usages>>) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(None));
        };
        let (root, docs) = (self.project.root.clone(), self.docs.shared());
        tokio::task::spawn_blocking(move || {
            let own = doc.facts();
            let symbol = doc.with(|source| source.symbol_at(&own, offset));
            let named = symbol.and_then(|(kind, name, file)| match kind {
                SymbolKind::File => Some((kind, file?)),
                kind => Some((kind, name)),
            });
            let Some((kind, name)) = named else {
                return reply.send(Ok(None));
            };
            let symbols = doc.symbols();
            let found = |rel: &str, text: &str| {
                let facts = Facts::read(text, file_kind(rel));
                syntax::usages(&facts, rel, kind, &name, |file| symbols.spelt(file))
            };
            let hits = projects::search_project(&root, &texts(&docs), &tex, &found, usize::MAX);
            let name = match kind {
                SymbolKind::Label => format!("\\label{{{name}}}"),
                SymbolKind::Citation => format!("\\cite{{{name}}}"),
                SymbolKind::Environment => format!("\\begin{{{name}}}"),
                _ => name,
            };
            let groups = hits.map(projects::search_groups);
            reply.send(groups.map(|groups| Some(Usages { name, groups })));
        });
    }
}

pub(super) fn tex(rel: &str) -> bool {
    matches!(file_kind(rel), FileKind::Tex | FileKind::Bib)
}

pub(super) fn texts(docs: &Shared) -> HashMap<String, String> {
    let docs = lock(docs).clone();
    docs.into_iter()
        .map(|(path, doc)| (path, doc.snapshot().0))
        .collect()
}
