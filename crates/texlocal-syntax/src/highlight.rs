//! Highlighting as CodeMirror's stex mode (@codemirror/legacy-modes) gives it,
//! token for token: the web's editor runs that mode, so both editors colour
//! a file alike. Line by line, each line starting from the state the one
//! before left; those states are kept, so an edit re-reads only from its
//! line, and only as far as asked.

use crate::Text;

/// What a run of text is, by the stex mode's token names. Plain text and
/// brackets have none.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
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
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
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
        while self.states.len() <= last {
            let index = self.states.len() - 1;
            let mut state = self.states[index].clone();
            tokenize(text.line(index), &mut state, |_, _, _| {});
            self.states.push(state);
        }
        let mut runs = Vec::new();
        for index in first..=last {
            let mut state = self.states[index].clone();
            let base = text.lines[index];
            tokenize(text.line(index), &mut state, |from, to, kind| {
                runs.push(Highlight {
                    start: base + from as u32,
                    length: (to - from) as u32,
                    kind,
                });
            });
        }
        runs
    }
}

#[derive(Clone, Default, PartialEq)]
struct State {
    mode: Mode,
    /// The commands whose arguments may follow, innermost last (stex's cmdState).
    commands: Vec<Command>,
}

#[derive(Clone, Copy, Default, PartialEq)]
enum Mode {
    #[default]
    Normal,
    /// In maths, until this closes it.
    Math(&'static str),
    /// After a command, where its arguments may start.
    Arguments,
}

#[derive(Clone, PartialEq)]
struct Command {
    /// Its arguments' kinds, the first argument's first; `None` for a
    /// command stex has no rule for, or a bare group.
    styles: Option<&'static [Option<HighlightKind>]>,
    /// Arguments opened so far.
    brackets: usize,
}

use HighlightKind::*;

fn styles(name: &[u16]) -> Option<&'static [Option<HighlightKind>]> {
    const ARGUMENT: &[Option<HighlightKind>] = &[Some(Argument)];
    Some(match String::from_utf16_lossy(name).as_str() {
        "importmodule" => &[Some(StringLiteral), Some(Builtin)],
        "documentclass" => &[None, Some(Argument)],
        "usepackage" | "begin" | "end" | "label" | "ref" | "eqref" | "cite" | "bibitem"
        | "Bibitem" | "RBibitem" => ARGUMENT,
        _ => return None,
    })
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
        if s.pos == from {
            s.pos += 1; // every rule consumes; this only guards the loop
        }
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
            state.commands.push(Command {
                styles: styles(&s.text[name..s.pos]),
                brackets: 0,
            });
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
        if state.commands.is_empty() {
            return Some(Invalid);
        }
        state.mode = Mode::Arguments;
        None
    } else if one_of(c, "{[") {
        state.commands.push(Command {
            styles: None,
            brackets: 0,
        });
        None
    } else if is_digit(c) {
        s.eat_while(|u| word(u) || one_of(u, ".%"));
        Some(Argument)
    } else {
        s.eat_while(|u| word(u) || u == b'-' as u16);
        // The innermost command with a rule styles what's in its arguments.
        let command = state.commands.iter().rev().find(|c| c.styles.is_some())?;
        let styles = command.styles?;
        command
            .brackets
            .checked_sub(1)
            .and_then(|argument| styles.get(argument).copied().flatten())
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
    let digits = |s: &mut Stream| s.eat_while(is_digit);
    if is_digit(c) || (c == b'.' as u16 && next.is_some_and(is_digit)) {
        digits(s);
        if s.peek() == Some(b'.' as u16) {
            s.pos += 1;
            digits(s);
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
        if let Some(command) = state.commands.last_mut() {
            command.brackets += 1;
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

fn letter(u: u16) -> bool {
    u < 128 && (u as u8).is_ascii_alphabetic()
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

/// JavaScript's \s and the no-break space.
pub(crate) fn space(u: u16) -> bool {
    matches!(u, 0x09..=0x0d | 0x20 | 0xa0 | 0x1680 | 0x2000..=0x200a | 0x2028 | 0x2029 | 0x202f | 0x205f | 0x3000 | 0xfeff)
}

#[cfg(test)]
mod tests {
    use crate::SourceDocument;

    /// The runs as (text, kind) pairs.
    fn runs(source: &str) -> Vec<(String, super::HighlightKind)> {
        let doc = SourceDocument::new(source.into());
        let units: Vec<u16> = source.encode_utf16().collect();
        doc.highlights(0, units.len() as u32)
            .into_iter()
            .map(|h| {
                (
                    String::from_utf16_lossy(
                        &units[h.start as usize..(h.start + h.length) as usize],
                    ),
                    h.kind,
                )
            })
            .collect()
    }

    use super::HighlightKind::*;

    #[test]
    fn commands_arguments_and_comments() {
        assert_eq!(
            runs("\\begin{itemize} % list"),
            [
                ("\\begin".into(), Command),
                ("itemize".into(), Argument),
                ("% list".into(), Comment)
            ]
        );
        assert_eq!(
            runs("\\documentclass[a4paper]{article}")[1..],
            [("article".into(), Argument)]
        );
        assert_eq!(runs("\\textbf{bold}"), [("\\textbf".into(), Command)]);
        assert_eq!(
            runs("50\\% off"),
            [("50".into(), Argument), ("\\%".into(), Command)]
        );
        assert_eq!(runs("}"), [("}".into(), Invalid)]);
    }

    #[test]
    fn maths() {
        assert_eq!(
            runs("$x^2 + \\alpha$"),
            [
                ("$".into(), MathDelimiter),
                ("x".into(), MathIdentifier),
                ("^".into(), Command),
                ("2".into(), Number),
                ("\\alpha".into(), Command),
                ("$".into(), MathDelimiter)
            ]
        );
        // stex's own reading: a line break in \[ \] is an error.
        assert_eq!(runs("\\[ a \\\\ \\]")[2], ("\\".into(), Invalid));
    }

    #[test]
    fn state_carries_across_lines_until_a_blank_one() {
        let doc = SourceDocument::new("$$\nx\n\ny".into());
        let kinds: Vec<_> = doc
            .highlights(0, 8)
            .into_iter()
            .map(|h| (h.start, h.kind))
            .collect();
        assert_eq!(kinds, [(0, MathDelimiter), (3, MathIdentifier)]); // y, after the blank line, is text
                                                                      // An edit re-reads from its line: closing the maths makes the rest text.
        doc.edit(0, 0, "$$".into()); // "$$$$\nx…": opened and closed on line 1
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
        let doc = SourceDocument::new(String::new());
        let mut text: Vec<u16> = Vec::new();
        for _ in 0..400 {
            let start = next(text.len() + 1);
            let length = next(text.len() - start + 1).min(4);
            let piece = PIECES[next(PIECES.len())];
            doc.edit(start as u32, length as u32, piece.into());
            text.splice(start..start + length, piece.encode_utf16());
            // Read part of it, so the kept states run only so far.
            let from = next(text.len() + 1) as u32;
            doc.highlights(from, 3);
            let fresh = SourceDocument::new(String::from_utf16_lossy(&text));
            assert_eq!(
                doc.highlights(0, text.len() as u32),
                fresh.highlights(0, text.len() as u32)
            );
        }
    }

    #[test]
    fn only_the_lines_asked_for() {
        let doc = SourceDocument::new("\\a\n\\b\n\\c".into());
        let runs = doc.highlights(3, 1);
        assert_eq!(runs.len(), 1);
        assert_eq!((runs[0].start, runs[0].length), (3, 2));
    }
}
