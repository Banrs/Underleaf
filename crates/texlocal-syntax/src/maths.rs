//! Maths, as web/src/editor.js reads it: whether a position is in maths
//! (`mathModeAt`), and the maths at the caret to preview (`mathAt`).

use std::{borrow::Cow, sync::LazyLock};

use regex::Regex;
use serde::Serialize;

use crate::{catalog, is, letter, space, utf16, Text};

fn find(src: &[u16], from: usize, needle: &[u16]) -> Option<usize> {
    (from..=src.len().checked_sub(needle.len())?).find(|&i| src[i..].starts_with(needle))
}

/// JavaScript's whitespace rules, used by the web editor's regex and trim.
fn trim_js_space(text: &str) -> &str {
    text.trim_matches(|c| c <= '\u{ffff}' && space(c as u16))
}

/// An environment's name in braces, within the web editor's 64-unit window.
fn environment_name(src: &[u16], from: usize) -> Option<(&[u16], usize)> {
    let window = &src[from..(from + 64).min(src.len())];
    let leading = window.iter().take_while(|&&u| space(u)).count();
    let rest = &window[leading..];
    if !rest.first().is_some_and(|&u| is(u, '{')) {
        return None;
    }
    let close = rest[1..].iter().position(|&u| is(u, '{') || is(u, '}'))? + 1;
    is(rest[close], '}').then_some((&rest[1..close], from + leading + close + 1))
}

/// Whether the end of `src` is in maths, read as TeX would: $…$, $$…$$,
/// \(…\), \[…\] and the maths environments (starred too) open maths; \text{…}
/// and its kin go back to text inside it; escapes (\$, \%, \\) aren't
/// delimiters; comments and verbatim are skipped; and a blank line ends an
/// unclosed $ or \[, as the paragraph it can't span. So `$|$` (an empty
/// pair, the caret between) is maths.
pub fn math_mode_at(src: &[u16]) -> bool {
    scan(src, |_, _| {}, |_, _, _| {})
}

/// A group open at a point: whether it's maths, what closes it, where it
/// opens, and the command whose argument it is (the command's backslash and
/// the end of its name), when the brace follows a command, spaces aside.
#[derive(Clone, Debug)]
pub(crate) struct Group {
    pub math: bool,
    pub end: Cow<'static, str>,
    pub open: usize,
    pub command: Option<(usize, usize)>,
}

/// Read math/code ranges and commands outside them in one pass. Callers merge
/// adjacent ranges; no range storage is needed when only the mode is wanted.
pub(crate) fn scan(
    src: &[u16],
    range: impl FnMut(usize, usize),
    command: impl FnMut(&str, usize, usize),
) -> bool {
    scan_groups(src, &[], range, command, |_, _| {}, |_, _| {})
}

