use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::scan::{blank_line, closing_brace};
use super::style::TextStyles;
use super::{
    INDENT, Insertion, Line, NEWLINE, SourceDocument, Text, TextEdit, TextRange, catalog, clamp,
    comment_start, complete, edit, indentation, is, span, splice,
};
use crate::{FileKind, file_kind, utf16};

#[derive(Serialize, JsonSchema)]
pub(crate) struct Change {
    pub(crate) edits: Vec<TextEdit>,
    pub(crate) selections: Vec<TextRange>,
}

type Styled = fn(TextStyles) -> Option<Vec<TextEdit>>;

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TextStyle {
    Bold,
    Italic,
    Underline,
}

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

fn runs(text: &Text, selections: &[TextRange]) -> Vec<(usize, usize)> {
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for line in touched_lines(text, selections) {
        match runs.last_mut() {
            Some(run) if line == run.1 + 1 => run.1 = line,
            _ => runs.push((line, line)),
        }
    }
    runs
}

static HEADING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(part|chapter|(?:sub){0,2}section|(?:sub)?paragraph)(\*?)\s*(\[[^\]]*\])?\s*\{")
        .unwrap()
});

static BLANK_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\n[ \t]*\n").unwrap());

/// How far either side of the caret a citation is read for the keys already in it.
const CITED: usize = 1000;

