//! Maths: whether a position is in maths (`math_mode_at`), and the maths at
//! the caret to preview (`math_at`).

use std::{borrow::Cow, sync::LazyLock};

use regex::Regex;
use serde::Serialize;

use super::prose::Names;
use super::stack::Stack;
use super::{NAME, Text, ascii, catalog, is, letter, space, utf16};

fn find(src: &[u16], from: usize, needle: &[u16]) -> Option<usize> {
    (from..=src.len().checked_sub(needle.len())?).find(|&i| src[i..].starts_with(needle))
}

/// Trimmed of ECMAScript's whitespace, as \s and trim() have it.
fn trim_js_space(text: &str) -> &str {
    text.trim_matches(|c| c <= '\u{ffff}' && space(c as u16))
}

/// An environment's name in braces, within a 64-unit window.
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

fn group(
    math: bool,
    end: impl Into<Cow<'static, str>>,
    open: usize,
    command: Option<(usize, usize)>,
) -> Group {
    let end = end.into();
    Group {
        math,
        end,
        open,
        command,
    }
}

/// What a scan reports as it reads: maths and literal code as ranges, which
/// callers merge; commands outside them, by name, backslash and name's end;
/// the groups open at each probe; and each brace group as its `}` closes it.
pub(crate) trait Visit {
    fn range(&mut self, _from: usize, _to: usize) {}
    fn command(&mut self, _name: &str, _start: usize, _name_end: usize) {}
    fn at(&mut self, _groups: Vec<Group>) {}
    fn closed(&mut self, _group: &Group, _close: usize) {}
}

impl Visit for () {}

