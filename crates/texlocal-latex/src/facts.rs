use std::ops::Range;
use std::sync::{Arc, LazyLock};

use regex::Regex;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::bib;
use crate::message::Message;
use crate::messages;
use crate::syntax::catalog::CATALOG;
use crate::syntax::headings::plain_title;
use crate::syntax::prose::Reading;
use crate::syntax::scan::{Group, Scanner, Visit, braced};
use crate::syntax::{SymbolKind, Text, headings, is, letter, scan};
use crate::{FileKind, utf16};

static MAGIC_COMMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\s*%\s*!\s*TeX\s+(root|(?:TS-)?program)\s*=\s*(.*?)\s*$").unwrap()
});

#[derive(Clone, Serialize, JsonSchema)]
pub struct Heading {
    #[serde(skip)]
    pub(crate) depth: usize,
    pub(crate) command: &'static str,
    pub level: &'static str,
    pub title: String,
    pub(crate) untitled: bool,
    pub line: usize,
    pub file: String,
    #[serde(skip)]
    pub(crate) words: usize,
}

impl Heading {
    fn new(depth: usize, title: Option<String>, line: usize) -> Self {
        let (command, level) = headings::LEVELS[depth];
        Self {
            depth,
            command,
            level,
            untitled: title.is_none(),
            title: title.unwrap_or_else(|| format!("Untitled {level}")),
            line,
            file: String::new(),
            words: 0,
        }
    }
}

#[derive(Default)]
pub struct Facts {
    pub(crate) headings: Vec<Heading>,
    pub(crate) inputs: Vec<Input>,
    pub words: usize,
    pub defined: Arc<Definitions>,
    pub(crate) uses: Vec<Named>,
    pub(crate) class: Option<String>,
    pub packages: Vec<String>,
    pub new_package: Option<Place>,
    pub(crate) bibliographies: Vec<String>,
    pub(crate) slips: Vec<Slip>,
    pub(crate) end: Option<Place>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Definitions {
    pub labels: Vec<Named>,
    pub citations: Vec<Named>,
    pub commands: Vec<Defined>,
    pub environments: Vec<Named>,
}

#[derive(
    Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
pub struct Place {
    pub line: u32,
    pub column: u32,
    pub length: u32,
}

impl Place {
    pub(crate) fn of(text: &Text, range: Range<usize>) -> Self {
        let line = text.line_index(range.start as u32);
        Self {
            line: line as u32 + 1,
            column: range.start as u32 - text.lines[line],
            length: range.len() as u32,
        }
    }

