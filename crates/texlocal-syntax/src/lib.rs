//! LaTeX editing logic every editor can share: highlighting, completion and
//! the editing commands, as ranges and edits for the editor to apply. The
//! editor owns the text, its undo and its drawing; a `SourceDocument` mirrors
//! the text through the editor's edits and answers in UTF-16 offsets, which
//! NSString, .NET strings and JavaScript all count in.
//!
//! A port of the web editor's logic (web/src/editor.js) and of CodeMirror's
//! stex mode, which the web still runs; the fixtures in tests/ hold both to
//! the same answers.

mod catalog;
mod complete;
mod edit;
mod highlight;

use serde::{Deserialize, Serialize};

pub use complete::{Completion, Completions, SnippetField};
pub use edit::math_mode_at;
pub use highlight::{Highlight, HighlightKind};

/// A range of the text, in UTF-16 units.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextRange {
    pub start: u32,
    pub length: u32,
}

/// Replace `length` units at `start` with `text`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TextEdit {
    pub start: u32,
    pub length: u32,
    pub text: String,
}

/// An edit and where the caret goes after it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Insertion {
    pub edit: TextEdit,
    pub caret: u32,
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
                    .filter(|(_, &u)| u == NEWLINE)
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
            .filter(|(_, &u)| u == NEWLINE)
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
}

impl SourceDocument {
    pub fn new(text: &str) -> Self {
        SourceDocument {
            text: Text::new(text),
            highlighter: highlight::Cache::default(),
        }
    }

    /// The editor replaced `length` units at `start` with `text`. A range
    /// past the end is cut to the text: the mirror never fails the editor.
    pub fn edit(&mut self, start: u32, length: u32, text: &str) {
        let start = start.min(self.text.len());
        let length = length.min(self.text.len() - start);
        let units: Vec<u16> = text.encode_utf16().collect();
        let first = self.text.replace(start, length, &units);
        self.highlighter.forget_from(first);
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

    /// The caret's line as a heading of `command` ("section"), or as plain
    /// text given none, as a paragraph style does: a heading changes level
    /// and keeps its title, a line of text becomes the title.
    pub fn set_heading(&self, caret: u32, command: &str) -> Insertion {
        edit::set_heading(&self.text, caret.min(self.text.len()), command)
    }

    /// A block by its id (the catalog's `blocks`) in place of the selection,
    /// on a line of its own; none for an id the catalog hasn't.
    pub fn insert_block(&self, id: &str, selection: TextRange) -> Option<Insertion> {
        edit::insert_block(&self.text, id, clamp(selection, self.text.len()))
    }

    /// A maths symbol's command in place of the selection: as it is in
    /// maths, and between dollars in text, where the bare command would stop
    /// the build.
    pub fn insert_symbol(&self, command: &str, selection: TextRange) -> Insertion {
        let selection = clamp(selection, self.text.len());
        let text = if math_mode_at(&self.text.units[..selection.start as usize]) {
            command.to_string()
        } else {
            format!("${command}$")
        };
        let caret = selection.start + text.encode_utf16().count() as u32;
        Insertion {
            edit: TextEdit {
                start: selection.start,
                length: selection.length,
                text,
            },
            caret,
        }
    }
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

    #[test]
    fn offsets_are_utf16() {
        let mut doc = SourceDocument::new("é😀\nx");
        assert_eq!(doc.line_start(2), 4); // é is one unit, the emoji two, then the line feed
        doc.edit(1, 2, "");
        assert_eq!(doc.text(), "é\nx");
    }
}
