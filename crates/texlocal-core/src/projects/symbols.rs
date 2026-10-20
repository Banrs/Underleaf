//! The labels and citation keys a project defines, for completion.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use super::skip_unreadable;
use super::tree::{file_kind, visit_files};
use crate::error::CoreError;
use crate::syntax::scan::strip_comment;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Symbols {
    pub citations: Vec<String>,
    pub labels: Vec<String>,
}

// Matched on the decoded text, not the raw bytes: in Unicode mode a byte that
// isn't UTF-8 (a Latin-1 umlaut) drops its entry, and `(?-u)` narrows `\s` to
// ASCII, which swallows a non-breaking space into the key.
static BIB_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@[0-9A-Za-z_]+\s*\{\s*([^,\s]+)\s*,").unwrap());
/// Not a bare prefix, as an inserted block's `fig:` is until it's filled in.
static LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\label\{([^}]*[^}:])\}").unwrap());
/// A thebibliography entry's key, which \cite takes as a .bib key.
static BIBITEM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\bibitem\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}").unwrap());

fn parse_symbols(bytes: &[u8], kind: &str) -> Symbols {
    let mut citations = Vec::new();
    let mut labels = Vec::new();
    let text = String::from_utf8_lossy(bytes);
    let found = |re: &Regex, text: &str, out: &mut Vec<String>| {
        out.extend(re.captures_iter(text).map(|m| m[1].to_string()));
    };
    if kind == "bib" {
        found(&BIB_KEY, &text, &mut citations);
    } else {
        for line in text.lines().map(strip_comment) {
            // Both start with a backslash.
            if !line.contains('\\') {
                continue;
            }
            found(&LABEL, line, &mut labels);
            found(&BIBITEM, line, &mut citations);
        }
    }
    Symbols { citations, labels }
}

/// The labels and citations of every .tex and .bib file, in file-name order,
/// which keeps completions stable, each at its first occurrence.
pub fn scan_symbols(root: &Path) -> Result<Symbols, CoreError> {
    let mut files = BTreeMap::new();
    visit_files(root, &mut |abs, rel| {
        let kind = file_kind(rel);
        if (kind == "bib" || kind == "tex")
            && let Some(bytes) = skip_unreadable(fs::read(abs))?
        {
            files.insert(rel.to_owned(), parse_symbols(&bytes, kind));
        }
        Ok(true)
    })?;
    fn dedup<'a>(symbols: impl Iterator<Item = &'a String>) -> Vec<String> {
        let mut seen = HashSet::new();
        symbols.filter(|s| seen.insert(*s)).cloned().collect()
    }
    Ok(Symbols {
        citations: dedup(files.values().flat_map(|s| &s.citations)),
        labels: dedup(files.values().flat_map(|s| &s.labels)),
    })
}
