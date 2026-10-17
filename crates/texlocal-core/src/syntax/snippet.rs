//! A snippet's fields: the places of a completion's or block's text to type
//! in, which Tab and Shift-Tab go through and which mirror each other.
//!
//! The editor and the snippet keep in step through these calls:
//!
//! - `start_snippet`, once the text is in: the first field is selected.
//! - A change to the text is reported with `follow`, which moves the fields
//!   and grows the one typed in. If that field has other places it is marked
//!   as changed, and `mirror_snippet` then answers the edits that copy it
//!   there; the editor applies them with `mirroring` set, reporting each the
//!   same way, and selects what it had.
//! - `tab` selects the next field or the one before. On the last field Tab
//!   ends the snippet and indents the lines, as it does without one.
//! - It also ends with Escape (`end_snippet`), with a selection outside the
//!   fields (`select`) and with a change outside the field typed in (`follow`).

use serde::Serialize;

use super::typing::closing_unit;
use super::{SnippetField, SourceDocument, TextEdit, TextRange, span, splice};

/// Tab: a snippet's next field, or the lines indented.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Tab {
    /// The field to select; none, with a snippet, where there's no other.
    pub field: Option<TextRange>,
    /// Without a snippet: the indentation, as `SourceDocument::indent` gives it.
    pub edits: Vec<TextEdit>,
}

/// A place of a snippet's field, in the text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Field {
    index: usize,
    start: usize,
    length: usize,
}

impl Field {
    fn end(&self) -> usize {
        self.start + self.length
    }

    fn holds(&self, start: usize, end: usize) -> bool {
        self.start <= start && end <= self.end()
    }
}

/// Fields with the same index are one field in several places, in the
/// order they are in the text.
#[derive(Clone, Debug)]
pub(super) struct Snippet {
    fields: Vec<Field>,
    /// The index of the field being typed in.
    active: usize,
    /// The active field changed, and its other places are to follow it.
    changed: bool,
}

impl Snippet {
    fn new(fields: &[SnippetField], at: usize) -> Self {
        let fields = fields
            .iter()
            .map(|f| Field {
                index: f.index as usize,
                start: at + f.start as usize,
                length: f.length as usize,
            })
            .collect();
        Self {
            fields,
            active: 0,
            changed: false,
        }
    }

    /// The first place of the field with this index, the one typed in.
    fn place(&self, index: usize) -> Option<Field> {
        self.fields.iter().find(|f| f.index == index).copied()
    }

    /// The editor replaced `start..end`, the text's length changing by
    /// `delta`: the fields move, and the one typed in (each place of one
    /// being mirrored, while `mirroring`) grows. False if the change is
    /// outside the field typed in, which ends the snippet.
    pub(super) fn follow(&mut self, start: usize, end: usize, delta: i64, mirroring: bool) -> bool {
        let typed = self.place(self.active);
        if !mirroring {
            if !typed.is_some_and(|typed| typed.holds(start, end)) {
                return false;
            }
            let places = self.fields.iter().filter(|f| f.index == self.active);
            self.changed = places.count() > 1;
        }
        let delta = delta as isize;
        for field in &mut self.fields {
            if field.holds(start, end) && (mirroring || Some(*field) == typed) {
                field.length = field.length.saturating_add_signed(delta);
            } else if field.start >= end {
                field.start = field.start.saturating_add_signed(delta);
            }
        }
        true
    }

    /// Whether a selection is within a field.
    pub(super) fn contains(&self, start: usize, end: usize) -> bool {
        self.fields.iter().any(|f| f.holds(start, end))
    }

    /// The field `step` after the active one, now active; none past the
    /// first or the last.
    fn go(&mut self, step: i64) -> Option<Field> {
        let index = self.active.checked_add_signed(step as isize)?;
        let field = self.place(index)?;
        self.active = index;
        Some(field)
    }

    /// What's typed in the active field, put in its other places, from the
    /// last, if it changed since.
    fn mirror(&mut self, units: &[u16]) -> Vec<TextEdit> {
        let Some(typed) = self.place(self.active).filter(|_| self.changed) else {
            return vec![];
        };
        self.changed = false;
        let end = typed.end().min(units.len());
        let text = String::from_utf16_lossy(&units[typed.start.min(end)..end]);
        self.fields
            .iter()
            .rev()
            .filter(|f| f.index == self.active && **f != typed)
            .map(|f| splice(f.start, f.length, text.clone()))
            .collect()
    }
}

impl SourceDocument {
    /// A completion's or block's fields, from `at`, the first selected: Tab
    /// goes through them while there's another, or a field in two places.
    /// None without a first field.
    pub fn start_snippet(&mut self, fields: &[SnippetField], at: u32) -> Option<TextRange> {
        let snippet = Snippet::new(fields, at as usize);
        let first = snippet.place(0)?;
        // A bracket closing an empty field is the snippet's own, put in for
        // the user like one auto-closed: typing it steps over.
        for field in snippet.fields.iter().filter(|f| f.length == 0) {
            if self
                .text
                .units
                .get(field.start)
                .is_some_and(|&u| closing_unit(u))
            {
                self.typing.closers.insert(field.start);
            }
        }
        self.typing.snippet = (snippet.fields.len() > 1).then_some(snippet);
        Some(span(first.start, first.length))
    }

    /// Escape: whether there was a snippet to end.
    pub fn end_snippet(&mut self) -> bool {
        self.typing.snippet.take().is_some()
    }

    /// Tab and Shift-Tab (`step` 1 and -1): a snippet's next field or the one
    /// before; without one, or past its last, the lines indented or
    /// outdented. Before its first field there is nowhere to go.
    pub fn tab(&mut self, selections: &[TextRange], step: i64) -> Tab {
        let moved = self.typing.snippet.as_mut().map(|snippet| snippet.go(step));
        let edits = match moved {
            Some(Some(field)) => {
                return Tab {
                    field: Some(span(field.start, field.length)),
                    edits: vec![],
                };
            }
            Some(None) if step < 0 => return Tab::default(),
            Some(None) => {
                self.typing.snippet = None;
                self.indent(selections, true)
            }
            None => self.indent(selections, step > 0),
        };
        Tab { field: None, edits }
    }

    /// What's typed in a snippet's field for its other places, from the
    /// last, once `follow` has seen it change; the editor applies them while
    /// `mirroring`, then selects what it had.
    pub fn mirror_snippet(&mut self) -> Vec<TextEdit> {
        let snippet = self.typing.snippet.as_mut();
        snippet.map_or(vec![], |snippet| snippet.mirror(&self.text.units))
    }
}