impl SourceDocument {
    pub(crate) fn toggle_comment(&self, selections: &[TextRange]) -> Vec<TextEdit> {
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

    pub(crate) fn indent(&self, selections: &[TextRange], more: bool) -> Vec<TextEdit> {
        let text = &self.text;
        touched_lines(text, selections)
            .into_iter()
            .filter_map(|l| {
                let start = text.lines[l];
                if more {
                    return Some(edit(start, 0, INDENT));
                }
                let line = text.line(l);
                let indent = &line[..indentation(line)];
                if indent.is_empty() {
                    return None;
                }
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

    pub(crate) fn set_heading(&self, caret: u32, command: &str) -> Insertion {
        let text = &self.text;
        let caret = caret.min(text.len());
        let index = text.line_index(caret);
        let (line, start) = (text.line(index), text.lines[index]);
        let length = line.len() as u32;
        let split = comment_start(line);
        let code = &String::from_utf16_lossy(&line[..split]);
        let comment = String::from_utf16_lossy(&line[split..]);
        let (before, marks, title, rest) = match HEADING
            .captures_iter(code)
            .find(|c| complete::unescaped(code, c.get_match().start()))
        {
            Some(c) => {
                let open = c.get_match();
                let body = &code[open.end()..];
                let marks = format!("{}{}", &c[2], c.get(3).map_or("", |m| m.as_str()));
                let close = closing_brace(body);
                let title = close.map_or(body, |close| &body[..close]);
                let rest = close.map(|close| &body[close + 1..]);
                (&code[..open.start()], marks, title, rest)
            }
            None => {
                let title = code.trim();
                let indentation = &code[..code.len() - code.trim_start().len()];
                let after = &code[code.trim_end().len()..];
                let rest = if title.is_empty() { "" } else { after };
                (indentation, String::new(), title, Some(rest))
            }
        };
        let (new, cursor) = match rest {
            _ if !command.is_empty() => {
                let head = format!("{before}\\{command}{marks}{{");
                let close = if rest.is_some() { "}" } else { "" };
                let tail = rest.unwrap_or_default();
                let cursor = utf16::len(&head) + utf16::len(title);
                (format!("{head}{title}{close}{tail}{comment}"), cursor)
            }
            Some(rest) => {
                let plain = format!("{before}{title}{rest}");
                (format!("{plain}{comment}"), utf16::len(&plain))
            }
            None => (format!("{code}{comment}"), (caret - start) as usize),
        };
        Insertion {
            edit: edit(start, length, new),
            caret: start + cursor as u32,
            fields: vec![],
        }
    }

    pub(crate) fn insert_block(&self, id: &str, selection: TextRange) -> Option<Insertion> {
        let (text, selection) = (&self.text, clamp(selection, self.text.len()));
        let template = catalog::CATALOG.blocks.get(id)?;
        let line = text.line_index(selection.start);
        let before = &text.units[text.lines[line] as usize..selection.start as usize];
        let newline = if blank_line(before) { "" } else { "\n" };
        let (mut block, mut fields) =
            complete::expand(text, selection.start, &format!("{newline}{template}"));
        if let Some((first, rest)) = fields.split_first_mut().filter(|_| selection.length > 0) {
            let (start, end) = selection.bounds();
            let at = utf16::byte_offset(&block, first.start as usize)?;
            block.insert_str(at, &String::from_utf16_lossy(&text.units[start..end]));
            first.length = selection.length;
            rest.iter_mut()
                .for_each(|field| field.start += selection.length);
        }
        Some(Insertion {
            caret: selection.start
                + fields
                    .first()
                    .map_or(utf16::len(&block) as u32, |f| f.start),
            edit: edit(selection.start, selection.length, block),
            fields,
        })
    }

    pub(crate) fn insert_symbol(&mut self, command: &str, selection: TextRange) -> Insertion {
        let selection = clamp(selection, self.text.len());
        let at = selection.start as usize;
        let text = if self.scanned_to(at).in_math() {
            command.to_string()
        } else {
            format!("${command}$")
        };
        let caret = selection.start + utf16::len(&text) as u32;
        Insertion {
            edit: edit(selection.start, selection.length, text),
            caret,
            fields: vec![],
        }
    }

    /// Cites `key` at the selection. Inside a citation's braces that is the key alone, with the commas that keep it
    /// apart from the keys either side, and put after the key the caret is inside so as not to split it; anywhere else
    /// it is a `\cite` of it. A citation's keys can run over lines but not past a blank one.
    pub(crate) fn cite(&self, key: &str, selection: TextRange) -> Insertion {
        let (start, end) = clamp(selection, self.text.len()).bounds();
        let units = &self.text.units;
        let before = String::from_utf16_lossy(&units[start.saturating_sub(CITED)..start]);
        let after = String::from_utf16_lossy(&units[end..(end + CITED).min(units.len())]);
        let blank = BLANK_LINE.find_iter(&before).last();
        let paragraph = blank.map_or(&before[..], |blank| &before[blank.end()..]);
        let open = complete::ARGUMENT.captures(paragraph).filter(|open| {
            let command = open.get_match().start();
            complete::unescaped(paragraph, command)
                && catalog::CATALOG.cite_commands.contains(&open[1])
        });
        let in_key = |c: char| !c.is_whitespace() && !",{}".contains(c);
        let Some(keys) = open.and_then(|_| paragraph.rsplit_once('{')) else {
            let cite = format!("\\cite{{{key}}}");
            let caret = (start + utf16::len(&cite)) as u32;
            return Insertion {
                edit: splice(start, end - start, cite),
                caret,
                fields: vec![],
            };
        };
        let inside = before.chars().next_back().is_some_and(in_key);
        let rest = &after[..after.find(|c| !inside || !in_key(c)).unwrap_or(after.len())];
        let keys = format!("{}{rest}", keys.1);
        let leading = !keys.trim().is_empty() && !keys.trim().ends_with(',');
        let next = after[rest.len()..].chars().find(|c| !c.is_whitespace());
        let (lead, trail) = (
            if leading { "," } else { "" },
            if next.is_some_and(in_key) { "," } else { "" },
        );
        let cite = format!("{lead}{key}{trail}");
        let past = utf16::len(rest);
        let (at, length) = if past > 0 {
            (end + past, 0)
        } else {
            (start, end - start)
        };
        Insertion {
            caret: (at + utf16::len(&cite)) as u32,
            edit: splice(at, length, cite),
            fields: vec![],
        }
    }

    pub(crate) fn move_lines(&self, selections: &[TextRange], up: bool) -> Option<Change> {
        let text = &self.text;
        let (units, len) = (&text.units[..], text.units.len());
        let mut edits = Vec::new();
        let mut moves = Vec::new();
        for (first, last) in runs(text, selections) {
            let (start, end) = (text.bounds(first).start, text.bounds(last).next);
            if end == start || (if up { first == 0 } else { end >= len }) {
                return None;
            }
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
            edits.push(splice(
                whole.start,
                whole.len(),
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
                // A line moved to the end has no newline, so one selected with it ends with the text.
                span(at, (selection.length as usize).min(len.saturating_sub(at)))
            })
            .collect();
        Some(Change { edits, selections })
    }

    pub(crate) fn duplicate_lines(&self, selections: &[TextRange]) -> Change {
        let text = &self.text;
        let edits: Vec<TextEdit> = runs(text, selections)
            .into_iter()
            .map(|(first, last)| {
                let start = text.bounds(first).start;
                let Line { end, next, .. } = text.bounds(last);
                let mut copy = text.units[start..next].to_vec();
                if end == next {
                    let before = last.checked_sub(1).map(|line| text.bounds(line));
                    copy.extend(before.map_or(&[NEWLINE][..], |b| &text.units[b.end..b.next]));
                }
                splice(start, 0, String::from_utf16_lossy(&copy))
            })
            .collect();
        Change {
            selections: map_selections(&edits, selections),
            edits,
        }
    }

    pub(crate) fn delete_lines(&self, selections: &[TextRange]) -> Change {
        let text = &self.text;
        let edits: Vec<TextEdit> = runs(text, selections)
            .into_iter()
            .map(|(first, last)| {
                let (mut start, next) = (text.bounds(first).start, text.bounds(last).next);
                if next == text.units.len() && first > 0 {
                    start = text.bounds(first - 1).end;
                }
                splice(start, next - start, "")
            })
            .collect();
        let mut selections = map_selections(&edits, selections);
        selections.dedup();
        Change { edits, selections }
    }

    pub(crate) fn wrap(&self, selections: &[TextRange], template: &str) -> Change {
        let (prefix, suffix) = template.split_once("$0").unwrap_or((template, ""));
        let selections = clamped(selections, self.text.len());
        let wrap = |selection: &TextRange| {
            let (start, end) = selection.bounds();
            let selected = String::from_utf16_lossy(&self.text.units[start..end]);
            splice(start, end - start, format!("{prefix}{selected}{suffix}"))
        };
        let edits: Vec<TextEdit> = selections.iter().map(wrap).collect();
        let into = utf16::len(prefix);
        let selections = selections
            .iter()
            .map(|&s| placed(&edits, s, into))
            .collect();
        Change { edits, selections }
    }

    pub(crate) fn toggle_style(&mut self, selections: &[TextRange], style: TextStyle) -> Change {
        let (styled, command): (Styled, _) = match style {
            TextStyle::Bold => (|styles| styles.bold, "textbf"),
            TextStyle::Italic => (|styles| styles.italic, "textit"),
            TextStyle::Underline => (|styles| styles.underline, "underline"),
        };
        let selections = clamped(selections, self.text.len());
        let (mut unwraps, mut wrapping) = (Vec::new(), Vec::new());
        for &selection in &selections {
            match styled(self.text_styles(selection)) {
                Some(unwrap) => unwraps.push(unwrap),
                None => wrapping.push(selection),
            }
        }
        // A style stays on where a selection being wrapped takes in part of its command or closing brace, as wrapping
        // that selection alone leaves it: the wrap already rewrites that text, so taking it out as well would overlap.
        let crosses = |markup: &TextEdit| {
            let (start, end) = (markup.start, markup.start + markup.length);
            wrapping
                .iter()
                .any(|s| s.start < end && start < s.start + s.length)
        };
        unwraps.retain(|unwrap| !unwrap.iter().any(crosses));
        let mut edits: Vec<TextEdit> = unwraps.into_iter().flatten().collect();
        let prefix = format!("\\{command}{{");
        edits.extend(self.wrap(&wrapping, &format!("{prefix}$0}}")).edits);
        // An insertion goes before a removal at the same place, which, made back to front, would otherwise take it out.
        edits.sort_by_key(|edit| (edit.start, edit.length));
        edits.dedup();
        let into = utf16::len(&prefix);
        // A selection whose style comes off maps through the edits, which shrink it if it held the command and brace.
        let mapped = map_selections(&edits, &selections);
        let place = |(&s, mapped)| {
            if wrapping.contains(&s) {
                placed(&edits, s, into)
            } else {
                mapped
            }
        };
        let selections = selections.iter().zip(mapped).map(place).collect();
        Change { edits, selections }
    }
}

fn clamped(selections: &[TextRange], len: u32) -> Vec<TextRange> {
    selections.iter().map(|&s| clamp(s, len)).collect()
}

/// Where a selection is once `edits` are made: moved past the edits before it, and `into` the edit wrapping it.
fn placed(edits: &[TextEdit], selection: TextRange, into: usize) -> TextRange {
    let before = edits.iter().filter(|edit| edit.start < selection.start);
    let moved: i64 = before
        .map(|e| utf16::len(&e.text) as i64 - i64::from(e.length))
        .sum();
    let start = (i64::from(selection.start) + moved).max(0) as usize + into;
    span(start, selection.length as usize)
}

pub(crate) fn include_graphics(path: &str, into: &str) -> Option<String> {
    let (_, extension) = path.rsplit_once('.')?;
    let figure = ["png", "jpg", "jpeg", "pdf"].contains(&extension.to_ascii_lowercase().as_str());
    if !figure || file_kind(into) != FileKind::Tex {
        return None;
    }
    let mut depth = 0_u32;
    for c in path.chars() {
        match c {
            '%' | '#' | '\\' => return None,
            '{' => depth += 1,
            '}' => depth = depth.checked_sub(1)?,
            _ => {}
        }
    }
    (depth == 0).then(|| format!("\\includegraphics{{{path}}}"))
}

pub(crate) fn map_selections(edits: &[TextEdit], selections: &[TextRange]) -> Vec<TextRange> {
    let map = |position: u64| {
        let (mut added, mut removed) = (0, 0);
        for e in edits {
            let inserted = utf16::len(&e.text) as u64;
            let (start, length) = (u64::from(e.start), u64::from(e.length));
            if start + length <= position {
                added += inserted;
                removed += length;
            } else if start < position {
                return (start + added + inserted).saturating_sub(removed);
            }
        }
        (position + added).saturating_sub(removed)
    };
    selections
        .iter()
        .map(|selection| {
            let start = u64::from(selection.start);
            let from = map(start);
            let to = map(start + u64::from(selection.length));
            span(from as usize, to.saturating_sub(from) as usize)
        })
        .collect()
}