    pub fn in_file(self, file: String) -> FilePlace {
        let Self {
            line,
            column,
            length,
        } = self;
        FilePlace {
            file,
            line,
            column,
            length,
        }
    }
}

#[derive(Serialize, JsonSchema)]
pub struct FilePlace {
    pub file: String,
    pub line: u32,
    pub column: u32,
    pub length: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Named {
    pub(crate) kind: SymbolKind,
    pub name: String,
    pub place: Place,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Defined {
    pub name: String,
    pub(crate) arguments: usize,
    pub(crate) place: Place,
    pub(crate) tex: Option<String>,
}

pub(crate) struct Input {
    pub(crate) before: usize,
    pub(crate) name: String,
    folder: Folder,
    pub(crate) place: Place,
    pub(crate) words: usize,
}

enum Folder {
    Inherited,
    Import(String),
    Sub(String),
}

impl Input {
    pub(crate) fn resolve(
        &self,
        file: &str,
        within: &str,
        found: impl Fn(&str) -> Option<String>,
    ) -> Option<(String, String)> {
        let parent = file.rsplit_once('/').map_or("", |(parent, _)| parent);
        let folder = match &self.folder {
            Folder::Inherited => None,
            Folder::Import(folder) => Some(folder.clone()),
            Folder::Sub(folder) => Some(joined(parent, folder)),
        };
        let folders = match (&folder, within) {
            (Some(folder), _) => vec![folder.as_str()],
            (None, "") => vec![""],
            (None, within) => vec![within, ""],
        };
        let name = &self.name;
        let tex = format!("{}.tex", name.strip_suffix(".tex").unwrap_or(name));
        let input = folders
            .iter()
            .flat_map(|folder| [joined(folder, &tex), joined(folder, name)])
            .find_map(|rel| found(&rel))?;
        Some((input, folder.unwrap_or_else(|| within.to_owned())))
    }
}

impl Facts {
    pub fn read(source: &str, kind: FileKind) -> Self {
        let text = Text::new(source);
        if kind == FileKind::Bib {
            return Self::read_bib(source, &text);
        }
        let mut reader = Reader {
            text: &text,
            facts: Self::default(),
            defined: Definitions::default(),
            prose: Reading::whole(&text),
            structure: Structure::default(),
            title: None,
            heading_line: None,
            cuts: Vec::new(),
        };
        let mut scanner = Scanner::default();
        scanner.run(&text.units, text.units.len(), &[], &mut reader);
        let Reader {
            mut facts,
            defined,
            prose,
            structure,
            cuts,
            ..
        } = reader;
        let (slips, end) = structure.finish(&text, scanner.groups());
        let (prose, len) = (prose.prose(), end.unwrap_or(text.units.len()));
        facts.words = prose.words(0..len);
        let (mut headings, mut inputs) = (facts.headings.iter_mut(), facts.inputs.iter_mut());
        for (i, &(from, heading)) in cuts.iter().enumerate() {
            let to = cuts.get(i + 1).map_or(len, |cut| cut.0).min(len);
            let counted = if heading {
                &mut headings.next().expect("a heading for each cut").words
            } else {
                &mut inputs.next().expect("an input for each cut").words
            };
            *counted = prose.words(from.min(len)..to);
        }
        facts.defined = Arc::new(defined);
        facts.slips = slips;
        facts.end = end.map(|end| Place::of(&text, end..end));
        facts
    }

    fn read_bib(source: &str, text: &Text) -> Self {
        let (mut facts, mut defined) = (Self::default(), Definitions::default());
        let (mut byte, mut unit) = (0, 0);
        let mut cited = |at: Range<usize>| {
            unit += utf16::len(&source[byte..at.start]);
            byte = at.start;
            let units = unit..unit + utf16::len(&source[at]);
            named(text, SymbolKind::Citation, units)
        };
        for (entry, body) in bib::entries(source) {
            let kind = entry[1].to_ascii_lowercase();
            if matches!(kind.as_str(), "comment" | "string" | "preamble") {
                continue;
            }
            let start = entry.get_match().end();
            defined.citations.push(Named {
                detail: bib::detail(&bib::fields(body)),
                ..cited(entry.get(2).expect("an entry has a key").range())
            });
            if let Some(parent) = bib::CROSSREF
                .captures(body)
                .and_then(|parent| parent.get(1))
            {
                let at = start + parent.start()..start + parent.end();
                facts.uses.push(cited(at));
            }
        }
        facts.defined = Arc::new(defined);
        facts
    }
}

struct Reader<'a> {
    text: &'a Text,
    facts: Facts,
    defined: Definitions,
    prose: Reading<'a>,
    structure: Structure,
    title: Option<(usize, String)>,
    heading_line: Option<usize>,
    cuts: Vec<(usize, bool)>,
}

impl Visit for Reader<'_> {
    fn range(&mut self, from: usize, to: usize) {
        self.prose.range(from, to);
    }

    fn comment(&mut self, from: usize, to: usize) {
        self.prose.comment(from, to);
    }

