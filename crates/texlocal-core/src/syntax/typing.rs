//! Typing as the source editor assists it: brackets that close and are
//! stepped over, Delete back to an indent stop, Return keeping the line's
//! indentation, a bracket's partner, snippet fields that Tab goes through and
//! that mirror each other, Move Line Up and Down, and wrapping the selection.
//! The editor applies the answers and reports back each change (`follow`)
//! and each selection (`select`): the closers it put in and the snippet's
//! fields are kept here, between keys.

use std::collections::BTreeSet;
use std::ops::Range;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

use super::{SnippetField, SourceDocument, TextEdit, TextRange};
use super::{clamp, edit, escaped, is, range, utf16};

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

use Completing::*;

/// Edits, applied from the last as one undo step, and the selections after.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Change {
    pub edits: Vec<TextEdit>,
    pub selections: Vec<TextRange>,
}

/// Tab: a snippet's next field, or the lines indented.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Tab {
    /// The field to select; none, with a snippet, where there's no other.
    pub field: Option<TextRange>,
    /// Without a snippet: the indentation, as `SourceDocument::indent` gives it.
    pub edits: Vec<TextEdit>,
}

/// The bold, italic or underline Format toggles.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Style {
    Bold,
    Italic,
    Underline,
}

/// A place of a snippet's field, in the text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Field {
    index: i64,
    start: i64,
    len: i64,
}

impl Field {
    fn holds(&self, (start, end): (i64, i64)) -> bool {
        self.start <= start && end <= self.start + self.len
    }

    fn range(&self) -> TextRange {
        range(self.start as u32, self.len as u32)
    }
}

/// Fields with the same index are one field in several places.
struct Snippet {
    fields: Vec<Field>,
    active: i64,
}

impl Snippet {
    /// The active field's first place, the one typed in.
    fn typed(&self) -> Option<Field> {
        self.fields.iter().find(|f| f.index == self.active).copied()
    }
}

/// What typing keeps between keys.
#[derive(Default)]
pub(crate) struct Typing {
    /// Closing brackets put in for the user, which typing one steps over.
    closers: BTreeSet<i64>,
    snippet: Option<Snippet>,
    /// The typed field changed: its other places are to follow it.
    needs_mirror: bool,
    /// A closer a key put in, kept once its edit, at `start`, is followed.
    pending: Option<(i64, i64)>,
}

fn closing_of(c: &str) -> Option<&'static str> {
    match c {
        "(" => Some(")"),
        "[" => Some("]"),
        "{" => Some("}"),
        _ => None,
    }
}

fn is_closing(c: &str) -> bool {
    matches!(c, ")" | "]" | "}")
}

/// A range's start and end, signed for the arithmetic of edits.
fn ends(r: TextRange) -> (i64, i64) {
    (r.start as i64, r.start as i64 + r.length as i64)
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
    let window = String::from_utf16_lossy(&units[from..(at + 32).min(units.len())]);
    let mut end = from;
    let mut clusters = window.graphemes(true);
    let cluster = clusters.find(|cluster| {
        end += utf16(cluster);
        at < end
    });
    cluster.map(str::to_owned)
}

/// NSString's line terminators: a CRLF is one.
fn line_break(u: u16) -> bool {
    matches!(u, 0x0a | 0x0d | 0x85 | 0x2028 | 0x2029)
}

/// Where the line `at` is on starts, as NSString's lineRange.
fn line_start(units: &[u16], at: usize) -> usize {
    let mut i = at.min(units.len());
    // Between a CR and its LF is in the line the pair ends.
    if i > 0 && i < units.len() && units[i] == 0x0a && units[i - 1] == 0x0d {
        i -= 1;
    }
    let found = units[..i].iter().rposition(|&u| line_break(u));
    found.map_or(0, |p| p + 1)
}

/// Where the line `at` is on ends, before and after its terminator.
fn line_end(units: &[u16], at: usize) -> (usize, usize) {
    let at = at.min(units.len());
    let Some(p) = units[at..].iter().position(|&u| line_break(u)) else {
        return (units.len(), units.len());
    };
    let contents = at + p;
    let crlf = units[contents] == 0x0d && units.get(contents + 1) == Some(&0x0a);
    (contents, contents + 1 + crlf as usize)
}