#[cfg(test)]
thread_local! {
    /// The units scanners have read on this thread, for the tests to tell how
    /// far a question read.
    pub(crate) static READ: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// The scan between two tokens: all it carries from the text before.
#[derive(Clone, Default)]
pub(crate) struct Scanner {
    /// Open groups, shared with the scanners kept before.
    stack: Stack<Group>,
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
        self.stack.top().is_some_and(|g| g.math)
    }

    fn close(&mut self, end: &str) {
        self.stack.pop_to(false, |g| g.end == end, |_| {});
    }

    /// The groups open, outermost first.
    fn groups(&self) -> Vec<Group> {
        let mut groups: Vec<Group> = self.stack.iter().cloned().collect();
        groups.reverse();
        groups
    }

    /// Read the tokens of `src` that start before `until`, telling `visit`.
    /// Given probes, it stops once all are answered and no brace group is
    /// open, as only those report their close.
    pub fn run(&mut self, src: &[u16], until: usize, probes: &[usize], visit: &mut impl Visit) {
        let catalog = &*catalog::CATALOG;
        let listed = |list: &[String], name: &str| list.iter().any(|n| n == name);
        #[cfg(test)]
        let from = self.i;
        let (n, mut probe) = (src.len(), 0);
        while self.i < n.min(until) {
            let start = self.i;
            while probes.get(probe).is_some_and(|&p| p <= start) {
                visit.at(self.groups());
                probe += 1;
            }
            let answered = !probes.is_empty() && probe == probes.len();
            if answered && !self.stack.iter().any(|g| g.end == "}") {
                break;
            }
            let (pending, in_math) = (self.last_command.take(), self.in_math());
            let mut code = false;
            self.i += 1;
            // One past what the token read beyond its end.
            let mut read = self.i + 1;
            match char::from_u32(src[start] as u32).unwrap_or_default() {
                '%' => {
                    // Comments remain prose, including the following line feed.
                    self.math_run = false;
                    self.last_command = pending;
                    self.i = find(src, self.i, &['\n' as u16]).unwrap_or(n);
                    self.reach = self.reach.max(self.i + 1);
                    continue;
                }
                '\n' => {
                    let spaces = |j: usize| matches!(src[j], 9 | 13 | 32);
                    let j = (self.i..n).find(|&j| !spaces(j)).unwrap_or(n);
                    self.reach = self.reach.max(j + 1);
                    if src.get(j).is_some_and(|&u| is(u, '\n')) {
                        let delimited = |g: &Group| matches!(&*g.end, "$" | "$$" | "\\)" | "\\]");
                        self.stack.pop_to(true, delimited, |_| {});
                        self.text_argument = false;
                    } else {
                        self.last_command = pending;
                    }
                    if self.math_run {
                        visit.range(start, self.i);
                    }
                    self.math_run = self.in_math();
                    continue;
                }
                '$' => {
                    let double = src.get(self.i).is_some_and(|&u| is(u, '$'));
                    match self.stack.top().map(|g| g.end.as_ref()) {
                        Some(end @ ("$" | "$$")) => {
                            self.i += (end == "$$" && double) as usize;
                            self.stack.pop();
                        }
                        _ if in_math => {} // a stray $ in an environment's maths
                        _ => {
                            let end = if double { "$$" } else { "$" };
                            self.stack.push(group(true, end, start, None));
                            self.i += double as usize;
                        }
                    }
                    self.text_argument = false;
                }
                '{' => {
                    let math = !self.text_argument && in_math;
                    self.stack.push(group(math, "}", start, pending));
                    self.text_argument = false;
                }
                '}' => {
                    let closed = |g: &Group| visit.closed(g, start);
                    self.stack.pop_to(false, |g| g.end == "}", closed);
                }
                '\\' if self.i < n && !letter(src[self.i]) => {
                    self.text_argument = false;
                    match char::from_u32(src[self.i] as u32).unwrap_or_default() {
                        '(' if !in_math => self.stack.push(group(true, "\\)", start, None)),
                        '[' if !in_math => self.stack.push(group(true, "\\]", start, None)),
                        ')' => self.close("\\)"),
                        ']' => self.close("\\]"),
                        _ => {}
                    }
                    self.i += 1;
                }
                '\\' if self.i < n => {
                    self.text_argument = false;
                    let name_start = self.i;
                    while self.i < n && letter(src[self.i]) {
                        self.i += 1;
                    }
                    let name_end = self.i;
                    let mut buf = [0; NAME];
                    let name = ascii(&src[name_start..name_end], &mut buf);
                    // Literal code: what ends it, and where to look for that from.
                    let mut literal: Option<(Vec<u16>, usize)> = None;
                    match name {
                        "verb" => {
                            self.i += src.get(self.i).is_some_and(|&u| is(u, '*')) as usize;
                            literal = src.get(self.i).map(|&d| (vec![d], self.i + 1));
                            code = true;
                        }
                        "begin" | "end" => {
                            read = (self.i + 64).min(n + 1);
                            if let Some((units, after)) = environment_name(src, self.i) {
                                let environment = String::from_utf16_lossy(units);
                                let environment = trim_js_space(&environment);
                                self.i = after;
                                if name == "end" {
                                    self.close(&format!("env:{environment}"));
                                } else if listed(&catalog.verbatim_environments, environment) {
                                    let end = format!("\\end{{{environment}}}");
                                    literal = Some((end.encode_utf16().collect(), self.i));
                                    code = true;
                                } else {
                                    let bare = environment.strip_suffix('*').unwrap_or(environment);
                                    let math = listed(&catalog.math_environments, bare) || in_math;
                                    let end = format!("env:{environment}");
                                    self.stack.push(group(math, end, start, None));
                                }
                            }
                        }
                        _ => {
                            self.text_argument = listed(&catalog.text_commands, name) && in_math;
                            self.last_command = Some((start, name_end));
                        }
                    }
                    if let Some((end, from)) = literal {
                        // \verb can't cross a line: unclosed, it ends where
                        // its line does (its delimiter may be that line feed).
                        let verb = name == "verb";
                        let line_end = verb.then(|| find(src, from - 1, &['\n' as u16])).flatten();
                        let limit = line_end.unwrap_or(n);
                        if verb {
                            read = limit + 1; // looking for the line's end
                        }
                        self.i = match (find(&src[..limit], from, &end), line_end) {
                            (Some(at), _) => at + end.len(),
                            (None, Some(line_end)) => line_end,
                            // Code to the end of the text, or the position
                            // asked about is in it.
                            (None, None) => {
                                self.stack = Stack::default();
                                n
                            }
                        };
                    }
                    if !in_math && !code {
                        visit.command(name, start, name_end);
                    }
                }
                _ => {
                    self.text_argument &= space(src[start]);
                    if space(src[start]) {
                        self.last_command = pending;
                    }
                }
            }
            let next_math = self.in_math();
            if code || self.math_run || next_math {
                visit.range(start, self.i);
            }
            self.math_run = next_math;
            self.reach = self.reach.max(read).max(self.i + 1);
        }
        for _ in &probes[probe..] {
            visit.at(self.groups());
        }
        #[cfg(test)]
        READ.with(|read| read.set(read.get() + (self.i - from)));
    }
}

