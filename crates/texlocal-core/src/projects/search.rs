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
use super::tree::{file_kind, visit_files};
use crate::analyze::Place;
use crate::error::CoreError;
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

/// What a search or a replace looks for, in any case.
pub struct Query {
    /// Folded as each line is.
    text: String,
    chars: usize,
}

impl Query {
    pub fn new(text: &str) -> Self {
        let mut folded = String::new();
        lower_into(text, &mut folded);
        Self {
            chars: folded.chars().count(),
            text: folded,
        }
    }

    /// Each match in `line`, left to right and none inside another, as the chars it spans;
    /// `folded` is room for the line in any case.
    fn in_line(&self, line: &str, folded: &mut String) -> Vec<Range<usize>> {
        let mut found = Vec::new();
        if self.text.is_empty() {
            return found;
        }
        lower_into(line, folded);
        let (mut from, mut chars) = (0, 0);
        while let Some(at) = folded[from..].find(&self.text) {
            chars += folded[from..from + at].chars().count();
            found.push(chars..chars + self.chars);
            (from, chars) = (from + at + self.text.len(), chars + self.chars);
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

/// The first of `found`'s places on each line, which it gives in order, of each text file
/// `chosen` takes, given its text with line feeds alone, up to `limit` lines; a file `open`
/// holds is read as the editor has it there. A line ends where the editor's does, at a carriage
/// return alone too.
pub fn search_project(
    root: &Path,
    open: &HashMap<String, String>,
    chosen: &dyn Fn(&str) -> bool,
    found: &dyn Fn(&str, &str) -> Vec<Place>,
    limit: usize,
) -> Result<Vec<SearchHit>, CoreError> {
    let mut hits = Vec::new();
    visit_files(root, &mut |abs, rel| {
        if !chosen(rel) {
            return Ok(true);
        }
        let text = match open.get(rel) {
            Some(text) => Cow::Borrowed(text.as_str()),
            None => match read_capped(abs, rel)? {
                Some(bytes) => Cow::Owned(lf(lossy_string(bytes))),
                None => return Ok(true),
            },
        };
        let places = found(rel, &text);
        let lines: Vec<&str> = text.split('\n').collect();
        let mut last = 0;
        for place in places {
            if hits.len() >= limit {
                break;
            }
            if place.line == last {
                continue;
            }
            last = place.line;
            let chars: Vec<char> = lines[place.line as usize - 1].chars().collect();
            // The char `units` UTF-16 units into the line starts.
            let char_at = |units: u32| {
                let mut seen = 0;
                let before = |c: &&char| {
                    let before = seen < units;
                    seen += c.len_utf16() as u32;
                    before
                };
                chars.iter().take_while(before).count()
            };
            let at = char_at(place.column)..char_at(place.column + place.length);
            let text = |range: Range<usize>| chars[range].iter().collect::<String>();
            let start = at.start.saturating_sub(24);
            let ellipsis = if start > 0 { "…" } else { "" };
            let before = format!("{ellipsis}{}", text(start..at.start));
            let after = text(at.end..(at.end + 60).min(chars.len()));
            hits.push(SearchHit {
                file: rel.to_owned(),
                line: place.line,
                column: place.column,
                length: place.length,
                before: before.trim_start().to_string(),
                matched: text(at),
                after: after.trim_end().to_string(),
            });
        }
        Ok(hits.len() < limit)
    })?;
    Ok(hits)
}

/// `to` in place of what `found` finds in each file `chosen` takes of those a search walks,
/// given its text with line feeds alone, each written with its lines ending as they did:
/// `{file, count}` for each, in the order of their paths. One too large to search is left out;
/// one that isn't UTF-8, which writing would change, refuses them all before any is written,
/// and one that can't be written puts back those written before it.
pub(crate) fn replace_in_files(
    root: &Path,
    chosen: &dyn Fn(&str) -> bool,
    found: &dyn Fn(&str, &str) -> Vec<Place>,
    to: &str,
) -> Result<Vec<Value>, CoreError> {
    // The file replaced, how many, and the file as it was.
    let replace = |abs: &Path, rel: &str| -> Result<Option<(String, usize, String)>, CoreError> {
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
        Ok(Some((replaced(&file, &places, to), places.len(), file)))
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
    let writing: Result<(), CoreError> = edited.into_iter().try_for_each(|(rel, abs)| {
        if let Some((file, count, was)) = replace(&abs, &rel)? {
            write_creating(&abs, file.as_bytes())?;
            written.push((abs, was, json!({ "file": rel, "count": count })));
        }
        Ok(())
    });
    if let Err(err) = writing {
        // Each was just written where it is, so can be again; the error to tell is the one that
        // stopped the replace.
        for (abs, was, _) in &written {
            let _ = write_creating(abs, was.as_bytes());
        }
        return Err(err);
    }
    Ok(written.into_iter().map(|(.., done)| done).collect())
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
    use crate::projects::is_text;
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
        let bib = fs::File::options().write(true).open(root.join("big.bib"));
        bib.unwrap().set_len(SEARCH_FILE_MAX + 1).unwrap();
        let needle = |_: &str, text: &str| Query::new("needle").places(text);
        let hits = search_project(&root, &HashMap::new(), &is_text, &needle, 10).unwrap();
        let mut files: Vec<&str> = hits.iter().map(|hit| hit.file.as_str()).collect();
        files.sort_unstable();
        assert_eq!(files, ["big.bib", "notes.tex"]);
        big.set_len(SEARCH_FILE_MAX).unwrap();
        let at_the_cap = read_capped(&root.join("big.csv"), "big.csv").unwrap();
        assert!(at_the_cap.is_some());
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
            Query::new("cat").places(text)
        };
        let written = replace_in_files(&root, &|rel| rel == "a.tex", &found, "dog").unwrap();
        assert_eq!(written, [json!({ "file": "a.tex", "count": 2 })]);
        let disk = fs::read_to_string(root.join("a.tex")).unwrap();
        assert_eq!(disk, "dog, their dog");
    }

    /// A file refused partway, read only here, leaves those before it as they were.
    #[test]
    fn a_replace_that_cannot_write_a_file_puts_back_those_it_wrote() {
        let (_dir, root) = project();
        for name in ["a.tex", "b.tex"] {
            fs::write(root.join(name), "cat").unwrap();
        }
        let b = root.join("b.tex");
        let mut perms = fs::metadata(&b).unwrap().permissions();
        perms.set_readonly(true);
        fs::set_permissions(&b, perms.clone()).unwrap();
        let found = |_: &str, text: &str| Query::new("cat").places(text);
        let replaced = replace_in_files(&root, &|rel| rel != "main.tex", &found, "dog");
        assert_eq!(replaced.unwrap_err().status, 403);
        assert_eq!(fs::read_to_string(root.join("a.tex")).unwrap(), "cat");
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        fs::set_permissions(&b, perms).unwrap();
    }

    /// Apart from each other and in any case; in UTF-16 units, where the emoji is two.
    #[test]
    fn the_matcher_finds_every_match_on_a_line() {
        let text = "😀 Cat cat catalogue\nCAT_cat cat\naaaa";
        let places = |query: &str| -> Vec<(u32, u32)> {
            let found = Query::new(query).places(text);
            let at = |place: &Place| {
                assert_eq!(place.length as usize, query.len());
                (place.line, place.column)
            };
            found.iter().map(at).collect()
        };
        let every = [(1, 3), (1, 7), (1, 11), (2, 0), (2, 4), (2, 8)];
        assert_eq!(places("cat"), every);
        assert_eq!(places("aa"), [(3, 0), (3, 2)]);
    }
}