/// NSString's lineRange: the whole lines a range touches, terminators and
/// all; one ending at a line's start leaves that line.
fn line_range(units: &[u16], start: usize, length: usize) -> (usize, usize) {
    let last = start + length.saturating_sub(1);
    (line_start(units, start), line_end(units, last).1)
}

/// How long the closer after the caret is, between an empty pair: 1, or 2
/// between `\[` and `\]`.
fn closer_after(units: &[u16], caret: usize) -> Option<usize> {
    let close = closing_of(&character(units, caret.checked_sub(1)?)?)?;
    let at = |i| character(units, i);
    if at(caret).as_deref() == Some(close) {
        return Some(1);
    }
    let escaped_pair = escaped(units, caret - 1) && at(caret).as_deref() == Some("\\");
    (escaped_pair && at(caret + 1).as_deref() == Some(close)).then_some(2)
}

fn key(e: Option<TextEdit>, s: Option<TextRange>, p: Option<u32>, c: Completing) -> Keystroke {
    Keystroke {
        edit: e,
        selection: s,
        partner: p,
        completions: c,
    }
}

impl SourceDocument {
    /// A character typed in place of the selection: a bracket closed for the
    /// user (`auto_pair`) or stepped over, or none of that.
    pub fn type_text(&mut self, selection: TextRange, typed: &str, auto_pair: bool) -> Keystroke {
        self.typing.pending = None;
        // More than a character, as an input method commits, goes in as it is.
        if typed.graphemes(true).count() != 1 {
            return key(None, None, None, Close);
        }
        let TextRange { start, length } = clamp(selection, self.text.len());
        self.text.reach_line(start + length);
        let (units, typing, at) = (self.text.units(), &mut self.typing, start as usize);
        let next = character(units, at);
        let next_is = |c: &str| next.as_deref() == Some(c);
        let step = |to: u32, partner| key(None, Some(range(to, 0)), Some(partner), Keep);
        if length == 0 && is_closing(typed) && typing.closers.contains(&(at as i64)) {
            if next_is(typed) {
                typing.closers.remove(&(at as i64));
                return step(start + 1, start);
            }
            // A closer put in as \] or \}: its bracket steps over both, and a
            // backslash typed for it goes. A backslash alone is typed in,
            // being a command's as often as the closer's.
            if next_is("\\") && character(units, at + 1).as_deref() == Some(typed) {
                typing.closers.remove(&(at as i64));
                if !escaped(units, at) {
                    return step(start + 2, start + 1);
                }
                let gone = Some(edit(start - 1, 1, ""));
                return key(gone, Some(range(start + 1, 0)), Some(start), Close);
            }
        }
        if let Some(close) = closing_of(typed).filter(|_| auto_pair) {
            if length > 0 {
                let selected = String::from_utf16_lossy(&units[at..at + length as usize]);
                typing.pending = Some((at as i64, (at + length as usize + 1) as i64));
                let round = Some(edit(start, length, format!("{typed}{selected}{close}")));
                return key(round, Some(range(start + 1, length)), None, Keep);
            }
            let before = |n: &str| n.starts_with(char::is_whitespace) || ")]}:;>".contains(n);
            if next.as_deref().is_none_or(before) {
                // \[ closes with \], \{ with \} and \( with \).
                let slash = if escaped(units, at) { "\\" } else { "" };
                typing.pending = Some((at as i64, at as i64 + 1));
                let pair = Some(edit(start, 0, format!("{typed}{slash}{close}")));
                return key(pair, Some(range(start + 1, 0)), None, Offer);
            }
        }
        key(None, None, is_closing(typed).then_some(start), Offer)
    }

