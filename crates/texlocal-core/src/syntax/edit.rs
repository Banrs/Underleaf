//! The editing commands of the menus and shortcuts: comment toggling,
//! indentation, heading levels, blocks and maths symbols, Move Line Up and
//! Down, and wrapping the selection. Each answers edits, and for those that
//! move the selection, where it goes.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use super::scan::{blank_line, closing_brace, strip_comment};
use super::{
    Insertion, Line, SourceDocument, Text, TextEdit, TextRange, catalog, clamp, complete, edit,
    indentation, is, span, splice, utf16,
};

/// Edits, applied from the last as one undo step, and the selections after.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Change {
    pub edits: Vec<TextEdit>,
    pub selections: Vec<TextRange>,
}

/// The bold, italic or underline Format toggles.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Style {
    Bold,
    Italic,
    Underline,
}

/// The lines the selections touch, in order. A selection ending at a
/// line's start leaves that line alone.
fn touched_lines(text: &Text, selections: &[TextRange]) -> BTreeSet<usize> {
    let len = text.units.len() as u32;
    let mut lines = BTreeSet::new();
    for selection in selections {
        let from = selection.start.min(len);
        let to = selection.start.saturating_add(selection.length).min(len);
        let end = if to > from && text.lines[text.line_index(to)] == to {
            to - 1
        } else {
            to
        };
        lines.extend(text.line_index(from)..=text.line_index(end));
    }
    lines
}

/// A sectioning command, to its title's opening brace: its star and short title.
static HEADING: LazyLock<Regex> = LazyLock::new(|| {
    // The levels the menus offer, then the one they don't.
    let levels = catalog::CATALOG.heading_levels.iter();
    let names = levels
        .map(|level| level.command.as_str())
        .chain(["subparagraph"]);
    let names = names.map(regex::escape).collect::<Vec<_>>().join("|");
    Regex::new(&format!(r"\\({names})(\*?)\s*(\[[^\]]*\])?\s*\{{")).unwrap()
});

impl SourceDocument {
    /// "%" comments on or off for the lines the selections touch: off when
    /// every one is already commented (or blank), on otherwise. In order;
    /// the editor applies them from the last.
    pub fn toggle_comment(&self, selections: &[TextRange]) -> Vec<TextEdit> {
        let text = &self.text;
        let lines = touched_lines(text, selections);
        let commented = |line: &[u16]| line.get(indentation(line)).is_some_and(|&u| is(u, '%'));
        let uncomment = lines
            .iter()
            .all(|&l| commented(text.line(l)) || blank_line(text.line(l)));
        lines
            .into_iter()
            .filter_map(|l| {
                let (line, start) = (text.line(l), text.lines[l]);
                if !uncomment {
                    return (!blank_line(line)).then(|| edit(start, 0, "% "));
                }
                let at = indentation(line);
                let space_after = line.get(at + 1).is_some_and(|&u| is(u, ' '));
                commented(line).then(|| edit(start + at as u32, 1 + space_after as u32, ""))
            })
            .collect()
    }

    /// Two spaces more, or one two-column indent unit fewer, at the start of
    /// each line the selections touch.
    pub fn indent(&self, selections: &[TextRange], more: bool) -> Vec<TextEdit> {
        let text = &self.text;
        touched_lines(text, selections)
            .into_iter()
            .filter_map(|l| {
                let start = text.lines[l];
                if more {
                    return Some(edit(start, 0, "  "));
                }
                let line = text.line(l);
                let indent = &line[..indentation(line)];
                if indent.is_empty() {
                    return None;
                }
                // A tab is four columns.
                let columns = indent.iter().fold(0usize, |col, &u| {
                    if is(u, '\t') {
                        col + 4 - col % 4
                    } else {
                        col + 1
                    }
                });
                let remaining = columns.saturating_sub(2);
                let keep = indent
                    .iter()
                    .take(remaining)
                    .take_while(|&&u| is(u, ' '))
                    .count();
                Some(edit(
                    start + keep as u32,
                    (indent.len() - keep) as u32,
                    " ".repeat(remaining - keep),
                ))
            })
            .collect()
    }