    fn command(&mut self, name: &str, start: usize, name_end: usize) {
        self.prose.command(name, start, name_end);
        let text = self.text;
        self.structure.command(text, name, start, name_end);
        let facts = &mut self.facts;
        facts
            .uses
            .push(named(text, SymbolKind::Command, start..name_end));
        let names = |list| {
            let names = listed(&text.units, name_end, list).into_iter();
            names.map(|at| String::from_utf16_lossy(&text.units[at]))
        };
        match name {
            "bibitem" => {
                let keys = listed(&text.units, name_end, false).into_iter();
                let keys = keys.map(|at| named(text, SymbolKind::Citation, at));
                self.defined.citations.extend(keys);
            }
            "documentclass" if facts.class.is_none() => {
                facts.class = braced(&text.units, name_end)
                    .0
                    .map(|(class, _)| class.trim().to_owned());
                facts.new_package = Some(after_line(text, name_end));
            }
            "usepackage" | "RequirePackage" => {
                facts.packages.extend(names(true));
                if name == "usepackage" {
                    facts.new_package = Some(after_line(text, name_end));
                }
            }
            "bibliography" | "addbibresource" => {
                facts.bibliographies.extend(names(name == "bibliography"));
            }
            "newcommand" | "renewcommand" | "providecommand" | "DeclareMathOperator" | "def" => {
                let command = defined(text, name, name_end);
                let command = command
                    .filter(|d| d.name.starts_with('\\') && (name != "def" || d.tex.is_some()));
                self.defined.commands.extend(command);
            }
            "newenvironment" => {
                let environment =
                    defined(text, name, name_end).filter(|d| !d.name.starts_with('\\'));
                let environment = environment.map(|Defined { name, place, .. }| Named {
                    kind: SymbolKind::Environment,
                    name,
                    place,
                    detail: None,
                });
                self.defined.environments.extend(environment);
            }
            "input" | "include" | "subfile" | "import" | "subimport" => {
                if let Some((name, folder, at)) = input(&text.units, name, name_end) {
                    facts.inputs.push(Input {
                        before: facts.headings.len(),
                        name,
                        folder,
                        place: Place::of(text, at),
                        words: 0,
                    });
                    self.cuts.push((name_end, false));
                }
            }
            _ => match headings::LEVELS.iter().position(|l| l.0 == name) {
                Some(depth) => self.titled(Some(depth), name_end),
                None if name == "caption" => self.titled(None, name_end),
                None => self.used(name, start, name_end),
            },
        }
    }

    fn math_command(&mut self, name: &str, start: usize, name_end: usize) {
        self.structure.command(self.text, name, start, name_end);
        let command = named(self.text, SymbolKind::Command, start..name_end);
        self.facts.uses.push(command);
        self.used(name, start, name_end);
    }

    fn brace(&mut self, at: usize, open: bool) {
        self.structure.brace(self.text, at, open);
    }

    fn unclosed(&mut self, group: &Group) {
        self.structure.unclosed(self.text, group);
    }
}

impl Reader<'_> {
    fn titled(&mut self, depth: Option<usize>, name_end: usize) {
        let (title, _) = braced(&self.text.units, name_end);
        let title = title.map(|(title, at)| (at.end, plain_title(&title)));
        if let Some(depth) = depth {
            let line = self.text.line_index(name_end as u32) + 1;
            if self.heading_line != Some(line)
                && let Some((_, title)) = &title
            {
                let heading = Heading::new(depth, title.clone(), line);
                self.facts.headings.push(heading);
                self.cuts.push((name_end, true));
            }
            self.heading_line = Some(line);
        }
        self.title = title.and_then(|(end, title)| Some((end, title?)));
    }

    fn used(&mut self, name: &str, start: usize, name_end: usize) {
        let (text, catalog) = (self.text, &*CATALOG);
        let kind = match name {
            "begin" | "end" => SymbolKind::Environment,
            "includegraphics" => SymbolKind::File,
            name if catalog.ref_commands.contains(name) => SymbolKind::Label,
            name if catalog.cite_commands.contains(name) => SymbolKind::Citation,
            "label" => {
                let after = |close: usize| {
                    let between = text.units.get(close + 1..start).unwrap_or_default();
                    String::from_utf16_lossy(between).trim().is_empty()
                };
                let line = || String::from_utf16_lossy(text.line(text.line_index(start as u32)));
                let detail = match &self.title {
                    Some((close, title)) if after(*close) => Some(title.clone()),
                    _ => plain_title(&line()).filter(|line| !line.contains('\\')),
                };
                let labels = listed(&text.units, name_end, false).into_iter();
                let labels = labels.map(|at| Named {
                    detail: detail.clone(),
                    ..named(text, SymbolKind::Label, at)
                });
                let labels = labels.filter(|label| !label.name.ends_with(':'));
                self.defined.labels.extend(labels);
                return;
            }
            _ => return,
        };
        let list = matches!(kind, SymbolKind::Label | SymbolKind::Citation);
        let names = listed(&text.units, name_end, list).into_iter();
        self.facts
            .uses
            .extend(names.map(|at| named(text, kind, at)));
    }
}

