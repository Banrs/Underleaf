use std::collections::BTreeSet;
use std::ops::Range;

use schemars::JsonSchema;
use serde::Serialize;

use super::scan::{Group, Visit, arguments, blank_line};
use super::snippet::Snippet;
use super::{
    INDENT, SourceDocument, TextEdit, TextRange, clamp, escaped, indentation, is, range, span,
    splice,
};
use crate::utf16;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, JsonSchema)]
pub(crate) struct Keystroke {
    pub(crate) edit: Option<TextEdit>,
    pub(crate) selection: Option<TextRange>,
    pub(crate) partner: Option<u32>,
    pub(crate) completions: Completing,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Completing {
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
    pub(crate) fn type_text(
        &mut self,
        selection: TextRange,
        typed: &str,
        auto_pair: bool,
    ) -> Keystroke {
        self.typing.pending = None;
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
        let dollar = auto_pair && is(key, '$');
        let innermost = (dollar && length == 0)
            .then(|| self.scanned_to(start).groups().pop())
            .flatten();
        let typing = &mut self.typing;
        let units = &self.text.units[..];
        let next = units.get(start).copied();
        if length == 0 && typing.closers.contains(&start) && (is_closing(key) || dollar) {
            let empty = |g: &Group| g.end == "$" && g.open + 1 == start;
            if dollar && next == Some(key) && innermost.as_ref().is_some_and(empty) {
                typing.pending = Some((start, start + 1));
                return Keystroke {
                    edit: Some(splice(start, 0, "$$")),
                    selection: Some(span(start + 1, 0)),
                    ..Keystroke::default()
                };
            }
            let escaped_closer =
                next.is_some_and(|u| is(u, '\\')) && units.get(start + 1) == Some(&key);
            if next == Some(key) && !(dollar && escaped(units, start)) || escaped_closer {
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
        let close = closing_of(key).or(dollar.then_some('$'));
        if let Some(close) = close.filter(|_| auto_pair) {
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
            let literal = dollar
                && (innermost.is_some_and(|g| g.math)
                    || escaped(units, start)
                    || units[..start].last().is_some_and(|&u| is(u, '$'))
                        && !escaped(units, start - 1));
            if next.is_none_or(|n| char::from_u32(n.into()).is_some_and(before)) && !literal {
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

    pub(crate) fn delete_backward(&mut self, selection: TextRange, auto_pair: bool) -> Keystroke {
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
        let dollars = units[caret - 1..].starts_with(&['$' as u16; 2]);
        if auto_pair
            && self.typing.closers.contains(&caret)
            && let Some(closer) = closer_after(units, caret).or(dollars.then_some(1))
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

    pub(crate) fn insert_newline(&mut self, selection: TextRange) -> Keystroke {
        self.typing.pending = None;
        let (mut start, end) = clamp(selection, self.text.len()).bounds();
        let mut length = end - start;
        let line = self.text.around(start);
        let groups = if length == 0 {
            self.scanned_to(start).groups()
        } else {
            vec![]
        };
        let units = &self.text.units[..];
        let indent = indentation(&units[line.start..line.end]);
        let indented = String::from_utf16_lossy(&units[line.start..line.start + indent]);
        let rest = units.get(start..line.end).unwrap_or_default();
        let key = |start: usize, length: usize, insert: String, caret: usize| Keystroke {
            edit: Some(splice(start, length, insert)),
            selection: Some(span(caret, 0)),
            completions: Completing::Close,
            ..Keystroke::default()
        };
        let begun = groups
            .last()
            .filter(|g| g.open >= line.start)
            .and_then(|g| {
                let name = g.end.strip_prefix("env:")?;
                let mut read = (g.open + "\\begin".len(), true);
                while read.1 {
                    read = arguments(&units[..start], read.0, |_, _| {});
                }
                (read.0 == start).then_some((name, g.open))
            });
        let step = match begun {
            Some(("document", _)) => "",
            _ if indented.starts_with('\t') => "\t",
            _ => INDENT,
        };
        let inner = format!("\n{indented}{step}");
        let caret = start + utf16::len(&inner);
        if let Some((name, begin)) = begun
            && blank_line(rest)
        {
            let rest = rest.len();
            let close = match self.environment_partner(begin) {
                Some(_) => String::new(),
                None => format!("\n{indented}\\end{{{name}}}"),
            };
            return key(start, rest, inner + &close, caret);
        }
        let end_tag = |(name, _)| utf16::lossy(rest).starts_with(&format!("\\end{{{name}}}"));
        if begun.is_some_and(end_tag) || length == 0 && closer_after(units, start).is_some() {
            return key(start, 0, format!("{inner}\n{indented}"), caret);
        }
        let list = groups.iter().rev().find_map(|g| g.end.strip_prefix("env:"));
        let from = line.start + indent;
        let content = utf16::lossy(units.get(from..start).unwrap_or_default());
        let item = content.strip_prefix("\\item");
        if matches!(list, Some("itemize" | "enumerate" | "description"))
            && blank_line(rest)
            && let Some(after) =
                item.filter(|after| after.starts_with(|c: char| !c.is_ascii_alphabetic()))
        {
            if after.trim().is_empty() {
                return key(from, line.end - from, String::new(), from);
            }
            let next = format!("\n{indented}\\item ");
            let caret = start + utf16::len(&next);
            return key(start, rest.len(), next, caret);
        }
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
        key(start, length, format!("\n{indented}"), start + 1 + indent)
    }

    pub fn apply_edit(
        &mut self,
        start: u32,
        length: u32,
        text: &str,
        changing: Option<TextRange>,
        mirroring: bool,
    ) -> Vec<TextEdit> {
        self.edit(start, length, text);
        let delta = utf16::len(text) as i64 - length as i64;
        self.follow(range(start, length), delta, changing, mirroring);
        if mirroring {
            return Vec::new();
        }
        self.mirror_snippet()
    }

    pub(super) fn follow(
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
        if !mirroring && typing.snippet.is_none() {
            self.typing.snippet = self.environment_names(selection);
        }
    }

    pub(super) fn environment_partner(&mut self, at: usize) -> Option<usize> {
        let mut scanner = self.scans.resume(&self.text, at, at).scanner;
        let units = &self.text.units;
        let mut partner = Partner { at, found: None };
        scanner.run(units, at + 1, &[], &mut partner);
        while partner.found.is_none()
            && scanner.i < units.len()
            && scanner.groups().iter().any(|g| g.open == at)
        {
            scanner.run(units, scanner.i + 1024, &[], &mut partner);
        }
        partner.found
    }

    pub(crate) fn partner(&self, at: u32) -> Option<u32> {
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

struct Partner {
    at: usize,
    found: Option<usize>,
}

impl Visit for Partner {
    fn closed(&mut self, group: &Group, close: Range<usize>) {
        if group.open == self.at {
            self.found = Some(close.start);
        } else if close.start == self.at {
            self.found = Some(group.open);
        }
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
