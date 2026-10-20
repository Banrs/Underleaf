//! The labels and citation keys a project defines, for completion.

use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use super::skip_unreadable;
use super::tree::{file_kind, visit_files};
use crate::analyze::Files;
use crate::error::CoreError;
pub use crate::syntax::Symbols;

/// Their union over the project's .tex and .bib files, each read again only once it changes.
pub fn scan_symbols(root: &Path, facts: &Files) -> Result<Symbols, CoreError> {
    let mut files = BTreeMap::new();
    visit_files(root, &mut |abs, rel| {
        if matches!(file_kind(rel), "tex" | "bib")
            && let Some(found) = skip_unreadable(facts.facts(abs, rel))?
        {
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
    let all = files.values();
    Ok(Symbols {
        citations: dedup(all.clone().flat_map(|f| &f.citations), String::as_str),
        labels: dedup(all.clone().flat_map(|f| &f.labels), String::as_str),
        commands: dedup(all.clone().flat_map(|f| &f.commands), |c| &c.name),
        environments: dedup(all.flat_map(|f| &f.environments), String::as_str),
        ..Symbols::default()
    })
}
