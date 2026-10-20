//! The TeX scanner every question about the text's meaning shares: maths, literal code, comments and groups,
//! read as TeX reads them.

use std::borrow::Cow;
use std::ops::Range;

use super::stack::Stack;
use super::{NAME, NEWLINE, ascii, catalog::CATALOG, is, letter};

/// A line alone can't tell a `%` that \verb or a verbatim environment holds.
pub(crate) fn strip_comment(line: &str) -> &str {
    let mut slashes = 0;
    for (i, b) in line.bytes().enumerate() {
        match b {
            b'\\' => slashes += 1,
            b'%' if slashes % 2 == 0 => return &line[..i],
            _ => slashes = 0,
        }
    }
    line
}

pub(crate) fn closing_brace(body: &str) -> Option<usize> {
    let (mut depth, mut slashes) = (1, 0);
    body.find(|c| {
        if slashes % 2 == 0 {
            depth += match c {
                '{' => 1,
                '}' => -1,
                _ => 0,
            };
        }
        slashes = if c == '\\' { slashes + 1 } else { 0 };
        depth == 0
    })
}

/// Any other character, a no-break space among them, is text.
pub(crate) fn tex_space(u: u16) -> bool {
    matches!(u, 0x09 | 0x0d | 0x20)
}

pub(crate) fn blank_line(line: &[u16]) -> bool {
    line.iter().all(|&u| tex_space(u))
}

fn spaces_end(src: &[u16], from: usize) -> usize {
    from + src[from..].iter().take_while(|&&u| tex_space(u)).count()
}

fn paragraph_end(src: &[u16], at: usize) -> bool {
    src.get(spaces_end(src, at + 1)) == Some(&NEWLINE)
}

fn find(src: &[u16], from: usize, needle: &[u16]) -> Option<usize> {
    (from..=src.len().checked_sub(needle.len())?).find(|&i| src[i..].starts_with(needle))
}

/// A command's arguments as TeX reads them: past spaces, line breaks and comments, a star, options and one
/// braced argument, none of it past a blank line.
pub(crate) fn arguments(
    src: &[u16],
    mut i: usize,
    mut piece: impl FnMut(Range<usize>, bool),
) -> (usize, bool) {
    let at = |i: usize| char::from_u32(src[i] as u32).unwrap_or_default();
    let (mut close, mut from, mut depth) = (None, i, 0);
    while i < src.len() && !(at(i) == '\n' && paragraph_end(src, i)) {
        match (at(i), close) {
            ('%', _) => {
                if let Some(c) = close {
                    piece(from..i, c == '}');
                }
                i = find(src, i, &[NEWLINE]).unwrap_or(src.len());
                from = i;
                continue;
            }
            // An escape, but not of a line feed: that may end the paragraph.
            ('\\', Some(_)) if i + 1 < src.len() && at(i + 1) != '\n' => i += 1,
            ('{', Some(_)) => depth += 1,
            ('}', Some(_)) if depth > 0 => depth -= 1,
            (c, Some(delimiter)) if c == delimiter && depth == 0 => {
                piece(from..i, c == '}');
                if c == '}' {
                    return (i + 1, true);
                }
                close = None;
            }
            (_, Some(_)) | ('*' | ' ' | '\t' | '\r' | '\n', None) => {}
            ('[', None) => (close, from) = (Some(']'), i + 1),
            ('{', None) => (close, from) = (Some('}'), i + 1),
            _ => break,
        }
        i += 1;
    }
    if let Some(c) = close {
        piece(from..i, c == '}');
    }
    (i, false)
}

const NAME_WINDOW: usize = 64;

pub(crate) fn environment_name(src: &[u16], from: usize) -> Option<(&[u16], usize)> {
    let window = &src[from..(from + NAME_WINDOW).min(src.len())];
    let leading = window
        .iter()
        .take_while(|&&u| tex_space(u) || u == NEWLINE)
        .count();
    let rest = &window[leading..];
    if !rest.first().is_some_and(|&u| is(u, '{')) {
        return None;
    }
    let close = rest[1..].iter().position(|&u| is(u, '{') || is(u, '}'))? + 1;
    is(rest[close], '}').then_some((&rest[1..close], from + leading + close + 1))
}

#[derive(Clone, Debug)]
pub(crate) struct Group {
    pub math: bool,
    pub end: Cow<'static, str>,
    pub open: usize,
    pub command: Option<(usize, usize)>,
}

impl Group {
    fn new(math: bool, end: impl Into<Cow<'static, str>>, open: usize) -> Self {
        Self {
            math,
            end: end.into(),
            open,
            command: None,
        }
    }

    pub fn brace(&self) -> bool {
        self.end == "}"
    }
}

