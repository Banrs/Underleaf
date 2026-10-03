//! Maths, as web/src/editor.js reads it: whether a position is in maths
//! (`mathModeAt`), and the maths at the caret to preview (`mathAt`).

use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::{catalog, is, letter, merge_range, space, utf16, Text, TextRange};

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
    scan(src, false).0
}

/// The UTF-16 ranges that are math or literal code, using the same scan as
/// `math_mode_at`. Math comments and the text arguments of \text-like
/// commands stay out of these ranges so they remain ordinary prose.
pub(crate) fn non_prose_ranges(src: &[u16]) -> Vec<TextRange> {
    scan(src, true).1
}

/// Scan once for both the math mode at EOF and non-prose math/code runs.
/// Keeping ranges here makes collection follow `math_mode_at`'s parsing rules.
fn scan(src: &[u16], collect_ranges: bool) -> (bool, Vec<TextRange>) {
    let catalog = &*catalog::CATALOG;
    let listed = |list: &[String], name: &str| list.iter().any(|n| n == name);
    // Open groups, innermost last: whether they're maths, and what closes
    // them: "$", "$$", "\)", "\]", "}" or "env:<name>".
    let mut stack: Vec<(bool, String)> = Vec::new();
    let math = |stack: &[(bool, String)]| stack.last().is_some_and(|g| g.0);
    let close = |stack: &mut Vec<(bool, String)>, end: &str| {
        if let Some(k) = stack.iter().rposition(|g| g.1 == end) {
            stack.truncate(k);
        }
    };
    let open =
        |stack: &mut Vec<(bool, String)>, math: bool, end: &str| stack.push((math, end.into()));
    // The next { opens a text argument (\text{).
    let mut text_argument = false;
    let mut ranges = RangeCollector {
        enabled: collect_ranges,
        math_start: None,
        ranges: Vec::new(),
    };
    let n = src.len();
    let mut i = 0;
    while i < n {
        let token_start = i;
        let was_math = math(&stack);
        let c = src[i];
        if is(c, '%') {
            // The line feed itself is read next, for the blank-line rule.
            ranges.end_math(i);
            let Some(eol) = find(src, i, &['\n' as u16]) else {
                break;
            };
            i = eol;
            continue;
        }
        if is(c, '\n') {
            let mut j = i + 1;
            while j < n && [' ', '\t', '\r'].iter().any(|&w| is(src[j], w)) {
                j += 1;
            }
            if j < n && is(src[j], '\n') {
                let paragraph =
                    |g: &(bool, String)| ["$", "$$", "\\)", "\\]"].contains(&g.1.as_str());
                if let Some(k) = stack.iter().position(paragraph) {
                    stack.truncate(k);
                }
                text_argument = false;
            }
            i += 1;
            ranges.transition(was_math, math(&stack), i, i);
            continue;
        }
        if is(c, '$') {
            let double = src.get(i + 1).is_some_and(|&u| is(u, '$'));
            match stack.last().map(|g| g.1.as_str()) {
                Some("$") => {
                    stack.pop();
                    i += 1;
                }
                Some("$$") => {
                    stack.pop();
                    i += 1 + double as usize;
                }
                _ if math(&stack) => i += 1, // a stray $ in an environment's maths
                _ => {
                    open(&mut stack, true, if double { "$$" } else { "$" });
                    i += 1 + double as usize;
                }
            }
            text_argument = false;
            ranges.transition(was_math, math(&stack), token_start, i);
            continue;
        }
        if is(c, '{') {
            let maths = !text_argument && math(&stack);
            open(&mut stack, maths, "}");
            text_argument = false;
            i += 1;
            ranges.transition(was_math, math(&stack), token_start, i);
            continue;
        }
        if is(c, '}') {
            // The innermost open brace, and anything unclosed inside it.
            close(&mut stack, "}");
            i += 1;
            ranges.transition(was_math, math(&stack), token_start, i);
            continue;
        }
        if !is(c, '\\') {
            text_argument &= space(c);
            i += 1;
            continue;
        }
        let Some(&d) = src.get(i + 1) else { break };
        if !letter(d) {
            // A control symbol: \( \) \[ \] open and close maths; any other
            // (\$, \%, \\, \{) is an escape and nothing more.
            if (is(d, '(') || is(d, '[')) && !math(&stack) {
                open(&mut stack, true, if is(d, '(') { "\\)" } else { "\\]" });
            } else if is(d, ')') || is(d, ']') {
                close(&mut stack, &String::from_utf16_lossy(&src[i..i + 2]));
            }
            text_argument = false;
            i += 2;
            ranges.transition(was_math, math(&stack), token_start, i);
            continue;
        }
        let j = i + 1 + src[i + 1..].iter().take_while(|&&u| letter(u)).count();
        let name = String::from_utf16_lossy(&src[i + 1..j]);
        i = j;
        text_argument = false;
        if name == "verb" {
            i += src.get(i).is_some_and(|&u| is(u, '*')) as usize;
            let Some(&delimiter) = src.get(i) else {
                ranges.code(token_start, n);
                ranges.end_math(n);
                return (math(&stack), ranges.ranges);
            };
            let Some(close) = find(src, i + 1, &[delimiter]) else {
                ranges.code(token_start, n);
                ranges.end_math(n);
                return (false, ranges.ranges); // inside \verb|…
            };
            i = close + 1;
            ranges.code(token_start, i);
        } else if name == "begin" || name == "end" {
            let Some((name_units, after)) = environment_name(src, i) else {
                continue;
            };
            let environment = String::from_utf16_lossy(name_units);
            let environment = trim_js_space(&environment);
            i = after;
            if name == "end" {
                close(&mut stack, &format!("env:{environment}"));
            } else if listed(&catalog.verbatim_environments, environment) {
                let end: Vec<u16> = format!("\\end{{{environment}}}").encode_utf16().collect();
                let Some(at) = find(src, i, &end) else {
                    ranges.code(token_start, n);
                    ranges.end_math(n);
                    return (false, ranges.ranges); // inside verbatim
                };
                i = at + end.len();
                ranges.code(token_start, i);
            } else {
                let bare = environment.strip_suffix('*').unwrap_or(environment);
                let maths = listed(&catalog.math_environments, bare) || math(&stack);
                open(&mut stack, maths, &format!("env:{environment}"));
            }
        } else if listed(&catalog.text_commands, &name) && math(&stack) {
            text_argument = true;
        }
        ranges.transition(was_math, math(&stack), token_start, i);
    }
    ranges.end_math(n);
    (math(&stack), ranges.ranges)
}

