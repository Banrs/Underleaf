//! Highlighting by the rules of CodeMirror's stex mode
//! (@codemirror/legacy-modes), token for token, whose token names the kinds
//! keep. Line by line, each line starting from the state the one
//! before left; those states are kept, so an edit re-reads only from its
//! line, and only as far as asked.

use super::stack::Stack;
use super::{NAME, Text, ascii, letter, space};

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
#[derive(Default)]
pub struct Cache {
    states: Vec<State>,
}

impl Cache {
    /// Line `line` and those after it may start differently now.
    pub fn forget_from(&mut self, line: usize) {
        self.states.truncate(line.max(1));
    }

    /// The runs in the lines from `start`'s to `end`'s.
    pub fn highlights(&mut self, text: &Text, start: u32, end: u32) -> Vec<Highlight> {
        let (first, last) = (text.line_index(start), text.line_index(end));
        if self.states.is_empty() {
            self.states.push(State::default());
        }
        let from = first.min(self.states.len() - 1);
        let (mut runs, mut state) = (Vec::new(), self.states[from].clone());
        for index in from..=last {
            let base = text.line_start(index);
            tokenize(text.line(index), &mut state, |from, to, kind| {
                let (start, length) = (base + from as u32, (to - from) as u32);
                if index >= first {
                    runs.push(Highlight { start, length, kind });
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
    opened: usize,
}

/// An open command, and the innermost command with a rule below it, so
/// styling a word looks no further than the top however deep it is.
#[derive(Clone, Copy)]
struct Open {
    command: Command,
    below: Option<Command>,
}

fn open(commands: &mut Stack<Open>, styles: &'static [Option<HighlightKind>]) {
    let (command, below) = (Command { styles, opened: 0 }, styled(commands));
    commands.push(Open { command, below });
}

/// The innermost command with a rule.
fn styled(commands: &Stack<Open>) -> Option<Command> {
    let top = commands.top()?;
    let ruled = (!top.command.styles.is_empty()).then_some(top.command);
    ruled.or(top.below)
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
            open(&mut state.commands, styles(&s.text[name..s.pos]));
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
        open(&mut state.commands, &[]);
        None
    } else if is_digit(c) {
        s.eat_while(|u| word(u) || one_of(u, ".%"));
        Some(Argument)
    } else {
        s.eat_while(|u| word(u) || u == b'-' as u16);
        // The innermost command with a rule styles what's in its arguments.
        let command = styled(&state.commands)?;
        let argument = command.opened.checked_sub(1)?;
        command.styles.get(argument).copied().flatten()
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
    let (c, next) = (s.peek()?, s.at(1));
    let tex_letter = |u| letter(u) || u == b'@' as u16;
    if c == b'\\' as u16 && next.is_some_and(tex_letter) {
        s.pos += 1;
        s.eat_while(tex_letter);
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
    // \d+\.\d*|\d*\.\d+|\d+
    if is_digit(c) || (c == b'.' as u16 && next.is_some_and(is_digit)) {
        s.eat_while(is_digit);
        if s.eat(".") {
            s.eat_while(is_digit);
        }
        return Some(Number);
    }
    s.pos += 1;
    if one_of(c, "^_&") {
        Some(Command)
    } else if one_of(c, "+-<>|=,/@!*:;'\"`~#?{}[]()") {
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
    if one_of(c, " \t\r") {
        s.pos += 1;
        return None;
    }
    state.mode = Mode::Normal;
    if !one_of(c, "{[") {
        state.commands.pop();
        return normal(s, state);
    }
    if let Some(top) = state.commands.top_mut() {
        top.command.opened += 1;
    }
    s.pos += 1;
    None
}

struct Stream<'a> {
    text: &'a [u16],
    pos: usize,
}

impl Stream<'_> {
    fn peek(&self) -> Option<u16> {
        self.at(0)
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
        let rest = &self.text[self.pos..];
        let ok = rest.len() >= ascii.len() && ascii.bytes().zip(rest).all(|(b, &u)| u == b as u16);
        self.pos += if ok { ascii.len() } else { 0 };
        ok
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

/// ECMAScript's \w.
fn word(u: u16) -> bool {
    u < 128 && ((u as u8).is_ascii_alphanumeric() || u == b'_' as u16)
}

/// A command name's letters: [a-zA-Z@\xc0-\u1fff\u2060-\uffff].
fn command_letter(u: u16) -> bool {
    letter(u) || u == b'@' as u16 || (0xc0..=0x1fff).contains(&u) || u >= 0x2060
}

#[cfg(test)]
mod tests {
    use super::HighlightKind::*;
    use crate::syntax::{SourceDocument, utf16};

    #[test]
    fn runs_are_stex_s_tokens() {
        // A source and the lines asked for, and its runs, each "text Kind".
        for case in [
            r"\begin{itemize} % list => \begin Command|itemize Argument|% list Comment",
            r"\documentclass[a4paper]{article} => \documentclass Command|article Argument",
            r"\textbf{bold} => \textbf Command",
            r"50\% off => 50 Argument|\% Command",
            r"} => } Invalid",
            r"$x^2 + \alpha.5$ => $ MathDelimiter|x MathIdentifier|^ Command|2 Number|\alpha Command|.5 Number|$ MathDelimiter",
            // stex's own reading: a line break in \[ \] is an error.
            r"\[ a \\ \] => \[ MathDelimiter|a MathIdentifier|\ Invalid|\ Invalid|\] MathDelimiter",
            // Only the lines asked for, each from the state the line before left,
            // until a blank line ends it.
            "\\a\n\\b\n\\c 3..4 => \\b Command",
            "$$\nx\n\ny 3..8 => x MathIdentifier",
        ] {
            let (source, runs) = case.split_once(" => ").unwrap();
            let (source, (start, end)) = match source.rsplit_once(' ') {
                Some((source, lines)) if lines.contains("..") => {
                    let (start, end) = lines.split_once("..").unwrap();
                    (source, (start.parse().unwrap(), end.parse().unwrap()))
                }
                _ => (source, (0, utf16(source) as u32)),
            };
            let found = SourceDocument::new(source).highlights(start, end - start);
            // The sources are ASCII: their units are their bytes.
            let run = |h: &super::Highlight| {
                let text = &source[h.start as usize..(h.start + h.length) as usize];
                format!("{text} {:?}", h.kind)
            };
            assert_eq!(found.iter().map(run).collect::<Vec<_>>().join("|"), runs);
        }
        // An edit re-reads from its line.
        let mut doc = SourceDocument::new("$$\nx");
        assert_eq!(doc.highlights(3, 1)[0].kind, MathIdentifier);
        doc.edit(0, 0, "$$"); // "$$$$\nx": opened and closed on line 1
        assert!(doc.highlights(5, 1).is_empty());
    }

    #[test]
    fn runs_are_as_the_plain_command_stack_gave_them() {
        // The runs of 300 seeded documents of braces, commands, maths and
        // line breaks, each read whole and again after an edit part way, as
        // one FNV-1a hash, as when the open commands were a vector, cloned
        // for each line and searched for each word.
        let pieces: Vec<&str> = "{|{|[|}|]|\\cite|\\begin|\\documentclass|\\importmodule|\\emph\
            |\\usepackage| word|x-y|42|\n|\n|\n\n|$|$$|% c\n|\\[|\\]|\\%|\\\\| |é"
            .split('|')
            .collect();
        let mut seed = 11u32;
        let mut next = |n: usize| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            (seed >> 16) as usize % n
        };
        let mut hash = 0xcbf2_9ce4_8422_2325u64;
        let mut add = |doc: &mut SourceDocument| {
            for run in doc.highlights(0, utf16(&doc.text()) as u32) {
                for value in [run.start, run.length, run.kind as u32] {
                    hash = (hash ^ u64::from(value)).wrapping_mul(0x100_0000_01b3);
                }
            }
        };
        for _ in 0..300 {
            let count = 1 + next(120);
            let source: String = (0..count).map(|_| pieces[next(pieces.len())]).collect();
            let mut doc = SourceDocument::new(&source);
            add(&mut doc);
            doc.edit(next(utf16(&source) + 1) as u32, 0, "{\\label{");
            add(&mut doc);
        }
        assert_eq!(hash, 572_227_848_898_975_436);
    }

    #[test]
    fn unclosed_groups_cost_no_more_as_they_pile_up() {
        // Each line opens a group nobody closes, under a command with a rule:
        // keeping each line's state and styling each word had been as slow
        // as the groups were deep, some 17 s in a release build for this.
        const LINES: usize = 20_000;
        let line = |n: usize| format!("{{ \\cite{{ line {n} word\n");
        let source: String = (0..LINES).map(line).collect();
        crate::syntax::stack::WORK.set(0);
        let mut doc = SourceDocument::new(&source);
        let len = utf16(&source) as u32;
        let last = doc.highlights(0, len).last().map(|r| r.kind);
        assert_eq!(last, Some(Argument));
        doc.edit(0, 0, "x");
        doc.highlights(len - 10, 10);
        // Each line is read twice, a few frames made or looked at for each
        // however deep the stack is.
        let work = crate::syntax::stack::WORK.get();
        assert!(work <= 8 * LINES, "{work} frames for {LINES} lines");
        drop(doc); // a deep stack drops without overflowing
    }
}
