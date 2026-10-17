//! LaTeX editing logic for the editors: highlighting, completion and the
//! editing commands, as ranges and edits for the editor to apply. The editor
//! owns the text, its undo and its drawing; a `SourceDocument` mirrors the
//! text through the editor's edits and answers in UTF-16 offsets, which
//! NSString and WinUI both count in. A session's open file
//! (`session::Document`) holds one, as does each of the FFI's own sources.
//! Its commands are its methods, each in the file of its kind: typing.rs
//! (keys and brackets), snippet.rs (the fields Tab goes through), edit.rs
//! (the menus' and shortcuts' commands) and complete.rs.

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

use serde::{Deserialize, Serialize};

pub use call::call;
pub use complete::{Completion, CompletionKind, Completions, SnippetField};
pub use edit::{Change, Style, map_selections};
pub use highlight::{Highlight, HighlightKind};
pub use preview::MathPreview;
pub use scan::math_mode_at;
pub use snippet::Tab;
pub use style::TextStyles;
pub use typing::{Completing, Keystroke};

/// A range of the text, in UTF-16 units; `TlRange` in the C ABI.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[repr(C)]
pub struct TextRange {
    pub start: u32,
    pub length: u32,
}

/// Replace `length` units at `start` with `text`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextEdit {
    pub start: u32,
    pub length: u32,
    pub text: String,
}

impl TextRange {
    /// Where it starts and ends, as indexes.
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

/// `range` and `edit` for the commands that count in indexes: the cast to
/// the API's UTF-16 offsets is made here, once.
fn span(start: usize, length: usize) -> TextRange {
    range(start as u32, length as u32)
}

fn splice(start: usize, length: usize, text: impl Into<String>) -> TextEdit {
    edit(start as u32, length as u32, text)
}

/// What asks for `SourceDocument::code_ranges`: the spelling checker or
/// Writing Tools.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Checker {
    Spelling,
    WritingTools,
}

/// An edit and where the caret goes after it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Insertion {
    pub edit: TextEdit,
    pub caret: u32,
    /// Where Tab goes in a block's text, as in a completion's.
    pub fields: Vec<SnippetField>,
}

const NEWLINE: u16 = b'\n' as u16;
const CARRIAGE_RETURN: u16 = b'\r' as u16;

/// A line's bounds in the text: where it starts, where its contents end and
/// where the next line starts (the text's end, for the last).
#[derive(Clone, Copy)]
pub(crate) struct Line {
    pub start: usize,
    pub end: usize,
    pub next: usize,
}

/// The editor's text and where its lines start (after each line feed).
pub(crate) struct Text {
    pub units: Vec<u16>,
    pub lines: Vec<u32>,
}

/// Where the lines after the line feeds in `units`, put at `at`, start.
fn line_starts(units: &[u16], at: u32) -> impl Iterator<Item = u32> + '_ {
    units
        .iter()
        .enumerate()
        .filter(|&(_, &u)| u == NEWLINE)
        .map(move |(i, _)| at + i as u32 + 1)
}

impl Text {
    fn new(text: &str) -> Self {
        let units: Vec<u16> = text.encode_utf16().collect();
        let lines = std::iter::once(0).chain(line_starts(&units, 0)).collect();
        Self { units, lines }
    }

    fn len(&self) -> u32 {
        self.units.len() as u32
    }

    /// The line an offset is on, from 0.
    pub fn line_index(&self, offset: u32) -> usize {
        self.lines.partition_point(|&start| start <= offset) - 1
    }

    /// Where a line starts, where its contents end and where the next line
    /// starts. Lines end at line feeds; a carriage return before one is part
    /// of the line break, so a CRLF file has the lines a LF file has.
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

    /// The line an offset is on.
    pub fn around(&self, offset: usize) -> Line {
        self.bounds(self.line_index(offset as u32))
    }

    /// A line's units, without its line break.
    pub fn line(&self, index: usize) -> &[u16] {
        let Line { start, end, .. } = self.bounds(index);
        &self.units[start..end]
    }

