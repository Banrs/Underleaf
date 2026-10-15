//! Typing as the source editor assists it: brackets that close and are
//! stepped over, Delete back to an indent stop, Return keeping the line's
//! indentation, a bracket's partner, snippet fields that Tab goes through and
//! that mirror each other, Move Line Up and Down, and wrapping the selection.
//! The editor applies the answers and reports back each change (`follow`)
//! and each selection (`select`): the closers it put in and the snippet's
//! fields are kept here, between keys.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

use crate::{SnippetField, Text, TextEdit, TextRange, edit, is, utf16};

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
    /// Without a snippet: the indentation, as "indent" gives it.
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
    length: i64,
}

impl Field {
    fn end(&self) -> i64 {
        self.start + self.length
    }
}

/// Fields with the same index are one field in several places.
#[derive(Clone, Debug)]
struct Snippet {
    fields: Vec<Field>,
    active: i64,
}

impl Snippet {
    fn contains(&self, start: i64, end: i64) -> bool {
        self.fields
            .iter()
            .any(|f| f.start <= start && end <= f.end())
    }

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

const PAIRS: [(&str, &str); 3] = [("(", ")"), ("[", "]"), ("{", "}")];

/// An opening bracket is closed for the user before these, or space, or the end.
const CLOSE_BEFORE: [&str; 6] = [")", "]", "}", ":", ";", ">"];

fn closing_of(c: &str) -> Option<&'static str> {
    PAIRS
        .iter()
        .find(|(open, _)| *open == c)
        .map(|&(_, close)| close)
}

fn is_closing(c: &str) -> bool {
    PAIRS.iter().any(|&(_, close)| close == c)
}

