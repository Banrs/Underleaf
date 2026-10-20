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
    fn dedup<'a>(symbols: impl Iterator<Item = &'a String>) -> Vec<String> {
        let mut seen = HashSet::new();
        symbols.filter(|s| seen.insert(*s)).cloned().collect()
    }
    Ok(Symbols {
        citations: dedup(files.values().flat_map(|f| &f.citations)),
        labels: dedup(files.values().flat_map(|f| &f.labels)),
        ..Symbols::default()
    })
}
