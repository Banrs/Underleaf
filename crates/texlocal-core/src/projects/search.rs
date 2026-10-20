//! Search across a project's text files.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;

use serde::Serialize;

use super::skip_unreadable;
use super::tree::{is_text, visit_files};
use crate::error::CoreError;

/// The largest file a search reads; a data set or log that size isn't where anyone looks.
const SEARCH_FILE_MAX: u64 = 8 << 20;

#[derive(Debug, Serialize)]
pub struct SearchHit {
    pub file: String,
    pub line: u32,
    /// Where the match starts in its line and how long it is, in UTF-16 units
    /// of the line's own text, as an editor counts them.
    pub column: u32,
    pub length: u32,
    pub before: String,
    #[serde(rename = "match")]
    pub matched: String,
    pub after: String,
}

#[derive(Debug, Serialize)]
pub struct SearchGroup {
    pub file: String,
    pub hits: Vec<SearchHit>,
}

pub fn search_groups(hits: Vec<SearchHit>) -> Vec<SearchGroup> {
    let mut groups: BTreeMap<String, Vec<SearchHit>> = BTreeMap::new();
    for hit in hits {
        groups.entry(hit.file.clone()).or_default().push(hit);
    }
    groups
        .into_iter()
        .map(|(file, hits)| SearchGroup { file, hits })
        .collect()
}

// Keep one folded character per original character so snippet offsets agree.
// ASCII, most of a TeX file, folds without Unicode's tables.
fn lower_into(s: &str, out: &mut String) {
    out.clear();
    out.extend(s.chars().map(|c| {
        if c.is_ascii() {
            c.to_ascii_lowercase()
        } else {
            c.to_lowercase().next().unwrap_or(c)
        }
    }));
}

fn read_searchable(path: &Path) -> Result<Option<String>, CoreError> {
    let Some(file) = skip_unreadable(File::open(path))? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    let Some(len) = skip_unreadable(file.take(SEARCH_FILE_MAX + 1).read_to_end(&mut bytes))? else {
        return Ok(None);
    };
    Ok((len as u64 <= SEARCH_FILE_MAX).then(|| crate::lossy_string(bytes)))
}

pub fn search_project(root: &Path, query: &str, limit: usize) -> Result<Vec<SearchHit>, CoreError> {
    let mut q = String::new();
    lower_into(query, &mut q);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let q_len = q.chars().count();
    let mut hits: Vec<SearchHit> = Vec::new();
    let mut lower = String::new();
    visit_files(root, &mut |abs, rel| {
        if !is_text(rel) {
            return Ok(true);
        }
        let Some(text) = read_searchable(abs)? else {
            return Ok(true);
        };
        for (i, line) in text.split('\n').enumerate() {
            if hits.len() >= limit {
                break;
            }
            lower_into(line, &mut lower);
            let Some(at) = lower.find(&q) else {
                continue;
            };
            let col = lower[..at].chars().count();
            let chars: Vec<char> = line.chars().collect();
            let start = col.saturating_sub(24);
            let ellipsis = if start > 0 { "…" } else { "" };
            let before: String = chars[start..col].iter().collect();
            let matched: String = chars[col..col + q_len].iter().collect();
            let after_end = (col + q_len + 60).min(chars.len());
            let after: String = chars[col + q_len..after_end].iter().collect();
            let utf16 = |cs: &[char]| -> u32 { cs.iter().map(|c| c.len_utf16() as u32).sum() };
            hits.push(SearchHit {
                file: rel.to_owned(),
                line: (i + 1) as u32,
                column: utf16(&chars[..col]),
                length: utf16(&chars[col..col + q_len]),
                before: format!("{ellipsis}{before}").trim_start().to_string(),
                matched,
                after: after.trim_end().to_string(),
            });
        }
        Ok(hits.len() < limit)
    })?;
    Ok(hits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::project;
    use std::fs;

    #[test]
    fn a_search_skips_a_file_too_large_to_read_and_finds_what_is_in_the_rest() {
        let (_dir, root) = project();
        fs::write(root.join("notes.tex"), "a needle\n").unwrap();
        // Sparse: past the cap without writing it, and made of NULs that no
        // line break splits.
        let big = fs::File::create(root.join("big.csv")).unwrap();
        big.set_len(SEARCH_FILE_MAX + 1).unwrap();
        let hits = search_project(&root, "needle", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].file, "notes.tex");
        big.set_len(SEARCH_FILE_MAX).unwrap();
        assert!(read_searchable(&root.join("big.csv")).unwrap().is_some());
    }
}
