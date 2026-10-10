//! Maths, as web/src/editor.js reads it: whether a position is in maths
//! (`mathModeAt`), and the maths at the caret to preview (`mathAt`).

use std::{borrow::Cow, sync::LazyLock};

use regex::Regex;
use serde::Serialize;

use crate::{ascii, catalog, is, letter, space, utf16, Text};

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
    let mut scanner = Scanner::default();
    scanner.run(src, src.len(), &[], &mut ());
    scanner.in_math()
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

/// What a scan reports as it reads: maths and literal code as ranges, which
/// callers merge; commands outside them, by name, backslash and name's end;
/// the groups open at each probe; and each brace group as its `}` closes it.
pub(crate) trait Visit {
    fn range(&mut self, _from: usize, _to: usize) {}
    fn command(&mut self, _name: &str, _start: usize, _name_end: usize) {}
    fn at(&mut self, _groups: &[Group]) {}
    fn closed(&mut self, _group: &Group, _close: usize) {}
}

impl Visit for () {}

/// The last maths or code run so far, adjacent ranges joined.
impl Visit for Option<(usize, usize)> {
    fn range(&mut self, from: usize, to: usize) {
        *self = match *self {
            Some((start, end)) if from <= end => Some((start, end.max(to))),
            _ => Some((from, to)),
        };
    }
}

/// The scan between two tokens: all it carries from the text before.
#[derive(Clone, Default)]
pub(crate) struct Scanner {
    /// Open groups, innermost last.
    stack: Vec<Group>,
    /// The next { opens a text argument (\text{).
    text_argument: bool,
    math_run: bool,
    /// The command just read, while only spaces, a line feed or a comment follow it.
    last_command: Option<(usize, usize)>,
    /// Where the next token starts.
    i: usize,
    /// One past the last unit read: past the text's end once a token ran
    /// into it, as a longer text could have read on.
    reach: usize,
}

impl Scanner {
    pub fn in_math(&self) -> bool {
        self.stack.last().is_some_and(|g| g.math)
    }

