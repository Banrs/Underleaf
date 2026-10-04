//! The editing commands, as web/src/editor.js has them: comment toggling,
//! indentation, heading levels and blocks.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;

use crate::{blank, catalog, complete, is, space, utf16, Insertion, Text, TextEdit, TextRange};

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

fn edit(start: u32, length: u32, text: impl Into<String>) -> TextEdit {
    TextEdit {
        start,
        length,
        text: text.into(),
    }
}

pub fn toggle_comment(text: &Text, selections: &[TextRange]) -> Vec<TextEdit> {
    let lines = touched_lines(text, selections);
    let indent = |line: &[u16]| line.iter().take_while(|&&u| space(u)).count();
    let commented = |line: &[u16]| line.get(indent(line)).is_some_and(|&u| is(u, '%'));
    let uncomment = lines
        .iter()
        .all(|&l| commented(text.line(l)) || blank(text.line(l)));
    lines
        .into_iter()
        .filter_map(|l| {
            let (line, start) = (text.line(l), text.lines[l]);
            if !uncomment {
                return (!blank(line)).then(|| edit(start, 0, "% "));
            }
            let at = indent(line);
            let space_after = line.get(at + 1).is_some_and(|&u| is(u, ' '));
            commented(line).then(|| edit(start + at as u32, 1 + space_after as u32, ""))
        })
        .collect()
}

/// Two spaces more, or one two-column indent unit fewer, at the start of
/// each line the selections touch (CodeMirror's indentMore and indentLess).
pub fn indent(text: &Text, selections: &[TextRange], more: bool) -> Vec<TextEdit> {
    touched_lines(text, selections)
        .into_iter()
        .filter_map(|l| {
            let start = text.lines[l];
            if more {
                return Some(edit(start, 0, "  "));
            }
            let line = text.line(l);
            let indent = &line[..line.iter().take_while(|&&u| space(u)).count()];
            if indent.is_empty() {
                return None;
            }
            // CodeMirror's default tab size is four columns.
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

/// A sectioning command, to its title's opening brace: its star and short title.
static HEADING: LazyLock<Regex> = LazyLock::new(|| {
    let names = catalog::alternation(&catalog::CATALOG.sections);
    Regex::new(&format!(r"\\({names})(\*?)\s*(\[[^\]]*\])?\s*\{{")).unwrap()
});

pub fn set_heading(text: &Text, caret: u32, command: &str) -> Insertion {
    let index = text.line_index(caret);
    let (line, start) = (text.line(index), text.lines[index]);
    let length = line.len() as u32;
    let line = String::from_utf16_lossy(line);
    let line = line.as_str();
    let (before, title, rest, marks) = match HEADING.captures(line) {
        Some(c) => {
            let open = c.get(0).unwrap();
            let body = &line[open.end()..];
            // The title runs to the brace that closes the command's.
            let mut depth = 1;
            let mut escaped = false;
            let close = body.find(|ch| {
                if ch == '\\' {
                    escaped = !escaped;
                    return false;
                }
                if escaped {
                    escaped = false;
                    return false;
                }
                depth += match ch {
                    '{' => 1,
                    '}' => -1,
                    _ => 0,
                };
                depth == 0
            });
            let (title, rest) = close.map_or((body, ""), |i| (&body[..i], &body[i + 1..]));
            let marks = format!("{}{}", &c[2], c.get(3).map_or("", |m| m.as_str()));
            (&line[..open.start()], title, rest, marks)
        }
        None => (
            &line[..line.len() - line.trim_start().len()],
            line.trim(),
            "",
            String::new(),
        ),
    };
    let (new, cursor) = if command.is_empty() {
        let text = format!("{before}{title}{rest}");
        let cursor = utf16(&text);
        (text, cursor)
    } else {
        let head = format!("{before}\\{command}{marks}{{");
        (
            format!("{head}{title}}}{rest}"),
            utf16(&head) + utf16(title),
        )
    };
    Insertion {
        edit: edit(start, length, new),
        caret: start + cursor as u32,
        fields: vec![],
    }
}

pub fn insert_block(text: &Text, id: &str, selection: TextRange) -> Option<Insertion> {
    let template = catalog::CATALOG.blocks.get(id)?;
    let line = text.line_index(selection.start);
    let before = &text.units[text.lines[line] as usize..selection.start as usize];
    // On a line of its own: after text, a line feed first. The template ends
    // with its own.
    let newline = if blank(before) { "" } else { "\n" };
    let (block, fields) = complete::expand(text, selection.start, &format!("{newline}{template}"));
    Some(Insertion {
        caret: selection.start + fields.first().map_or(utf16(&block) as u32, |f| f.start),
        edit: edit(selection.start, selection.length, block),
        fields,
    })
}

#[cfg(test)]
mod tests {
    use super::edit;
    use crate::{SourceDocument, TextRange};

    #[test]
    fn outdent_keeps_visual_columns_and_the_matching_prefix() {
        let doc = SourceDocument::new("🙂\n\tb\n \tc\n    d");
        let edits = doc.indent(
            &[TextRange {
                start: 3,
                length: 12,
            }],
            false,
        );
        assert_eq!(edits, [edit(3, 1, "  "), edit(7, 1, " "), edit(12, 2, ""),]);
    }
}
