//! Highlighting as CodeMirror's stex mode (@codemirror/legacy-modes) gives it,
//! token for token: the web's editor runs that mode, so both editors colour
//! a file alike. Line by line, each line starting from the state the one
//! before left; those states are kept, so an edit re-reads only from its
//! line, and only as far as asked.

use crate::stack::Stack;
use crate::{ascii, letter, space, Text, NAME};

/// What a run of text is, by the stex mode's token names. Plain text and
/// brackets have none. The C ABI numbers them in this order, from 0.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HighlightKind {
    /// `\command`, an escape (`\%`), `\\`, and maths' `^ _ &` (stex's tag).
    Command,
    /// An environment's, package's, label's, reference's or citation's name,
    /// and a number in text (atom).
    Argument,
    /// `$ $$ \( \) \[ \]` (keyword).
    MathDelimiter,
    /// Letters in maths (variableName.special).
    MathIdentifier,
    /// A number in maths.
    Number,
    Comment,
    /// A stray closing brace, or what maths can't hold (error).
    Invalid,
    /// `\importmodule`'s first argument (string).
    StringLiteral,
    /// Its second (builtin).
    Builtin,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Highlight {
    pub start: u32,
    pub length: u32,
    pub kind: HighlightKind,
}

/// The states lines start in, from the first line on.
pub struct Cache {
    states: Vec<State>,
}

impl Default for Cache {
    fn default() -> Self {
        Cache {
            states: vec![State::default()],
        }
    }
}

impl Cache {
    /// Line `line` and those after it may start differently now.
    pub fn forget_from(&mut self, line: usize) {
        self.states.truncate(line.max(1));
    }

    /// The runs in the lines from `start`'s to `end`'s.
    pub fn highlights(&mut self, text: &Text, start: u32, end: u32) -> Vec<Highlight> {
        let (first, last) = (text.line_index(start), text.line_index(end));
        let from = first.min(self.states.len() - 1);
        let mut runs = Vec::new();
        let mut state = self.states[from].clone();
        for index in from..=last {
            let base = text.lines[index];
            tokenize(text.line(index), &mut state, |from, to, kind| {
                if index >= first {
                    runs.push(Highlight {
                        start: base + from as u32,
                        length: (to - from) as u32,
                        kind,
                    });
                }
            });
            if self.states.len() == index + 1 {
                self.states.push(state.clone());
            }
        }
        runs
    }
}

#[derive(Clone, Default)]
struct State {
    mode: Mode,
    /// The commands whose arguments may follow (stex's cmdState), shared
    /// with the states kept for the lines before.
    commands: Stack<Open>,
}

#[derive(Clone, Copy, Default)]
enum Mode {
    #[default]
    Normal,
    /// In maths, until this closes it.
    Math(&'static str),
    /// After a command, where its arguments may start.
    Arguments,
}

#[derive(Clone, Copy)]
struct Command {
    /// Its arguments' kinds, the first argument's first; empty for a
    /// command stex has no rule for, or a bare group.
    styles: &'static [Option<HighlightKind>],
    /// Arguments opened so far.
    brackets: usize,
}

/// An open command, and the innermost command with a rule below it, so
/// styling a word looks no further than the top however deep it is.
#[derive(Clone, Copy)]
struct Open {
    command: Command,
    styled_below: Option<Command>,
}

fn open(commands: &mut Stack<Open>, command: Command) {
    let styled_below = styled(commands);
    commands.push(Open {
        command,
        styled_below,
    });
}

/// The innermost command with a rule.
fn styled(commands: &Stack<Open>) -> Option<Command> {
    let top = commands.top()?;
    (!top.command.styles.is_empty())
        .then_some(top.command)
        .or(top.styled_below)
}

use HighlightKind::*;

fn styles(name: &[u16]) -> &'static [Option<HighlightKind>] {
    match ascii(name, &mut [0; NAME]) {
        "importmodule" => &[Some(StringLiteral), Some(Builtin)],
        "documentclass" => &[None, Some(Argument)],
        "usepackage" | "begin" | "end" | "label" | "ref" | "eqref" | "cite" | "bibitem"
        | "Bibitem" | "RBibitem" => &[Some(Argument)],
        _ => &[],
    }
}

