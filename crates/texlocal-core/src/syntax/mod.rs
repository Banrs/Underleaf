//! LaTeX editing logic for the editors, as ranges and edits for the editor to apply. A `SourceDocument` mirrors the
//! editor's text and answers in UTF-16 offsets, which NSString and WinUI count in. Its commands are its methods,
//! each in the file of its kind.

mod call;
pub(crate) mod catalog;
mod complete;
mod edit;
pub(crate) mod headings;
mod highlight;
mod preview;
pub(crate) mod prose;
pub(crate) mod render;
pub(crate) mod scan;
mod scans;
mod snippet;
mod stack;
mod style;
pub(crate) mod theme;
mod typing;

#[cfg(test)]
mod tests;

use std::sync::Arc;

use serde::{Deserialize, Serialize};

pub use call::call;
use complete::SnippetField;
pub use complete::{SymbolKind, Symbols};
use highlight::Highlight;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[repr(C)]
pub struct TextRange {
    pub start: u32,
    pub length: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextEdit {
    pub start: u32,
    pub length: u32,
    pub text: String,
}

impl TextRange {
    fn bounds(self) -> (usize, usize) {
        let start = self.start as usize;
        (start, start + self.length as usize)
    }
}

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
}

fn edit(start: u32, length: u32, text: impl Into<String>) -> TextEdit {
    TextEdit {
        start,
        length,
        text: text.into(),
    }
}

fn span(start: usize, length: usize) -> TextRange {
    range(start as u32, length as u32)
}

