//! Search across a project's text files, and replacing what is found in them.

use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::io::Read;
use std::ops::Range;
use std::path::Path;

use serde::Serialize;
use serde_json::{Value, json};

use super::files::write_creating;
use super::skip_unreadable;
use super::tree::{file_kind, is_text, visit_files};
use crate::analyze::Place;
use crate::error::CoreError;
use crate::syntax::{Text, TextEdit};
use crate::{lf, lossy_string};

/// The largest file but a .tex or .bib that a search reads; a data set or log that size isn't
/// where anyone looks.
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

/// What a search or a replace looks for: `text`, in any case unless `match_case`, and with
/// `whole_word` only where neither end runs on into a letter, digit or underscore.
pub struct Query {
    /// Folded as each line is, unless the case must match.
    text: String,
    chars: usize,
    match_case: bool,
    whole_word: bool,
}

impl Query {
    pub fn new(text: &str, match_case: bool, whole_word: bool) -> Self {
        let mut folded = String::new();
        if match_case {
            folded.push_str(text);
        } else {
            lower_into(text, &mut folded);
        }
        Self {
            chars: folded.chars().count(),
            text: folded,
            match_case,
            whole_word,
        }
    }

    /// Each match in `line`, left to right and none inside another, as the chars it spans;
    /// `folded` is room for the line in any case.
    fn in_line(&self, line: &str, folded: &mut String) -> Vec<Range<usize>> {
        let mut found = Vec::new();
        if self.text.is_empty() {
            return found;
        }
        let line = if self.match_case {
            line
        } else {
            lower_into(line, folded);
            folded.as_str()
        };
        let word = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
        let apart = |outside, inside| !(word(outside) && word(inside));
        let (first, last) = (self.text.chars().next(), self.text.chars().next_back());
        let (mut from, mut chars) = (0, 0);
        while let Some(at) = line[from..].find(&self.text) {
            let (at, end) = (from + at, from + at + self.text.len());
            chars += line[from..at].chars().count();
            if !self.whole_word
                || apart(line[..at].chars().next_back(), first)
                    && apart(line[end..].chars().next(), last)
            {
                found.push(chars..chars + self.chars);
                (from, chars) = (end, chars + self.chars);
            } else {
                // A match that stands alone may start inside this one.
                from = at + first.map_or(1, char::len_utf8);
                chars += 1;
            }
        }
        found
    }

    /// Every match in `text`: its line, from 1, and its column and length in UTF-16 units of
    /// the line, as the editors count them.
    pub fn places(&self, text: &str) -> Vec<Place> {
        let (mut places, mut folded) = (Vec::new(), String::new());
        for (i, line) in text.split('\n').enumerate() {
            let found = self.in_line(line, &mut folded);
            if found.is_empty() {
                continue;
            }
            let chars: Vec<char> = line.chars().collect();
            places.extend(found.into_iter().map(|at| Place {
                line: i as u32 + 1,
                column: utf16(&chars[..at.start]),
                length: utf16(&chars[at]),
            }));
        }
        places
    }
}

fn utf16(chars: &[char]) -> u32 {
    chars.iter().map(|c| c.len_utf16() as u32).sum()
}

/// A file's bytes, or None if it can't be read or is too large to be where anyone looks; a
/// .tex or .bib file is read at any size, as the symbols are, since a shared bibliography can
/// be larger and a rename must reach its keys.
fn read_capped(abs: &Path, rel: &str) -> Result<Option<Vec<u8>>, CoreError> {
    let Some(file) = skip_unreadable(File::open(abs))? else {
        return Ok(None);
    };
    let cap = match file_kind(rel) {
        "tex" | "bib" => u64::MAX,
        _ => SEARCH_FILE_MAX,
    };
    let mut bytes = Vec::new();
    let Some(len) = skip_unreadable(file.take(cap.saturating_add(1)).read_to_end(&mut bytes))?
    else {
        return Ok(None);
    };
    Ok((len as u64 <= cap).then_some(bytes))
}

