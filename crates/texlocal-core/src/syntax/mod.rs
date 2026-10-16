//! LaTeX editing logic for the editors: highlighting, completion and the
//! editing commands, as ranges and edits for the editor to apply. The editor
//! owns the text, its undo and its drawing; a `SourceDocument` mirrors the
//! text through the editor's edits and answers in UTF-16 offsets, which
//! NSString and WinUI both count in. A session's open file
//! (`session::Document`) holds one, as does each of the FFI's own sources.

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
pub use maths::{MathPreview, math_mode_at};
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

fn edit(start: u32, length: u32, text: impl Into<String>) -> TextEdit {
    TextEdit {
        start,
        length,
        text: text.into(),
    }
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

/// The editor's text and where its lines start (after each line feed).
pub(crate) struct Text {
    pub units: Vec<u16>,
    pub lines: Vec<u32>,
}

impl Text {
    fn new(text: &str) -> Self {
        let units: Vec<u16> = text.encode_utf16().collect();
        let lines = std::iter::once(0)
            .chain(
                units
                    .iter()
                    .enumerate()
                    .filter(|&(_, &u)| u == NEWLINE)
                    .map(|(i, _)| i as u32 + 1),
            )
            .collect();
        Text { units, lines }
    }

    fn len(&self) -> u32 {
        self.units.len() as u32
    }

    /// The line an offset is on, from 0.
    pub fn line_index(&self, offset: u32) -> usize {
        self.lines.partition_point(|&start| start <= offset) - 1
    }

    /// A line's units, without its line feed.
    pub fn line(&self, index: usize) -> &[u16] {
        let start = self.lines[index] as usize;
        let end = self
            .lines
            .get(index + 1)
            .map_or(self.units.len(), |&next| next as usize - 1);
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
        let added = text
            .iter()
            .enumerate()
            .filter(|&(_, &u)| u == NEWLINE)
            .map(|(i, _)| start + i as u32 + 1);
        self.lines.splice(first..last, added);
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
    scans: maths::Scans,
    /// The project's, which "completions" offers in `\ref{` and `\cite{`.
    labels: Vec<String>,
    citations: Vec<String>,
    /// The closers and snippet fields typing keeps between keys.
    typing: typing::Typing,
}

impl SourceDocument {
    pub fn new(text: &str) -> Self {
        SourceDocument {
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
            .map(|h| TextRange {
                start: h.start,
                length: h.length,
            })
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
        // After a backslash that is not itself escaped, as the bracket of `\[` is.
        let escaped = |at: usize| {
            units[..at]
                .iter()
                .rev()
                .take_while(|&&u| is(u, '\\'))
                .count()
                % 2
                == 1
        };
        let end = (0..units.len())
            .find(|&i| is(units[i], '%') && !escaped(i))
            .unwrap_or(units.len());
        let word = name.get(1).is_some_and(|&u| tex_letter(u));
        let (mut found, mut from) = (vec![], 0);
        while let Some(at) = units[from..end].windows(name.len()).position(|w| w == name) {
            let at = from + at;
            from = at + name.len();
            let longer = word && units.get(from).is_some_and(|&u| tex_letter(u));
            if !escaped(at) && !longer {
                found.push(TextRange {
                    start: at as u32,
                    length: name.len() as u32,
                });
            }
        }
        found
    }

    /// What to offer at the caret, if anything: commands after a backslash
    /// (only once a letter follows unless `explicit`, asked for by the user),
    /// the labels, citations or environments an argument takes, or a
    /// bibliography entry's type after "@".
    pub fn completions(
        &self,
        caret: u32,
        explicit: bool,
        labels: &[String],
        citations: &[String],
    ) -> Option<Completions> {
        let caret = caret.min(self.text.len());
        complete::completions(&self.text, caret, explicit, labels, citations)
    }

    /// "%" comments on or off for the lines the selections touch: off when
    /// every one is already commented (or blank), on otherwise. In order;
    /// the editor applies them from the last.
    pub fn toggle_comment(&self, selections: &[TextRange]) -> Vec<TextEdit> {
        edit::toggle_comment(&self.text, selections)
    }

    /// Two spaces more, or up to two fewer, at the start of each line the
    /// selections touch.
    pub fn indent(&self, selections: &[TextRange], more: bool) -> Vec<TextEdit> {
        edit::indent(&self.text, selections, more)
    }

    /// The caret's line as a heading of `command` ("section"), or as plain
    /// text given none, as a paragraph style does: a heading changes level
    /// and keeps its title, a line of text becomes the title.
    pub fn set_heading(&self, caret: u32, command: &str) -> Insertion {
        edit::set_heading(&self.text, caret.min(self.text.len()), command)
    }

    /// The bold, italic and underline the whole selection is in, each as the
    /// edits that unwrap the command giving it, in order.
    pub fn text_styles(&mut self, selection: TextRange) -> TextStyles {
        let selection = clamp(selection, self.text.len());
        style::text_styles(&self.text, &mut self.scans, selection)
    }

    /// A character typed in place of the selection: a bracket closed for the
    /// user (`auto_pair`) or stepped over, or none of that.
    pub fn type_text(&mut self, selection: TextRange, typed: &str, auto_pair: bool) -> Keystroke {
        let selection = clamp(selection, self.text.len());
        self.typing
            .type_text(&self.text, selection, typed, auto_pair)
    }

    /// Delete at the caret: an empty pair put in for the user goes whole,
    /// and in the indentation it goes back to a two-column stop.
    pub fn delete_backward(&mut self, selection: TextRange, auto_pair: bool) -> Keystroke {
        let selection = clamp(selection, self.text.len());
        self.typing
            .delete_backward(&self.text, selection, auto_pair)
    }

    /// Return, keeping the line's indentation.
    pub fn insert_newline(&mut self, selection: TextRange) -> Keystroke {
        let selection = clamp(selection, self.text.len());
        self.typing.insert_newline(&self.text, selection)
    }

    /// Where the bracket at `at` is matched, within 10,000 units.
    pub fn partner(&self, at: u32) -> Option<u32> {
        typing::partner(&self.text, at)
    }

    /// The editor changed `old` by `delta` units (`Typing::follow`).
    pub fn follow(
        &mut self,
        old: TextRange,
        delta: i64,
        changing: Option<TextRange>,
        mirroring: bool,
    ) {
        self.typing.follow(old, delta, changing, mirroring);
    }

    /// The editor's selection (its first) moved.
    pub fn select(&mut self, selection: TextRange, mirroring: bool) {
        self.typing.select(&self.text, selection, mirroring);
    }

    /// A completion's or block's fields, from `at`: the first to select.
    pub fn start_snippet(&mut self, fields: &[SnippetField], at: u32) -> Option<TextRange> {
        self.typing.start_snippet(fields, at)
    }

    /// Forgets the closers and snippet fields typing keeps, as when the
    /// editor shows the document again: they belong to a visit, not to the text.
    pub fn reset_typing(&mut self) {
        self.typing = typing::Typing::default();
    }

    /// Whether there was a snippet to end.
    pub fn end_snippet(&mut self) -> bool {
        self.typing.end_snippet()
    }

    /// Tab (`step` 1) or Shift-Tab (-1).
    pub fn tab(&mut self, selections: &[TextRange], step: i64) -> Tab {
        self.typing.tab(&self.text, selections, step)
    }

    /// What's typed in a snippet's field, for its other places.
    pub fn mirror_snippet(&mut self) -> Vec<TextEdit> {
        self.typing.mirror_snippet(&self.text)
    }

    /// Move Line Up or Down; none when a line has nowhere to go.
    pub fn move_lines(&self, selections: &[TextRange], up: bool) -> Option<Change> {
        typing::move_lines(&self.text, selections, up)
    }

    /// Bold, Italic or Underline, on or off.
    pub fn toggle_style(&mut self, selections: &[TextRange], style: Style) -> Change {
        let styles = self.text_styles(selections.first().copied().unwrap_or_default());
        typing::toggle_style(&self.text, styles, selections, style)
    }

    /// The selection round a template's "$0".
    pub fn wrap(&self, selections: &[TextRange], template: &str) -> Change {
        typing::wrap(&self.text, selections, template)
    }

    /// The maths to preview at the caret, if it's in some.
    pub fn math_at(&self, caret: u32) -> Option<MathPreview> {
        maths::math_at(&self.text, caret.min(self.text.len()))
    }

    /// A block by its id (the catalog's `blocks`) in place of the selection,
    /// on a line of its own, the caret in its first field; none for an id
    /// the catalog hasn't.
    pub fn insert_block(&self, id: &str, selection: TextRange) -> Option<Insertion> {
        edit::insert_block(&self.text, id, clamp(selection, self.text.len()))
    }

    /// A maths symbol's command in place of the selection: as it is in
    /// maths, and between dollars in text, where the bare command would stop
    /// the build.
    pub fn insert_symbol(&mut self, command: &str, selection: TextRange) -> Insertion {
        let selection = clamp(selection, self.text.len());
        let at = selection.start as usize;
        let mut scanner = self.scans.resume(&self.text, at, at).scanner;
        scanner.run(&self.text.units[..at], at, &[], &mut ());
        let text = if scanner.in_math() {
            command.to_string()
        } else {
            format!("${command}$")
        };
        let caret = selection.start + utf16(&text) as u32;
        Insertion {
            edit: edit(selection.start, selection.length, text),
            caret,
            fields: vec![],
        }
    }
}

fn is(u: u16, c: char) -> bool {
    u == c as u16
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

fn clamp(range: TextRange, len: u32) -> TextRange {
    let start = range.start.min(len);
    TextRange {
        start,
        length: range.length.min(len - start),
    }
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
        let all = TextRange {
            start: 0,
            length: utf16(text) as u32,
        };
        let ranges = |doc: &mut SourceDocument, checker| -> Vec<(u32, u32)> {
            let mut found: Vec<_> = doc
                .code_ranges(all, checker)
                .iter()
                .map(|r| (r.start, r.length))
                .collect();
            found.sort();
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