/// Collects ordered UTF-16 math and literal-code ranges while the shared
/// scanner moves through the source. A math run absorbs code nested inside it.
struct RangeCollector {
    enabled: bool,
    math_start: Option<u32>,
    ranges: Vec<TextRange>,
}

impl RangeCollector {
    fn transition(&mut self, was_math: bool, is_math: bool, token_start: usize, token_end: usize) {
        if !self.enabled {
            return;
        }
        if is_math {
            self.math_start.get_or_insert(token_start as u32);
        } else if was_math {
            self.end_math(token_end);
        }
    }

    fn end_math(&mut self, end: usize) {
        if let Some(start) = self.math_start.take() {
            self.push(start as usize, end);
        }
    }

    fn code(&mut self, start: usize, end: usize) {
        if self.enabled && self.math_start.is_none() {
            self.push(start, end);
        }
    }

    fn push(&mut self, start: usize, end: usize) {
        if start < end {
            merge_range(
                &mut self.ranges,
                TextRange {
                    start: start as u32,
                    length: (end - start) as u32,
                },
            );
        }
    }
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

/// A display block in the text read: its start and end, its environment's
/// name if it's one, and its body.
type Block<'a> = (usize, usize, Option<&'a str>, &'a str);

fn paired_block<'a>(re: &Regex, window: &'a str, at: usize) -> Option<Block<'a>> {
    re.captures_iter(window)
        .map(|c| {
            let whole = c.get(0).unwrap();
            (whole.start(), whole.end(), None, c.get(1).unwrap().as_str())
        })
        .take_while(|b| b.0 <= at)
        .find(|b| at <= b.1)
}

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
    let block = environments(&window)
        .take_while(|b| b.0 <= at)
        .find(|b| at <= b.1)
        .or_else(|| paired_block(&DOLLARS, &window, at))
        .or_else(|| paired_block(&BRACKETS, &window, at));
    if let Some((start, _, environment, body)) = block {
        return preview(
            from + utf16(&window[..start]),
            preview_tex(environment, body),
            true,
        );
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

/// The maths environments in `window` that close, in order.
fn environments(window: &str) -> impl Iterator<Item = Block<'_>> {
    let mut from = 0;
    std::iter::from_fn(move || {
        while let Some(c) = BEGIN.captures_at(window, from) {
            let (open, name) = (c.get(0).unwrap(), c.get(1).unwrap().as_str());
            from = open.start() + 1;
            let end = format!("\\end{{{name}{}}}", &c[2]);
            if let Some(close) = window[open.end()..].find(&end) {
                let body = &window[open.end()..open.end() + close];
                from = open.end() + close + end.len();
                return Some((open.start(), from, Some(name), body));
            }
        }
        None
    })
}

/// What KaTeX shows of maths: no labels or numbering, and an environment's
/// body as the aligned or cases block it can render.
fn preview_tex(environment: Option<&str>, body: &str) -> String {
    let body = LABELS.replace_all(body, "");
    let body = NUMBERING.replace_all(&body, "");
    let clean = trim_js_space(&body);
    match environment {
        None | Some("equation" | "multline") => clean.to_string(),
        Some("cases") => format!("\\begin{{cases}}{clean}\\end{{cases}}"),
        Some("gather") => format!("\\begin{{gathered}}{clean}\\end{{gathered}}"),
        Some(_) => format!("\\begin{{aligned}}{clean}\\end{{aligned}}"),
    }
}