/// A line's runs, given the state it starts in, which it leaves as the next
/// line's. An empty line ends everything open (stex's blankLine).
fn tokenize(line: &[u16], state: &mut State, mut run: impl FnMut(usize, usize, HighlightKind)) {
    if line.is_empty() {
        *state = State::default();
        return;
    }
    let mut s = Stream { text: line, pos: 0 };
    while s.pos < line.len() {
        let from = s.pos;
        let kind = match state.mode {
            Mode::Normal => normal(&mut s, state),
            Mode::Math(end) => math(&mut s, state, end),
            Mode::Arguments => arguments(&mut s, state),
        };
        if let Some(kind) = kind {
            run(from, s.pos, kind);
        }
    }
}

fn normal(s: &mut Stream, state: &mut State) -> Option<HighlightKind> {
    if s.peek() == Some(b'\\' as u16) {
        if s.at(1).is_some_and(command_letter) {
            s.pos += 1;
            let name = s.pos;
            s.eat_while(command_letter);
            open(
                &mut state.commands,
                Command {
                    styles: styles(&s.text[name..s.pos]),
                    brackets: 0,
                },
            );
            state.mode = Mode::Arguments;
            return Some(Command);
        }
        if s.at(1).is_some_and(|u| one_of(u, "$&%#{}_,;!/\\")) {
            s.pos += 2;
            return Some(Command);
        }
        for (open, close) in [("\\[", "\\]"), ("\\(", "\\)")] {
            if s.eat(open) {
                state.mode = Mode::Math(close);
                return Some(MathDelimiter);
            }
        }
    }
    for delimiter in ["$$", "$"] {
        if s.eat(delimiter) {
            state.mode = Mode::Math(delimiter);
            return Some(MathDelimiter);
        }
    }
    let c = s.next();
    if c == b'%' as u16 {
        s.pos = s.text.len();
        Some(Comment)
    } else if one_of(c, "}]") {
        if state.commands.top().is_none() {
            return Some(Invalid);
        }
        state.mode = Mode::Arguments;
        None
    } else if one_of(c, "{[") {
        open(
            &mut state.commands,
            Command {
                styles: &[],
                brackets: 0,
            },
        );
        None
    } else if is_digit(c) {
        s.eat_while(|u| word(u) || one_of(u, ".%"));
        Some(Argument)
    } else {
        s.eat_while(|u| word(u) || u == b'-' as u16);
        // The innermost command with a rule styles what's in its arguments.
        let command = styled(&state.commands)?;
        command
            .brackets
            .checked_sub(1)
            .and_then(|argument| command.styles.get(argument).copied().flatten())
    }
}

fn math(s: &mut Stream, state: &mut State, end: &'static str) -> Option<HighlightKind> {
    if s.eat_while(space) {
        return None;
    }
    if s.eat(end) {
        state.mode = Mode::Normal;
        return Some(MathDelimiter);
    }
    let c = s.peek()?;
    let next = s.at(1);
    if c == b'\\' as u16 && next.is_some_and(|u| letter(u) || u == b'@' as u16) {
        s.pos += 1;
        s.eat_while(|u| letter(u) || u == b'@' as u16);
        return Some(Command);
    }
    if letter(c) {
        s.eat_while(letter);
        return Some(MathIdentifier);
    }
    if c == b'\\' as u16 && next.is_some_and(|u| one_of(u, "$&%#{}_,;!/")) {
        s.pos += 2;
        return Some(Command);
    }
    if one_of(c, "^_&") {
        s.pos += 1;
        return Some(Command);
    }
    if one_of(c, "+-<>|=,/@!*:;'\"`~#?") {
        s.pos += 1;
        return None;
    }
    // \d+\.\d*|\d*\.\d+|\d+
    if is_digit(c) || (c == b'.' as u16 && next.is_some_and(is_digit)) {
        s.eat_while(is_digit);
        if s.peek() == Some(b'.' as u16) {
            s.pos += 1;
            s.eat_while(is_digit);
        }
        return Some(Number);
    }
    s.pos += 1;
    if one_of(c, "{}[]()") {
        None
    } else if c == b'%' as u16 {
        s.pos = s.text.len();
        Some(Comment)
    } else {
        Some(Invalid)
    }
}