    /// Read the tokens of `src` that start before `until`, telling `visit`.
    /// Given probes, it stops once all are answered and no group is open,
    /// as nothing later can close one open at them.
    pub fn run(&mut self, src: &[u16], until: usize, probes: &[usize], visit: &mut impl Visit) {
        let catalog = &*catalog::CATALOG;
        let listed = |list: &[String], name: &str| list.iter().any(|n| n == name);
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
        let Scanner {
            mut stack,
            mut text_argument,
            mut math_run,
            mut last_command,
            mut i,
            mut reach,
        } = std::mem::take(self);
        let mut probe = 0;
        let n = src.len();
        while i < n.min(until) {
            let token_start = i;
            while probe < probes.len() && probes[probe] <= token_start {
                visit.at(&stack);
                probe += 1;
            }
            if !probes.is_empty() && probe == probes.len() && stack.is_empty() {
                break;
            }
            let pending = last_command.take();
            let c = char::from_u32(src[i] as u32).unwrap_or_default();
            let mut code = false;
            i += 1;
            // One past what the token read beyond its end.
            let mut read = i + 1;
            match c {
                '%' => {
                    // Comments remain prose, including the following line feed.
                    math_run = false;
                    last_command = pending;
                    i = find(src, i, &['\n' as u16]).unwrap_or(n);
                    reach = reach.max(i + 1);
                    continue;
                }
                '\n' => {
                    let j = i + src[i..]
                        .iter()
                        .take_while(|&&u| matches!(u, 9 | 13 | 32))
                        .count();
                    reach = reach.max(j + 1);
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
                        visit.range(token_start, i);
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
                        visit.closed(&stack[k], token_start);
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
                        let name_end = i;
                        let mut buf = [0; 64];
                        let name = ascii(&src[name_start..name_end], &mut buf);
                        let mut verb = false;
                        let literal_end: Option<(Cow<'_, [u16]>, usize)> = match name {
                            "verb" => {
                                code = true;
                                verb = true;
                                i += src.get(i).is_some_and(|&u| is(u, '*')) as usize;
                                src.get(i).map(|_| (Cow::Borrowed(&src[i..i + 1]), i + 1))
                            }
                            "begin" | "end" => {
                                read = (i + 64).min(n + 1);
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
                                        let bare =
                                            environment.strip_suffix('*').unwrap_or(environment);
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
                                text_argument = listed(&catalog.text_commands, name) && in_math;
                                last_command = Some((token_start, name_end));
                                None
                            }
                        };
                        if let Some((end, from)) = literal_end {
                            // \verb can't cross a line: unclosed, it ends where
                            // its line does (its delimiter may be that line feed).
                            let line_end =
                                verb.then(|| find(src, from - 1, &['\n' as u16])).flatten();
                            let limit = line_end.unwrap_or(n);
                            if verb {
                                read = limit + 1; // looking for the line's end
                            }
                            i = match (find(&src[..limit], from, &end), line_end) {
                                (Some(at), _) => at + end.len(),
                                (None, Some(line_end)) => line_end,
                                // Code to the end of the text, or the position
                                // asked about is in it.
                                (None, None) => {
                                    stack.clear();
                                    n
                                }
                            };
                        }
                        if !in_math && !code {
                            visit.command(name, token_start, name_end);
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
                visit.range(token_start, i);
            }
            math_run = next_math;
            reach = reach.max(read).max(i + 1);
        }
        for _ in &probes[probe..] {
            visit.at(&stack);
        }
        *self = Scanner {
            stack,
            text_argument,
            math_run,
            last_command,
            i,
            reach,
        };
    }
}

/// Scanners kept through the text every few thousand units, so a question
/// about one place reads from the nearest before it rather than from the
/// start. An edit forgets those that read what it changed.
pub(crate) struct Scans(Vec<Point>);

/// A kept scanner, and the maths or code run that ranges after it may join.
#[derive(Clone, Default)]
pub(crate) struct Point {
    pub scanner: Scanner,
    pub run: Option<(usize, usize)>,
}

const SPACING: usize = 4096;
/// A scanner with more open groups isn't kept: braces nobody closes would
/// make every one as big as the text.
const KEPT_GROUPS: usize = 64;

impl Default for Scans {
    fn default() -> Self {
        Scans(vec![Point::default()])
    }
}

impl Scans {
    pub fn forget_from(&mut self, at: usize) {
        // The first point has read nothing, so it's always kept.
        let kept = self.0.partition_point(|p| p.scanner.reach <= at);
        self.0.truncate(kept);
    }

    /// The last point at or before `before` that has read nothing at or past
    /// `end`, from which reading `src[..end]` goes as it would from the start.
    pub fn resume(&mut self, src: &[u16], before: usize, end: usize) -> Point {
        let mut point = self.0[self.0.len() - 1].clone();
        while point.scanner.i + SPACING <= before && point.scanner.i < src.len() {
            let until = point.scanner.i + SPACING;
            point.scanner.run(src, until, &[], &mut point.run);
            if point.scanner.stack.len() <= KEPT_GROUPS {
                self.0.push(point.clone());
            }
        }
        let k = self
            .0
            .partition_point(|p| p.scanner.i <= before && p.scanner.reach <= end);
        self.0[k - 1].clone()
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

#[cfg(test)]
mod tests {
    use crate::SourceDocument;

    fn in_math(text: &str) -> bool {
        super::math_mode_at(&text.encode_utf16().collect::<Vec<_>>())
    }

    #[test]
    fn an_unclosed_verb_ends_with_its_line() {
        // \verb can't cross a line, so what follows is read as ever.
        assert!(in_math("a \\verb|x\n$y"));
        assert!(!in_math("a \\verb|x\n$y$ z"));
        assert!(in_math("$ \\verb|x\ny"), "the maths it was in goes on");
        // A line feed straight after \verb ends it too.
        assert!(in_math("\\verb\n$y"));
        // Still on its line, the position is in the code, not maths.
        assert!(!in_math("$ \\verb|x"));
        // Closed, it's skipped as before, delimiters and all.
        assert!(!in_math("\\verb|$| a"));
        assert!(in_math("\\verb*+x+ $a"));

        // A spelling checker skips the code on its line, and no more.
        let text = "\\verb|Speling\nprose \\cite{key}";
        let doc = SourceDocument::new(text);
        let ranges = doc.not_prose(0, text.len() as u32);
        let covered = |needle: &str| {
            let at = text.find(needle).unwrap() as u32;
            ranges
                .iter()
                .any(|r| r.start <= at && at < r.start + r.length)
        };
        assert!(covered("Speling"));
        assert!(!covered("prose"));
        assert!(covered("key"));
    }
}
