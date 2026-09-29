//! The editing commands, as web/src/editor.js has them: comment toggling,
//! heading levels, blocks, and whether a position is in maths.

use std::collections::BTreeSet;

use crate::highlight::space;
use crate::{catalog, Insertion, Text, TextEdit, TextRange};

fn units(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

fn is(u: u16, c: char) -> bool {
    u == c as u16
}

fn blank(line: &[u16]) -> bool {
    line.iter().all(|&u| space(u))
}

/// Where each line ends, before its line feed.
fn line_end(text: &Text, index: usize) -> u32 {
    text.lines
        .get(index + 1)
        .map_or(text.units.len() as u32, |&next| next - 1)
}

pub fn toggle_comment(text: &Text, selections: &[TextRange]) -> Vec<TextEdit> {
    let len = text.units.len() as u32;
    let mut lines = BTreeSet::new();
    for selection in selections {
        let from = selection.start.min(len);
        let to = (selection.start.saturating_add(selection.length)).min(len);
        // A selection ending at a line's start only touches that line.
        let end = if to > from && text.lines[text.line_index(to)] == to {
            to - 1
        } else {
            to
        };
        let mut line = text.line_index(from);
        loop {
            lines.insert(line);
            if line_end(text, line) >= end {
                break;
            }
            line += 1;
        }
    }
    let indent = |line: &[u16]| line.iter().take_while(|&&u| space(u)).count();
    let commented = |line: &[u16]| line.get(indent(line)).is_some_and(|&u| is(u, '%'));
    let uncomment = lines
        .iter()
        .all(|&l| commented(text.line(l)) || blank(text.line(l)));
    lines
        .into_iter()
        .filter_map(|l| {
            let (line, start) = (text.line(l), text.lines[l]);
            if uncomment {
                let at = indent(line);
                commented(line).then(|| {
                    let length = if line.get(at + 1).is_some_and(|&u| is(u, ' ')) {
                        2
                    } else {
                        1
                    };
                    TextEdit {
                        start: start + at as u32,
                        length,
                        text: String::new(),
                    }
                })
            } else {
                (!blank(line)).then(|| TextEdit {
                    start,
                    length: 0,
                    text: "% ".into(),
                })
            }
        })
        .collect()
}

pub fn set_heading(text: &Text, caret: u32, command: &str) -> Insertion {
    let index = text.line_index(caret);
    let (line, start) = (text.line(index), text.lines[index]);
    let (new, cursor) = heading_line(line, command);
    Insertion {
        edit: TextEdit {
            start,
            length: line.len() as u32,
            text: String::from_utf16_lossy(&new),
        },
        caret: start + cursor as u32,
    }
}

const SECTIONS: [&str; 7] = [
    "part",
    "chapter",
    "section",
    "subsection",
    "subsubsection",
    "paragraph",
    "subparagraph",
];

/// A sectioning command where the outline finds one (state.js SECTION_RE):
/// its start, its star, its short title and where its title starts.
struct Heading {
    start: usize,
    star: bool,
    short: std::ops::Range<usize>,
    title: usize,
}

fn find_heading(line: &[u16]) -> Option<Heading> {
    let skip_space = |mut i: usize| {
        while line.get(i).is_some_and(|&u| space(u)) {
            i += 1;
        }
        i
    };
    (0..line.len())
        .filter(|&p| is(line[p], '\\'))
        .find_map(|start| {
            SECTIONS.iter().find_map(|name| {
                let name = units(name);
                let mut i = start + 1 + name.len();
                if line.get(start + 1..i) != Some(&name[..]) {
                    return None;
                }
                let star = line.get(i).is_some_and(|&u| is(u, '*'));
                i = skip_space(i + star as usize);
                let mut short = i..i;
                if line.get(i).is_some_and(|&u| is(u, '[')) {
                    let close = i + line[i..].iter().position(|&u| is(u, ']'))?;
                    short = i..close + 1;
                    i = close + 1;
                }
                i = skip_space(i);
                line.get(i).is_some_and(|&u| is(u, '{')).then(|| Heading {
                    start,
                    star,
                    short,
                    title: i + 1,
                })
            })
        })
}

/// A line as a heading of `command`, or as plain text given none, and where
/// the caret goes: after the title. An existing heading keeps its short
/// title; otherwise the line is the title.
pub fn heading_line(line: &[u16], command: &str) -> (Vec<u16>, usize) {
    let heading = find_heading(line);
    let (before, title, rest): (&[u16], &[u16], &[u16]) = match &heading {
        Some(h) => {
            // The title runs to the brace that closes the command's.
            let (mut depth, mut i) = (1, h.title);
            while i < line.len() && depth > 0 {
                depth += if is(line[i], '{') {
                    1
                } else if is(line[i], '}') {
                    -1
                } else {
                    0
                };
                i += 1;
            }
            let closed = depth == 0;
            (
                &line[..h.start],
                &line[h.title..if closed { i - 1 } else { line.len() }],
                if closed { &line[i..] } else { &[] },
            )
        }
        None => {
            let indent = line.iter().take_while(|&&u| space(u)).count();
            let end = line.len() - line.iter().rev().take_while(|&&u| space(u)).count();
            (&line[..indent], &line[indent.min(end)..end], &[])
        }
    };
    if command.is_empty() {
        let text = [before, title, rest].concat();
        let cursor = text.len();
        return (text, cursor);
    }
    let mut head = before.to_vec();
    head.extend(units(&format!("\\{command}")));
    if let Some(h) = &heading {
        if h.star {
            head.push('*' as u16);
        }
        head.extend_from_slice(&line[h.short.clone()]);
    }
    head.push('{' as u16);
    let cursor = head.len() + title.len();
    (
        head.into_iter()
            .chain(title.iter().copied())
            .chain(['}' as u16])
            .chain(rest.iter().copied())
            .collect(),
        cursor,
    )
}

pub fn insert_block(text: &Text, id: &str, selection: TextRange) -> Option<Insertion> {
    let template = catalog::get().blocks.get(id)?;
    let line = text.line_index(selection.start);
    let before = &text.units[text.lines[line] as usize..selection.start as usize];
    let (block, cursor) = block_insertion(before, template);
    Some(Insertion {
        edit: TextEdit {
            start: selection.start,
            length: selection.length,
            text: block,
        },
        caret: selection.start + cursor as u32,
    })
}

/// A block as inserted after `before`, the line's text ahead of the caret,
/// and where the caret goes in it ("$0", else the end). A block starts a line
/// of its own; the template ends with its own line feed.
fn block_insertion(before: &[u16], template: &str) -> (String, usize) {
    let newline = if blank(before) { "" } else { "\n" };
    let text = format!("{newline}{}", template.replacen("$0", "", 1));
    let cursor = match template.find("$0") {
        Some(at) => newline.len() + template[..at].encode_utf16().count(),
        None => text.encode_utf16().count(),
    };
    (text, cursor)
}

const MATH_ENVIRONMENTS: [&str; 14] = [
    "equation",
    "align",
    "gather",
    "multline",
    "eqnarray",
    "alignat",
    "flalign",
    "xalignat",
    "xxalignat",
    "math",
    "displaymath",
    "dmath",
    "dgroup",
    "darray",
];
const VERBATIM_ENVIRONMENTS: [&str; 7] = [
    "verbatim",
    "verbatim*",
    "Verbatim",
    "Verbatim*",
    "lstlisting",
    "minted",
    "comment",
];
/// Commands whose braced argument is text, even in maths.
const TEXT_COMMANDS: [&str; 16] = [
    "text",
    "textrm",
    "textit",
    "textbf",
    "textsf",
    "texttt",
    "textup",
    "textsl",
    "textsc",
    "textmd",
    "textnormal",
    "mbox",
    "hbox",
    "fbox",
    "intertext",
    "shortintertext",
];

#[derive(PartialEq)]
enum End {
    Dollar,
    Dollars,
    Paren,
    Bracket,
    Brace,
    Environment(String),
}

struct Group {
    math: bool,
    end: End,
}

fn find(src: &[u16], from: usize, needle: &[u16]) -> Option<usize> {
    (from..=src.len().checked_sub(needle.len())?).find(|&i| src[i..].starts_with(needle))
}

/// Whether the end of `src` is in maths, read as TeX would: $…$, $$…$$,
/// \(…\), \[…\] and the maths environments (starred too) open maths; \text{…}
/// and its kin go back to text inside it; escapes (\$, \%, \\) aren't
/// delimiters; comments and verbatim are skipped; and a blank line ends an
/// unclosed $ or \[, as the paragraph it can't span. So `$|$` (an empty
/// pair, the caret between) is maths.
pub fn math_mode_at(src: &[u16]) -> bool {
    let mut stack: Vec<Group> = Vec::new();
    let math = |stack: &Vec<Group>| stack.last().is_some_and(|g| g.math);
    let truncate_at = |stack: &mut Vec<Group>, end: End| {
        if let Some(k) = stack.iter().rposition(|g| g.end == end) {
            stack.truncate(k);
        }
    };
    // The next { opens a text argument (\text{).
    let mut text_argument = false;
    let n = src.len();
    let mut i = 0;
    while i < n {
        let c = src[i];
        if is(c, '%') {
            // The line feed itself is read next, for the blank-line rule.
            match find(src, i, &['\n' as u16]) {
                Some(eol) => i = eol,
                None => break,
            }
            continue;
        }
        if is(c, '\n') {
            let mut j = i + 1;
            while j < n && [' ', '\t', '\r'].iter().any(|&w| is(src[j], w)) {
                j += 1;
            }
            if j < n && is(src[j], '\n') {
                let paragraph = |g: &Group| {
                    matches!(
                        g.end,
                        End::Dollar | End::Dollars | End::Paren | End::Bracket
                    )
                };
                if let Some(k) = stack.iter().position(paragraph) {
                    stack.truncate(k);
                }
                text_argument = false;
            }
            i += 1;
            continue;
        }
        if is(c, '$') {
            let double = src.get(i + 1).is_some_and(|&u| is(u, '$'));
            match stack.last().map(|g| &g.end) {
                Some(End::Dollar) => {
                    stack.pop();
                    i += 1;
                }
                Some(End::Dollars) => {
                    stack.pop();
                    i += if double { 2 } else { 1 };
                }
                _ if math(&stack) => i += 1, // a stray $ in an environment's maths
                _ if double => {
                    stack.push(Group {
                        math: true,
                        end: End::Dollars,
                    });
                    i += 2;
                }
                _ => {
                    stack.push(Group {
                        math: true,
                        end: End::Dollar,
                    });
                    i += 1;
                }
            }
            text_argument = false;
            continue;
        }
        if is(c, '{') {
            stack.push(Group {
                math: !text_argument && math(&stack),
                end: End::Brace,
            });
            text_argument = false;
            i += 1;
            continue;
        }
        if is(c, '}') {
            // The innermost open brace, and anything unclosed inside it.
            truncate_at(&mut stack, End::Brace);
            i += 1;
            continue;
        }
        if !is(c, '\\') {
            if text_argument && !space(c) {
                text_argument = false;
            }
            i += 1;
            continue;
        }
        let Some(&d) = src.get(i + 1) else { break };
        if !(d < 128 && (d as u8).is_ascii_alphabetic()) {
            // A control symbol: \( \) \[ \] open and close maths; any other
            // (\$, \%, \\, \{) is an escape and nothing more.
            if is(d, '(') || is(d, '[') {
                if !math(&stack) {
                    stack.push(Group {
                        math: true,
                        end: if is(d, '(') { End::Paren } else { End::Bracket },
                    });
                }
            } else if is(d, ')') {
                truncate_at(&mut stack, End::Paren);
            } else if is(d, ']') {
                truncate_at(&mut stack, End::Bracket);
            }
            text_argument = false;
            i += 2;
            continue;
        }
        let mut j = i + 1;
        while j < n && src[j] < 128 && (src[j] as u8).is_ascii_alphabetic() {
            j += 1;
        }
        let name = String::from_utf16_lossy(&src[i + 1..j]);
        i = j;
        text_argument = false;
        if name == "verb" {
            if src.get(i).is_some_and(|&u| is(u, '*')) {
                i += 1;
            }
            let Some(&delimiter) = src.get(i) else { break };
            match find(src, i + 1, &[delimiter]) {
                Some(close) => i = close + 1,
                None => return false, // inside \verb|…
            }
            continue;
        }
        if name == "begin" || name == "end" {
            // \s*\{([^{}]*)\} within the next 64 units
            let window = &src[i..n.min(i + 64)];
            let open = window.iter().take_while(|&&u| space(u)).count();
            if !window.get(open).is_some_and(|&u| is(u, '{')) {
                continue;
            }
            let Some(close) = window[open + 1..]
                .iter()
                .position(|&u| is(u, '{') || is(u, '}'))
                .map(|p| open + 1 + p)
            else {
                continue;
            };
            if !is(window[close], '}') {
                continue;
            }
            let environment = String::from_utf16_lossy(&window[open + 1..close])
                .trim()
                .to_string();
            i += close + 1;
            if name == "end" {
                truncate_at(&mut stack, End::Environment(environment));
            } else if VERBATIM_ENVIRONMENTS.contains(&environment.as_str()) {
                let end = units(&format!("\\end{{{environment}}}"));
                match find(src, i, &end) {
                    Some(close) => i = close + end.len(),
                    None => return false, // inside verbatim
                }
            } else {
                let maths = MATH_ENVIRONMENTS
                    .contains(&environment.strip_suffix('*').unwrap_or(&environment));
                stack.push(Group {
                    math: maths || math(&stack),
                    end: End::Environment(environment),
                });
            }
            continue;
        }
        if TEXT_COMMANDS.contains(&name.as_str()) && math(&stack) {
            text_argument = true;
        }
    }
    math(&stack)
}
