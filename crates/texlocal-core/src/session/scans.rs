use std::collections::HashMap;
use std::fs;
use std::path::Path;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::facts::{Facts, Place};
use texlocal_latex::search::Query;
use texlocal_latex::syntax::{self, SymbolKind};
use texlocal_latex::{file_kind, is_source};

use super::actor::Actor;
use super::{Document, Pending};
use crate::projects::{self, SearchGroup};
use crate::{lf, lossy_string, paths};

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
                usages_in(rel, text, kind, &name, |file| symbols.spelt(file))
            };
            let hits =
                projects::search_project(&project, &texts(&docs), &is_source, &found, usize::MAX);
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

/// Where a file's text uses the symbol. A label or citation is spelt out where it's used, so a text without its name
/// isn't parsed.
pub(super) fn usages_in(
    rel: &str,
    text: &str,
    kind: SymbolKind,
    name: &str,
    spelt: impl Fn(&str) -> Option<String>,
) -> Vec<Place> {
    if matches!(kind, SymbolKind::Label | SymbolKind::Citation) && !text.contains(name) {
        return Vec::new();
    }
    syntax::usages(&Facts::read(text, file_kind(rel)), rel, kind, name, spelt)
}

pub(super) fn texts(docs: &HashMap<String, Document>) -> HashMap<String, String> {
    let texts = docs
        .iter()
        .map(|(path, doc)| (path.clone(), doc.snapshot().0));
    texts.collect()
}

/// A file's text as the session sees it: the open document's, else the file on disk with its line endings made LF.
pub(super) fn current_text(
    docs: &HashMap<String, Document>,
    root: &Path,
    rel: &str,
) -> Option<String> {
    match docs.get(rel) {
        Some(doc) => Some(doc.snapshot().0),
        None => fs::read(paths::safe_path(root, rel).ok()?)
            .ok()
            .map(|bytes| lf(lossy_string(bytes))),
    }
}
