//! LaTeX editing logic for the editors: highlighting, completion and the
//! editing commands, as ranges and edits for the editor to apply. The editor
//! owns the text, its undo and its drawing; a `SourceDocument` mirrors the
//! text through the editor's edits and answers in UTF-16 offsets, which
//! NSString and WinUI both count in. A session's open file
//! (`session::Document`) holds one, as does each of the FFI's own sources.
//! Its commands are its methods, each in the file of its kind: typing.rs,
//! edit.rs and complete.rs.

mod call;
pub(crate) mod catalog;
mod complete;
mod edit;
pub(crate) mod headings;
mod highlight;
mod maths;
mod prose;
pub(crate) mod render;
mod stack;
mod style;
pub(crate) mod theme;
mod typing;

use serde::{Deserialize, Serialize};

pub use call::call;
pub use complete::{Completion, CompletionKind, Completions, SnippetField};
pub use highlight::{Highlight, HighlightKind};
pub use maths::MathPreview;
pub use style::TextStyles;
pub use typing::{Change, Completing, Keystroke, Style, Tab, map_selections};

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

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
}

fn edit(start: u32, length: u32, text: impl Into<String>) -> TextEdit {
    let text = text.into();
    TextEdit { start, length, text }
}

/// What asks for `SourceDocument::code_ranges`: the spelling checker or
/// Writing Tools.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Checker {
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

/// The editor's text, in a gap buffer, and where its lines start. An edit
/// moves only the units between it and the one before, which typing keeps
/// close: a flat buffer moved all those after each key's, 11 of an edit's
/// 13 µs in a 24,000-line document. A question reads `units`, the text
/// before the gap, once `reach` has moved the gap past what it reads.
pub(crate) struct Text {
    buf: Vec<u16>,
    gap: usize,
    len: usize,
    /// After each line feed. Those from `moved` on are `shift` (wrapping)
    /// on from what's kept, so an edit shifts only those between it and
    /// the one before, as the gap does.
    starts: Vec<u32>,
    moved: usize,
    shift: u32,
}

/// Where the lines after the line feeds in `units`, put at `at`, start.
fn line_starts(units: &[u16], at: u32) -> impl Iterator<Item = u32> + '_ {
    let feeds = units.iter().enumerate().filter(|&(_, &u)| is(u, '\n'));
    feeds.map(move |(i, _)| at + i as u32 + 1)
}

impl Text {
    fn new(text: &str) -> Self {
        let buf: Vec<u16> = text.encode_utf16().collect();
        let starts = std::iter::once(0).chain(line_starts(&buf, 0)).collect();
        let (gap, len) = (buf.len(), buf.len());
        Self { buf, gap, len, starts, moved: 1, shift: 0 }
    }

    fn len(&self) -> u32 {
        self.len as u32
    }

    /// The text before the gap: as far as `reach` was asked, at least.
    pub fn units(&self) -> &[u16] {
        &self.buf[..self.gap]
    }

    fn reach(&mut self, end: usize) {
        let end = end.min(self.len);
        if self.gap < end {
            self.move_gap(end);
        }
    }

    /// Past `offset`'s line, and as far again as typing looks for a character.
    fn reach_line(&mut self, offset: u32) {
        self.reach(self.line_end(self.line_index(offset)) + 64);
    }

    fn move_gap(&mut self, to: usize) {
        let size = self.buf.len() - self.len;
        if to < self.gap {
            self.buf.copy_within(to..self.gap, to + size);
        } else {
            self.buf.copy_within(self.gap + size..to + size, self.gap);
        }
        self.gap = to;
    }

    fn string(&self) -> String {
        let after = &self.buf[self.gap + self.buf.len() - self.len..];
        String::from_utf16_lossy(&[self.units(), after].concat())
    }

    pub fn line_count(&self) -> usize {
        self.starts.len()
    }

