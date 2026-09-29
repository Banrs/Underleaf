//! Maths, as web/src/editor.js reads it: whether a position is in maths
//! (`mathModeAt`), and the maths at the caret to preview (`mathAt`).

use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::{catalog, is, letter, space, utf16, Text};

fn find(src: &[u16], from: usize, needle: &[u16]) -> Option<usize> {
    (from..=src.len().checked_sub(needle.len())?).find(|&i| src[i..].starts_with(needle))
}

/// An environment's name in braces, after `\begin` or `\end`.
static ENVIRONMENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*\{([^{}]*)\}").unwrap());

/// Whether the end of `src` is in maths, read as TeX would: $…$, $$…$$,
/// \(…\), \[…\] and the maths environments (starred too) open maths; \text{…}
/// and its kin go back to text inside it; escapes (\$, \%, \\) aren't
/// delimiters; comments and verbatim are skipped; and a blank line ends an
/// unclosed $ or \[, as the paragraph it can't span. So `$|$` (an empty
/// pair, the caret between) is maths.
pub fn math_mode_at(src: &[u16]) -> bool {
    let catalog = catalog::get();
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
    let n = src.len();
    let mut i = 0;
    while i < n {
        let c = src[i];
        if is(c, '%') {
            // The line feed itself is read next, for the blank-line rule.
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
            continue;
        }
        if is(c, '{') {
            let maths = !text_argument && math(&stack);
            open(&mut stack, maths, "}");
            text_argument = false;
            i += 1;
            continue;
        }
        if is(c, '}') {
            // The innermost open brace, and anything unclosed inside it.
            close(&mut stack, "}");
            i += 1;
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
            continue;
        }
        let j = i + 1 + src[i + 1..].iter().take_while(|&&u| letter(u)).count();
        let name = String::from_utf16_lossy(&src[i + 1..j]);
        i = j;
        text_argument = false;
        if name == "verb" {
            i += src.get(i).is_some_and(|&u| is(u, '*')) as usize;
            let Some(&delimiter) = src.get(i) else { break };
            let Some(close) = find(src, i + 1, &[delimiter]) else {
                return false; // inside \verb|…
            };
            i = close + 1;
        } else if name == "begin" || name == "end" {
            let window = String::from_utf16_lossy(&src[i..n.min(i + 64)]);
            let Some(m) = ENVIRONMENT.captures(&window) else {
                continue;
            };
            let environment = m[1].trim();
            i += utf16(&m[0]);
            if name == "end" {
                close(&mut stack, &format!("env:{environment}"));
            } else if listed(&catalog.verbatim_environments, environment) {
                let end: Vec<u16> = format!("\\end{{{environment}}}").encode_utf16().collect();
                let Some(at) = find(src, i, &end) else {
                    return false; // inside verbatim
                };
                i = at + end.len();
            } else {
                let bare = environment.strip_suffix('*').unwrap_or(environment);
                let maths = listed(&catalog.math_environments, bare) || math(&stack);
                open(&mut stack, maths, &format!("env:{environment}"));
            }
        } else if listed(&catalog.text_commands, &name) && math(&stack) {
            text_argument = true;
        }
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
    let names = catalog::alternation(&catalog::get().preview_environments);
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
    let pairs = |re: &'static Regex| {
        re.captures_iter(&window).map(|c| {
            let whole = c.get(0).unwrap();
            (whole.start(), whole.end(), None, c.get(1).unwrap().as_str())
        })
    };
    let kinds: [Box<dyn Iterator<Item = Block<'_>> + '_>; 3] = [
        Box::new(environments(&window)),
        Box::new(pairs(&DOLLARS)),
        Box::new(pairs(&BRACKETS)),
    ];
    for blocks in kinds {
        if let Some((start, _, environment, body)) =
            blocks.take_while(|b| b.0 <= at).find(|b| at <= b.1)
        {
            return preview(
                from + utf16(&window[..start]),
                preview_tex(environment, body),
                true,
            );
        }
    }
    // Inline: single, unescaped dollars on the caret's line, paired in order.
    let index = text.line_index(caret);
    let (line, line_start) = (text.line(index), text.lines[index] as usize);
    let unit = |i: Option<usize>| i.and_then(|i| line.get(i).copied());
    let dollars: Vec<usize> = (0..line.len())
        .filter(|&i| {
            let (previous, next) = (unit(i.checked_sub(1)), unit(Some(i + 1)));
            is(line[i], '$')
                && ![Some('\\' as u16), Some('$' as u16)].contains(&previous)
                && next != Some('$' as u16)
        })
        .collect();
    let column = pos - line_start;
    let pair = dollars
        .chunks_exact(2)
        .find(|p| column > p[0] && column <= p[1])?;
    let tex = preview_tex(None, &String::from_utf16_lossy(&line[pair[0] + 1..pair[1]]));
    preview(line_start + pair[0], tex, false)
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
    let clean = body.trim();
    match environment {
        None | Some("equation" | "multline") => clean.to_string(),
        Some("cases") => format!("\\begin{{cases}}{clean}\\end{{cases}}"),
        Some("gather") => format!("\\begin{{gathered}}{clean}\\end{{gathered}}"),
        Some(_) => format!("\\begin{{aligned}}{clean}\\end{{aligned}}"),
    }
}