    /// Replaces a range, keeping the line starts; returns the first line
    /// whose start the edit may have moved.
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

/// An open file's text, mirrored from the editor, and the answers about it.
pub struct SourceDocument {
    text: Text,
    highlighter: highlight::Cache,
    /// Kept for the questions that read the text from its start.
    scans: scans::Scans,
    /// The project's, which "completions" offers in `\ref{` and `\cite{`.
    labels: Vec<String>,
    citations: Vec<String>,
    /// The closers and snippet fields typing keeps between keys.
    typing: typing::Typing,
}

impl SourceDocument {
    pub fn new(text: &str) -> Self {
        Self {
            text: Text::new(text),
            highlighter: highlight::Cache::default(),
            scans: scans::Scans::default(),
            labels: Vec::new(),
            citations: Vec::new(),
            typing: typing::Typing::default(),
        }
    }

    /// The project's labels and citations, which `call`'s "completions"
    /// offers until they are set again: kept here rather than sent with each
    /// key's completions, a bibliography being thousands of keys.
    pub fn set_symbols(&mut self, labels: Vec<String>, citations: Vec<String>) {
        (self.labels, self.citations) = (labels, citations);
    }

    /// The editor replaced `length` units at `start` with `text`. A range
    /// past the end is cut to the text: the mirror never fails the editor.
    pub fn edit(&mut self, start: u32, length: u32, text: &str) {
        let start = start.min(self.text.len());
        let length = length.min(self.text.len() - start);
        let units: Vec<u16> = text.encode_utf16().collect();
        let first = self.text.replace(start, length, &units);
        self.highlighter.forget_from(first);
        self.scans.forget_from(start as usize);
    }

    pub fn text(&self) -> String {
        String::from_utf16_lossy(&self.text.units)
    }

    /// The line an offset is on, from 1.
    pub fn line_at(&self, offset: u32) -> u32 {
        self.text.line_index(offset) as u32 + 1
    }

    /// Where a line (from 1) starts; past the last line, the last line's start.
    pub fn line_start(&self, line: u32) -> u32 {
        let index = (line.max(1) as usize - 1).min(self.text.lines.len() - 1);
        self.text.lines[index]
    }

    pub fn line_count(&self) -> u32 {
        self.text.lines.len() as u32
    }

    /// The highlighted runs of the lines a range touches.
    pub fn highlights(&mut self, start: u32, length: u32) -> Vec<Highlight> {
        let end = start.saturating_add(length).min(self.text.len());
        self.highlighter.highlights(&self.text, start.min(end), end)
    }

    /// What a spelling checker passes over where a range is: maths, literal
    /// code, and the names commands take (packages, citations, labels,
    /// files), each from its start, however far before the range.
    pub fn not_prose(&mut self, start: u32, length: u32) -> Vec<TextRange> {
        let end = start.saturating_add(length).min(self.text.len());
        prose::not_prose(&self.text, &mut self.scans, start.min(end), end)
    }

    /// What a checker leaves alone where a range is: the code it highlights
    /// and what isn't prose (`not_prose`). Spelling takes only the kinds that
    /// are never words, since the highlighter colours a word in \text{…} as
    /// maths, which is prose to `not_prose`.
    pub fn code_ranges(&mut self, selection: TextRange, checker: Checker) -> Vec<TextRange> {
        use HighlightKind::*;
        let code = |kind| {
            checker == Checker::WritingTools
                || matches!(kind, Command | Argument | StringLiteral | Builtin)
        };
        let highlighted = self
            .highlights(selection.start, selection.length)
            .into_iter();
        let mut ranges: Vec<TextRange> = highlighted
            .filter(|h| code(h.kind))
            .map(|h| range(h.start, h.length))
            .collect();
        ranges.extend(self.not_prose(selection.start, selection.length));
        ranges
    }

