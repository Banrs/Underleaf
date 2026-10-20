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
        if !matches!(file_kind(rel), "tex" | "bib") {
            return Ok(true);
        }
        let found = match open.get(rel) {
            Some(text) => Some(Arc::new(Facts::read(text, file_kind(rel)))),
            None => skip_unreadable(facts.facts(abs, rel))?,
        };
        if let Some(found) = found {
            files.insert(rel.to_owned(), found);
        }
        Ok(true)
    })?;
    facts.keep(files.keys());
    /// The first of each name.
    fn dedup<'a, T: Clone>(
        symbols: impl Iterator<Item = &'a T>,
        name: fn(&'a T) -> &'a str,
    ) -> Vec<T> {
        let mut seen = HashSet::new();
        symbols.filter(|s| seen.insert(name(s))).cloned().collect()
    }
    fn names(list: &[Named]) -> impl Iterator<Item = &String> {
        list.iter().map(|named| &named.name)
    }
    let all = files.values();
    Ok(Symbols {
        citations: dedup(all.clone().flat_map(|f| &f.citations), |c| &c.name),
        labels: dedup(all.clone().flat_map(|f| names(&f.labels)), String::as_str),
        commands: dedup(all.clone().flat_map(|f| &f.commands), |c| &c.name),
        environments: dedup(all.flat_map(|f| names(&f.environments)), String::as_str),
        by_file: files,
        ..Symbols::default()
    })
}