/// The first `limit` lines with a match, each with its first; a file `open` holds is read
/// as the editor has it there. A line ends where the editor's does, at a carriage return
/// alone too.
pub fn search_project(
    root: &Path,
    query: &Query,
    open: &HashMap<String, String>,
    limit: usize,
) -> Result<Vec<SearchHit>, CoreError> {
    if query.text.is_empty() {
        return Ok(Vec::new());
    }
    let (mut hits, mut folded) = (Vec::new(), String::new());
    visit_files(root, &mut |abs, rel| {
        if !is_text(rel) {
            return Ok(true);
        }
        let text = match open.get(rel) {
            Some(text) => Cow::Borrowed(text.as_str()),
            None => match read_capped(abs, rel)? {
                Some(bytes) => Cow::Owned(lf(lossy_string(bytes))),
                None => return Ok(true),
            },
        };
        for (i, line) in text.split('\n').enumerate() {
            if hits.len() >= limit {
                break;
            }
            let Some(at) = query.in_line(line, &mut folded).into_iter().next() else {
                continue;
            };
            let chars: Vec<char> = line.chars().collect();
            let start = at.start.saturating_sub(24);
            let ellipsis = if start > 0 { "…" } else { "" };
            let before: String = chars[start..at.start].iter().collect();
            let after: String = chars[at.end..(at.end + 60).min(chars.len())]
                .iter()
                .collect();
            hits.push(SearchHit {
                file: rel.to_owned(),
                line: i as u32 + 1,
                column: utf16(&chars[..at.start]),
                length: utf16(&chars[at.clone()]),
                before: format!("{ellipsis}{before}").trim_start().to_string(),
                matched: chars[at].iter().collect(),
                after: after.trim_end().to_string(),
            });
        }
        Ok(hits.len() < limit)
    })?;
    Ok(hits)
}

/// `to` in place of each of `places`, which are in order, as edits of `text` in UTF-16 offsets.
pub(crate) fn edits(text: &Text, places: &[Place], to: &str) -> Vec<TextEdit> {
    let edit = |place: &Place| TextEdit {
        start: text.lines[place.line as usize - 1] + place.column,
        length: place.length,
        text: to.to_owned(),
    };
    places.iter().map(edit).collect()
}

/// `to` in place of what `found` finds in each file `chosen` takes of those a search walks,
/// given its text with line feeds alone, each written with its lines ending as they did:
/// `{file, count}` for each, in the order of their paths. One too large to search is left out;
/// one that isn't UTF-8, which writing would change, refuses them all before any is written.
pub(crate) fn replace_in_files(
    root: &Path,
    chosen: &dyn Fn(&str) -> bool,
    found: &dyn Fn(&str, &str) -> Vec<Place>,
    to: &str,
) -> Result<Vec<Value>, CoreError> {
    let replace = |abs: &Path, rel: &str| -> Result<Option<(String, usize)>, CoreError> {
        let Some(bytes) = read_capped(abs, rel)? else {
            return Ok(None);
        };
        let (file, utf8) = match String::from_utf8(bytes) {
            Ok(file) => (file, true),
            Err(err) => (String::from_utf8_lossy(err.as_bytes()).into_owned(), false),
        };
        let places = found(rel, &lf(file.clone()));
        if places.is_empty() {
            return Ok(None);
        }
        if !utf8 {
            return Err(CoreError::bad_request(format!(
                "“{rel}” isn't UTF-8 text, and writing it would change it, so nothing was changed. Convert it to UTF-8 to edit it."
            )));
        }
        Ok(Some((replaced(&file, &places, to), places.len())))
    };
    let mut edited = BTreeMap::new();
    visit_files(root, &mut |abs, rel| {
        if chosen(rel) && replace(abs, rel)?.is_some() {
            edited.insert(rel.to_owned(), abs.to_owned());
        }
        Ok(true)
    })?;
    // Each read again as it's written: another app may have written it while the rest were read.
    let mut written = Vec::new();
    for (rel, abs) in edited {
        if let Some((file, count)) = replace(&abs, &rel)? {
            write_creating(&abs, file.as_bytes())?;
            written.push(json!({ "file": rel, "count": count }));
        }
    }
    Ok(written)
}