    /// The caret's line as a heading of `command` ("section"), or as plain
    /// text given none, as a paragraph style does: a heading changes level
    /// and keeps its title, a line of text becomes the title. A comment at
    /// the line's end stays outside the braces. A title whose closing brace
    /// is on another line has no brace added: it keeps the command's change,
    /// and as plain text the line is left as it is, since the brace would be
    /// left behind.
    pub fn set_heading(&self, caret: u32, command: &str) -> Insertion {
        let text = &self.text;
        let caret = caret.min(text.len());
        let index = text.line_index(caret);
        let (line, start) = (text.line(index), text.lines[index]);
        // A CRLF line's CR is its end, not its text.
        let line = line.strip_suffix(&[0x0d]).unwrap_or(line);
        let length = line.len() as u32;
        let line = String::from_utf16_lossy(line);
        let (code, comment) = line.split_at(strip_comment(&line).len());
        let (before, title, rest, marks, closed) = match HEADING.captures(code) {
            Some(c) => {
                let open = c.get_match();
                let body = &code[open.end()..];
                let marks = format!("{}{}", &c[2], c.get(3).map_or("", |m| m.as_str()));
                let (title, rest) = match closing_brace(body) {
                    Some(close) => (&body[..close], Some(&body[close + 1..])),
                    None => (body, None),
                };
                (
                    &code[..open.start()],
                    title,
                    rest.unwrap_or(""),
                    marks,
                    rest.is_some(),
                )
            }
            None => {
                let title = code.trim();
                let indentation = &code[..code.len() - code.trim_start().len()];
                // The blanks after a title stay, before the comment; none after no title.
                let after = &code[code.trim_end().len()..];
                (
                    indentation,
                    title,
                    if title.is_empty() { "" } else { after },
                    String::new(),
                    true,
                )
            }
        };
        let (new, cursor) = if !command.is_empty() {
            let head = format!("{before}\\{command}{marks}{{");
            let cursor = utf16(&head) + utf16(title);
            let close = if closed { "}" } else { "" };
            (format!("{head}{title}{close}{rest}{comment}"), cursor)
        } else if closed {
            let plain = format!("{before}{title}{rest}");
            let cursor = utf16(&plain);
            (format!("{plain}{comment}"), cursor)
        } else {
            (line.clone(), (caret - start) as usize)
        };
        Insertion {
            edit: edit(start, length, new),
            caret: start + cursor as u32,
            fields: vec![],
        }
    }

    /// A block by its id (the catalog's `blocks`) in place of the selection,
    /// on a line of its own, the caret in its first field; none for an id
    /// the catalog hasn't.
    pub fn insert_block(&self, id: &str, selection: TextRange) -> Option<Insertion> {
        let (text, selection) = (&self.text, clamp(selection, self.text.len()));
        let template = catalog::CATALOG.blocks.get(id)?;
        let line = text.line_index(selection.start);
        let before = &text.units[text.lines[line] as usize..selection.start as usize];
        // On a line of its own: after text, a line feed first. The template ends
        // with its own.
        let newline = if blank_line(before) { "" } else { "\n" };
        let (block, fields) =
            complete::expand(text, selection.start, &format!("{newline}{template}"));
        Some(Insertion {
            caret: selection.start + fields.first().map_or(utf16(&block) as u32, |f| f.start),
            edit: edit(selection.start, selection.length, block),
            fields,
        })
    }

    /// A maths symbol's command in place of the selection: as it is in
    /// maths, and between dollars in text, where the bare command would stop
    /// the build.
    pub fn insert_symbol(&mut self, command: &str, selection: TextRange) -> Insertion {
        let selection = clamp(selection, self.text.len());
        let at = selection.start as usize;
        let mut scanner = self.scans.resume(&self.text, at, at).scanner;
        scanner.run(&self.text.units[..at], at, &[], &mut ());
        let text = if scanner.in_math() {
            command.to_string()
        } else {
            format!("${command}$")
        };
        let caret = selection.start + utf16(&text) as u32;
        Insertion {
            edit: edit(selection.start, selection.length, text),
            caret,
            fields: vec![],
        }
    }

