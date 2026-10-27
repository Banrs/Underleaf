use schemars::JsonSchema;

use super::catalog::CATALOG;
use super::scan::blank_line;
use super::stack::Stack;
use super::{NAME, Text, ascii, letter};

#[derive(Clone, Copy, Debug, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HighlightKind {
    Command,
    Argument,
    Maths,
    Comment,
    Invalid,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Highlight {
    pub start: u32,
    pub length: u32,
    pub kind: HighlightKind,
}

pub(crate) struct Cache(Vec<State>);

impl Default for Cache {
    fn default() -> Self {
        Self(vec![State::default()])
    }
}

impl Cache {
    pub(crate) fn forget_from(&mut self, line: usize) {
        self.0.truncate(line.max(1));
    }

    pub(crate) fn highlights(&mut self, text: &Text, start: u32, end: u32) -> Vec<Highlight> {
        let (first, last) = (text.line_index(start), text.line_index(end));
        let from = first.min(self.0.len() - 1);
        let mut runs = Vec::new();
        let mut state = self.0[from].clone();
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
            if self.0.len() == index + 1 {
                self.0.push(state.clone());
            }
        }
        runs
    }
}

#[derive(Clone, Default)]
struct State {
    mode: Mode,
    commands: Stack<Open>,
}

#[derive(Clone, Copy, Default)]
enum Mode {
    #[default]
    Normal,
    Math(&'static str),
    Arguments,
    Opening(&'static str),
    Verbatim(&'static str),
    Verb(u16),
}

#[derive(Clone, Copy)]
struct Command {
    styles: &'static [Option<HighlightKind>],
    brackets: usize,
}

#[derive(Clone, Copy)]
struct Open {
    command: Command,
    styled_below: Option<Command>,
}

fn open(commands: &mut Stack<Open>, styles: &'static [Option<HighlightKind>]) {
    commands.push(Open {
        command: Command {
            styles,
            brackets: 0,
        },
        styled_below: styled(commands),
    });
}

fn styled(commands: &Stack<Open>) -> Option<Command> {
    let top = commands.top()?;
    (!top.command.styles.is_empty())
        .then_some(top.command)
        .or(top.styled_below)
}

use HighlightKind::*;

fn styles(name: &[u16]) -> &'static [Option<HighlightKind>] {
    let mut buf = [0; NAME];
    let name = ascii(name, &mut buf);
    let named = [
        &CATALOG.name_commands,
        &CATALOG.ref_commands,
        &CATALOG.cite_commands,
    ];
    if name == "documentclass" {
        &[None, Some(Argument)]
    } else if named.iter().any(|names| names.contains(name))
        || matches!(name, "Bibitem" | "RBibitem")
    {
        &[Some(Argument)]
    } else {
        &[]
    }
}

fn tokenize(line: &[u16], state: &mut State, mut run: impl FnMut(usize, usize, HighlightKind)) {
    if blank_line(line) {
        if !matches!(state.mode, Mode::Verbatim(_)) {
            *state = State::default();
        }
        return;
    }
    let mut s = Stream { text: line, pos: 0 };
    while s.pos < line.len() {
        let from = s.pos;
        let kind = match state.mode {
            Mode::Normal => normal(&mut s, state),
            Mode::Math(end) => math(&mut s, state, end),
            Mode::Arguments => arguments(&mut s, state),
            Mode::Opening(name) => opening(&mut s, state, name),
            Mode::Verbatim(name) => verbatim(&mut s, state, name),
            Mode::Verb(delimiter) => verb(&mut s, state, delimiter),
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
            let name = &s.text[name..s.pos];
            match ascii(name, &mut [0; NAME]) {
                "verb" => {
                    s.eat("*");
                    if let Some(delimiter) = s.peek() {
                        state.mode = Mode::Verb(delimiter);
                    }
                }
                "begin" if let Some(name) = verbatim_environment(&s.text[s.pos..]) => {
                    state.mode = Mode::Opening(name);
                }
                _ => {
                    open(&mut state.commands, styles(name));
                    state.mode = Mode::Arguments;
                }
            }
            return Some(Command);
        }
        if s.at(1).is_some_and(|u| one_of(u, "$&%#{}_,;!/\\")) {
            s.pos += 2;
            return Some(Command);
        }
    }
    for (open, close) in [("\\[", "\\]"), ("\\(", "\\)"), ("$$", "$$"), ("$", "$")] {
        if s.eat(open) {
            state.mode = Mode::Math(close);
            return Some(Maths);
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
        s.eat_while(|u| word(u) || u == b'.' as u16);
        Some(Argument)
    } else {
        s.eat_while(|u| word(u) || u == b'-' as u16);
        let command = styled(&state.commands)?;
        command
            .brackets
            .checked_sub(1)
            .and_then(|argument| command.styles.get(argument).copied().flatten())
    }
}

fn math(s: &mut Stream, state: &mut State, end: &'static str) -> Option<HighlightKind> {
    if s.eat_while(|u| char::from_u32(u.into()).is_some_and(char::is_whitespace)) {
        return None;
    }
    if s.eat(end) {
        state.mode = Mode::Normal;
        return Some(Maths);
    }
    let c = s.peek()?;
    let next = s.at(1);
    if c == b'\\' as u16 && next.is_some_and(|u| letter(u) || u == b'@' as u16) {
        s.pos += 1;
        s.eat_while(|u| letter(u) || u == b'@' as u16);
        return Some(Command);
    }
    if math_letter(c) {
        s.eat_while(math_letter);
        return Some(Maths);
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
    if is_digit(c) || (c == b'.' as u16 && next.is_some_and(is_digit)) {
        s.eat_while(is_digit);
        if s.peek() == Some(b'.' as u16) {
            s.pos += 1;
            s.eat_while(is_digit);
        }
        return Some(Maths);
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

fn verbatim_environment(rest: &[u16]) -> Option<&'static str> {
    if rest.first() != Some(&(b'{' as u16)) {
        return None;
    }
    let close = rest.iter().take(NAME).position(|&u| u == b'}' as u16)?;
    let mut buf = [0; NAME];
    let name = ascii(&rest[1..close], &mut buf);
    CATALOG.verbatim_environments.get(name).map(String::as_str)
}

fn opening(s: &mut Stream, state: &mut State, name: &'static str) -> Option<HighlightKind> {
    match char::from_u32(s.next() as u32) {
        Some('{') => None,
        Some('}') => {
            state.mode = Mode::Verbatim(name);
            None
        }
        _ => {
            s.pos += name.len() - 1;
            Some(Argument)
        }
    }
}

fn verbatim(s: &mut Stream, state: &mut State, name: &'static str) -> Option<HighlightKind> {
    let end: Vec<u16> = format!("\\end{{{name}}}").encode_utf16().collect();
    match s.text[s.pos..].windows(end.len()).position(|w| w == end) {
        Some(at) => {
            s.pos += at;
            state.mode = Mode::Normal;
        }
        None => s.pos = s.text.len(),
    }
    None
}

fn verb(s: &mut Stream, state: &mut State, delimiter: u16) -> Option<HighlightKind> {
    s.pos += 1;
    s.eat_while(|u| u != delimiter);
    s.pos = (s.pos + 1).min(s.text.len());
    state.mode = Mode::Normal;
    None
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

fn word(u: u16) -> bool {
    u < 128 && ((u as u8).is_ascii_alphanumeric() || u == b'_' as u16)
}

fn command_letter(u: u16) -> bool {
    u == b'@' as u16 || math_letter(u)
}

fn math_letter(u: u16) -> bool {
    letter(u) || (0xc0..=0x1fff).contains(&u) || u >= 0x2060
}