fn splice(start: usize, length: usize, text: impl Into<String>) -> TextEdit {
    edit(start as u32, length as u32, text)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Checker {
    Spelling,
    WritingTools,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Insertion {
    pub edit: TextEdit,
    pub caret: u32,
    pub fields: Vec<SnippetField>,
}

const NEWLINE: u16 = b'\n' as u16;
const CARRIAGE_RETURN: u16 = b'\r' as u16;

#[derive(Clone, Copy)]
pub(crate) struct Line {
    pub start: usize,
    pub end: usize,
    pub next: usize,
}

pub(crate) struct Text {
    pub units: Vec<u16>,
    pub lines: Vec<u32>,
}

fn line_starts(units: &[u16], at: u32) -> impl Iterator<Item = u32> + '_ {
    units
        .iter()
        .enumerate()
        .filter(|&(_, &u)| u == NEWLINE)
        .map(move |(i, _)| at + i as u32 + 1)
}

impl Text {
    pub(crate) fn new(text: &str) -> Self {
        let units: Vec<u16> = text.encode_utf16().collect();
        let lines = std::iter::once(0).chain(line_starts(&units, 0)).collect();
        Self { units, lines }
    }

    fn len(&self) -> u32 {
        self.units.len() as u32
    }

    pub fn line_index(&self, offset: u32) -> usize {
        self.lines.partition_point(|&start| start <= offset) - 1
    }

    /// A carriage return before a line feed is part of the break, so a CRLF file has a LF file's lines.
    pub fn bounds(&self, index: usize) -> Line {
        let start = self.lines[index] as usize;
        let last = index + 1 == self.lines.len();
        let next = self
            .lines
            .get(index + 1)
            .map_or(self.units.len(), |&next| next as usize);
        let mut end = if last { next } else { next - 1 };
        if end > start && self.units[end - 1] == CARRIAGE_RETURN {
            end -= 1;
        }
        Line { start, end, next }
    }

    pub fn around(&self, offset: usize) -> Line {
        self.bounds(self.line_index(offset as u32))
    }

    pub fn line(&self, index: usize) -> &[u16] {
        let Line { start, end, .. } = self.bounds(index);
        &self.units[start..end]
    }

    fn replace(&mut self, start: u32, length: u32, text: &[u16]) -> usize {
        let end = start + length;
        let first = self.lines.partition_point(|&s| s <= start);
        let last = self.lines.partition_point(|&s| s <= end);
        let delta = text.len() as i64 - length as i64;
        for line in &mut self.lines[last..] {
            *line = (*line as i64 + delta) as u32;
        }
        self.lines.splice(first..last, line_starts(text, start));
        self.units
            .splice(start as usize..end as usize, text.iter().copied());
        first
    }
}

pub struct SourceDocument {
    text: Text,
    highlighter: highlight::Cache,
    scans: scans::Scans,
    symbols: Arc<Symbols>,
    typing: typing::Typing,
    /// The project's name for the file, which its own definitions are placed in; none for a
    /// source of the editor's own.
    pub(crate) path: String,
}

impl SourceDocument {
    pub fn new(text: &str) -> Self {
        Self {
            text: Text::new(text),
            highlighter: highlight::Cache::default(),
            scans: scans::Scans::default(),
            symbols: Arc::default(),
            typing: typing::Typing::default(),
            path: String::new(),
        }
    }

    pub(crate) fn named(text: &str, path: &str) -> Self {
        Self {
            path: path.to_owned(),
            ..Self::new(text)
        }
    }

    /// Kept here rather than sent with each completions call: a bibliography is thousands of keys.
    pub fn set_symbols(&mut self, symbols: Arc<Symbols>) {
        self.symbols = symbols;
    }

    /// A range past the end is cut to the text: the mirror never fails the editor.
    pub fn edit(&mut self, start: u32, length: u32, text: &str) {
        let start = start.min(self.text.len());
        let length = length.min(self.text.len() - start);
        let units: Vec<u16> = text.encode_utf16().collect();
        let first = self.text.replace(start, length, &units);
        self.highlighter.forget_from(first);
        self.scans.forget_from(start as usize);
    }

    pub fn text(&self) -> String {
        crate::utf16_lossy(&self.text.units)
    }

    pub fn line_at(&self, offset: u32) -> u32 {
        self.text.line_index(offset) as u32 + 1
    }

    pub fn line_start(&self, line: u32) -> u32 {
        let index = (line.max(1) as usize - 1).min(self.text.lines.len() - 1);
        self.text.lines[index]
    }

    pub fn line_count(&self) -> u32 {
        self.text.lines.len() as u32
    }

    pub fn highlights(&mut self, start: u32, length: u32) -> Vec<Highlight> {
        let end = start.saturating_add(length).min(self.text.len());
        self.highlighter.highlights(&self.text, start.min(end), end)
    }

    /// Not as the start of a longer name, nor after a backslash that is itself a command's (`\\foo` is a line break
    /// and a word), nor in a comment.
    pub fn command_ranges(&self, line: u32, command: &str) -> Vec<TextRange> {
        let index = line.max(1) as usize - 1;
        let name: Vec<u16> = command.encode_utf16().collect();
        if index >= self.text.lines.len() || name.is_empty() {
            return vec![];
        }
        let units = self.text.line(index);
        // TeX's letters, with `@` as in a class's or a package's own source.
        let tex_letter = |u: u16| letter(u) || is(u, '@');
        let end = comment_start(units);
        let word = name.get(1).is_some_and(|&u| tex_letter(u));
        let (mut found, mut from) = (vec![], 0);
        while let Some(at) = units[from..end].windows(name.len()).position(|w| w == name) {
            let at = from + at;
            from = at + name.len();
            let longer = word && units.get(from).is_some_and(|&u| tex_letter(u));
            if !escaped(units, at) && !longer {
                found.push(span(at, name.len()));
            }
        }
        found
    }

    /// They belong to a visit, not to the text.
    pub fn reset_typing(&mut self) {
        self.typing = typing::Typing::default();
    }
}

fn is(u: u16, c: char) -> bool {
    u == c as u16
}

fn escaped(units: &[u16], at: usize) -> bool {
    let slashes = units[..at]
        .iter()
        .rev()
        .take_while(|&&u| is(u, '\\'))
        .count();
    slashes % 2 == 1
}

/// A line alone can't tell a `%` that \verb or a verbatim environment holds.
fn comment_start(line: &[u16]) -> usize {
    let percent = |&i: &usize| is(line[i], '%') && !escaped(line, i);
    (0..line.len()).find(percent).unwrap_or(line.len())
}

const NAME: usize = 64;

fn ascii<'a>(units: &[u16], buf: &'a mut [u8; NAME]) -> &'a str {
    if units.len() > buf.len() || units.iter().any(|&u| u > 0x7f) {
        return "";
    }
    for (b, &u) in buf.iter_mut().zip(units) {
        *b = u as u8;
    }
    std::str::from_utf8(&buf[..units.len()]).unwrap_or_default()
}

fn letter(u: u16) -> bool {
    u < 128 && (u as u8).is_ascii_alphabetic()
}

fn indentation(line: &[u16]) -> usize {
    line.iter()
        .take_while(|&&u| is(u, ' ') || is(u, '\t'))
        .count()
}

fn utf16(s: &str) -> usize {
    s.encode_utf16().count()
}

fn clamp(selection: TextRange, len: u32) -> TextRange {
    let start = selection.start.min(len);
    range(start, selection.length.min(len - start))
}
