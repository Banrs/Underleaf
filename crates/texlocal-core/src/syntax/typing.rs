//! Typing as the source editor assists it: brackets that close and are stepped over, Delete back to an indent stop,
//! Return keeping indentation, and a bracket's partner. The closers put in are kept between keys, as the snippet's fields are.

use std::collections::BTreeSet;

use serde::Serialize;

use super::snippet::Snippet;
use super::{SourceDocument, TextEdit, TextRange, clamp, escaped, indentation, is, span, splice};

/// What a key does instead of the editor: an edit typed as a key types (so it undoes with the typing around it),
/// and where the selection goes.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Keystroke {
    pub edit: Option<TextEdit>,
    pub selection: Option<TextRange>,
    pub partner: Option<u32>,
    pub completions: Completing,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Completing {
    #[default]
    Keep,
    Offer,
    Close,
}

#[derive(Default)]
pub(crate) struct Typing {
    pub(super) closers: BTreeSet<usize>,
    pub(super) snippet: Option<Snippet>,
    pending: Option<(usize, usize)>,
}

/// An opening bracket is closed for the user before these, or space, or the end.
const CLOSE_BEFORE: &str = ")]}:;>";

const PARTNER_WITHIN: usize = 10_000;

const PAIRS: [(char, char); 3] = [('(', ')'), ('[', ']'), ('{', '}')];

fn closing_of(u: u16) -> Option<char> {
    PAIRS.iter().find(|pair| is(u, pair.0)).map(|pair| pair.1)
}

pub(super) fn is_closing(u: u16) -> bool {
    PAIRS.iter().any(|pair| is(u, pair.1))
}

fn closer_after(units: &[u16], caret: usize) -> Option<usize> {
    let opener = caret.checked_sub(1)?;
    let close = closing_of(units[opener])?;
    let at = |i, c| units.get(i).is_some_and(|&u| is(u, c));
    if at(caret, close) {
        return Some(1);
    }
    (escaped(units, opener) && at(caret, '\\') && at(caret + 1, close)).then_some(2)
}

impl SourceDocument {
    pub fn type_text(&mut self, selection: TextRange, typed: &str, auto_pair: bool) -> Keystroke {
        let typing = &mut self.typing;
        typing.pending = None;
        let units = &self.text.units[..];
        // More than a character, as an input method commits, goes in as it is.
        let Some(key) = typed
            .encode_utf16()
            .next()
            .filter(|_| typed.chars().count() == 1)
        else {
            return Keystroke {
                completions: Completing::Close,
                ..Keystroke::default()
            };
        };
        let (start, end) = clamp(selection, self.text.len()).bounds();
        let length = end - start;
        let next = units.get(start).copied();
        if length == 0 && typing.closers.contains(&start) && is_closing(key) {
            // A closer put in as \] or \}: its bracket steps over both, and a backslash typed for it goes. A
            // backslash alone is typed in, being a command's as often as the closer's.
            let escaped_closer =
                next.is_some_and(|u| is(u, '\\')) && units.get(start + 1) == Some(&key);
            if next == Some(key) || escaped_closer {
                typing.closers.remove(&start);
                let mut bracket = start + escaped_closer as usize;
                let mut keystroke = Keystroke::default();
                if escaped_closer && escaped(units, start) {
                    keystroke.edit = Some(splice(start - 1, 1, ""));
                    keystroke.completions = Completing::Close;
                    bracket -= 1;
                }
                keystroke.selection = Some(span(bracket + 1, 0));
                keystroke.partner = Some(bracket as u32);
                return keystroke;
            }
        }
        if let Some(close) = closing_of(key).filter(|_| auto_pair) {
            if length > 0 {
                let selected = String::from_utf16_lossy(&units[start..end]);
                typing.pending = Some((start, end + 1));
                return Keystroke {
                    edit: Some(splice(start, length, format!("{typed}{selected}{close}"))),
                    selection: Some(span(start + 1, length)),
                    ..Keystroke::default()
                };
            }
            let before = |c: char| c.is_whitespace() || CLOSE_BEFORE.contains(c);
            if next.is_none_or(|n| char::from_u32(n.into()).is_some_and(before)) {
                let slash = if escaped(units, start) { "\\" } else { "" };
                typing.pending = Some((start, start + 1));
                return Keystroke {
                    edit: Some(splice(start, 0, format!("{typed}{slash}{close}"))),
                    selection: Some(span(start + 1, 0)),
                    completions: Completing::Offer,
                    ..Keystroke::default()
                };
            }
        }
        Keystroke {
            partner: is_closing(key).then_some(start as u32),
            completions: Completing::Offer,
            ..Keystroke::default()
        }
    }