/// Scanners kept through the text every few thousand units, so a question
/// about one place reads from the nearest before it rather than from the
/// start. An edit forgets those that read what it changed.
#[derive(Default)]
pub(crate) struct Scans(Vec<Point>);

/// A kept scanner, the maths or code run that ranges after it may join, and
/// how far name arguments have been read.
#[derive(Clone, Default)]
pub(crate) struct Point {
    pub scanner: Scanner,
    pub run: Option<(usize, usize)>,
    pub names: Names,
}

/// What a point is kept with, read through the whole text.
struct Keeping<'a> {
    text: &'a Text,
    run: &'a mut Option<(usize, usize)>,
    names: &'a mut Names,
}

impl Visit for Keeping<'_> {
    /// The last maths or code run so far, adjacent ranges joined.
    fn range(&mut self, from: usize, to: usize) {
        *self.run = match *self.run {
            Some((start, end)) if from <= end => Some((start, end.max(to))),
            _ => Some((from, to)),
        };
    }

    fn command(&mut self, name: &str, start: usize, name_end: usize) {
        let end = self.text.units().len();
        (self.names).command(self.text, (name, start, name_end), end, &mut Vec::new());
    }
}

const SPACING: usize = 4096;

impl Scans {
    pub fn forget_from(&mut self, at: usize) {
        // The first point has read nothing, so it's always kept.
        let kept = self.0.partition_point(|p| p.scanner.reach <= at);
        self.0.truncate(kept);
    }