/// `scan`, which also hands `at` the groups open at each of `probes` (in
/// order), and `closed` each brace group as its `}` closes it.
pub(crate) fn scan_groups(
    src: &[u16],
    probes: &[usize],
    mut range: impl FnMut(usize, usize),
    mut command: impl FnMut(&str, usize, usize),
    mut at: impl FnMut(usize, &[Group]),
    mut closed: impl FnMut(&Group, usize),
) -> bool {
    let catalog = &*catalog::CATALOG;
    let listed = |list: &[String], name: &str| list.iter().any(|n| n == name);
    // Open groups, innermost last.
    let mut stack: Vec<Group> = Vec::new();
    let group = |math: bool, end: Cow<'static, str>, open: usize| Group {
        math,
        end,
        open,
        command: None,
    };
    let math = |stack: &[Group]| stack.last().is_some_and(|g| g.math);
    let close = |stack: &mut Vec<Group>, end: &str| {
        if let Some(k) = stack.iter().rposition(|g| g.end == end) {
            stack.truncate(k);
        }
    };
    let mut text_argument = false; // The next { opens a text argument (\text{).
    let mut math_run = false;
    // The command just read, while only spaces, a line feed or a comment follow it.
    let mut last_command: Option<(usize, usize)> = None;
    let mut probe = 0;
    let n = src.len();
    let mut i = 0;
    while i < n {
        let token_start = i;
        while probe < probes.len() && probes[probe] <= token_start {
            at(probes[probe], &stack);
            probe += 1;
        }
        let pending = last_command.take();
        let c = char::from_u32(src[i] as u32).unwrap_or_default();
        let mut code = false;
        i += 1;
        match c {
            '%' => {
                // Comments remain prose, including the following line feed.
                math_run = false;
                last_command = pending;
                let Some(eol) = find(src, i, &['\n' as u16]) else {
                    break;
                };
                i = eol;
                continue;
            }
            '\n' => {
                let j = i + src[i..]
                    .iter()
                    .take_while(|&&u| matches!(u, 9 | 13 | 32))
                    .count();
                if src.get(j).is_some_and(|&u| is(u, '\n')) {
                    if let Some(k) = stack
                        .iter()
                        .position(|g| matches!(g.end.as_ref(), "$" | "$$" | "\\)" | "\\]"))
                    {
                        stack.truncate(k);
                    }
                    text_argument = false;
                } else {
                    last_command = pending;
                }
                if math_run {
                    range(token_start, i);
                }
                math_run = math(&stack);
                continue;
            }
            '$' => {
                let double = src.get(i).is_some_and(|&u| is(u, '$'));
                match stack.last().map(|g| g.end.as_ref()) {
                    Some(end @ ("$" | "$$")) => {
                        i += (end == "$$" && double) as usize;
                        stack.pop();
                    }
                    _ if math(&stack) => {} // a stray $ in an environment's maths
                    _ => {
                        stack.push(group(
                            true,
                            if double { "$$" } else { "$" }.into(),
                            token_start,
                        ));
                        i += double as usize;
                    }
                }
                text_argument = false;
            }
            '{' => {
                stack.push(Group {
                    command: pending,
                    ..group(!text_argument && math(&stack), "}".into(), token_start)
                });
                text_argument = false;
            }
            '}' => {
                if let Some(k) = stack.iter().rposition(|g| g.end == "}") {
                    closed(&stack[k], token_start);
                    stack.truncate(k);
                }
            }
            '\\' if i < n => {
                let in_math = math(&stack);
                text_argument = false;
                if !letter(src[i]) {
                    let d = char::from_u32(src[i] as u32).unwrap_or_default();
                    match d {
                        '(' | '[' if !in_math => stack.push(group(
                            true,
                            if d == '(' { "\\)" } else { "\\]" }.into(),
                            token_start,
                        )),
                        ')' | ']' => close(&mut stack, if d == ')' { "\\)" } else { "\\]" }),
                        _ => {}
                    }
                    i += 1;
                } else {
                    let name_start = i;
                    while i < n && letter(src[i]) {
                        i += 1;
                    }
                    let name = String::from_utf16_lossy(&src[name_start..i]);
                    let name_end = i;
                    let literal_end: Option<(Cow<'_, [u16]>, usize)> = match name.as_str() {
                        "verb" => {
                            code = true;
                            i += src.get(i).is_some_and(|&u| is(u, '*')) as usize;
                            src.get(i).map(|_| (Cow::Borrowed(&src[i..i + 1]), i + 1))
                        }
                        "begin" | "end" => {
                            if let Some((name_units, after)) = environment_name(src, i) {
                                let environment = String::from_utf16_lossy(name_units);
                                let environment = trim_js_space(&environment);
                                i = after;
                                if name == "end" {
                                    close(&mut stack, &format!("env:{environment}"));
                                    None
                                } else if listed(&catalog.verbatim_environments, environment) {
                                    code = true;
                                    Some((
                                        format!("\\end{{{environment}}}")
                                            .encode_utf16()
                                            .collect::<Vec<_>>()
                                            .into(),
                                        i,
                                    ))
                                } else {
                                    let bare = environment.strip_suffix('*').unwrap_or(environment);
                                    stack.push(group(
                                        listed(&catalog.math_environments, bare) || in_math,
                                        format!("env:{environment}").into(),
                                        token_start,
                                    ));
                                    None
                                }
                            } else {
                                None
                            }
                        }
                        _ => {
                            text_argument = listed(&catalog.text_commands, &name) && in_math;
                            last_command = Some((token_start, name_end));
                            None
                        }
                    };
                    if let Some((end, from)) = literal_end {
                        i = find(src, from, &end).map_or_else(
                            || {
                                stack.clear();
                                n
                            },
                            |at| at + end.len(),
                        );
                    }
                    if !in_math && !code {
                        command(&name, token_start, name_end);
                    }
                }
            }
            _ => {
                text_argument &= space(src[token_start]);
                if space(src[token_start]) {
                    last_command = pending;
                }
            }
        }
        let next_math = math(&stack);
        if code || math_run || next_math {
            range(token_start, i);
        }
        math_run = next_math;
    }
    for &p in &probes[probe..] {
        at(p, &stack);
    }
    math(&stack)
}

