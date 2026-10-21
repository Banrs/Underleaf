//! What a project's files define and refer to, for completion and definitions.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;

use super::skip_unreadable;
use super::tree::{file_kind, visit_files};
use crate::analyze::{Facts, Files, Named};
use crate::error::CoreError;
pub use crate::syntax::Symbols;

/// Their union over the project's .tex and .bib files, each read again only once it changes;
/// one an editor has open from its text in `open`.
pub fn scan_symbols(
    root: &Path,
    facts: &Files,
    open: &HashMap<String, String>,
) -> Result<Symbols, CoreError> {
    let mut files = BTreeMap::new();
    visit_files(root, &mut |abs, rel| {
        let kind = file_kind(rel);
        if !matches!(kind, "tex" | "bib") {
            return Ok(true);
        }
        let found = match open.get(rel) {
            Some(text) => Some(Arc::new(Facts::read(text, kind))),
            None => skip_unreadable(facts.facts(abs, rel))?,
        };
        files.extend(found.map(|found| (rel.to_owned(), found)));
        Ok(true)
    })?;
    facts.keep(files.keys());
    /// The first of each name, in the files' order.
    fn firsts<'a, T: Clone>(
        all: impl Iterator<Item = &'a T>,
        name: fn(&'a T) -> &'a str,
    ) -> Vec<T> {
        let mut seen = HashSet::new();
        all.filter(|item| seen.insert(name(item)))
            .cloned()
            .collect()
    }
    let all = || files.values().map(|facts| &**facts);
    let names = |named: Vec<Named>| named.into_iter().map(|named| named.name).collect();
    Ok(Symbols {
        citations: firsts(all().flat_map(|f| &f.citations), |c| &c.name),
        labels: names(firsts(all().flat_map(|f| &f.labels), |l| &l.name)),
        commands: firsts(all().flat_map(|f| &f.commands), |c| &c.name),
        environments: names(firsts(all().flat_map(|f| &f.environments), |e| &e.name)),
        by_file: files,
        ..Symbols::default()
    })
}
