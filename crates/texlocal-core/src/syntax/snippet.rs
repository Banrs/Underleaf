//! A snippet's fields: the places of a completion's or block's text to type in, which Tab and Shift-Tab go through
//! and which mirror each other, as an environment's name does in its `\begin` and `\end`. The editor reports each change with `follow`; `mirror_snippet` then answers the
//! edits that copy the typed field to its other places, which the editor applies with `mirroring` set.

use serde::Serialize;

use super::scan::environment_name;
use super::typing::is_closing;
use super::{
    NAME, SnippetField, SourceDocument, TextEdit, TextRange, ascii, clamp, escaped, is, letter,
    span, splice,
};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Tab {
    pub field: Option<TextRange>,
    pub edits: Vec<TextEdit>,
}

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

#[derive(Clone, Debug)]
pub(super) struct Snippet {
    fields: Vec<Field>,
    active: usize,
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

    fn place(&self, index: usize) -> Option<Field> {
        self.fields.iter().find(|f| f.index == index).copied()
    }

    /// A field alone, as an environment's name is, has none to go to.
    fn tabs(&self) -> bool {
        self.place(1).is_some()
    }

    /// False if the change is outside the field typed in, which ends the snippet.
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

    pub(super) fn contains(&self, start: usize, end: usize) -> bool {
        self.fields.iter().any(|f| f.holds(start, end))
    }

    fn go(&mut self, step: i64) -> Option<Field> {
        let index = self.active.checked_add_signed(step as isize)?;
        let field = self.place(index)?;
        self.active = index;
        Some(field)
    }

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

/// The name of the `\begin` or `\end` at `at`.
fn name_field(units: &[u16], at: usize) -> Option<Field> {
    let word = units[at + 1..].iter().take_while(|&&u| letter(u)).count();
    let command = &units[at + 1..at + 1 + word];
    if !matches!(ascii(command, &mut [0; NAME]), "begin" | "end") || escaped(units, at) {
        return None;
    }
    let (name, after) = environment_name(units, at + 1 + word)?;
    Some(Field {
        index: 0,
        start: after - 1 - name.len(),
        length: name.len(),
    })
}

impl SourceDocument {
    pub fn start_snippet(&mut self, fields: &[SnippetField], at: u32) -> Option<TextRange> {
        let snippet = Snippet::new(fields, at as usize);
        let first = snippet.place(0)?;
        // A bracket closing an empty field is the snippet's own, put in for
        // the user like one auto-closed: typing it steps over.
        for field in snippet.fields.iter().filter(|f| f.length == 0) {
            if let Some(&u) = self.text.units.get(field.start)
                && is_closing(u)
            {
                self.typing.closers.insert(field.start);
            }
        }
        self.typing.snippet = (snippet.fields.len() > 1).then_some(snippet);
        Some(span(first.start, first.length))
    }

    /// Escape is the host's in a snippet with no field to go to.
    pub fn end_snippet(&mut self) -> bool {
        let tabs = self.typing.snippet.as_ref().is_some_and(Snippet::tabs);
        if tabs {
            self.typing.snippet = None;
        }
        tabs
    }

    pub fn tab(&mut self, selections: &[TextRange], step: i64) -> Tab {
        // Without a field to go to, Tab and Shift-Tab indent.
        let snippet = self.typing.snippet.as_mut().filter(|s| s.tabs());
        let moved = snippet.map(|snippet| snippet.go(step));
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

    /// An environment's name, in its `\begin` and its `\end`, as one field in two places, the selection's first: the
    /// names are typed in together while they match.
    pub(super) fn environment_names(&mut self, selection: TextRange) -> Option<Snippet> {
        let (start, end) = clamp(selection, self.text.len()).bounds();
        let line = self.text.around(start).start;
        let units = &self.text.units;
        let command = line + units[line..start].iter().rposition(|&u| is(u, '\\'))?;
        let here = name_field(units, command).filter(|f| f.holds(start, end))?;
        let partner = self.environment_partner(command)?;
        let there = name_field(&self.text.units, partner)?;
        Some(Snippet {
            fields: vec![here, there],
            active: 0,
            changed: false,
        })
    }

    pub fn mirror_snippet(&mut self) -> Vec<TextEdit> {
        let snippet = self.typing.snippet.as_mut();
        let edits = snippet.map_or(vec![], |snippet| snippet.mirror(&self.text.units));
        // A brace, as one typed at a name's end, would break the other places too.
        if edits.iter().any(|e| e.text.contains(['{', '}'])) {
            self.typing.snippet = None;
            return vec![];
        }
        edits
    }
}
