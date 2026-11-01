use std::ops::Range;

use schemars::JsonSchema;
use serde::Deserialize;

use super::catalog::CATALOG;
use super::scan::blank_line;
use super::stack::Stack;
use super::{NAME, Text, ascii, is, letter};

#[derive(Clone, Copy, Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HighlightKind {
    Command,
    Argument,
    Maths,
    Comment,
    Invalid,
}

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
    Opening(Environment),
    Verbatim(&'static str),
    MathEnvironment(&'static str, bool),
    Verb(u16),
}

#[derive(Clone, Copy)]
enum Environment {
    Verbatim(&'static str),
    Maths(&'static str, bool),
}

#[derive(Clone, Copy)]
struct Command {
    named: bool,
    address: bool,
    braces: usize,
    optional: bool,
}

#[derive(Clone, Copy)]
struct Open {
    command: Command,
    styled_below: Option<Command>,
}

fn open(commands: &mut Stack<Open>, named: bool, address: bool) {
    commands.push(Open {
        command: Command {
            named,
            address,
            braces: 0,
            optional: false,
        },
        styled_below: styled(commands),
    });
}

fn styled(commands: &Stack<Open>) -> Option<Command> {
    let top = commands.top()?;
    top.command
        .named
        .then_some(top.command)
        .or(top.styled_below)
}

use HighlightKind::*;

fn named(name: &[u16]) -> bool {
    let mut buf = [0; NAME];
    let name = ascii(name, &mut buf);
    let named = [
        &CATALOG.name_commands,
        &CATALOG.ref_commands,
        &CATALOG.cite_commands,
    ];
    named.iter().any(|names| names.contains(name)) || matches!(name, "Bibitem" | "RBibitem")
}

fn tokenize(line: &[u16], state: &mut State, mut run: impl FnMut(usize, usize, HighlightKind)) {
    if blank_line(line) {
        if !matches!(state.mode, Mode::Verbatim(_) | Mode::MathEnvironment(..)) {
            *state = State::default();
        }
        return;
    }
    let mut s = Stream { text: line, pos: 0 };
    while s.pos < line.len() {
        let from = s.pos;
        let kind = match state.mode {
            Mode::Normal => normal(&mut s, state),
            Mode::Math(end) => math(&mut s, state, Some(end)),
            Mode::Arguments => arguments(&mut s, state),
            Mode::Opening(environment) => opening(&mut s, state, environment),
            Mode::Verbatim(name) => verbatim(&mut s, state, name),
            Mode::MathEnvironment(name, starred) => math_environment(&mut s, state, name, starred),
            Mode::Verb(delimiter) => verb(&mut s, state, delimiter),
        };
        if let Some(kind) = kind {
            run(from, s.pos, kind);
        }
    }
}

fn normal(s: &mut Stream, state: &mut State) -> Option<HighlightKind> {
    if let Some(name) = control_word(s) {
        let name = &s.text[name];
        match ascii(name, &mut [0; NAME]) {
            "verb" => {
                s.eat("*");
                if let Some(delimiter) = s.peek() {
                    state.mode = Mode::Verb(delimiter);
                }
            }
            "begin" if let Some(environment) = environment(&s.text[s.pos..]) => {
                state.mode = Mode::Opening(environment);
            }
            word => {
                let address = matches!(word, "url" | "href");
                open(&mut state.commands, named(name), address);
                state.mode = Mode::Arguments;
            }
        }
        return Some(Command);
    }
    for (open, close) in [("\\[", "\\]"), ("\\(", "\\)"), ("$$", "$$"), ("$", "$")] {
        if s.eat(open) {
            state.mode = Mode::Math(close);
            return Some(Maths);
        }
    }
    if control_symbol(s) {
        return Some(Command);
    }
    let c = s.next();
    let address = state.commands.top().is_some_and(|top| top.command.address);
    if is(c, '%') && !address {
        s.pos = s.text.len();
        Some(Comment)
    } else if one_of(c, "}]") {
        if state.commands.top().is_none() {
            return Some(Invalid);
        }
        state.mode = Mode::Arguments;
        None
    } else if one_of(c, "{[") {
        open(&mut state.commands, false, false);
        None
    } else if is_digit(c) {
        s.eat_while(|u| word(u) || is(u, '.'));
        Some(Argument)
    } else {
        s.eat_while(|u| word(u) || is(u, '-'));
        let command = styled(&state.commands)?;
        (command.braces == 1 && !command.optional).then_some(Argument)
    }
}

fn math_environment(
    s: &mut Stream,
    state: &mut State,
    name: &'static str,
    starred: bool,
) -> Option<HighlightKind> {
    let mut end = Stream { ..*s };
    if end.eat("\\end{") && end.eat(name) && (!starred || end.eat("*")) && end.eat("}") {
        state.mode = Mode::Normal;
        return None;
    }
    math(s, state, None)
}

fn math(s: &mut Stream, state: &mut State, end: Option<&'static str>) -> Option<HighlightKind> {
    if s.eat_while(|u| char::from_u32(u.into()).is_some_and(char::is_whitespace)) {
        return None;
    }
    if end.is_some_and(|end| s.eat(end)) {
        state.mode = Mode::Normal;
        return Some(Maths);
    }
    if control_word(s).is_some() || control_symbol(s) {
        return Some(Command);
    }
    let c = s.peek()?;
    if math_letter(c) {
        s.eat_while(math_letter);
        return Some(Maths);
    }
    if one_of(c, "^_&") {
        s.pos += 1;
        return Some(Command);
    }
    if one_of(c, "+-<>|=,/@!*:;'\"`~#?") {
        s.pos += 1;
        return None;
    }
    if is_digit(c) || (is(c, '.') && s.at(1).is_some_and(is_digit)) {
        s.eat_while(is_digit);
        if s.peek().is_some_and(|u| is(u, '.')) {
            s.pos += 1;
            s.eat_while(is_digit);
        }
        return Some(Maths);
    }
    s.pos += 1;
    if one_of(c, "{}[]()") {
        None
    } else if is(c, '%') {
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
            top.command.optional = is(c, '[');
            top.command.braces += usize::from(is(c, '{'));
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

fn control_word(s: &mut Stream) -> Option<Range<usize>> {
    let backslash = s.peek().is_some_and(|u| is(u, '\\'));
    if !backslash || !s.at(1).is_some_and(command_letter) {
        return None;
    }
    s.pos += 1;
    let name = s.pos;
    s.eat_while(command_letter);
    Some(name..s.pos)
}

fn control_symbol(s: &mut Stream) -> bool {
    let symbol = s.peek().is_some_and(|u| is(u, '\\')) && s.at(1).is_some_and(|u| u < 128);
    s.pos += 2 * symbol as usize;
    symbol
}

fn environment(rest: &[u16]) -> Option<Environment> {
    if !rest.first().is_some_and(|&u| is(u, '{')) {
        return None;
    }
    let close = rest.iter().take(NAME).position(|&u| is(u, '}'))?;
    let mut buf = [0; NAME];
    let name = ascii(&rest[1..close], &mut buf);
    if let Some(name) = CATALOG.verbatim_environments.get(name) {
        return Some(Environment::Verbatim(name));
    }
    let bare = name.strip_suffix('*');
    let maths = CATALOG.math_environments.get(bare.unwrap_or(name))?;
    Some(Environment::Maths(maths, bare.is_some()))
}

fn opening(s: &mut Stream, state: &mut State, environment: Environment) -> Option<HighlightKind> {
    let (body, length) = match environment {
        Environment::Verbatim(name) => (Mode::Verbatim(name), name.len()),
        Environment::Maths(name, starred) => (
            Mode::MathEnvironment(name, starred),
            name.len() + usize::from(starred),
        ),
    };
    match char::from_u32(s.next() as u32) {
        Some('{') => None,
        Some('}') => {
            state.mode = body;
            None
        }
        _ => {
            s.pos += length - 1;
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
    u < 128 && ((u as u8).is_ascii_alphanumeric() || is(u, '_'))
}

fn command_letter(u: u16) -> bool {
    is(u, '@') || math_letter(u)
}

fn math_letter(u: u16) -> bool {
    letter(u) || (0xc0..=0x1fff).contains(&u) || u >= 0x2060
}