fn arguments(s: &mut Stream, state: &mut State) -> Option<HighlightKind> {
    let c = s.peek()?;
    if one_of(c, "{[") {
        if let Some(top) = state.commands.top_mut() {
            top.command.brackets += 1;
        }
        s.pos += 1;
        state.mode = Mode::Normal;
        return None;
    }
    if one_of(c, " \t\r") {
        s.pos += 1;
        return None;
    }
    state.mode = Mode::Normal;
    state.commands.pop();
    normal(s, state)
}

struct Stream<'a> {
    text: &'a [u16],
    pos: usize,
}

impl Stream<'_> {
    fn peek(&self) -> Option<u16> {
        self.text.get(self.pos).copied()
    }

    fn at(&self, ahead: usize) -> Option<u16> {
        self.text.get(self.pos + ahead).copied()
    }

    fn next(&mut self) -> u16 {
        self.pos += 1;
        self.text[self.pos - 1]
    }

    /// Whether the text goes on with `ascii`, taking it if so.
    fn eat(&mut self, ascii: &str) -> bool {
        let found = ascii
            .bytes()
            .enumerate()
            .all(|(i, b)| self.at(i) == Some(b as u16));
        if found {
            self.pos += ascii.len();
        }
        found
    }

    /// Whether anything was taken.
    fn eat_while(&mut self, f: impl Fn(u16) -> bool) -> bool {
        let start = self.pos;
        while self.peek().is_some_and(&f) {
            self.pos += 1;
        }
        self.pos > start
    }
}

fn one_of(u: u16, ascii: &str) -> bool {
    u < 128 && ascii.as_bytes().contains(&(u as u8))
}

fn is_digit(u: u16) -> bool {
    u < 128 && (u as u8).is_ascii_digit()
}

/// JavaScript's \w.
fn word(u: u16) -> bool {
    u < 128 && ((u as u8).is_ascii_alphanumeric() || u == b'_' as u16)
}

/// A command name's letters: [a-zA-Z@\xc0-\u1fff\u2060-\uffff].
fn command_letter(u: u16) -> bool {
    letter(u) || u == b'@' as u16 || (0xc0..=0x1fff).contains(&u) || u >= 0x2060
}

#[cfg(test)]
mod tests {
    use super::Highlight;
    use super::HighlightKind::*;
    use crate::{utf16, SourceDocument};

    /// The runs as "text Kind" pairs.
    fn runs(source: &str) -> Vec<String> {
        let units: Vec<u16> = source.encode_utf16().collect();
        let runs = SourceDocument::new(source).highlights(0, units.len() as u32);
        let text = |h: &super::Highlight| {
            String::from_utf16_lossy(&units[h.start as usize..(h.start + h.length) as usize])
        };
        runs.iter()
            .map(|h| format!("{} {:?}", text(h), h.kind))
            .collect()
    }

    #[test]
    fn commands_arguments_and_comments() {
        assert_eq!(
            runs("\\begin{itemize} % list"),
            ["\\begin Command", "itemize Argument", "% list Comment"]
        );
        assert_eq!(
            runs("\\documentclass[a4paper]{article}")[1..],
            ["article Argument"]
        );
        assert_eq!(runs("\\textbf{bold}"), ["\\textbf Command"]);
        assert_eq!(runs("50\\% off"), ["50 Argument", "\\% Command"]);
        assert_eq!(runs("}"), ["} Invalid"]);
    }

    #[test]
    fn maths() {
        let expected = [
            "$ MathDelimiter",
            "x MathIdentifier",
            "^ Command",
            "2 Number",
            "\\alpha Command",
            "$ MathDelimiter",
        ];
        assert_eq!(runs("$x^2 + \\alpha$"), expected);
        // stex's own reading: a line break in \[ \] is an error.
        assert_eq!(runs("\\[ a \\\\ \\]")[2], "\\ Invalid");
    }

    #[test]
    fn state_carries_across_lines_until_a_blank_one() {
        let mut doc = SourceDocument::new("$$\nx\n\ny");
        let kinds: Vec<_> = doc
            .highlights(0, 8)
            .into_iter()
            .map(|h| (h.start, h.kind))
            .collect();
        // y, after the blank line, is text.
        assert_eq!(kinds, [(0, MathDelimiter), (3, MathIdentifier)]);
        // An edit re-reads from its line: closing the maths makes the rest text.
        doc.edit(0, 0, "$$"); // "$$$$\nx…": opened and closed on line 1
        assert_eq!(doc.highlights(5, 1).len(), 0);
    }

