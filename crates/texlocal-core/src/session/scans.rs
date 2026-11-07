use std::collections::HashMap;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::facts::Facts;
use texlocal_latex::search::Query;
use texlocal_latex::syntax::{self, SymbolKind};
use texlocal_latex::{FileKind, file_kind};

use super::actor::Actor;
use super::{Document, Pending};
use crate::projects::{self, SearchGroup};

#[derive(Serialize, JsonSchema)]
pub(crate) struct Usages {
    name: String,
    groups: Vec<SearchGroup>,
}

impl Actor {
    pub fn search(&self, query: Query, reply: Pending<Vec<SearchGroup>>) {
        let (project, docs) = (self.core.project.clone(), self.docs.handles());
        tokio::task::spawn_blocking(move || {
            let found = |_: &str, text: &str| query.places(text);
            let open = texts(&docs);
            let hits =
                projects::search_project(&project, &open, &texlocal_latex::is_text, &found, 100);
            reply.send(hits.map(projects::search_groups));
        });
    }

    pub fn usages(&self, path: &str, offset: u32, reply: Pending<Option<Usages>>) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(None));
        };
        let (project, docs) = (self.core.project.clone(), self.docs.handles());
        tokio::task::spawn_blocking(move || {
            let symbol = doc.with(|source| source.symbol_at(offset));
            let named = symbol.and_then(|(kind, name, file)| match kind {
                SymbolKind::File => Some((kind, file?)),
                kind => Some((kind, name)),
            });
            let Some((kind, name)) = named else {
                return reply.send(Ok(None));
            };
            let symbols = doc.symbols();
            let found = |rel: &str, text: &str| {
                if !may_name(kind, &name, text) {
                    return Vec::new();
                }
                let facts = Facts::read(text, file_kind(rel));
                syntax::usages(&facts, rel, kind, &name, |file| symbols.spelt(file))
            };
            let hits = projects::search_project(&project, &texts(&docs), &tex, &found, usize::MAX);
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

/// A label or citation is a slice of the text naming it, so a text without the name needn't be read.
pub(super) fn may_name(kind: SymbolKind, name: &str, text: &str) -> bool {
    !matches!(kind, SymbolKind::Label | SymbolKind::Citation) || text.contains(name)
}

pub(super) fn tex(rel: &str) -> bool {
    matches!(file_kind(rel), FileKind::Tex | FileKind::Bib)
}

pub(super) fn texts(docs: &HashMap<String, Document>) -> HashMap<String, String> {
    let texts = docs
        .iter()
        .map(|(path, doc)| (path.clone(), doc.snapshot().0));
    texts.collect()
}
