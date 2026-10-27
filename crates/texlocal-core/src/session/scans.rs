use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Value, json};
use texlocal_latex::analyze::{self, Facts};
use texlocal_latex::checks;
use texlocal_latex::file_kind;
use texlocal_latex::logparse::LogItem;
use texlocal_latex::syntax::{self, SymbolKind};

use super::actor::Actor;
use super::{Document, Msg, Reply};
use crate::projects::{self, Query, Symbols};
use crate::service::out;
use crate::{CoreError, lock, tex};

impl Actor {
    pub fn scan_symbols(&mut self) {
        self.symbols_seq += 1;
        let (seq, root, tx) = (self.symbols_seq, self.project.root.clone(), self.tx.clone());
        let (facts, docs) = (Arc::clone(&self.facts), Arc::clone(&self.shared));
        let mut files: Vec<String> = self.tree.files.iter().cloned().collect();
        files.sort_unstable();
        let (service, main, edits) = (
            Arc::clone(&self.service),
            self.tree.main.clone(),
            self.edits,
        );
        let shown = self.docs.values().find(|doc| doc.doc.id() == self.shown);
        let shown = shown.map(|doc| doc.path.clone());
        tokio::task::spawn_blocking(move || {
            let symbols = projects::scan_symbols(&root, &facts, &texts(&docs));
            let installed = tex::installed(&service.tool_paths().0);
            let result = symbols.and_then(|symbols| {
                let symbols = Symbols {
                    files,
                    installed,
                    ..symbols
                };
                let checks = main
                    .as_deref()
                    .map_or_else(Vec::new, |main| checks::check(&symbols, main));
                let analysis =
                    analyze::analyze_project(&symbols, main.as_deref(), shown.as_deref());
                let outline = out(&analysis)?;
                Ok(Box::new((symbols, checks, outline)))
            });
            let _ = tx.send(Msg::Symbols { seq, edits, result });
        });
    }

    pub fn symbols_done(
        &mut self,
        seq: u64,
        edits: u64,
        result: Result<Box<(Symbols, Vec<LogItem>, Value)>, CoreError>,
    ) {
        if let Ok(scanned) = result
            && seq == self.symbols_seq
        {
            let (symbols, checks, outline) = *scanned;
            *self.symbols.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(symbols);
            self.checks_done(checks, edits);
            if outline != self.outline {
                self.emit("outline", outline.clone());
                self.outline = outline;
            }
        }
    }

    pub fn search(&self, query: Query, reply: Reply) {
        let (root, docs) = (self.project.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            let found = |_: &str, text: &str| query.places(text);
            let open = texts(&docs);
            let hits =
                projects::search_project(&root, &open, &texlocal_latex::is_text, &found, 100);
            reply.send(hits.and_then(|hits| out(projects::search_groups(hits))));
        });
    }

    pub fn usages(&self, path: &str, offset: u32, reply: Reply) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(Value::Null));
        };
        let (root, docs) = (self.project.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            let own = doc.facts();
            let symbol = doc.with(|source| source.symbol_at(&own, offset));
            let named = symbol.and_then(|(kind, name, file)| match kind {
                SymbolKind::File => Some((kind, file?)),
                kind => Some((kind, name)),
            });
            let Some((kind, name)) = named else {
                return reply.send(Ok(Value::Null));
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
            reply.send(groups.map(|groups| json!({ "name": name, "groups": groups })));
        });
    }
}

pub(super) fn tex(rel: &str) -> bool {
    matches!(file_kind(rel), "tex" | "bib")
}

pub(super) fn texts(docs: &Mutex<HashMap<String, Document>>) -> HashMap<String, String> {
    let docs = lock(docs).clone();
    docs.into_iter()
        .map(|(path, doc)| (path, doc.snapshot().0))
        .collect()
}