    #[test]
    fn edits_leave_the_runs_a_fresh_read_gives() {
        const PIECES: [&str; 12] = [
            "\\begin{", "}", "$", "$$", "\n", "\n\n", "% c", "\\[", "\\]", "x", "{", "\\cite",
        ];
        let mut seed = 7u32;
        let mut next = |n: usize| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            (seed >> 16) as usize % n
        };
        let mut doc = SourceDocument::new("");
        let mut text: Vec<u16> = Vec::new();
        for _ in 0..400 {
            let start = next(text.len() + 1);
            let length = next(text.len() - start + 1).min(4);
            let piece = PIECES[next(PIECES.len())];
            doc.edit(start as u32, length as u32, piece);
            text.splice(start..start + length, piece.encode_utf16());
            // Read part of it, so the kept states run only so far.
            let from = next(text.len() + 1) as u32;
            doc.highlights(from, 3);
            let mut fresh = SourceDocument::new(&String::from_utf16_lossy(&text));
            assert_eq!(
                doc.highlights(0, text.len() as u32),
                fresh.highlights(0, text.len() as u32)
            );
        }
    }

    #[test]
    fn only_the_lines_asked_for() {
        let mut doc = SourceDocument::new("\\a\n\\b\n\\c");
        let runs = doc.highlights(3, 1);
        assert_eq!(runs.len(), 1);
        assert_eq!((runs[0].start, runs[0].length), (3, 2));
    }

    /// The runs of 300 seeded documents of braces, commands, maths and
    /// line breaks, each read whole and again after an edit part way, as one
    /// FNV-1a hash.
    fn seeded_runs_fingerprint() -> u64 {
        const PIECES: [&str; 26] = [
            "{",
            "{",
            "[",
            "}",
            "]",
            "\\cite",
            "\\begin",
            "\\documentclass",
            "\\importmodule",
            "\\emph",
            "\\usepackage",
            " word",
            "x-y",
            "42",
            "\n",
            "\n",
            "\n\n",
            "$",
            "$$",
            "% c\n",
            "\\[",
            "\\]",
            "\\%",
            "\\\\",
            " ",
            "é",
        ];
        let mut seed = 11u32;
        let mut next = |n: usize| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            (seed >> 16) as usize % n
        };
        let mut hash = 0xcbf2_9ce4_8422_2325u64;
        let mut add = |runs: Vec<Highlight>| {
            for run in runs {
                for value in [run.start, run.length, run.kind as u32] {
                    hash = (hash ^ u64::from(value)).wrapping_mul(0x100_0000_01b3);
                }
            }
        };
        for _ in 0..300 {
            let pieces = 1 + next(120);
            let source: String = (0..pieces).map(|_| PIECES[next(PIECES.len())]).collect();
            let mut doc = SourceDocument::new(&source);
            add(doc.highlights(0, utf16(&source) as u32));
            let at = next(utf16(&source) + 1) as u32;
            doc.edit(at, 0, "{\\label{");
            add(doc.highlights(0, utf16(&doc.text()) as u32));
        }
        hash
    }

    #[test]
    fn runs_are_as_the_plain_command_stack_gave_them() {
        // The fingerprint of the runs when the open commands were a vector,
        // cloned for each line and searched for each word.
        assert_eq!(seeded_runs_fingerprint(), 572_227_848_898_975_436);
    }

    #[test]
    fn unclosed_groups_cost_no_more_as_they_pile_up() {
        // Each line opens a group nobody closes, under a command with a rule:
        // keeping each line's state and styling each word had been as slow
        // as the groups were deep, some 17 s in a release build for this.
        let source: String = (0..20_000)
            .map(|n| format!("{{ \\cite{{ line {n} word\n"))
            .collect();
        let started = std::time::Instant::now();
        let mut doc = SourceDocument::new(&source);
        let len = utf16(&source) as u32;
        let runs = doc.highlights(0, len);
        doc.edit(0, 0, "x");
        doc.highlights(len - 10, 10);
        assert_eq!(runs.last().map(|r| r.kind), Some(Argument));
        assert!(
            started.elapsed() < std::time::Duration::from_secs(5),
            "{:?}",
            started.elapsed()
        );
        drop(doc); // a deep stack drops without overflowing
    }
}