    /// Delete at the caret: an empty pair put in for the user goes whole,
    /// and in a line's indentation it goes back to the last two-column stop.
    pub fn delete_backward(&mut self, selection: TextRange, auto_pair: bool) -> Keystroke {
        self.typing.pending = None;
        let TextRange { start, length } = clamp(selection, self.text.len());
        if length != 0 || start == 0 {
            return Keystroke::default();
        }
        self.text.reach_line(start);
        let (units, caret) = (self.text.units(), start as usize);
        let delete = |from: usize, to: usize| {
            let gone = edit(from as u32, (to - from) as u32, "");
            key(Some(gone), None, None, Close)
        };
        // Only a closer put in for the user goes with its bracket.
        let closer = closer_after(units, caret).filter(|_| auto_pair);
        if let Some(closer) = closer.filter(|_| self.typing.closers.contains(&(caret as i64))) {
            return delete(caret - 1, caret + closer);
        }
        let indent = &units[line_start(units, caret)..caret];
        if !indent.is_empty() && indent.iter().all(|&u| is(u, ' ')) {
            return delete(caret - (2 - indent.len() % 2), caret);
        }
        Keystroke::default()
    }

    /// Return: the line's indentation on the new line, and between an empty
    /// pair its closer on a line of its own below; the spaces after the caret
    /// go, and a caret in the indentation takes it down.
    pub fn insert_newline(&mut self, selection: TextRange) -> Keystroke {
        self.typing.pending = None;
        let selection = clamp(selection, self.text.len());
        self.text.reach_line(selection.start);
        let units = self.text.units();
        let (mut start, mut length) = (selection.start as usize, selection.length as usize);
        let line = line_start(units, start);
        let text = String::from_utf16_lossy(&units[line..line_end(units, start).1]);
        // Trimmed of .newlines at both ends, as Foundation trims.
        let text = text.trim_matches(|c| "\n\u{b}\u{c}\r\u{85}\u{2028}\u{2029}".contains(c));
        let indent = &text[..text.len() - text.trim_start_matches([' ', '\t']).len()];
        let line_end = line + utf16(text);
        let mut insert = format!("\n{indent}");
        if length == 0 && closer_after(units, start).is_some() {
            insert = insert.repeat(2);
        } else {
            while start + length < line_end && is(units[start + length], ' ') {
                length += 1;
            }
            let lead = String::from_utf16_lossy(&units[line..start]);
            if start > line && lead.chars().all(char::is_whitespace) {
                (start, length) = (line, length + start - line);
            }
        }
        let caret = Some(range((start + 1 + utf16(indent)) as u32, 0));
        let newline = Some(edit(start as u32, length as u32, insert));
        key(newline, caret, None, Close)
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
        let within = |c: &TextRange| c.start == old.start && c.length <= old.length;
        let (start, end) = ends(changing.filter(within).unwrap_or(old));
        let after = typing.closers.split_off(&end);
        typing.closers.retain(|&p| p < start);
        typing.closers.extend(after.into_iter().map(|p| p + delta));
        if let Some((at, closer)) = typing.pending.take()
            && at == start
        {
            typing.closers.insert(closer);
        }
        let Some(snippet) = &mut typing.snippet else {
            return;
        };
        let typed = snippet.typed();
        if !mirroring {
            if !typed.is_some_and(|typed| typed.holds((start, end))) {
                typing.snippet = None;
                return;
            }
            let places = snippet.fields.iter().filter(|f| f.index == snippet.active);
            typing.needs_mirror = places.count() > 1;
        }
        for field in &mut snippet.fields {
            if field.holds((start, end)) && (mirroring || typed == Some(*field)) {
                field.len += delta;
            } else if field.start >= end {
                field.start += delta;
            }
        }
    }

    /// The editor's selection (its first) moved: a snippet ends once it's
    /// outside the fields (unless the editor is mirroring one), and closers
    /// before its line are no longer stepped over.
    pub fn select(&mut self, selection: TextRange, mirroring: bool) {
        let typing = &mut self.typing;
        let outside = |s: &Snippet| !s.fields.iter().any(|f| f.holds(ends(selection)));
        if !mirroring && typing.snippet.as_ref().is_some_and(outside) {
            typing.snippet = None;
        }
        self.text.reach(selection.start as usize + 1);
        let line = line_start(self.text.units(), selection.start as usize) as i64;
        typing.closers.retain(|&p| p >= line);
    }

    /// A completion's or block's fields, from `at`, the first selected: Tab
    /// goes through them while there's another, or a field in two places.
    /// None without a first field.
    pub fn start_snippet(&mut self, fields: &[SnippetField], at: u32) -> Option<TextRange> {
        let field = |f: &SnippetField| {
            let (index, len) = (f.index as i64, f.length as i64);
            let start = at as i64 + f.start as i64;
            Field { index, start, len }
        };
        let fields: Vec<Field> = fields.iter().map(field).collect();
        let first = fields.iter().find(|f| f.index == 0)?.range();
        self.typing.snippet = (fields.len() > 1).then_some(Snippet { fields, active: 0 });
        Some(first)
    }

