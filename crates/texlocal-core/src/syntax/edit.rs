//! The editing commands: comment toggling, indentation, heading levels and
//! blocks.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;

use super::{Insertion, SourceDocument, Text, TextEdit, TextRange, blank, catalog, clamp};
use super::{complete, edit, is, space, utf16};

/// The lines the selections touch, in order, reached. A selection ending at
/// a line's start leaves that line alone.
fn touched_lines(text: &mut Text, selections: &[TextRange]) -> BTreeSet<usize> {
    let len = text.len();
    let mut lines = BTreeSet::new();
    for selection in selections {
        let from = selection.start.min(len);
        let to = selection.start.saturating_add(selection.length).min(len);
        let at_line_start = to > from && text.line_start(text.line_index(to)) == to;
        lines.extend(text.line_index(from)..=text.line_index(to - at_line_start as u32));
    }
    if let Some(&last) = lines.last() {
        text.reach(text.line_end(last));
    }
    lines
}

/// How many units of spaces a line starts with.
fn leading(line: &[u16]) -> usize {
    line.iter().take_while(|&&u| space(u)).count()
}

/// A sectioning command, to its title's opening brace: its star and short title.
static HEADING: LazyLock<Regex> = LazyLock::new(|| {
    let levels = catalog::CATALOG.heading_levels.iter().map(|l| &*l.command);
    let names = catalog::alternation(levels.chain(["subparagraph"]));
    Regex::new(&format!(r"\\({names})(\*?)\s*(\[[^\]]*\])?\s*\{{")).unwrap()
});

impl SourceDocument {
    /// "%" comments on or off for the lines the selections touch: off when
    /// every one is already commented (or blank), on otherwise. In order;
    /// the editor applies them from the last.
    pub fn toggle_comment(&mut self, selections: &[TextRange]) -> Vec<TextEdit> {
        let lines = touched_lines(&mut self.text, selections);
        let text = &self.text;
        let commented = |line: &[u16]| line.get(leading(line)).is_some_and(|&u| is(u, '%'));
        let uncomment = (lines.iter()).all(|&l| commented(text.line(l)) || blank(text.line(l)));
        let toggled = |l: usize| {
            let (line, start) = (text.line(l), text.line_start(l));
            if !uncomment {
                return (!blank(line)).then(|| edit(start, 0, "% "));
            }
            let at = leading(line);
            let space_after = line.get(at + 1).is_some_and(|&u| is(u, ' '));
            commented(line).then(|| edit(start + at as u32, 1 + space_after as u32, ""))
        };
        lines.into_iter().filter_map(toggled).collect()
    }

    /// Two spaces more, or one two-column indent unit fewer, at the start of
    /// each line the selections touch.
    pub fn indent(&mut self, selections: &[TextRange], more: bool) -> Vec<TextEdit> {
        let lines = touched_lines(&mut self.text, selections);
        let text = &self.text;
        let indented = |l: usize| {
            let (line, start) = (text.line(l), text.line_start(l));
            let indent = &line[..leading(line)];
            if more || indent.is_empty() {
                return more.then(|| edit(start, 0, "  "));
            }
            // A tab is four columns.
            let columns = |col: usize, &u: &u16| col + 1 + is(u, '\t') as usize * (3 - col % 4);
            let remaining = indent.iter().fold(0, columns).saturating_sub(2);
            let kept = &indent[..remaining.min(indent.len())];
            let keep = kept.iter().take_while(|&&u| is(u, ' ')).count();
            let spaces = " ".repeat(remaining - keep);
            let length = (indent.len() - keep) as u32;
            Some(edit(start + keep as u32, length, spaces))
        };
        lines.into_iter().filter_map(indented).collect()
    }

    /// The caret's line as a heading of `command` ("section"), or as plain
    /// text given none, as a paragraph style does: a heading changes level
    /// and keeps its title, a line of text becomes the title.
    pub fn set_heading(&mut self, caret: u32, command: &str) -> Insertion {
        let caret = caret.min(self.text.len());
        self.text.reach_line(caret);
        let index = self.text.line_index(caret);
        let (units, start) = (self.text.line(index), self.text.line_start(index));
        let line = String::from_utf16_lossy(units);
        let (before, title, rest, marks) = match HEADING.captures(&line) {
            Some(c) => {
                let open = c.get_match();
                let body = &line[open.end()..];
                // The title runs to the brace that closes the command's.
                let (mut depth, mut escaped) = (1, false);
                let close = body.find(|ch| {
                    let skip = escaped;
                    escaped = !skip && ch == '\\';
                    depth += match ch {
                        '{' if !skip => 1,
                        '}' if !skip => -1,
                        _ => 0,
                    };
                    depth == 0
                });
                let (title, rest) = close.map_or((body, ""), |i| (&body[..i], &body[i + 1..]));
                let marks = format!("{}{}", &c[2], c.get(3).map_or("", |m| m.as_str()));
                (&line[..open.start()], title, rest, marks)
            }
            None => {
                let indent = &line[..line.len() - line.trim_start().len()];
                (indent, line.trim(), "", String::new())
            }
        };
        // Plain, the caret goes to the line's end; a heading's, its title's.
        let (head, close, after) = match command {
            "" => (before.to_owned(), "", rest),
            _ => (format!("{before}\\{command}{marks}{{"), "}", ""),
        };
        let caret = start + (utf16(&head) + utf16(title) + utf16(after)) as u32;
        let new = format!("{head}{title}{close}{rest}");
        let edit = edit(start, units.len() as u32, new);
        Insertion { edit, caret, fields: vec![] }
    }

    /// A block by its id (the catalog's `blocks`) in place of the selection,
    /// on a line of its own, the caret in its first field; none for an id
    /// the catalog hasn't.
    pub fn insert_block(&mut self, id: &str, selection: TextRange) -> Option<Insertion> {
        let TextRange { start, length } = clamp(selection, self.text.len());
        let template = catalog::CATALOG.blocks.get(id)?;
        self.text.reach_line(start);
        let text = &self.text;
        let line_start = text.line_start(text.line_index(start)) as usize;
        // On a line of its own: after text, a line feed first. The template ends
        // with its own.
        let before = &text.units()[line_start..start as usize];
        let newline = if blank(before) { "" } else { "\n" };
        let (block, fields) = complete::expand(text, start, &format!("{newline}{template}"));
        let caret = start + fields.first().map_or(utf16(&block) as u32, |f| f.start);
        Some(Insertion { edit: edit(start, length, block), caret, fields })
    }
}