/// The character (grapheme cluster) a unit is in, as NSString's composed
/// character sequence there.
fn character(units: &[u16], at: i64) -> Option<String> {
    if at < 0 || at as usize >= units.len() {
        return None;
    }
    let at = at as usize;
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

/// Whether the unit at `at` follows an unescaped backslash, as `\[`'s
/// bracket does.
fn escaped(units: &[u16], at: i64) -> bool {
    let at = at.clamp(0, units.len() as i64) as usize;
    let slashes = units[..at]
        .iter()
        .rev()
        .take_while(|&&u| is(u, '\\'))
        .count();
    slashes % 2 == 1
}

/// NSString's line terminators: a CRLF is one.
fn line_break(u: u16) -> bool {
    matches!(u, 0x0a | 0x0d | 0x85 | 0x2028 | 0x2029)
}

/// Where the line `at` is on starts, as NSString's lineRange.
fn line_start(units: &[u16], at: i64) -> i64 {
    let mut i = at.clamp(0, units.len() as i64) as usize;
    // Between a CR and its LF is in the line the pair ends.
    if i > 0 && i < units.len() && units[i] == 0x0a && units[i - 1] == 0x0d {
        i -= 1;
    }
    while i > 0 && !line_break(units[i - 1]) {
        i -= 1;
    }
    i as i64
}

/// Where the line `at` is on ends, before and after its terminator.
fn line_end(units: &[u16], at: i64) -> (i64, i64) {
    let mut i = at.clamp(0, units.len() as i64) as usize;
    while i < units.len() && !line_break(units[i]) {
        i += 1;
    }
    let contents = i;
    if i < units.len() {
        i += if units[i] == 0x0d && units.get(i + 1) == Some(&0x0a) {
            2
        } else {
            1
        };
    }
    (contents as i64, i as i64)
}

/// NSString's lineRange: the whole lines a range touches, terminators and
/// all; one ending at a line's start leaves that line.
fn line_range(units: &[u16], start: i64, length: i64) -> (i64, i64) {
    let last = if length > 0 {
        start + length - 1
    } else {
        start
    };
    (line_start(units, start), line_end(units, last).1)
}

fn range(start: i64, length: i64) -> TextRange {
    TextRange {
        start: start.max(0) as u32,
        length: length.max(0) as u32,
    }
}

fn span(range: TextRange) -> (i64, i64) {
    (range.start as i64, range.length as i64)
}

fn substring(units: &[u16], start: i64, end: i64) -> String {
    String::from_utf16_lossy(&units[start as usize..end as usize])
}

impl Typing {
    /// A character typed in place of the selection.
    pub fn type_text(
        &mut self,
        text: &Text,
        selection: TextRange,
        typed: &str,
        auto_pair: bool,
    ) -> Keystroke {
        self.pending = None;
        let units = &text.units[..];
        // More than a character, as an input method commits, goes in as it is.
        if typed.graphemes(true).count() != 1 {
            return Keystroke {
                completions: Completing::Close,
                ..Keystroke::default()
            };
        }
        let (start, length) = span(selection);
        let next = character(units, start);
        let next_is = |c: &str| next.as_deref() == Some(c);
        if length == 0 && self.closers.contains(&start) && is_closing(typed) {
            if next_is(typed) {
                self.closers.remove(&start);
                return Keystroke {
                    selection: Some(range(start + 1, 0)),
                    partner: Some(start as u32),
                    ..Keystroke::default()
                };
            }
            // A closer put in as \] or \}: its bracket steps over both, and a
            // backslash typed for it goes. A backslash alone is typed in,
            // being a command's as often as the closer's.
            if next_is("\\") && character(units, start + 1).as_deref() == Some(typed) {
                self.closers.remove(&start);
                let mut bracket = start + 1;
                let mut keystroke = Keystroke::default();
                if escaped(units, start) {
                    keystroke.edit = Some(edit(start as u32 - 1, 1, ""));
                    keystroke.completions = Completing::Close;
                    bracket -= 1;
                }
                keystroke.selection = Some(range(bracket + 1, 0));
                keystroke.partner = Some(bracket as u32);
                return keystroke;
            }
        }
        if let Some(close) = closing_of(typed).filter(|_| auto_pair) {
            if length > 0 {
                let selected = substring(units, start, start + length);
                self.pending = Some((start, start + length + 1));
                return Keystroke {
                    edit: Some(edit(
                        start as u32,
                        length as u32,
                        format!("{typed}{selected}{close}"),
                    )),
                    selection: Some(range(start + 1, length)),
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
                self.pending = Some((start, start + 1));
                return Keystroke {
                    edit: Some(edit(start as u32, 0, pair)),
                    selection: Some(range(start + 1, 0)),
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

    /// How long the closer after the caret is, between an empty pair: 1, or
    /// 2 between `\[` and `\]`.
    fn closer_after(units: &[u16], caret: i64) -> Option<i64> {
        let close = character(units, caret - 1).and_then(|c| closing_of(&c))?;
        let at = |i: i64| character(units, i);
        if at(caret).as_deref() == Some(close) {
            return Some(1);
        }
        (escaped(units, caret - 1)
            && at(caret).as_deref() == Some("\\")
            && at(caret + 1).as_deref() == Some(close))
        .then_some(2)
    }

    /// Delete: an empty pair put in for the user goes whole, and in a line's
    /// indentation it goes back to the last two-column stop.
    pub fn delete_backward(
        &mut self,
        text: &Text,
        selection: TextRange,
        auto_pair: bool,
    ) -> Keystroke {
        self.pending = None;
        let units = &text.units[..];
        let (caret, length) = span(selection);
        if length != 0 || caret == 0 {
            return Keystroke::default();
        }
        let delete = |from: i64, to: i64| Keystroke {
            edit: Some(edit(from as u32, (to - from) as u32, "")),
            completions: Completing::Close,
            ..Keystroke::default()
        };
        // Only a closer put in for the user goes with its bracket.
        if auto_pair
            && self.closers.contains(&caret)
            && let Some(closer) = Self::closer_after(units, caret)
        {
            return delete(caret - 1, caret + closer);
        }
        let indent = &units[line_start(units, caret) as usize..caret as usize];
        if !indent.is_empty() && indent.iter().all(|&u| is(u, ' ')) {
            let drop = if indent.len().is_multiple_of(2) { 2 } else { 1 };
            return delete(caret - drop, caret);
        }
        Keystroke::default()
    }

    /// Return: the line's indentation on the new line, and between an empty
    /// pair its closer on a line of its own below; the spaces after the caret
    /// go, and a caret in the indentation takes it down.
    pub fn insert_newline(&mut self, text: &Text, selection: TextRange) -> Keystroke {
        self.pending = None;
        let units = &text.units[..];
        let (mut start, mut length) = span(selection);
        let (line, line_end_all) = line_range(units, start, 0);
        let line_text = substring(units, line, line_end_all);
        // Trimmed of .newlines at both ends, as Foundation trims.
        let newline = |c: char| {
            matches!(
                c,
                '\n' | '\u{0b}' | '\u{0c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
            )
        };
        let line_text = line_text.trim_matches(newline);
        let indent: String = line_text
            .chars()
            .take_while(|&c| c == ' ' || c == '\t')
            .collect();
        let line_end = line + utf16(line_text) as i64;
        let between = length == 0 && Self::closer_after(units, start).is_some();
        let mut insert = format!("\n{indent}");
        if between {
            insert.push_str(&format!("\n{indent}"));
        } else {
            while start + length < line_end && is(units[(start + length) as usize], ' ') {
                length += 1;
            }
            if start > line
                && String::from_utf16_lossy(&units[line as usize..start as usize])
                    .chars()
                    .all(char::is_whitespace)
            {
                length += start - line;
                start = line;
            }
        }
        Keystroke {
            edit: Some(edit(start as u32, length as u32, insert)),
            selection: Some(range(start + 1 + utf16(&indent) as i64, 0)),
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
        let old = changing
            .filter(|c| c.start == old.start && c.start + c.length <= old.start + old.length)
            .unwrap_or(old);
        let (start, length) = span(old);
        let end = start + length;
        self.closers = self
            .closers
            .iter()
            .filter_map(|&p| {
                if p >= end {
                    Some(p + delta)
                } else {
                    (p < start).then_some(p)
                }
            })
            .collect();
        if let Some((at, closer)) = self.pending.take()
            && at == start
        {
            self.closers.insert(closer);
        }
        let Some(snippet) = &mut self.snippet else {
            return;
        };
        let in_field = |f: &Field| f.start <= start && end <= f.end();
        if !mirroring {
            if !snippet.typed().is_some_and(|typed| in_field(&typed)) {
                self.snippet = None;
                return;
            }
            let active = snippet.active;
            self.needs_mirror = snippet.fields.iter().filter(|f| f.index == active).count() > 1;
        }
        for i in 0..snippet.fields.len() {
            let field = snippet.fields[i];
            if in_field(&field) && (mirroring || snippet.typed() == Some(field)) {
                snippet.fields[i].length += delta;
            } else if field.start >= end {
                snippet.fields[i].start += delta;
            }
        }
    }

    /// The selection moved: a snippet ends once it's outside the fields
    /// (unless the editor is mirroring one), and closers before its line are
    /// no longer stepped over.
    pub fn select(&mut self, text: &Text, selection: TextRange, mirroring: bool) {
        let (start, length) = span(selection);
        if !mirroring
            && self
                .snippet
                .as_ref()
                .is_some_and(|s| !s.contains(start, start + length))
        {
            self.snippet = None;
        }
        let line = line_start(&text.units, start);
        self.closers.retain(|&p| p >= line);
    }

    /// A snippet's fields, from `at`, the first selected: Tab goes through
    /// them while there's another, or a field in two places. None without a
    /// first field.
    pub fn start_snippet(&mut self, fields: &[SnippetField], at: u32) -> Option<TextRange> {
        let fields: Vec<Field> = fields
            .iter()
            .map(|f| Field {
                index: f.index as i64,
                start: at as i64 + f.start as i64,
                length: f.length as i64,
            })
            .collect();
        let first = *fields.iter().find(|f| f.index == 0)?;
        self.snippet = (fields.len() > 1).then_some(Snippet { fields, active: 0 });
        Some(range(first.start, first.length))
    }

    /// Escape: whether there was a snippet to end.
    pub fn end_snippet(&mut self) -> bool {
        self.snippet.take().is_some()
    }

    /// Tab and Shift-Tab (`step` 1 and -1): a snippet's next field or the one
    /// before; without one, the lines indented or outdented.
    pub fn tab(&mut self, text: &Text, selections: &[TextRange], step: i64) -> Tab {
        let Some(snippet) = &mut self.snippet else {
            return Tab {
                field: None,
                edits: crate::edit::indent(text, selections, step > 0),
            };
        };
        let next = snippet.active + step;
        let Some(field) = snippet.fields.iter().find(|f| f.index == next).copied() else {
            return Tab::default();
        };
        snippet.active = next;
        if snippet.fields.iter().all(|f| f.index <= next) {
            self.snippet = None;
        }
        Tab {
            field: Some(range(field.start, field.length)),
            edits: vec![],
        }
    }

    /// What's typed in a field for its other places, from the last, once
    /// `follow` has seen it change; the editor applies them while
    /// `mirroring`, then selects what it had.
    pub fn mirror_snippet(&mut self, text: &Text) -> Vec<TextEdit> {
        let Some(snippet) = self.snippet.as_ref().filter(|_| self.needs_mirror) else {
            return vec![];
        };
        let Some(typed) = snippet.typed() else {
            return vec![];
        };
        self.needs_mirror = false;
        let len = text.units.len() as i64;
        let typed_text = substring(&text.units, typed.start.min(len), typed.end().min(len));
        snippet
            .fields
            .iter()
            .rev()
            .filter(|f| f.index == snippet.active && **f != typed)
            .map(|f| edit(f.start as u32, f.length as u32, typed_text.clone()))
            .collect()
    }
}

/// Where a bracket at `at` is matched, within 10,000 units either way.
pub fn partner(text: &Text, at: u32) -> Option<u32> {
    let units = &text.units[..];
    let c = *units.get(at as usize)?;
    let ch = char::from_u32(c as u32)?.to_string();
    let close = closing_of(&ch);
    let open = PAIRS.iter().find(|(_, cl)| *cl == ch).map(|&(o, _)| o);
    let other = close.or(open)?.encode_utf16().next()?;
    let (mut depth, mut i) = (0i64, at as i64);
    while (i - at as i64).abs() <= 10_000 && i >= 0 && (i as usize) < units.len() {
        let d = units[i as usize];
        if d == c {
            depth += 1;
        } else if d == other {
            depth -= 1;
        }
        if depth == 0 {
            return Some(i as u32);
        }
        i += if close.is_some() { 1 } else { -1 };
    }
    None
}

/// The lines the selections touch, each run of them past the line above or
/// below, the selections going with them; none when a run is already at the
/// text's start or end.
pub fn move_lines(text: &Text, selections: &[TextRange], up: bool) -> Option<Change> {
    let units = &text.units[..];
    let len = units.len() as i64;
    // Each selection's whole lines; one ending at a line's start doesn't take that line.
    let mut runs: Vec<(i64, i64)> = Vec::new();
    for selection in selections {
        let (start, length) = span(*selection);
        let run = line_range(units, start.min(len), length.min(len - start.min(len)));
        match runs.last_mut() {
            Some(previous) if run.0 <= previous.1 => {
                *previous = (previous.0.min(run.0), previous.1.max(run.1));
            }
            _ => runs.push(run),
        }
    }
    runs.sort_by_key(|run| run.0);
    let mut edits = Vec::new();
    let mut shifts = Vec::new();
    for &(start, end) in &runs {
        // The empty line after a final line break has nothing to move.
        if end == start || (if up { start == 0 } else { end >= len }) {
            return None;
        }
        let neighbour = line_range(units, if up { start - 1 } else { end }, 0);
        let whole = (start.min(neighbour.0), end.max(neighbour.1));
        // The lines' text trades places; the line ends stay where they were,
        // so a last line without one keeps none.
        let mut lines = Vec::new();
        let mut at = whole.0;
        while at < whole.1 {
            let (contents, next) = line_end(units, at);
            let (contents, next) = (contents.min(whole.1), next.min(whole.1));
            lines.push((
                substring(units, at, contents),
                substring(units, contents, next),
            ));
            at = next;
        }
        // The neighbour is one line, first going up and last going down.
        let mut moved: Vec<&String> = lines.iter().map(|(text, _)| text).collect();
        if up {
            moved.rotate_left(1);
        } else {
            moved.rotate_right(1);
        }
        let joined: String = moved
            .iter()
            .zip(&lines)
            .map(|(text, (_, end))| format!("{text}{end}"))
            .collect();
        edits.push(edit(whole.0 as u32, (whole.1 - whole.0) as u32, joined));
        let new_start = if up {
            whole.0
        } else {
            whole.0 + (utf16(moved[0]) + utf16(&lines[0].1)) as i64
        };
        shifts.push(((start, end), new_start - start));
    }
    let selections = selections
        .iter()
        .map(|selection| {
            let (at, length) = span(*selection);
            let by = shifts
                .iter()
                .find(|((start, end), _)| {
                    (*start <= at && at < *end) || (at == *end && length == 0 && *end == len)
                })
                .map_or(0, |&(_, by)| by);
            range(at + by, length)
        })
        .collect();
    Some(Change { edits, selections })
}

/// The selection (the first) between a template's text before "$0" and
/// after, still selected, or the caret between them.
pub fn wrap(text: &Text, selections: &[TextRange], template: &str) -> Change {
    let joined = format!("{template}$0");
    let parts: Vec<&str> = joined.split("$0").collect();
    let prefix = parts[0];
    let suffix = parts[1..parts.len() - 1].join("$0");
    wrap_in(text, selections, prefix, &suffix)
}

fn wrap_in(text: &Text, selections: &[TextRange], prefix: &str, suffix: &str) -> Change {
    let selection = crate::clamp(
        selections.first().copied().unwrap_or_default(),
        text.units.len() as u32,
    );
    let (start, length) = span(selection);
    let selected = substring(&text.units, start, start + length);
    Change {
        edits: vec![edit(
            selection.start,
            selection.length,
            format!("{prefix}{selected}{suffix}"),
        )],
        selections: vec![range(start + utf16(prefix) as i64, length)],
    }
}

/// Bold, Italic or Underline off where the selection (the first) is in its
/// command, as a word processor's: the command unwraps, the selections
/// following the text; on otherwise, round the selection.
pub fn toggle_style(
    text: &Text,
    styles: crate::TextStyles,
    selections: &[TextRange],
    style: Style,
) -> Change {
    let (unwrap, command) = match style {
        Style::Bold => (styles.bold, "\\textbf{"),
        Style::Italic => (styles.italic, "\\textit{"),
        Style::Underline => (styles.underline, "\\underline{"),
    };
    match unwrap {
        Some(edits) => Change {
            selections: map_selections(&edits, selections),
            edits,
        },
        None => wrap_in(text, selections, command, "}"),
    }
}

/// Where selections go through edits (in order, applied from the last): text
/// put in at a selection's start goes before it, and a selection's end in
/// replaced text goes to the replacement's end.
pub fn map_selections(edits: &[TextEdit], selections: &[TextRange]) -> Vec<TextRange> {
    let map = |position: i64| {
        let mut shift = 0i64;
        for e in edits {
            let inserted = utf16(&e.text) as i64;
            let (start, length) = (e.start as i64, e.length as i64);
            if start + length <= position {
                shift += inserted - length;
            } else if start < position {
                return start + shift + inserted;
            }
        }
        position + shift
    };
    selections
        .iter()
        .map(|s| {
            let (start, length) = span(*s);
            let from = map(start);
            range(from, map(start + length) - from)
        })
        .collect()
}
