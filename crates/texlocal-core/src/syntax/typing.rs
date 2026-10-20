//! Typing as the source editor assists it: brackets that close and are stepped over, Delete back to an indent stop,
//! Return keeping indentation, and a bracket's partner. The closers put in are kept between keys, as the snippet's fields are.

use std::collections::BTreeSet;

use serde::Serialize;
use unicode_segmentation::UnicodeSegmentation;

use super::snippet::Snippet;
use super::{
    SourceDocument, TextEdit, TextRange, clamp, escaped, indentation, is, span, splice, utf16,
};

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
const CLOSE_BEFORE: [&str; 6] = [")", "]", "}", ":", ";", ">"];

const PARTNER_WITHIN: usize = 10_000;

fn bracket(c: &str) -> Option<(&'static str, bool)> {
    Some(match c {
        "(" => (")", true),
        "[" => ("]", true),
        "{" => ("}", true),
        ")" => ("(", false),
        "]" => ("[", false),
        "}" => ("{", false),
        _ => return None,
    })
}

fn closing_of(c: &str) -> Option<&'static str> {
    bracket(c).and_then(|(close, opens)| opens.then_some(close))
}

pub(super) fn is_closing(c: &str) -> bool {
    bracket(c).is_some_and(|(_, opens)| !opens)
}

/// As NSString's composed character sequence.
fn character(units: &[u16], at: usize) -> Option<String> {
    if at >= units.len() {
        return None;
    }
    let mut from = at.saturating_sub(32);
    while from > 0 && (0xdc00..0xe000).contains(&units[from]) {
        from -= 1;
    }
    let to = (at + 32).min(units.len());
    let window = String::from_utf16_lossy(&units[from..to]);
    let mut offset = from;
    for cluster in window.graphemes(true) {
        let end = offset + utf16(cluster);
        if at < end {
            return Some(cluster.to_owned());
        }
        offset = end;
    }
    None
}

fn whitespace(c: &str) -> bool {
    c.chars().next().is_some_and(char::is_whitespace)
}

fn closer_after(units: &[u16], caret: usize) -> Option<usize> {
    let opener = caret.checked_sub(1)?;
    let close = character(units, opener).and_then(|c| closing_of(&c))?;
    let at = |i| character(units, i);
    if at(caret).as_deref() == Some(close) {
        return Some(1);
    }
    (escaped(units, opener)
        && at(caret).as_deref() == Some("\\")
        && at(caret + 1).as_deref() == Some(close))
    .then_some(2)
}

impl SourceDocument {
    pub fn type_text(&mut self, selection: TextRange, typed: &str, auto_pair: bool) -> Keystroke {
        let typing = &mut self.typing;
        typing.pending = None;
        let units = &self.text.units[..];
        // More than a character, as an input method commits, goes in as it is.
        if typed.graphemes(true).count() != 1 {
            return Keystroke {
                completions: Completing::Close,
                ..Keystroke::default()
            };
        }
        let (start, end) = clamp(selection, self.text.len()).bounds();
        let length = end - start;
        let next = character(units, start);
        let next_is = |c: &str| next.as_deref() == Some(c);
        if length == 0 && typing.closers.contains(&start) && is_closing(typed) {
            if next_is(typed) {
                typing.closers.remove(&start);
                return Keystroke {
                    selection: Some(span(start + 1, 0)),
                    partner: Some(start as u32),
                    ..Keystroke::default()
                };
            }
            // A closer put in as \] or \}: its bracket steps over both, and a
            // backslash typed for it goes. A backslash alone is typed in,
            // being a command's as often as the closer's.
            if next_is("\\") && character(units, start + 1).as_deref() == Some(typed) {
                typing.closers.remove(&start);
                let mut bracket = start + 1;
                let mut keystroke = Keystroke::default();
                if escaped(units, start) {
                    keystroke.edit = Some(splice(start - 1, 1, ""));
                    keystroke.completions = Completing::Close;
                    bracket -= 1;
                }
                keystroke.selection = Some(span(bracket + 1, 0));
                keystroke.partner = Some(bracket as u32);
                return keystroke;
            }
        }
        if let Some(close) = closing_of(typed).filter(|_| auto_pair) {
            if length > 0 {
                let selected = String::from_utf16_lossy(&units[start..end]);
                typing.pending = Some((start, end + 1));
                return Keystroke {
                    edit: Some(splice(start, length, format!("{typed}{selected}{close}"))),
                    selection: Some(span(start + 1, length)),
                    ..Keystroke::default()
                };
            }
            if next
                .as_deref()
                .is_none_or(|n| whitespace(n) || CLOSE_BEFORE.contains(&n))
            {
                let pair = if escaped(units, start) {
                    format!("{typed}\\{close}")
                } else {
                    format!("{typed}{close}")
                };
                typing.pending = Some((start, start + 1));
                return Keystroke {
                    edit: Some(splice(start, 0, pair)),
                    selection: Some(span(start + 1, 0)),
                    completions: Completing::Offer,
                    ..Keystroke::default()
                };
            }
        }
        Keystroke {
            partner: is_closing(typed).then_some(start as u32),
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
        let (partner, opens) = bracket(&String::from_utf16_lossy(&[start]))?;
        let partner = u16::from(partner.as_bytes()[0]);
        let near = at.saturating_sub(PARTNER_WITHIN)..(at + PARTNER_WITHIN + 1).min(units.len());
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
            if !comment && near.contains(&i) && (u == start || u == partner) {
                brackets.push((i, u, escaped));
            }
            slashes = if is(u, '\\') { slashes + 1 } else { 0 };
        }
        let here = brackets.iter().position(|&(i, ..)| i == at)?;
        let escaped = brackets[here].2;
        let same = |b: &&(usize, u16, bool)| b.2 == escaped;
        let found = if opens {
            matched(brackets[here..].iter().filter(same), start)
        } else {
            matched(brackets[..=here].iter().rev().filter(same), start)
        };
        found.map(|i| i as u32)
    }
}

fn matched<'a>(
    brackets: impl Iterator<Item = &'a (usize, u16, bool)>,
    start: u16,
) -> Option<usize> {
    brackets
        .scan(0, |depth, &(i, u, _)| {
            *depth += if u == start { 1 } else { -1 };
            Some((i, *depth))
        })
        .find_map(|(i, depth)| (depth == 0).then_some(i))
}