    /// Escape: whether there was a snippet to end.
    pub fn end_snippet(&mut self) -> bool {
        self.typing.snippet.take().is_some()
    }

    /// Tab and Shift-Tab (`step` 1 and -1): a snippet's next field or the one
    /// before; without one, the lines indented or outdented.
    pub fn tab(&mut self, selections: &[TextRange], step: i64) -> Tab {
        let Some(snippet) = &mut self.typing.snippet else {
            let edits = self.indent(selections, step > 0);
            return Tab { field: None, edits };
        };
        let next = snippet.active + step;
        let Some(field) = snippet.fields.iter().find(|f| f.index == next).copied() else {
            return Tab::default();
        };
        snippet.active = next;
        if snippet.fields.iter().all(|f| f.index <= next) {
            self.typing.snippet = None;
        }
        let (field, edits) = (Some(field.range()), vec![]);
        Tab { field, edits }
    }

    /// What's typed in a snippet's field for its other places, from the
    /// last, once `follow` has seen it change; the editor applies them while
    /// `mirroring`, then selects what it had.
    pub fn mirror_snippet(&mut self) -> Vec<TextEdit> {
        let typing = &mut self.typing;
        let snippet = typing.snippet.as_ref().filter(|_| typing.needs_mirror);
        let Some((snippet, typed)) = snippet.and_then(|s| Some((s, s.typed()?))) else {
            return vec![];
        };
        typing.needs_mirror = false;
        let n = self.text.len() as i64;
        let (from, to) = (typed.start.min(n), (typed.start + typed.len).min(n));
        self.text.reach(to as usize);
        let text = String::from_utf16_lossy(&self.text.units()[from as usize..to as usize]);
        let other = |f: &&Field| f.index == snippet.active && **f != typed;
        let mirrored = |f: &Field| edit(f.start as u32, f.len as u32, text.clone());
        let places = snippet.fields.iter().rev().filter(other);
        places.map(mirrored).collect()
    }

    /// Where the bracket at `at` is matched, within 10,000 units either way.
    pub fn partner(&mut self, at: u32) -> Option<u32> {
        let at = at as usize;
        self.text.reach(at + 10_001);
        let units = self.text.units();
        let c = *units.get(at)?;
        // Each opener, then its closer: a bracket's partner is its neighbour.
        let i = "()[]{}".find(char::from_u32(c as u32)?)?;
        let (other, forward) = (b"()[]{}"[i ^ 1] as u16, i % 2 == 0);
        let mut depth = 0;
        let mut matched = |&i: &usize| {
            depth += (units[i] == c) as i32 - (units[i] == other) as i32;
            depth == 0
        };
        let found = if forward {
            (at..units.len().min(at + 10_001)).find(&mut matched)
        } else {
            (at.saturating_sub(10_000)..=at).rev().find(&mut matched)
        };
        found.map(|i| i as u32)
    }