    /// Move Line Up or Down: the lines the selections touch, each run of
    /// them past the line above or below, the selections going with them;
    /// none when a run is already at the text's start or end.
    pub fn move_lines(&self, selections: &[TextRange], up: bool) -> Option<Change> {
        let text = &self.text;
        let (units, len) = (&text.units[..], text.units.len());
        // Runs of the lines the selections touch, by their first and last.
        let mut runs: Vec<(usize, usize)> = Vec::new();
        for line in touched_lines(text, selections) {
            match runs.last_mut() {
                Some(run) if line == run.1 + 1 => run.1 = line,
                _ => runs.push((line, line)),
            }
        }
        let mut edits = Vec::new();
        // Each run's bounds, and where its first line goes.
        let mut moves = Vec::new();
        for (first, last) in runs {
            let (start, end) = (text.bounds(first).start, text.bounds(last).next);
            // The empty line after a final line break has nothing to move.
            if end == start || (if up { first == 0 } else { end >= len }) {
                return None;
            }
            // With the line above or below, the lines' text trades places;
            // the line breaks stay where they were, so a last line without
            // one keeps none.
            let (from, to) = if up {
                (first - 1, last)
            } else {
                (first, last + 1)
            };
            let lines: Vec<Line> = (from..=to).map(|l| text.bounds(l)).collect();
            let mut moved: Vec<&[u16]> = lines.iter().map(|l| &units[l.start..l.end]).collect();
            if up {
                moved.rotate_left(1);
            } else {
                moved.rotate_right(1);
            }
            let joined: Vec<u16> = moved
                .iter()
                .zip(&lines)
                .flat_map(|(contents, l)| contents.iter().chain(&units[l.end..l.next]))
                .copied()
                .collect();
            let whole = lines[0].start..lines[lines.len() - 1].next;
            let at = if up {
                whole.start
            } else {
                whole.start + moved[0].len() + (lines[0].next - lines[0].end)
            };
            let length = whole.end - whole.start;
            edits.push(splice(
                whole.start,
                length,
                String::from_utf16_lossy(&joined),
            ));
            moves.push((start, end, at));
        }
        let selections = selections
            .iter()
            .map(|selection| {
                let (at, to) = selection.bounds();
                let found = moves.iter().find(|&&(start, end, _)| {
                    (start <= at && at < end) || (at == end && at == to && end == len)
                });
                let at = found.map_or(at, |&(start, _, first)| at - start + first);
                span(at, (selection.length) as usize)
            })
            .collect();
        Some(Change { edits, selections })
    }

    /// The selection (the first) between a template's text before "$0" and
    /// after, still selected, or the caret between them.
    pub fn wrap(&self, selections: &[TextRange], template: &str) -> Change {
        let (prefix, suffix) = template.split_once("$0").unwrap_or((template, ""));
        let first = selections.first().copied().unwrap_or_default();
        let (start, end) = clamp(first, self.text.len()).bounds();
        let selected = String::from_utf16_lossy(&self.text.units[start..end]);
        Change {
            edits: vec![splice(
                start,
                end - start,
                format!("{prefix}{selected}{suffix}"),
            )],
            selections: vec![span(start + utf16(prefix), end - start)],
        }
    }

    /// Bold, Italic or Underline off where the selection (the first) is in
    /// its command, as a word processor's: the command unwraps, the
    /// selections following the text; on otherwise, round the selection.
    pub fn toggle_style(&mut self, selections: &[TextRange], style: Style) -> Change {
        let styles = self.text_styles(selections.first().copied().unwrap_or_default());
        let (unwrap, template) = match style {
            Style::Bold => (styles.bold, "\\textbf{$0}"),
            Style::Italic => (styles.italic, "\\textit{$0}"),
            Style::Underline => (styles.underline, "\\underline{$0}"),
        };
        match unwrap {
            Some(edits) => Change {
                selections: map_selections(&edits, selections),
                edits,
            },
            None => self.wrap(selections, template),
        }
    }
}

/// Where selections go through edits (in order, applied from the last): text
/// put in at a selection's start goes before it, and a selection's end in
/// replaced text goes to the replacement's end.
pub fn map_selections(edits: &[TextEdit], selections: &[TextRange]) -> Vec<TextRange> {
    let map = |position: usize| {
        // What the edits before the position put in and took out, so that
        // nothing is taken from a position before it was added to.
        let (mut added, mut removed) = (0, 0);
        for e in edits {
            let inserted = utf16(&e.text);
            let (start, end) = (e.start as usize, (e.start + e.length) as usize);
            if end <= position {
                added += inserted;
                removed += e.length as usize;
            } else if start < position {
                return start + added - removed + inserted;
            }
        }
        position + added - removed
    };
    selections
        .iter()
        .map(|selection| {
            let (start, end) = selection.bounds();
            let from = map(start);
            span(from, map(end) - from)
        })
        .collect()
}
