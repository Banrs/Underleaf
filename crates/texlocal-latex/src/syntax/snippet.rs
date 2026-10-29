use schemars::JsonSchema;
use serde::Serialize;

use super::scan::environment_name;
use super::typing::is_closing;
use super::{
    NAME, SnippetField, SourceDocument, TextEdit, TextRange, ascii, clamp, escaped, is, letter,
    span, splice,
};

#[derive(Default, Serialize, JsonSchema)]
pub(crate) struct Tabbing {
    pub(crate) field: Option<TextRange>,
    pub(crate) edits: Vec<TextEdit>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
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

pub(super) struct Snippet {
    fields: Vec<Field>,
    active: usize,
    typed: Option<usize>,
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
            typed: None,
        }
    }

    fn place(&self, index: usize) -> Option<Field> {
        self.fields.iter().find(|f| f.index == index).copied()
    }

    fn tabs(&self) -> bool {
        self.place(1).is_some()
    }

    pub(super) fn follow(&mut self, start: usize, end: usize, delta: i64, mirroring: bool) -> bool {
        let typed = if mirroring {
            None
        } else {
            let copy = |f: &Field| f.index == self.active;
            let Some(at) = self
                .fields
                .iter()
                .position(|f| copy(f) && f.holds(start, end))
            else {
                return false;
            };
            self.typed = (self.fields.iter().filter(|f| copy(f)).count() > 1).then_some(at);
            Some(at)
        };
        let delta = delta as isize;
        for (i, field) in self.fields.iter_mut().enumerate() {
            if field.holds(start, end) && (mirroring || Some(i) == typed) {
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
        let Some(typed) = self.typed.take().map(|at| self.fields[at]) else {
            return vec![];
        };
        let end = typed.end().min(units.len());
        let text = String::from_utf16_lossy(&units[typed.start.min(end)..end]);
        self.fields
            .iter()
            .rev()
            .filter(|f| f.index == typed.index && **f != typed)
            .map(|f| splice(f.start, f.length, text.clone()))
            .collect()
    }
}

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
    pub(crate) fn start_snippet(&mut self, fields: &[SnippetField], at: u32) -> Option<TextRange> {
        let snippet = Snippet::new(fields, at as usize);
        let first = snippet.place(0)?;
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

    pub(crate) fn end_snippet(&mut self) -> bool {
        self.typing.snippet.take_if(|s| s.tabs()).is_some()
    }

    pub(crate) fn tab(&mut self, selections: &[TextRange], step: i64) -> Tabbing {
        let snippet = self.typing.snippet.as_mut().filter(|s| s.tabs());
        let moved = snippet.map(|snippet| snippet.go(step));
        let edits = match moved {
            Some(Some(field)) => {
                return Tabbing {
                    field: Some(span(field.start, field.length)),
                    edits: vec![],
                };
            }
            Some(None) if step < 0 => return Tabbing::default(),
            Some(None) => {
                self.typing.snippet = None;
                self.indent(selections, true)
            }
            None => self.indent(selections, step > 0),
        };
        Tabbing { field: None, edits }
    }

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
            typed: None,
        })
    }

    pub(super) fn mirror_snippet(&mut self) -> Vec<TextEdit> {
        let snippet = self.typing.snippet.as_mut();
        let edits = snippet.map_or(vec![], |snippet| snippet.mirror(&self.text.units));
        if edits.iter().any(|e| e.text.contains(['{', '}', '\n'])) {
            self.typing.snippet = None;
            return vec![];
        }
        edits
    }
}