    pub fn delete_backward(&mut self, selection: TextRange, auto_pair: bool) -> Keystroke {
        self.typing.pending = None;
        let units = &self.text.units[..];
        let (caret, end) = clamp(selection, self.text.len()).bounds();
        if end != caret || caret == 0 {
            return Keystroke::default();
        }
        let delete = |from: usize, to: usize| Keystroke {
            edit: Some(splice(from, to - from, "")),
            completions: Completing::Close,
            ..Keystroke::default()
        };
        if auto_pair
            && self.typing.closers.contains(&caret)
            && let Some(closer) = closer_after(units, caret)
        {
            return delete(caret - 1, caret + closer);
        }
        let indent = &units[self.text.around(caret).start..caret];
        if !indent.is_empty() && indent.iter().all(|&u| is(u, ' ')) {
            let drop = if indent.len().is_multiple_of(2) { 2 } else { 1 };
            return delete(caret - drop, caret);
        }
        Keystroke::default()
    }

    pub fn insert_newline(&mut self, selection: TextRange) -> Keystroke {
        self.typing.pending = None;
        let units = &self.text.units[..];
        let (mut start, end) = clamp(selection, self.text.len()).bounds();
        let mut length = end - start;
        let line = self.text.around(start);
        let indent = indentation(&units[line.start..line.end]);
        let indented = String::from_utf16_lossy(&units[line.start..line.start + indent]);
        let mut insert = format!("\n{indented}");
        if length == 0 && closer_after(units, start).is_some() {
            insert.push('\n');
            insert.push_str(&indented);
        } else {
            while start + length < line.end
                && (is(units[start + length], ' ') || is(units[start + length], '\t'))
            {
                length += 1;
            }
            let before = &units[line.start..start];
            if !before.is_empty() && indentation(before) == before.len() {
                length += start - line.start;
                start = line.start;
            }
        }
        Keystroke {
            edit: Some(splice(start, length, insert)),
            selection: Some(span(start + 1 + indent, 0)),
            completions: Completing::Close,
            ..Keystroke::default()
        }
    }

    /// `changing`, the range the editor said it would change, stands for `old` when it is within it from the same start.
    pub fn follow(
        &mut self,
        old: TextRange,
        delta: i64,
        changing: Option<TextRange>,
        mirroring: bool,
    ) {
        let typing = &mut self.typing;
        let (start, end) = old.bounds();
        let (start, end) = changing
            .map(TextRange::bounds)
            .filter(|&(from, to)| from == start && to <= end)
            .unwrap_or((start, end));
        typing.closers = typing
            .closers
            .iter()
            .filter_map(|&p| {
                if p >= end {
                    Some(p.saturating_add_signed(delta as isize))
                } else {
                    (p < start).then_some(p)
                }
            })
            .collect();
        if let Some((at, closer)) = typing.pending.take()
            && at == start
        {
            typing.closers.insert(closer);
        }
        if let Some(snippet) = &mut typing.snippet
            && !snippet.follow(start, end, delta, mirroring)
        {
            typing.snippet = None;
        }
    }

    pub fn select(&mut self, selection: TextRange, mirroring: bool) {
        let typing = &mut self.typing;
        let (start, end) = selection.bounds();
        if !mirroring
            && typing
                .snippet
                .as_ref()
                .is_some_and(|snippet| !snippet.contains(start, end))
        {
            typing.snippet = None;
        }
        let line = self.text.around(start).start;
        typing.closers.retain(|&p| p >= line);
    }

    /// Brackets in comments are no one's, and an escaped one pairs only with the escaped.
    pub fn partner(&self, at: u32) -> Option<u32> {
        let at = at as usize;
        let units = &self.text.units[..];
        let start = *units.get(at)?;
        let &(open, close) = PAIRS
            .iter()
            .find(|pair| is(start, pair.0) || is(start, pair.1))?;
        let opens = is(start, open);
        let partner = if opens { close } else { open } as u16;
        let near = at.saturating_sub(PARTNER_WITHIN)..(at + PARTNER_WITHIN + 1).min(units.len());
        let escaped_here = escaped(units, at);
        // A comment is known from its line's start, so reading starts there.
        let mut brackets = Vec::new();
        let (mut comment, mut slashes) = (false, 0);
        let from = self.text.around(near.start).start;
        for (i, &u) in units.iter().enumerate().take(near.end).skip(from) {
            let escaped = slashes % 2 == 1;
            if is(u, '\n') {
                comment = false;
            } else if is(u, '%') && !escaped {
                comment = true;
            }
            let ours = u == start || u == partner;
            if ours && !comment && escaped == escaped_here && near.contains(&i) {
                brackets.push((i, u));
            }
            slashes = if is(u, '\\') { slashes + 1 } else { 0 };
        }
        let here = brackets.iter().position(|&(i, _)| i == at)?;
        let found = if opens {
            matched(brackets[here..].iter(), start)
        } else {
            matched(brackets[..=here].iter().rev(), start)
        };
        found.map(|i| i as u32)
    }
}

fn matched<'a>(brackets: impl Iterator<Item = &'a (usize, u16)>, start: u16) -> Option<usize> {
    brackets
        .scan(0, |depth, &(i, u)| {
            *depth += if u == start { 1 } else { -1 };
            Some((i, *depth))
        })
        .find_map(|(i, depth)| (depth == 0).then_some(i))
}