    /// The last point at or before `before` that has read nothing at or past
    /// `end`, from which reading the text up to `end` (all of it reached)
    /// goes as it would from the start. Points are kept as far as `before`
    /// first, each a few pointers whatever the groups open.
    pub fn resume(&mut self, text: &Text, before: usize, end: usize) -> Point {
        if self.0.is_empty() {
            self.0.push(Point::default());
        }
        let (units, mut point) = (text.units(), self.0[self.0.len() - 1].clone());
        // Its names were read through the text as it was when it was kept,
        // past what an edit since may have changed.
        point.names.resume(text, units.len(), &mut Vec::new());
        while point.scanner.i + SPACING <= before && point.scanner.i < units.len() {
            let until = point.scanner.i + SPACING;
            let (run, names) = (&mut point.run, &mut point.names);
            let keeping = &mut Keeping { text, run, names };
            point.scanner.run(units, until, &[], keeping);
            self.0.push(point.clone());
        }
        let resumable = |p: &Point| p.scanner.i <= before && p.scanner.reach <= end;
        self.0[self.0.partition_point(resumable) - 1].clone()
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

/// How far either side of the caret `math_at` reads.
pub(crate) const PREVIEW_READS: usize = 20_000;

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
/// line. Only `PREVIEW_READS` units either side are read, reached, and the
/// caret's line. None when it holds no TeX.
pub fn math_at(text: &Text, caret: u32) -> Option<MathPreview> {
    let (units, pos) = (text.units(), caret as usize);
    let from = pos.saturating_sub(PREVIEW_READS);
    let before = String::from_utf16_lossy(&units[from..pos]);
    let after = String::from_utf16_lossy(&units[pos..(pos + PREVIEW_READS).min(units.len())]);
    let at = before.len();
    let window = before + &after;
    let preview = |start: usize, tex: String, display| {
        let start = start as u32;
        (!tex.is_empty()).then_some(MathPreview {
            start,
            tex,
            display,
        })
    };
    for (re, is_environment) in [(&*BEGIN, true), (&*DOLLARS, false), (&*BRACKETS, false)] {
        let mut offset = 0;
        while let Some(c) = re.captures_at(&window, offset) {
            let whole = c.get_match();
            if whole.start() > at {
                break;
            }
            offset = whole.end();
            let (environment, body) = if is_environment {
                let name = &c[1];
                let end = format!("\\end{{{name}{}}}", &c[2]);
                let Some(close) = window[offset..].find(&end) else {
                    continue;
                };
                let body = &window[offset..offset + close];
                offset += close + end.len();
                (Some(name), body)
            } else {
                (None, &c[1])
            };
            if at <= offset {
                let start = from + utf16(&window[..whole.start()]);
                return preview(start, preview_tex(environment, body), true);
            }
        }
    }
    // Inline: single, unescaped dollars on the caret's line, paired in order.
    let index = text.line_index(caret);
    let (line, line_start) = (text.line(index), text.line_start(index) as usize);
    let dollar = |i: usize| {
        let previous = i.checked_sub(1).map(|i| line[i]);
        let after = line.get(i + 1).copied();
        is(line[i], '$')
            && !previous.is_some_and(|u| is(u, '\\') || is(u, '$'))
            && after != Some('$' as u16)
    };
    let column = pos - line_start;
    let dollars = (0..column).filter(|&i| dollar(i));
    let open = dollars.fold(None, |open, i| open.xor(Some(i)))?;
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
    use super::{READ, SPACING};
    use crate::syntax::{SourceDocument, TextRange};

    /// Whether 200 spelling and style questions near the end of `source`, between
    /// edits, read it once to keep their points and then near each question only:
    /// each of a question's three answers reads at most from the kept point before
    /// it, less than twice their spacing, where from the start would be the text.
    fn questions_near_the_end_read_near_them(source: &str) {
        const QUESTIONS: usize = 200;
        let len = source.encode_utf16().count();
        let mut doc = SourceDocument::new(source);
        let before = READ.get();
        for k in 0..QUESTIONS {
            let at = (len - 1_000 - k * 37) as u32;
            let range = |length| TextRange { start: at, length };
            doc.not_prose(at, 40);
            doc.text_styles(range(3));
            doc.insert_symbol("\\alpha", range(0));
            if k % 20 == 0 {
                doc.edit(at + 500, 0, "x");
            }
        }
        let read = READ.get() - before;
        let most = len + QUESTIONS * 3 * 2 * SPACING;
        assert!(read < most, "{read} units read of {len}");
    }

    #[test]
    fn questions_about_a_long_text_read_only_near_them() {
        // 2.8 million units, braces closed and paragraphs short: each question
        // had read it all from the start, 52 s in a test build for these.
        let source = "A paragraph with $x^2$ and \\textbf{bold \\emph{words}}.\n\n".repeat(50_000);
        questions_near_the_end_read_near_them(&source);
        // 20,000 lines, a brace left open on each and no blank line: kept points
        // had been dropped above 64 open groups, and each question read the
        // whole text from the start, twice.
        let source: String = (0..20_000).map(|n| format!("{{ line {n} word\n")).collect();
        questions_near_the_end_read_near_them(&source);
    }

    #[test]
    fn an_unclosed_verb_ends_with_its_line() {
        // The maths it was in goes on; a line feed straight after \verb ends
        // it; closed, it's skipped, delimiters and all.
        for text in ["$ \\verb|x\ny", "\\verb\n$y", "\\verb*+x+ $a"] {
            let units: Vec<u16> = text.encode_utf16().collect();
            assert!(super::math_mode_at(&units), "{text}");
        }
    }

    #[test]
    fn a_probed_scan_stops_in_an_open_environment() {
        // Only a brace group reports its close, so the document environment
        // (open to the end of every real file) keeps no scan reading.
        let body = "More words in a paragraph.\n\n".repeat(1_000);
        let source = format!("\\begin{{document}}\n\\textbf{{a b}} c\n{body}\\end{{document}}");
        let units: Vec<u16> = source.encode_utf16().collect();
        let (at, len) = (source.find(" b}").unwrap(), units.len());
        let mut scanner = super::Scanner::default();
        scanner.run(&units, len, &[at, at], &mut ());
        let read = scanner.i;
        assert!(read < 100, "read on to {read} of {len}");
    }
}