    /// Where line `line` (from 1) has `command` (with its backslash), each
    /// time it does, in units from the line's start: not as the start of a
    /// longer name, not after a backslash that is itself a command's (`\\foo`
    /// is a line break and a word), and not in a comment.
    pub fn command_ranges(&self, line: u32, command: &str) -> Vec<TextRange> {
        let index = line.max(1) as usize - 1;
        let name: Vec<u16> = command.encode_utf16().collect();
        if index >= self.text.lines.len() || name.is_empty() {
            return vec![];
        }
        let units = self.text.line(index);
        // TeX's letters, with `@` as in a class's or a package's own source.
        let tex_letter = |u: u16| letter(u) || is(u, '@');
        let end = (0..units.len())
            .find(|&i| is(units[i], '%') && !escaped(units, i))
            .unwrap_or(units.len());
        let word = name.get(1).is_some_and(|&u| tex_letter(u));
        let (mut found, mut from) = (vec![], 0);
        while let Some(at) = units[from..end].windows(name.len()).position(|w| w == name) {
            let at = from + at;
            from = at + name.len();
            let longer = word && units.get(from).is_some_and(|&u| tex_letter(u));
            if !escaped(units, at) && !longer {
                found.push(range(at as u32, name.len() as u32));
            }
        }
        found
    }

    /// The bold, italic and underline the whole selection is in, each as the
    /// edits that unwrap the command giving it, in order.
    pub fn text_styles(&mut self, selection: TextRange) -> TextStyles {
        let selection = clamp(selection, self.text.len());
        style::text_styles(&self.text, &mut self.scans, selection)
    }

    /// Forgets the closers and snippet fields typing keeps, as when the
    /// editor shows the document again: they belong to a visit, not to the text.
    pub fn reset_typing(&mut self) {
        self.typing = typing::Typing::default();
    }

