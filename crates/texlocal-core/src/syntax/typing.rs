//! Typing as the source editor assists it: brackets that close and are
//! stepped over, Delete back to an indent stop, Return keeping the line's
//! indentation, and a bracket's partner. The editor applies the answers and
//! reports back each change (`follow`) and each selection (`select`): the
//! closers it put in are kept here, between keys, with the snippet's fields
//! (snippet.rs).

use std::collections::BTreeSet;

use serde::Serialize;
use unicode_segmentation::UnicodeSegmentation;

use super::snippet::Snippet;
use super::{
    SourceDocument, TextEdit, TextRange, clamp, escaped, indentation, is, span, splice, utf16,
};

/// What a key does instead of what the editor would: an edit, typed as a
/// key types (so it undoes with the typing around it), and where the
/// selection goes. Neither: the editor handles the key itself.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Keystroke {
    pub edit: Option<TextEdit>,
    /// Once the edit is in, if not where the edit leaves it.
    pub selection: Option<TextRange>,
    /// A bracket whose partner to show once the edit is in (`partner`).
    pub partner: Option<u32>,
    pub completions: Completing,
}

/// What the completion list does after a key.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Completing {
    /// As it is.
    #[default]
    Keep,
    /// Offered for the text as typed: an open list filters, or one opens.
    Offer,
    Close,
}

/// What typing keeps between keys.
#[derive(Default)]
pub(crate) struct Typing {
    /// Closing brackets put in for the user, which typing one steps over.
    pub(super) closers: BTreeSet<usize>,
    pub(super) snippet: Option<Snippet>,
    /// A closer a key put in, kept once its edit, at `start`, is followed.
    pending: Option<(usize, usize)>,
}

/// An opening bracket is closed for the user before these, or space, or the end.
const CLOSE_BEFORE: [&str; 6] = [")", "]", "}", ":", ";", ">"];

/// How far a bracket's partner is looked for, either way.
const PARTNER_WITHIN: usize = 10_000;

/// If a character is a bracket, its partner and whether it opens.
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

/// The character (grapheme cluster) a unit is in, as NSString's composed
/// character sequence there.
fn character(units: &[u16], at: usize) -> Option<String> {
    if at >= units.len() {
        return None;
    }
    // A window wide enough for any cluster but a pathological one.
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

/// Swift's Character.isWhitespace: its first scalar's.
fn whitespace(c: &str) -> bool {
    c.chars().next().is_some_and(char::is_whitespace)
}

/// How long the closer after the caret is, between an empty pair: 1, or 2
/// between `\[` and `\]`.
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
    /// A character typed in place of the selection: a bracket closed for the
    /// user (`auto_pair`) or stepped over, or none of that.
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
                // \[ closes with \], \{ with \} and \( with \).
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

    /// Delete at the caret: an empty pair put in for the user goes whole,
    /// and in a line's indentation it goes back to the last two-column stop.
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
        // Only a closer put in for the user goes with its bracket.
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

    /// Return: the line's indentation on the new line, and between an empty
    /// pair its closer on a line of its own below; the spaces after the caret
    /// go, and a caret in the indentation takes it down.
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
            while start + length < line.end && is(units[start + length], ' ') {
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

    /// The editor replaced `old` (before the change), its length changing by
    /// `delta`; `changing`, the range it said it would change, stands for
    /// `old` when it's within it from the same start. Closers after it move
    /// with the text and those in it go; a snippet's fields move, the one
    /// typed in grows (each mirrored place, while `mirroring`), and an edit
    /// anywhere else ends the snippet.
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

    /// The editor's selection (its first) moved: a snippet ends once it's
    /// outside the fields (unless the editor is mirroring one), and closers
    /// before its line are no longer stepped over.
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

    /// Where the bracket at `at` is matched, within 10,000 units either way.
    /// Brackets in comments are no one's, and an escaped one (`\{`, `\]`)
    /// pairs only with the escaped.
    pub fn partner(&self, at: u32) -> Option<u32> {
        let at = at as usize;
        let units = &self.text.units[..];
        let start = *units.get(at)?;
        let (partner, opens) = bracket(&String::from_utf16_lossy(&[start]))?;
        let partner = u16::from(partner.as_bytes()[0]);
        let near = at.saturating_sub(PARTNER_WITHIN)..(at + PARTNER_WITHIN + 1).min(units.len());
        // The brackets outside comments and whether each is escaped, in the
        // range; a comment is known from its line's start, so reading starts there.
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

/// Where the depth returns to zero, from the first of `brackets` (the one
/// matched): each `start` deepens it and each other lessens it.
fn matched<'a>(
    brackets: impl Iterator<Item = &'a (usize, u16, bool)>,
    start: u16,
) -> Option<usize> {
    let mut depth = 0;
    for &(i, u, _) in brackets {
        depth = if u == start { depth + 1 } else { depth - 1 };
        if depth == 0 {
            return Some(i);
        }
    }
    None
}