fn named(text: &Text, kind: SymbolKind, at: Range<usize>) -> Named {
    Named {
        kind,
        name: String::from_utf16_lossy(&text.units[at.clone()]),
        place: Place::of(text, at),
        detail: None,
    }
}

pub const MAGIC_LINES: usize = 20;

pub fn magic_comments(text: &str) -> (Option<String>, Option<String>) {
    let mut found = (None, None);
    let lines = text.lines().take(MAGIC_LINES);
    for m in lines.filter_map(|line| MAGIC_COMMENT.captures(line)) {
        let slot = if m[1].eq_ignore_ascii_case("root") {
            &mut found.0
        } else {
            &mut found.1
        };
        slot.get_or_insert_with(|| m[2].to_string());
    }
    found
}

fn defined(text: &Text, command: &str, name_end: usize) -> Option<Defined> {
    let units = &text.units;
    let (name, at, stop) = match braced(units, name_end) {
        (Some((name, at)), stop) => (name.trim().to_owned(), at, stop),
        (None, stop) if units.get(stop).is_some_and(|&u| is(u, '\\')) => {
            let end = stop + 1 + units[stop + 1..].iter().take_while(|&&u| letter(u)).count();
            (String::from_utf16_lossy(&units[stop..end]), stop..end, end)
        }
        _ => return None,
    };
    if name.trim_start_matches('\\').is_empty() {
        return None;
    }
    let (mut options, mut body) = (Vec::new(), Vec::new());
    let (_, closed) = scan::arguments(units, stop, |piece, braced| {
        if braced {
            body.extend_from_slice(&units[piece]);
        } else {
            options.push(String::from_utf16_lossy(&units[piece]));
        }
    });
    let count = options.first().and_then(|count| count.trim().parse().ok());
    let arguments = count
        .unwrap_or(0_usize)
        .saturating_sub(usize::from(options.len() > 1));
    let body = String::from_utf16_lossy(&body);
    let parameters = |count| (1..=count).map(|n| format!("#{n}")).collect::<String>();
    let tex = match (command, options.get(1)) {
        _ if !closed => None,
        ("def", _) if !options.is_empty() => None,
        ("DeclareMathOperator", _) => {
            let star = if units.get(name_end).is_some_and(|&u| is(u, '*')) {
                "*"
            } else {
                ""
            };
            Some(format!("\\def{name}{{\\operatorname{star}{{{body}}}}}"))
        }
        (_, Some(default)) => Some(format!(
            "\\def{name}{{\\texlocal@optional{name}@{{{default}}}}}\\def{name}@{}{{{body}}}",
            parameters(arguments + 1)
        )),
        _ => Some(format!("\\def{name}{}{{{body}}}", parameters(arguments))),
    };
    Some(Defined {
        name,
        arguments,
        place: Place::of(text, at),
        tex,
    })
}

fn after_line(text: &Text, name_end: usize) -> Place {
    let (_, stop) = braced(&text.units, name_end);
    let end = text.around(stop - 1).end;
    Place::of(text, end..end)
}

fn joined(folder: &str, name: &str) -> String {
    match folder.trim_end_matches('/') {
        "" => name.to_owned(),
        folder => format!("{folder}/{name}"),
    }
}

fn listed(units: &[u16], name_end: usize, list: bool) -> Vec<Range<usize>> {
    let blank = |&&u: &&u16| scan::tex_space(u) || is(u, '\n');
    let mut names = Vec::new();
    let (_, closed) = scan::arguments(units, name_end, |piece, braced| {
        if !braced {
            return;
        }
        let commas = piece.clone().filter(|&i| list && is(units[i], ','));
        let mut from = piece.start;
        for end in commas.chain([piece.end]) {
            let start = from + units[from..end].iter().take_while(blank).count();
            let trail = units[start..end].iter().rev().take_while(blank).count();
            if start < end {
                names.push(start..end - trail);
            }
            from = end + 1;
        }
    });
    if closed { names } else { Vec::new() }
}