    /// The maths to preview at the caret, if it's in some.
    pub fn math_at(&mut self, caret: u32) -> Option<MathPreview> {
        preview::math_at(&self.text, &mut self.scans, caret.min(self.text.len()))
    }
}

fn is(u: u16, c: char) -> bool {
    u == c as u16
}

/// Whether the unit at `at` follows a backslash that is not itself escaped,
/// as the bracket of `\[` does.
fn escaped(units: &[u16], at: usize) -> bool {
    let slashes = units[..at]
        .iter()
        .rev()
        .take_while(|&&u| is(u, '\\'))
        .count();
    slashes % 2 == 1
}

/// The longest command name `ascii` reads; longer than any in the catalog.
const NAME: usize = 64;

/// A command name's UTF-16 units as the ASCII they are, without allocating:
/// "" for one longer than `NAME` or not ASCII, which no name it's matched
/// against is.
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

/// Whether a unit is whitespace; half of a surrogate pair is not.
fn space(u: u16) -> bool {
    char::from_u32(u.into()).is_some_and(char::is_whitespace)
}

/// A line of nothing but spaces, or of nothing.
fn blank(line: &[u16]) -> bool {
    line.iter().all(|&u| space(u))
}

fn utf16(s: &str) -> usize {
    s.encode_utf16().count()
}

fn clamp(selection: TextRange, len: u32) -> TextRange {
    let start = selection.start.min(len);
    range(start, selection.length.min(len - start))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_starts_follow_edits() {
        let mut doc = SourceDocument::new("a\nb\nc");
        assert_eq!(doc.line_count(), 3);
        doc.edit(1, 2, "x\ny\nz"); // "a" + "x\ny\nz" + "\nc"
        assert_eq!(doc.text(), "ax\ny\nz\nc");
        assert_eq!(
            (0..4).map(|l| doc.line_start(l + 1)).collect::<Vec<_>>(),
            [0, 3, 5, 7]
        );
        doc.edit(0, 7, "");
        assert_eq!(doc.text(), "c");
        assert_eq!(doc.line_count(), 1);
        assert_eq!(doc.line_at(1), 1);
        // Past the end: cut to the text, never a panic.
        doc.edit(10, 5, "!");
        assert_eq!(doc.text(), "c!");
    }

    /// The labels and citations are the document's, set when they change
    /// rather than sent with each completions call: offered until set again,
    /// and none on a new document.
    #[test]
    fn completions_offer_the_symbols_set_on_the_document() {
        let offered = |doc: &mut SourceDocument, caret: u32| -> Vec<String> {
            let answer = doc.call("completions", &format!(r#"{{"caret": {caret}}}"#));
            let value: serde_json::Value = serde_json::from_str(&answer.unwrap()).unwrap();
            value["items"].as_array().map_or(vec![], |items| {
                items
                    .iter()
                    .map(|i| i["label"].as_str().unwrap().to_owned())
                    .collect()
            })
        };
        let owned = |names: &[&str]| names.iter().map(|&n| n.to_owned()).collect();
        let mut doc = SourceDocument::new("\\cite{sm} \\ref{fig");
        assert!(offered(&mut doc, 8).is_empty(), "a new document has none");
        doc.set_symbols(
            owned(&["fig:one", "sec:two"]),
            owned(&["smith2020", "jones"]),
        );
        assert_eq!(offered(&mut doc, 8), ["smith2020"]);
        assert_eq!(offered(&mut doc, 18), ["fig:one"]);
        // Kept through edits, and replaced whole.
        doc.edit(0, 0, "x ");
        assert_eq!(offered(&mut doc, 10), ["smith2020"]);
        doc.set_symbols(vec![], owned(&["smyth"]));
        assert_eq!(offered(&mut doc, 10), ["smyth"]);
        assert!(offered(&mut doc, 20).is_empty());
    }

    /// An undefined command is found where its line has it: not a longer one
    /// that starts with it, nor a comment's, nor one after an escaped backslash.
    #[test]
    fn a_command_is_found_on_its_line() {
        let found = |line: &str, command: &str| -> Vec<(u32, u32)> {
            let doc = SourceDocument::new(&format!("first\n{line}\nlast"));
            let ranges = doc.command_ranges(2, command);
            ranges.iter().map(|r| (r.start, r.length)).collect()
        };
        assert_eq!(found("a \\foo b \\foo{c}", "\\foo"), [(2, 4), (9, 4)]);
        assert_eq!(found("\\foobar \\foo@ \\\\foo \\foo1", "\\foo"), [(20, 4)]);
        assert_eq!(found("\\foo % \\foo", "\\foo"), [(0, 4)]);
        assert_eq!(found("50\\% \\foo", "\\foo"), [(5, 4)]);
        assert_eq!(found("a\\;b \\\\;", "\\;"), [(1, 2)]);
        assert!(found("no such command", "\\foo").is_empty());
        let doc = SourceDocument::new("\\foo");
        assert!(doc.command_ranges(2, "\\foo").is_empty(), "no such line");
        assert!(doc.command_ranges(1, "").is_empty());
    }

    /// Spelling passes over the code that is never words; Writing Tools over
    /// all the code there is.
    #[test]
    fn checkers_leave_code_alone() {
        let text = "Prose \\emph{word} $x$ % note";
        let mut doc = SourceDocument::new(text);
        let all = range(0, utf16(text) as u32);
        let ranges = |doc: &mut SourceDocument, checker| -> Vec<(u32, u32)> {
            let mut found: Vec<_> = doc
                .code_ranges(all, checker)
                .iter()
                .map(|r| (r.start, r.length))
                .collect();
            found.sort_unstable();
            found
        };
        // The command, then the maths not_prose finds; the comment is prose to spelling.
        assert_eq!(ranges(&mut doc, Checker::Spelling), [(6, 5), (18, 3)]);
        let writing = ranges(&mut doc, Checker::WritingTools);
        assert!(writing.contains(&(22, 6)), "the comment: {writing:?}");
        assert!(
            writing.contains(&(18, 1)) && writing.contains(&(18, 3)),
            "the maths: {writing:?}"
        );
    }

    #[test]
    fn offsets_are_utf16() {
        let mut doc = SourceDocument::new("é😀\nx");
        assert_eq!(doc.line_start(2), 4); // é is one unit, the emoji two, then the line feed
        doc.edit(1, 2, "");
        assert_eq!(doc.text(), "é\nx");
    }
}