    pub fn line_start(&self, index: usize) -> u32 {
        let shift = if index < self.moved { 0 } else { self.shift };
        self.starts[index].wrapping_add(shift)
    }

    /// Where a line ends, before its line feed.
    pub fn line_end(&self, index: usize) -> usize {
        let next = (index + 1 < self.starts.len()).then(|| self.line_start(index + 1) - 1);
        next.map_or(self.len, |end| end as usize)
    }

    /// The line an offset is on, from 0.
    pub fn line_index(&self, offset: u32) -> usize {
        let (kept, moved) = self.starts.split_at(self.moved);
        match kept.partition_point(|&start| start <= offset) {
            k if k < kept.len() => k - 1,
            k => k + moved.partition_point(|&s| s.wrapping_add(self.shift) <= offset) - 1,
        }
    }

    /// A line's units, without its line feed, once reached.
    pub fn line(&self, index: usize) -> &[u16] {
        &self.units()[self.line_start(index) as usize..self.line_end(index)]
    }

    /// Replaces a range; returns the first line whose start it may have moved.
    fn replace(&mut self, start: usize, length: usize, text: &[u16]) -> usize {
        let first = self.line_index(start as u32) + 1;
        let last = self.line_index((start + length) as u32) + 1;
        let shift = self.shift;
        if self.moved < last {
            let moving = &mut self.starts[self.moved..last];
            moving.iter_mut().for_each(|s| *s = s.wrapping_add(shift));
        } else {
            let kept = &mut self.starts[last..self.moved];
            kept.iter_mut().for_each(|s| *s = s.wrapping_sub(shift));
        }
        let count = self.starts.len();
        self.starts.splice(first..last, line_starts(text, start as u32));
        self.moved = last + self.starts.len() - count;
        let grown = (text.len() as u32).wrapping_sub(length as u32);
        self.shift = shift.wrapping_add(grown);
        // The units replaced join the gap, which grows when the text won't fit.
        self.move_gap(start + length);
        (self.gap, self.len) = (start, self.len - length);
        if self.buf.len() - self.len < text.len() {
            let more = std::iter::repeat_n(0, text.len() + self.len / 16);
            self.buf.splice(start..start, more);
        }
        self.buf[start..start + text.len()].copy_from_slice(text);
        (self.gap, self.len) = (start + text.len(), self.len + text.len());
        first
    }
}