/// What a scan reports as it reads; callers merge the ranges.
pub(crate) trait Visit {
    fn range(&mut self, _from: usize, _to: usize) {}
    fn command(&mut self, _name: &str, _start: usize, _name_end: usize) {}
    fn comment(&mut self, _from: usize, _to: usize) {}
    fn at(&mut self, _groups: Vec<Group>) {}
    fn closed(&mut self, _group: &Group, _close: Range<usize>) {}
}

impl Visit for () {}

#[cfg(test)]
thread_local! {
    /// The units scanners have read on this thread, for tests to tell how far a question read.
    pub(crate) static READ: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[derive(Clone, Default)]
pub(crate) struct Scanner {
    stack: Stack<Group>,
    text_argument: bool,
    math_run: bool,
    last_command: Option<(usize, usize)>,
    pub(super) i: usize,
    /// Past the text's end once a token ran into it, as a longer text could have read on.
    pub(super) reach: usize,
}

impl Scanner {
    pub fn in_math(&self) -> bool {
        self.stack.top().is_some_and(|g| g.math)
    }

    pub fn groups(&self) -> Vec<Group> {
        let mut groups: Vec<Group> = self.stack.iter().cloned().collect();
        groups.reverse();
        groups
    }

    /// Stops once all probes are answered and no brace group is open, or at the paragraph's end after them:
    /// a command's argument rarely runs past it.
    pub fn run(&mut self, src: &[u16], until: usize, probes: &[usize], visit: &mut impl Visit) {
        #[cfg(test)]
        let from = self.i;
        let (mut probe, mut paragraph_ended) = (0, false);
        while self.i < src.len().min(until) {
            let start = self.i;
            while probe < probes.len() && probes[probe] <= start {
                visit.at(self.groups());
                probe += 1;
            }
            let answered = !probes.is_empty() && probe == probes.len();
            if answered && (paragraph_ended || !self.stack.iter().any(Group::brace)) {
                break;
            }
            let pending = self.last_command.take();
            self.i += 1;
            let (mut code, mut read) = (false, self.i + 1);
            match char::from_u32(src[start] as u32).unwrap_or_default() {
                '%' => {
                    self.comment(src, start, pending, visit);
                    continue;
                }
                '\n' => {
                    paragraph_ended |= self.line_feed(src, start, pending, visit) && answered;
                    continue;
                }
                '$' => self.dollar(src, start, visit),
                '{' => {
                    let math = !self.text_argument && self.in_math();
                    self.stack.push(Group {
                        command: pending,
                        ..Group::new(math, "}", start)
                    });
                    self.text_argument = false;
                }
                '}' => self.close(start..self.i, "}", visit),
                '\\' if self.i < src.len() => (code, read) = self.control(src, start, visit),
                _ => {
                    let space = tex_space(src[start]);
                    self.text_argument &= space;
                    if space {
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

    /// Prose, which keeps a command's argument coming, as a line feed does.
    fn comment(
        &mut self,
        src: &[u16],
        start: usize,
        pending: Option<(usize, usize)>,
        visit: &mut impl Visit,
    ) {
        self.math_run = false;
        self.last_command = pending;
        self.i = find(src, self.i, &[NEWLINE]).unwrap_or(src.len());
        self.reach = self.reach.max(self.i + 1);
        visit.comment(start, self.i);
    }

    fn line_feed(
        &mut self,
        src: &[u16],
        start: usize,
        pending: Option<(usize, usize)>,
        visit: &mut impl Visit,
    ) -> bool {
        let next = spaces_end(src, self.i);
        self.reach = self.reach.max(next + 1);
        let ends = src.get(next) == Some(&NEWLINE);
        if ends {
            let delimited = |g: &Group| matches!(g.end.as_ref(), "$" | "$$" | "\\)" | "\\]");
            self.stack.pop_to(true, delimited, |_| {});
            self.text_argument = false;
        } else {
            self.last_command = pending;
        }
        if self.math_run {
            visit.range(start, self.i);
        }
        self.math_run = self.in_math();
        ends
    }

    fn dollar(&mut self, src: &[u16], start: usize, visit: &mut impl Visit) {
        let double = src.get(self.i).is_some_and(|&u| is(u, '$'));
        let top = self.stack.top().map(|g| g.end.as_ref());
        if let Some(end @ ("$" | "$$")) = top {
            self.i += (end == "$$" && double) as usize;
            let close = start..self.i;
            self.stack
                .pop_to(false, |_| true, |g| visit.closed(g, close));
        } else if !self.in_math() {
            let end = if double { "$$" } else { "$" };
            self.stack.push(Group::new(true, end, start));
            self.i += double as usize;
        } // else a stray $ in an environment's maths
        self.text_argument = false;
    }

    fn close(&mut self, token: Range<usize>, end: &str, visit: &mut impl Visit) {
        self.stack
            .pop_to(false, |g| g.end == end, |g| visit.closed(g, token));
    }

    fn control(&mut self, src: &[u16], start: usize, visit: &mut impl Visit) -> (bool, usize) {
        let in_math = self.in_math();
        self.text_argument = false;
        if !letter(src[self.i]) {
            let token = start..start + 2;
            match char::from_u32(src[self.i] as u32).unwrap_or_default() {
                '(' if !in_math => self.stack.push(Group::new(true, "\\)", start)),
                '[' if !in_math => self.stack.push(Group::new(true, "\\]", start)),
                ')' => self.close(token, "\\)", visit),
                ']' => self.close(token, "\\]", visit),
                _ if !in_math => visit.command("", start, start + 2),
                _ => {}
            }
            self.i += 1;
            return (false, self.i + 1);
        }
        let name_start = self.i;
        self.i += src[name_start..].iter().take_while(|&&u| letter(u)).count();
        let name_end = self.i;
        let mut buf = [0; NAME];
        let name = ascii(&src[name_start..name_end], &mut buf);
        let (code, read) = match name {
            "verb" => (true, self.verb(src)),
            "begin" | "end" => self.environment(src, start, name == "end", in_math, visit),
            _ => {
                self.text_argument = in_math && CATALOG.text_commands.contains(name);
                self.last_command = Some((start, name_end));
                (false, self.i + 1)
            }
        };
        if !in_math && !code {
            visit.command(name, start, name_end);
        }
        (code, read)
    }

    /// It can't cross a line: unclosed, it ends where its line does.
    fn verb(&mut self, src: &[u16]) -> usize {
        self.i += src.get(self.i).is_some_and(|&u| is(u, '*')) as usize;
        let Some(&delimiter) = src.get(self.i) else {
            return self.i + 1;
        };
        let line_end = find(src, self.i, &[NEWLINE]);
        self.skip_literal(src, self.i + 1, &[delimiter], line_end);
        line_end.unwrap_or(src.len()) + 1 // looking for the line's end
    }

    fn environment(
        &mut self,
        src: &[u16],
        start: usize,
        end: bool,
        in_math: bool,
        visit: &mut impl Visit,
    ) -> (bool, usize) {
        let read = (self.i + NAME_WINDOW).min(src.len() + 1);
        let Some((name, after)) = environment_name(src, self.i) else {
            return (false, read);
        };
        let name = String::from_utf16_lossy(name);
        let name = name.trim();
        self.i = after;
        if end {
            self.close(start..after, &format!("env:{name}"), visit);
        } else if CATALOG.verbatim_environments.contains(name) {
            let end: Vec<u16> = format!("\\end{{{name}}}").encode_utf16().collect();
            self.skip_literal(src, after, &end, None);
            return (true, read);
        } else {
            let bare = name.strip_suffix('*').unwrap_or(name);
            let math = in_math || CATALOG.math_environments.contains(bare);
            self.stack
                .push(Group::new(math, format!("env:{name}"), start));
        }
        (false, read)
    }

    /// Unclosed at the text's end, the code runs to it and no group is open after.
    fn skip_literal(&mut self, src: &[u16], from: usize, end: &[u16], line_end: Option<usize>) {
        let limit = line_end.unwrap_or(src.len());
        self.i = match (find(&src[..limit], from, end), line_end) {
            (Some(at), _) => at + end.len(),
            (None, Some(line_end)) => line_end,
            (None, None) => {
                self.stack = Stack::default();
                src.len()
            }
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probed_read(source: &str) -> usize {
        let units: Vec<u16> = source.encode_utf16().collect();
        let at = source.find(" b}").unwrap();
        let mut scanner = Scanner::default();
        scanner.run(&units, units.len(), &[at, at], &mut ());
        scanner.i
    }

    #[test]
    fn a_probed_scan_stops_once_its_probes_are_answered() {
        // Only a brace group reports its close, so the document environment
        // (open to the end of every real file) keeps no scan reading.
        let words = "More words in a paragraph.\n\n".repeat(1_000);
        let source = format!("\\begin{{document}}\n\\textbf{{a b}} c\n{words}\\end{{document}}\n");
        assert!(probed_read(&source) < 100);
        let words = "More {words}.\n".repeat(1_000);
        assert!(probed_read(&format!("{{ stray\n\\textbf{{a b}} c\n\n{words}")) < 40);
    }

    #[test]
    fn a_comment_starts_at_a_percent_no_backslash_escapes() {
        assert_eq!(strip_comment("a % b"), "a ");
        assert_eq!(strip_comment("50\\% off % note"), "50\\% off ");
        assert_eq!(
            strip_comment("a \\\\% line break, then a comment"),
            "a \\\\"
        );
        assert_eq!(strip_comment("no comment\n"), "no comment\n");
    }
}