/// `to` in place of each of `places`, which are in order, in `file` as written: a place's line
/// and column count as they do with line feeds alone, so each line keeps its own ending, which
/// in a file edited on more than one system needn't be the first's.
fn replaced(file: &str, places: &[Place], to: &str) -> String {
    // The byte the first `units` UTF-16 units of `s` end at.
    let byte = |s: &str, units: u32| {
        let mut seen = 0;
        let mut chars = s.char_indices();
        let past = chars.find(|&(_, c)| {
            let past = seen >= units;
            seen += c.len_utf16() as u32;
            past
        });
        past.map_or(s.len(), |(i, _)| i)
    };
    let (mut out, mut line, mut start, mut copied) = (String::new(), 1, 0, 0);
    for place in places {
        while line < place.line {
            let end = start + file[start..].find(['\r', '\n']).expect("the place's line");
            start = end + 1 + usize::from(file[end..].starts_with("\r\n"));
            line += 1;
        }
        let at = start + byte(&file[start..], place.column);
        out.push_str(&file[copied..at]);
        out.push_str(to);
        copied = at + byte(&file[at..], place.length);
    }
    out.push_str(&file[copied..]);
    out
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
        // line break splits. A bibliography that large is read, as the symbols are, so a rename
        // finds its keys.
        let big = fs::File::create(root.join("big.csv")).unwrap();
        big.set_len(SEARCH_FILE_MAX + 1).unwrap();
        fs::write(root.join("big.bib"), "@misc{needle,}\n").unwrap();
        let bib = fs::OpenOptions::new()
            .write(true)
            .open(root.join("big.bib"));
        bib.unwrap().set_len(SEARCH_FILE_MAX + 1).unwrap();
        let needle = Query::new("needle", false, false);
        let hits = search_project(&root, &needle, &HashMap::new(), 10).unwrap();
        let mut files: Vec<&str> = hits.iter().map(|hit| hit.file.as_str()).collect();
        files.sort_unstable();
        assert_eq!(files, ["big.bib", "notes.tex"]);
        big.set_len(SEARCH_FILE_MAX).unwrap();
        assert!(
            read_capped(&root.join("big.csv"), "big.csv")
                .unwrap()
                .is_some()
        );
    }

    /// Another app's write while the replace reads the project is kept, not written over.
    #[test]
    fn a_replace_reads_each_file_again_as_it_writes_it() {
        let (_dir, root) = project();
        fs::write(root.join("a.tex"), "cat").unwrap();
        let other_app = std::cell::Cell::new(true);
        let found = |_: &str, text: &str| {
            if other_app.replace(false) {
                fs::write(root.join("a.tex"), "cat, their cat").unwrap();
            }
            Query::new("cat", false, false).places(text)
        };
        let written = replace_in_files(&root, &|rel| rel == "a.tex", &found, "dog").unwrap();
        assert_eq!(written, [json!({ "file": "a.tex", "count": 2 })]);
        let disk = fs::read_to_string(root.join("a.tex")).unwrap();
        assert_eq!(disk, "dog, their dog");
    }

    /// Apart from each other, in any case or in the query's, and as whole words or not; in
    /// UTF-16 units, where the emoji is two.
    #[test]
    fn the_matcher_finds_every_match_on_a_line() {
        let text = "😀 Cat cat catalogue\nCAT_cat cat\naaaa";
        let places = |query: &str, match_case, whole_word| -> Vec<(u32, u32)> {
            let found = Query::new(query, match_case, whole_word).places(text);
            assert!(
                found
                    .iter()
                    .all(|place| place.length as usize == query.len())
            );
            found
                .iter()
                .map(|place| (place.line, place.column))
                .collect()
        };
        let every = [(1, 3), (1, 7), (1, 11), (2, 0), (2, 4), (2, 8)];
        assert_eq!(places("cat", false, false), every);
        assert_eq!(
            places("cat", true, false),
            [(1, 7), (1, 11), (2, 4), (2, 8)]
        );
        assert_eq!(places("cat", false, true), [(1, 3), (1, 7), (2, 8)]);
        assert_eq!(places("aa", false, false), [(3, 0), (3, 2)]);
    }
}