fn input(units: &[u16], command: &str, name_end: usize) -> Option<(String, Folder, Range<usize>)> {
    let (name, folder, at) = match (command, braced(units, name_end)) {
        ("input" | "include" | "subfile", (Some((name, at)), _)) => (name, Folder::Inherited, at),
        ("input", (None, stop)) => {
            let name: String = char::decode_utf16(units[stop..].iter().copied())
                .map_while(|c| c.ok().filter(|c| !"{}\\% \t\r\n".contains(*c)))
                .collect();
            let end = stop + utf16::len(&name);
            (name, Folder::Inherited, stop..end)
        }
        ("import" | "subimport", (Some((folder, _)), stop)) => {
            let folder = folder.trim().to_owned();
            let folder = match command {
                "import" => Folder::Import(folder),
                _ => Folder::Sub(folder),
            };
            let (name, at) = braced(units, stop).0?;
            (name, folder, at)
        }
        _ => return None,
    };
    Some((name.trim().to_owned(), folder, at))
}

pub(crate) struct Slip {
    pub(crate) place: Place,
    pub(crate) message: Message,
    pub(crate) kind: Kind,
}

#[derive(PartialEq, Eq)]
pub(crate) enum Kind {
    Mismatched,
    Unbegun(String),
    Unended(String),
    Unbalanced,
}

#[derive(Default)]
pub(crate) struct Structure {
    environments: Vec<(String, usize)>,
    braces: Vec<usize>,
    slips: Vec<Slip>,
    end: Option<usize>,
}

impl Structure {
    pub(crate) fn command(&mut self, text: &Text, name: &str, start: usize, name_end: usize) {
        if !matches!(name, "begin" | "end") || !self.braces.is_empty() || !self.read(start) {
            return;
        }
        let Some((environment, _)) = scan::environment_name(&text.units, name_end) else {
            return;
        };
        let environment = String::from_utf16_lossy(environment).trim().to_owned();
        if name == "begin" {
            self.environments.push((environment, start));
            return;
        }
        if environment == "document" {
            self.end = Some(start);
        }
        let begun = self
            .environments
            .iter()
            .rposition(|(e, _)| *e == environment);
        let Some(begun) = begun else {
            let message = messages::end_without_begin(&environment);
            return self.slip(text, start, message, Kind::Unbegun(environment));
        };
        if let Some((open, at)) = self.environments.get(begun + 1..).and_then(<[_]>::last) {
            let message = messages::ended_by_another(open, line(text, *at), &environment);
            self.slip(text, start, message, Kind::Mismatched);
        }
        self.environments.truncate(begun);
    }

    pub(crate) fn brace(&mut self, text: &Text, at: usize, open: bool) {
        if !self.read(at) {
            return;
        }
        if open {
            self.braces.push(at);
        } else if self.braces.pop().is_none() {
            self.slip(text, at, messages::nothing_to_close(), Kind::Unbalanced);
        }
    }

    pub(crate) fn unclosed(&mut self, text: &Text, group: &Group) {
        if !self.read(group.open) {
            return;
        }
        let width = group.delimiter().unwrap_or_default();
        let open = &text.units[group.open..group.open + width];
        let message = messages::open_at_paragraph_end(String::from_utf16_lossy(open));
        self.slip(text, group.open, message, Kind::Unbalanced);
    }

    pub(crate) fn finish<'a>(
        mut self,
        text: &Text,
        open: impl Iterator<Item = &'a Group>,
    ) -> (Vec<Slip>, Option<usize>) {
        for group in open.filter(|group| group.delimiter().is_some()) {
            self.unclosed(text, group);
        }
        for at in std::mem::take(&mut self.braces) {
            self.slip(text, at, messages::never_closed(), Kind::Unbalanced);
            self.environments.clear();
        }
        for (environment, at) in std::mem::take(&mut self.environments) {
            let message = messages::never_ended(&environment);
            self.slip(text, at, message, Kind::Unended(environment));
        }
        self.slips.sort_by_key(|slip| slip.place);
        (self.slips, self.end)
    }

    fn read(&self, at: usize) -> bool {
        self.end.is_none_or(|end| at < end)
    }

    fn slip(&mut self, text: &Text, at: usize, message: Message, kind: Kind) {
        let place = Place::of(text, at..at);
        self.slips.push(Slip {
            place,
            message,
            kind,
        });
    }
}

fn line(text: &Text, at: usize) -> u32 {
    text.line_index(at as u32) as u32 + 1
}
