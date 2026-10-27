use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap};
use std::ops::Range;
use std::path::Path;

use serde::Serialize;
use serde_json::{Value, json};
use texlocal_latex::analyze::Place;
use texlocal_latex::file_kind;

use super::files::{Planned, inside, write_all};
use super::history::MAX_KEPT;
use super::read_capped;
use super::tree::visit_files;
use crate::error::CoreError;
use crate::{lf, lossy_string, newline};

const SEARCH_FILE_MAX: u64 = 8 << 20;

#[derive(Debug, Serialize)]
pub struct SearchHit {
    pub file: String,
    pub line: u32,
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

fn fold_into(s: &str, match_case: bool, out: &mut String) {
    out.clear();
    out.extend(s.chars().map(|c| match c {
        _ if match_case => c,
        c if c.is_ascii() => c.to_ascii_lowercase(),
        c => c.to_lowercase().next().unwrap_or(c),
    }));
}

pub struct Query {
    text: String,
    chars: usize,
    match_case: bool,
    whole_word: bool,
}

impl Query {
    pub fn new(text: &str, match_case: bool, whole_word: bool) -> Self {
        let mut folded = String::new();
        fold_into(text, match_case, &mut folded);
        Self {
            chars: folded.chars().count(),
            text: folded,
            match_case,
            whole_word,
        }
    }

    fn in_line(&self, line: &str, folded: &mut String) -> Vec<Range<usize>> {
        let mut found = Vec::new();
        if self.text.is_empty() {
            return found;
        }
        fold_into(line, self.match_case, folded);
        let word = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
        let (mut from, mut chars) = (0, 0);
        while let Some(at) = folded[from..].find(&self.text) {
            let (start, end) = (from + at, from + at + self.text.len());
            chars += folded[from..start].chars().count();
            if self.whole_word
                && (word(folded[..start].chars().next_back()) || word(folded[end..].chars().next()))
            {
                let next = folded[start..].chars().next().map_or(1, char::len_utf8);
                (from, chars) = (start + next, chars + 1);
                continue;
            }
            found.push(chars..chars + self.chars);
            (from, chars) = (end, chars + self.chars);
        }
        found
    }

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

fn cap(rel: &str) -> u64 {
    match file_kind(rel) {
        "tex" | "bib" => u64::MAX,
        _ => SEARCH_FILE_MAX,
    }
}

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
            None => match read_capped(abs, cap(rel))? {
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

pub(crate) fn replace_in_files(
    root: &Path,
    chosen: &dyn Fn(&str) -> bool,
    found: &dyn Fn(&str, &str) -> Vec<Place>,
    to: &str,
) -> Result<Vec<Value>, CoreError> {
    let replace = |abs: &Path, rel: &str| -> Result<Option<(String, usize, String)>, CoreError> {
        let Some(bytes) = read_capped(abs, cap(rel))? else {
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
        let now = replaced(&file, &places, to);
        if file.len().max(now.len()) as u64 > MAX_KEPT {
            return Err(CoreError::bad_request(format!(
                "“{rel}” is too large for the version history to keep, so nothing was changed, as it couldn’t be put back."
            )));
        }
        Ok(Some((now, places.len(), file)))
    };
    let mut edited = BTreeMap::new();
    visit_files(root, &mut |abs, rel| {
        if chosen(rel) && inside(root, abs) && replace(abs, rel)?.is_some() {
            edited.insert(rel.to_owned(), abs.to_owned());
        }
        Ok(true)
    })?;
    write_all(edited, |(rel, abs)| {
        let planned = replace(&abs, &rel)?.map(|(file, count, was)| Planned {
            abs,
            bytes: file.into_bytes(),
            was: Some(was.into_bytes()),
            done: json!({ "file": rel, "count": count }),
        });
        Ok(planned)
    })
}

fn replaced(file: &str, places: &[Place], to: &str) -> String {
    let to = &to.replace('\n', newline(file));
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