/// An open file's text, mirrored from the editor, and the answers about it.
pub struct SourceDocument {
    text: Text,
    highlighter: highlight::Cache,
    /// Kept for the questions that read the text from its start.
    scans: maths::Scans,
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
            scans: maths::Scans::default(),
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
        let TextRange { start, length } = clamp(range(start, length), self.text.len());
        let units: Vec<u16> = text.encode_utf16().collect();
        let first = self.text.replace(start as usize, length as usize, &units);
        self.highlighter.forget_from(first);
        self.scans.forget_from(start as usize);
    }

    pub fn text(&self) -> String {
        self.text.string()
    }

    /// The line an offset is on, from 1.
    pub fn line_at(&self, offset: u32) -> u32 {
        self.text.line_index(offset) as u32 + 1
    }

    /// Where a line (from 1) starts; past the last line, the last line's start.
    pub fn line_start(&self, line: u32) -> u32 {
        let index = line.max(1) as usize - 1;
        self.text.line_start(index.min(self.text.line_count() - 1))
    }

    pub fn line_count(&self) -> u32 {
        self.text.line_count() as u32
    }

    /// The highlighted runs of the lines a range touches.
    pub fn highlights(&mut self, start: u32, length: u32) -> Vec<Highlight> {
        let end = start.saturating_add(length).min(self.text.len());
        self.text.reach_line(end);
        self.highlighter.highlights(&self.text, start.min(end), end)
    }

    /// What a spelling checker passes over where a range is: maths, literal
    /// code, and the names commands take (packages, citations, labels,
    /// files), each from its start, however far before the range.
    pub fn not_prose(&mut self, start: u32, length: u32) -> Vec<TextRange> {
        let end = start.saturating_add(length).min(self.text.len());
        self.text.reach(usize::MAX);
        prose::not_prose(&self.text, &mut self.scans, start.min(end), end)
    }

    /// What a checker leaves alone where a range is: the code it highlights
    /// and what isn't prose (`not_prose`). Spelling takes only the kinds that
    /// are never words, since the highlighter colours a word in \text{…} as
    /// maths, which is prose to `not_prose`.
    pub(crate) fn code_ranges(&mut self, selection: TextRange, checker: Checker) -> Vec<TextRange> {
        use HighlightKind::*;
        let TextRange { start, length } = selection;
        let all = checker == Checker::WritingTools;
        let code =
            |h: &Highlight| all || matches!(h.kind, Command | Argument | StringLiteral | Builtin);
        let highlights = self.highlights(start, length).into_iter().filter(code);
        let mut ranges: Vec<TextRange> = highlights.map(|h| range(h.start, h.length)).collect();
        ranges.extend(self.not_prose(start, length));
        ranges
    }

    /// Where line `line` (from 1) has `command` (with its backslash), each
    /// time it does, in units from the line's start: not as the start of a
    /// longer name, not after a backslash that is itself a command's (`\\foo`
    /// is a line break and a word), and not in a comment.
    pub(crate) fn command_ranges(&mut self, line: u32, command: &str) -> Vec<TextRange> {
        let index = line.max(1) as usize - 1;
        let name: Vec<u16> = command.encode_utf16().collect();
        if index >= self.text.line_count() || name.is_empty() {
            return vec![];
        }
        self.text.reach_line(self.text.line_start(index));
        let units = self.text.line(index);
        // TeX's letters, with `@` as in a class's or a package's own source.
        let tex_letter = |u: u16| letter(u) || is(u, '@');
        let comment = (0..units.len()).find(|&i| is(units[i], '%') && !escaped(units, i));
        let end = comment.unwrap_or(units.len());
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
        self.text.reach(usize::MAX);
        style::text_styles(&self.text, &mut self.scans, selection)
    }

    /// Forgets the closers and snippet fields typing keeps, as when the
    /// editor shows the document again: they belong to a visit, not to the text.
    pub fn reset_typing(&mut self) {
        self.typing = typing::Typing::default();
    }

    /// The maths to preview at the caret, if it's in some.
    pub fn math_at(&mut self, caret: u32) -> Option<MathPreview> {
        let caret = caret.min(self.text.len());
        self.text.reach_line(caret);
        self.text.reach(caret as usize + maths::PREVIEW_READS);
        maths::math_at(&self.text, caret)
    }

    /// A maths symbol's command in place of the selection: as it is in
    /// maths, and between dollars in text, where the bare command would stop
    /// the build.
    pub fn insert_symbol(&mut self, command: &str, selection: TextRange) -> Insertion {
        let TextRange { start, length } = clamp(selection, self.text.len());
        self.text.reach(usize::MAX);
        let at = start as usize;
        let mut scanner = self.scans.resume(&self.text, at, at).scanner;
        scanner.run(&self.text.units()[..at], at, &[], &mut ());
        let text = format!("{0}{command}{0}", if scanner.in_math() { "" } else { "$" });
        let caret = start + utf16(&text) as u32;
        let edit = edit(start, length, text);
        Insertion { edit, caret, fields: vec![] }
    }
}

fn is(u: u16, c: char) -> bool {
    u == c as u16
}

