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

use std::sync::Mutex;

pub use complete::{Completion, CompletionKind, Completions, SnippetField};
pub use edit::math_mode_at;
pub use highlight::{Highlight, HighlightKind};

#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

/// A range of the text, in UTF-16 units.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct TextRange {
    pub start: u32,
    pub length: u32,
}

/// Replace `length` units at `start` with `text`.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct TextEdit {
    pub start: u32,
    pub length: u32,
    pub text: String,
}

/// An edit and where the caret goes after it.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
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
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct SourceDocument {
    inner: Mutex<Inner>,
}

struct Inner {
    text: Text,
    highlighter: highlight::Cache,
}

impl SourceDocument {
    fn with<T>(&self, f: impl FnOnce(&mut Inner) -> T) -> T {
        // A panic mid-edit can't leave the mirror half-changed in a way that
        // matters more than losing the editor: carry on with what's there.
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        f(&mut inner)
    }
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl SourceDocument {
    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn new(text: String) -> Self {
        SourceDocument {
            inner: Mutex::new(Inner {
                text: Text::new(&text),
                highlighter: highlight::Cache::default(),
            }),
        }
    }

    /// The editor replaced `length` units at `start` with `text`. A range
    /// past the end is cut to the text: the mirror never fails the editor.
    pub fn edit(&self, start: u32, length: u32, text: String) {
        self.with(|inner| {
            let start = start.min(inner.text.len());
            let length = length.min(inner.text.len() - start);
            let units: Vec<u16> = text.encode_utf16().collect();
            let first = inner.text.replace(start, length, &units);
            inner.highlighter.forget_from(first);
        })
    }

    pub fn text(&self) -> String {
        self.with(|inner| String::from_utf16_lossy(&inner.text.units))
    }

    /// The line an offset is on, from 1.
    pub fn line_at(&self, offset: u32) -> u32 {
        self.with(|inner| inner.text.line_index(offset) as u32 + 1)
    }

    /// Where a line (from 1) starts; past the last line, the last line's start.
    pub fn line_start(&self, line: u32) -> u32 {
        self.with(|inner| {
            let index = (line.max(1) as usize - 1).min(inner.text.lines.len() - 1);
            inner.text.lines[index]
        })
    }

    pub fn line_count(&self) -> u32 {
        self.with(|inner| inner.text.lines.len() as u32)
    }

    /// The highlighted runs of the lines a range touches.
    pub fn highlights(&self, start: u32, length: u32) -> Vec<Highlight> {
        self.with(|inner| {
            let end = start.saturating_add(length).min(inner.text.len());
            inner
                .highlighter
                .highlights(&inner.text, start.min(end), end)
        })
    }

    /// What to offer at the caret, if anything: commands after a backslash
    /// (only once a letter follows unless `explicit`, asked for by the user),
    /// the labels, citations or environments an argument takes, or a
    /// bibliography entry's type after "@".
    pub fn completions(
        &self,
        caret: u32,
        explicit: bool,
        labels: Vec<String>,
        citations: Vec<String>,
    ) -> Option<Completions> {
        self.with(|inner| {
            complete::completions(
                &inner.text,
                caret.min(inner.text.len()),
                explicit,
                &labels,
                &citations,
            )
        })
    }

    /// "%" comments on or off for the lines the selections touch: off when
    /// every one is already commented (or blank), on otherwise. In order;
    /// the editor applies them from the last.
    pub fn toggle_comment(&self, selections: Vec<TextRange>) -> Vec<TextEdit> {
        self.with(|inner| edit::toggle_comment(&inner.text, &selections))
    }

    /// The caret's line as a heading of `command` ("section"), or as plain
    /// text given none, as a paragraph style does: a heading changes level
    /// and keeps its title, a line of text becomes the title.
    pub fn set_heading(&self, caret: u32, command: String) -> Insertion {
        self.with(|inner| edit::set_heading(&inner.text, caret.min(inner.text.len()), &command))
    }

    /// A block by its id (the catalog's `blocks`) in place of the selection,
    /// on a line of its own; none for an id the catalog hasn't.
    pub fn insert_block(&self, id: String, selection: TextRange) -> Option<Insertion> {
        self.with(|inner| edit::insert_block(&inner.text, &id, clamp(selection, inner.text.len())))
    }

    /// A maths symbol's command in place of the selection: as it is in
    /// maths, and between dollars in text, where the bare command would stop
    /// the build.
    pub fn insert_symbol(&self, command: String, selection: TextRange) -> Insertion {
        self.with(|inner| {
            let selection = clamp(selection, inner.text.len());
            let text = if math_mode_at(&inner.text.units[..selection.start as usize]) {
                command
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
        })
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
        let doc = SourceDocument::new("a\nb\nc".into());
        assert_eq!(doc.line_count(), 3);
        doc.edit(1, 2, "x\ny\nz".into()); // "a" + "x\ny\nz" + "\nc"
        assert_eq!(doc.text(), "ax\ny\nz\nc");
        assert_eq!(
            (0..4).map(|l| doc.line_start(l + 1)).collect::<Vec<_>>(),
            [0, 3, 5, 7]
        );
        doc.edit(0, 7, String::new());
        assert_eq!(doc.text(), "c");
        assert_eq!(doc.line_count(), 1);
        assert_eq!(doc.line_at(1), 1);
        // Past the end: cut to the text, never a panic.
        doc.edit(10, 5, "!".into());
        assert_eq!(doc.text(), "c!");
    }

    #[test]
    fn offsets_are_utf16() {
        let doc = SourceDocument::new("é😀\nx".into());
        assert_eq!(doc.line_start(2), 4); // é is one unit, the emoji two, then the line feed
        doc.edit(1, 2, String::new());
        assert_eq!(doc.text(), "é\nx");
    }
}