    /// Move Line Up or Down: the lines the selections touch, each run of
    /// them past the line above or below, the selections going with them;
    /// none when a run is already at the text's start or end.
    pub fn move_lines(&mut self, selections: &[TextRange], up: bool) -> Option<Change> {
        self.text.reach(usize::MAX);
        let units = self.text.units();
        let len = units.len();
        // Each selection's whole lines; one ending at a line's start doesn't take that line.
        let mut runs: Vec<(usize, usize)> = Vec::new();
        for selection in selections {
            let start = (selection.start as usize).min(len);
            let run = line_range(units, start, (selection.length as usize).min(len - start));
            match runs.last_mut() {
                Some(last) if run.0 <= last.1 => *last = (last.0.min(run.0), last.1.max(run.1)),
                _ => runs.push(run),
            }
        }
        runs.sort_by_key(|run| run.0);
        let piece = |r: &Range<usize>| String::from_utf16_lossy(&units[r.clone()]);
        let (mut edits, mut shifts) = (vec![], vec![]);
        for &(start, end) in &runs {
            // The empty line after a final line break has nothing to move.
            if end == start || if up { start == 0 } else { end >= len } {
                return None;
            }
            let neighbour = line_range(units, if up { start - 1 } else { end }, 0);
            let (from, to) = (start.min(neighbour.0), end.max(neighbour.1));
            // The lines' text trades places; the line ends stay where they were,
            // so a last line without one keeps none. The neighbour is one line,
            // first going up and last going down.
            let (mut texts, mut breaks, mut at) = (vec![], vec![], from);
            while at < to {
                let (contents, next) = line_end(units, at);
                let (contents, next) = (contents.min(to), next.min(to));
                texts.push(at..contents);
                breaks.push(contents..next);
                at = next;
            }
            let by = if up { 1 } else { texts.len() - 1 };
            texts.rotate_left(by);
            let pairs = texts.iter().zip(&breaks);
            let moved: String = pairs.flat_map(|(t, b)| [piece(t), piece(b)]).collect();
            edits.push(edit(from as u32, (to - from) as u32, moved));
            let first = texts[0].len() + breaks[0].len();
            let new_start = if up { from } else { from + first };
            shifts.push((start, end, new_start as i64 - start as i64));
        }
        let moved = |s: &TextRange| {
            let at = s.start as usize;
            let moving = |&&(start, end, _): &&(usize, usize, i64)| {
                (start..end).contains(&at) || (at == end && s.length == 0 && end == len)
            };
            let by = shifts.iter().find(moving).map_or(0, |r| r.2);
            range((at as i64 + by) as u32, s.length)
        };
        let selections = selections.iter().map(moved).collect();
        Some(Change { edits, selections })
    }

    /// The selection (the first) between a template's text before "$0" and
    /// after, still selected, or the caret between them.
    pub fn wrap(&mut self, selections: &[TextRange], template: &str) -> Change {
        let (prefix, suffix) = template.split_once("$0").unwrap_or((template, ""));
        self.wrap_in(selections, prefix, suffix)
    }

    fn wrap_in(&mut self, selections: &[TextRange], prefix: &str, suffix: &str) -> Change {
        let first = selections.first().copied().unwrap_or_default();
        let TextRange { start, length } = clamp(first, self.text.len());
        self.text.reach((start + length) as usize);
        let selected = &self.text.units()[start as usize..][..length as usize];
        let text = format!("{prefix}{}{suffix}", String::from_utf16_lossy(selected));
        let edits = vec![edit(start, length, text)];
        let selections = vec![range(start + utf16(prefix) as u32, length)];
        Change { edits, selections }
    }

    /// Bold, Italic or Underline off where the selection (the first) is in
    /// its command, as a word processor's: the command unwraps, the
    /// selections following the text; on otherwise, round the selection.
    pub fn toggle_style(&mut self, selections: &[TextRange], style: Style) -> Change {
        let styles = self.text_styles(selections.first().copied().unwrap_or_default());
        let (unwrap, command) = match style {
            Style::Bold => (styles.bold, "\\textbf{"),
            Style::Italic => (styles.italic, "\\textit{"),
            Style::Underline => (styles.underline, "\\underline{"),
        };
        let Some(edits) = unwrap else {
            return self.wrap_in(selections, command, "}");
        };
        let selections = map_selections(&edits, selections);
        Change { edits, selections }
    }
}

/// Where selections go through edits (in order, applied from the last): text
/// put in at a selection's start goes before it, and a selection's end in
/// replaced text goes to the replacement's end.
pub fn map_selections(edits: &[TextEdit], selections: &[TextRange]) -> Vec<TextRange> {
    let map = |position: i64| {
        let mut shift = 0i64;
        for e in edits {
            let (start, end) = ends(range(e.start, e.length));
            let inserted = utf16(&e.text) as i64;
            if end <= position {
                shift += inserted - (end - start);
            } else if start < position {
                return start + shift + inserted;
            }
        }
        position + shift
    };
    let to = |s: &TextRange| {
        let (from, to) = (map(s.start as i64), map(ends(*s).1));
        range(from.max(0) as u32, (to - from).max(0) as u32)
    };
    selections.iter().map(to).collect()
}