/// Whether the unit at `at` follows a backslash that is not itself escaped,
/// as the bracket of `\[` does.
fn escaped(units: &[u16], at: usize) -> bool {
    let slashes = units[..at].iter().rev().take_while(|&&u| is(u, '\\'));
    slashes.count() % 2 == 1
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

/// ECMAScript's \s.
fn space(u: u16) -> bool {
    matches!(u, 0x09..=0x0d | 0x20 | 0xa0 | 0x1680 | 0x2000..=0x200a | 0x2028 | 0x2029 | 0x202f | 0x205f | 0x3000 | 0xfeff)
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

    /// The labels and citations are the document's, set when they change
    /// rather than sent with each completions call: offered until set again,
    /// and none on a new document.
    #[test]
    fn completions_offer_the_symbols_set_on_the_document() {
        let offered = |doc: &mut SourceDocument, caret: u32| -> Vec<String> {
            let args = format!(r#"{{"caret": {caret}}}"#);
            let answer = doc.call("completions", &args).unwrap();
            let value: serde_json::Value = serde_json::from_str(&answer).unwrap();
            let items = value["items"].as_array().cloned().unwrap_or_default();
            let label = |i: &serde_json::Value| i["label"].as_str().unwrap().to_owned();
            items.iter().map(label).collect()
        };
        let owned = |names: &str| names.split(' ').map(str::to_owned).collect();
        let mut doc = SourceDocument::new("\\cite{sm} \\ref{fig");
        assert!(offered(&mut doc, 8).is_empty(), "a new document has none");
        doc.set_symbols(owned("fig:one sec:two"), owned("smith2020 jones"));
        assert_eq!(offered(&mut doc, 8), ["smith2020"]);
        assert_eq!(offered(&mut doc, 18), ["fig:one"]);
        // Kept through edits, and replaced whole.
        doc.edit(0, 0, "x ");
        assert_eq!(offered(&mut doc, 10), ["smith2020"]);
        doc.set_symbols(vec![], owned("smyth"));
        assert_eq!(offered(&mut doc, 10), ["smyth"]);
        assert!(offered(&mut doc, 20).is_empty());
    }

    /// An undefined command is found where its line has it: not a longer one
    /// that starts with it, nor a comment's, nor one after an escaped backslash.
    #[test]
    fn a_command_is_found_on_its_line() {
        for (line, command, found) in [
            ("a \\foo b \\foo{c}", "\\foo", "2 9"),
            ("\\foobar \\foo@ \\\\foo \\foo1", "\\foo", "20"),
            ("\\foo % \\foo", "\\foo", "0"),
            ("50\\% \\foo", "\\foo", "5"),
            ("a\\;b \\\\;", "\\;", "1"),
            ("no such command", "\\foo", ""),
            ("\\foo", "", ""),
        ] {
            let mut doc = SourceDocument::new(&format!("first\n{line}\nlast"));
            let ranges = doc.command_ranges(2, command);
            assert!(ranges.iter().all(|r| r.length == utf16(command) as u32));
            let starts: Vec<String> = ranges.iter().map(|r| r.start.to_string()).collect();
            assert_eq!(starts.join(" "), found, "{command} in {line}");
        }
        let none = SourceDocument::new("\\foo").command_ranges(2, "\\foo");
        assert!(none.is_empty(), "no such line");
    }

    /// Spelling passes over the code that is never words; Writing Tools over
    /// all the code there is.
    #[test]
    fn checkers_leave_code_alone() {
        let text = "Prose \\emph{word} $x$ % note";
        let mut doc = SourceDocument::new(text);
        let mut ranges = |checker| {
            let ranges = doc.code_ranges(range(0, utf16(text) as u32), checker);
            let mut found: Vec<_> = ranges.iter().map(|r| (r.start, r.length)).collect();
            found.sort_unstable();
            found
        };
        // The command, then the maths not_prose finds; the comment is prose to spelling.
        assert_eq!(ranges(Checker::Spelling), [(6, 5), (18, 3)]);
        let (writing, expected) = (ranges(Checker::WritingTools), [(22, 6), (18, 1), (18, 3)]);
        assert!(expected.iter().all(|r| writing.contains(r)), "{writing:?}");
    }
}
