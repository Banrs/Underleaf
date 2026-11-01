use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::facts::Place;
use texlocal_latex::{FileKind, file_kind, utf16};

use super::files::{Planned, inside, write_all};
use super::history::MAX_KEPT;
use super::read_capped;
use super::tree::visit_files;
use crate::error::CoreError;
use crate::messages;
use crate::{lf, lossy_string, newline};

const SEARCH_FILE_MAX: u64 = 8 << 20;

#[derive(Debug, Serialize, JsonSchema)]
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

#[derive(Debug, Serialize, JsonSchema)]
pub struct SearchGroup {
    pub file: String,
    pub hits: Vec<SearchHit>,
}

#[derive(Debug, Serialize, JsonSchema)]
pub struct Written {
    pub file: String,
    pub count: usize,
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

fn cap(rel: &str) -> u64 {
    match file_kind(rel) {
        FileKind::Tex | FileKind::Bib => u64::MAX,
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
            let line = lines[place.line as usize - 1];
            let byte = |units: u32| utf16::byte_offset(line, units as usize).unwrap_or(line.len());
            let (start, end) = (byte(place.column), byte(place.column + place.length));
            let from = line[..start]
                .char_indices()
                .rev()
                .nth(23)
                .map_or(0, |(at, _)| at);
            let to = line[end..]
                .char_indices()
                .nth(60)
                .map_or(line.len(), |(at, _)| end + at);
            let ellipsis = if from > 0 { "…" } else { "" };
            hits.push(SearchHit {
                file: rel.to_owned(),
                line: place.line,
                column: place.column,
                length: place.length,
                before: format!("{ellipsis}{}", &line[from..start])
                    .trim_start()
                    .to_owned(),
                matched: line[start..end].to_owned(),
                after: line[end..to].trim_end().to_owned(),
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
) -> Result<Vec<Written>, CoreError> {
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
            return Err(CoreError::bad_request(messages::not_utf8_file(rel)));
        }
        let now = replaced(&file, &places, to);
        if file.len().max(now.len()) as u64 > MAX_KEPT {
            return Err(CoreError::bad_request(messages::too_large_to_keep(rel)));
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
            done: Written { file: rel, count },
        });
        Ok(planned)
    })
}

fn replaced(file: &str, places: &[Place], to: &str) -> String {
    let to = &to.replace('\n', newline(file));
    let byte = |s: &str, units: u32| utf16::byte_offset(s, units as usize).unwrap_or(s.len());
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