/// Maths to preview: where it starts, its TeX as KaTeX reads it, and
/// whether it's displayed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct MathPreview {
    pub start: u32,
    pub tex: String,
    pub display: bool,
}

static BEGIN: LazyLock<Regex> = LazyLock::new(|| {
    let names = catalog::alternation(&catalog::CATALOG.preview_environments);
    Regex::new(&format!(r"\\begin\{{({names})(\*?)\}}")).unwrap()
});
static DOLLARS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)\$\$(.*?)\$\$").unwrap());
static BRACKETS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)\\\[(.*?)\\\]").unwrap());
static LABELS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\(?:label|tag)\{[^}]*\}").unwrap());
static NUMBERING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\(?:nonumber|notag)(?-u:\b)").unwrap());

/// The maths the caret is in or just after: the first display block that
/// holds it (a maths environment, then $$…$$, then \[…\]), else $…$ on its
/// line. Only 20,000 units either side are read. None when it holds no TeX.
pub fn math_at(text: &Text, caret: u32) -> Option<MathPreview> {
    let pos = caret as usize;
    let from = pos.saturating_sub(20_000);
    let before = String::from_utf16_lossy(&text.units[from..pos]);
    let after = String::from_utf16_lossy(&text.units[pos..(pos + 20_000).min(text.units.len())]);
    let at = before.len();
    let window = before + &after;
    let preview = |start: usize, tex: String, display| {
        (!tex.is_empty()).then_some(MathPreview {
            start: start as u32,
            tex,
            display,
        })
    };
    for (re, is_environment) in [(&*BEGIN, true), (&*DOLLARS, false), (&*BRACKETS, false)] {
        let mut offset = 0;
        while let Some(c) = re.captures_at(&window, offset) {
            let whole = c.get(0).unwrap();
            if whole.start() > at {
                break;
            }
            offset = whole.end();
            let (environment, body) = if is_environment {
                let name = c.get(1).unwrap().as_str();
                let end = format!("\\end{{{name}{}}}", &c[2]);
                let Some(close) = window[offset..].find(&end) else {
                    continue;
                };
                let body = &window[offset..offset + close];
                offset += close + end.len();
                (Some(name), body)
            } else {
                (None, c.get(1).unwrap().as_str())
            };
            if at <= offset {
                return preview(
                    from + utf16(&window[..whole.start()]),
                    preview_tex(environment, body),
                    true,
                );
            }
        }
    }
    // Inline: single, unescaped dollars on the caret's line, paired in order.
    let index = text.line_index(caret);
    let (line, line_start) = (text.line(index), text.lines[index] as usize);
    let unit = |i: Option<usize>| i.and_then(|i| line.get(i).copied());
    let dollar = |i: usize| {
        let (previous, next) = (unit(i.checked_sub(1)), unit(Some(i + 1)));
        is(line[i], '$')
            && ![Some('\\' as u16), Some('$' as u16)].contains(&previous)
            && next != Some('$' as u16)
    };
    let column = pos - line_start;
    let mut open = None;
    for i in 0..column {
        if dollar(i) {
            open = if open.is_some() { None } else { Some(i) };
        }
    }
    let open = open?;
    let close = (column..line.len()).find(|&i| dollar(i))?;
    let tex = preview_tex(None, &String::from_utf16_lossy(&line[open + 1..close]));
    preview(line_start + open, tex, false)
}

/// What KaTeX shows of maths: no labels or numbering, and an environment's
/// body as the aligned or cases block it can render.
fn preview_tex(environment: Option<&str>, body: &str) -> String {
    let body = LABELS.replace_all(body, "");
    let body = NUMBERING.replace_all(&body, "");
    let clean = trim_js_space(&body);
    let environment = match environment {
        None | Some("equation" | "multline") => return clean.to_string(),
        Some("cases") => "cases",
        Some("gather") => "gathered",
        Some(_) => "aligned",
    };
    format!("\\begin{{{environment}}}{clean}\\end{{{environment}}}")
}
