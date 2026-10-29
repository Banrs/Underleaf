use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

use crate::analyze::{Facts, Heading, INPUT_DEPTH, Input, Named, Place};
use crate::logparse::{LogItem, Severity};
use crate::message::Message;
use crate::messages;
use crate::syntax::scan::{self, Group};
use crate::syntax::{SymbolKind, Symbols, Text};

pub(crate) struct Slip {
    place: Place,
    message: Message,
    kind: Kind,
}

#[derive(PartialEq, Eq)]
enum Kind {
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

fn literal(name: &str) -> bool {
    !name.is_empty() && !name.contains(['\\', '#'])
}

fn read<'a>(facts: &'a Facts, names: &'a [Named]) -> impl Iterator<Item = &'a Named> {
    names
        .iter()
        .filter(|n| facts.end.is_none_or(|end| n.place < end))
}

pub(crate) struct Walk<'a> {
    symbols: &'a Symbols,
    pub(crate) files: Vec<(&'a str, &'a Facts)>,
    labels: Vec<(&'a str, &'a Named)>,
    slips: Vec<(&'a str, &'a Slip)>,
    missing: Vec<(&'a str, &'a Input)>,
    pub(crate) outline: Vec<Heading>,
    pub(crate) words: usize,
}

impl<'a> Walk<'a> {
    pub(crate) fn from(symbols: &'a Symbols, file: &str) -> Self {
        let mut walk = Self {
            symbols,
            files: Vec::new(),
            labels: Vec::new(),
            slips: Vec::new(),
            missing: Vec::new(),
            outline: Vec::new(),
            words: 0,
        };
        walk.read(file, "", 0);
        walk
    }

    fn read(&mut self, file: &str, within: &str, depth: usize) {
        let symbols = self.symbols;
        if depth == INPUT_DEPTH {
            return;
        }
        let Some((file, facts)) = symbols.by_file.get_key_value(file) else {
            return;
        };
        let file = file.as_str();
        if self.files.iter().any(|(read, ..)| *read == file) {
            return;
        }
        self.files.push((file, facts));
        let mut labels = read(facts, &facts.labels).peekable();
        let mut slips = facts.slips.iter().peekable();
        let headings = &facts.headings;
        let read_headings = headings
            .iter()
            .take_while(|h| facts.end.is_none_or(|end| h.line as u32 <= end.line))
            .count();
        let placed = |heading: &Heading| Heading {
            file: file.to_owned(),
            ..heading.clone()
        };
        let headed: usize = headings.iter().map(|h| h.words).sum();
        let after_inputs: usize = facts.inputs.iter().map(|input| input.words).sum();
        self.credit(facts.words - headed - after_inputs);
        let mut at = 0;
        let inputs = facts.inputs.iter();
        for input in inputs.filter(|i| facts.end.is_none_or(|end| i.place < end)) {
            while let Some(label) = labels.next_if(|label| label.place < input.place) {
                self.labels.push((file, label));
            }
            while let Some(slip) = slips.next_if(|slip| slip.place < input.place) {
                self.slip(file, slip);
            }
            let before = input.before.min(read_headings);
            self.outline.extend(headings[at..before].iter().map(placed));
            at = before;
            match input.resolve(file, within, |rel| symbols.spelt(rel)) {
                Some((input, within)) => self.read(&input, &within, depth + 1),
                None => self.missing.push((file, input)),
            }
            self.credit(input.words);
        }
        self.outline
            .extend(headings[at..read_headings].iter().map(placed));
        self.words += facts.words;
        self.labels.extend(labels.map(|label| (file, label)));
        slips.for_each(|slip| self.slip(file, slip));
    }

    fn credit(&mut self, words: usize) {
        if let Some(last) = self.outline.last_mut() {
            last.words += words;
        }
    }

    fn slip(&mut self, file: &'a str, slip: &'a Slip) {
        let begun = self
            .slips
            .iter()
            .rposition(|(_, open)| match (&open.kind, &slip.kind) {
                (Kind::Unended(a), Kind::Unbegun(b)) => a == b,
                _ => false,
            });
        match begun {
            Some(begun) => drop(self.slips.remove(begun)),
            None => self.slips.push((file, slip)),
        }
    }
}

fn twice<'a>(
    defined: impl IntoIterator<Item = (&'a str, &'a Named)>,
    said: fn(&str, u32, &str) -> Message,
) -> Vec<LogItem> {
    let mut first = HashMap::new();
    let mut twice = Vec::new();
    for (file, named) in defined.into_iter().filter(|(_, n)| literal(&n.name)) {
        match first.entry(named.name.as_str()) {
            Entry::Vacant(entry) => {
                entry.insert((file, named.place.line));
            }
            Entry::Occupied(entry) => {
                let (at, line) = entry.get();
                let message = said(&named.name, *line, at);
                twice.push(warning(file, named.place.line, message));
            }
        }
    }
    twice
}

fn warning(file: &str, line: u32, message: Message) -> LogItem {
    LogItem::new(Severity::Warning, Some(file.into()), Some(line), message)
}

pub fn check(symbols: &Symbols, main: &str) -> Vec<LogItem> {
    let walk = Walk::from(symbols, main);
    let reached = || walk.files.iter().copied();
    let undefined = |kind, said: fn(&str) -> Message, defined: &HashSet<&str>| -> Vec<LogItem> {
        let uses =
            reached().flat_map(|(file, facts)| read(facts, &facts.uses).map(move |u| (file, u)));
        let uses = uses.filter(|(_, used)| used.kind == kind && literal(&used.name));
        let undefined = uses.filter(|(_, used)| !defined.contains(&*used.name));
        let item = |(file, used): (&str, &Named)| warning(file, used.place.line, said(&used.name));
        undefined.map(item).collect()
    };
    let packages: HashSet<&str> = reached()
        .flat_map(|(_, facts)| &facts.packages)
        .map(String::as_str)
        .collect();
    let mut items = twice(walk.labels.iter().copied(), |name, line, file| {
        messages::label_defined_twice(name, line, file)
    });

    if !packages.contains("xr") && !packages.contains("xr-hyperref") {
        let mut labels: HashSet<&str> = walk.labels.iter().map(|(_, l)| l.name.as_str()).collect();
        if packages.contains("lastpage") {
            labels.extend(["LastPage", "VeryLastPage"]);
        }
        items.extend(undefined(
            SymbolKind::Label,
            |name| messages::no_label(name),
            &labels,
        ));
    }

    let named = reached().flat_map(|(_, facts)| &facts.bibliographies);
    let bibliographies: Vec<Option<String>> = named
        .map(|name| {
            symbols
                .spelt(&format!("{name}.bib"))
                .or_else(|| symbols.spelt(name))
        })
        .collect();
    let mut seen = HashSet::new();
    let bibs = bibliographies
        .iter()
        .flatten()
        .filter(|bib| seen.insert(*bib));
    let entries = bibs.filter_map(|bib| symbols.by_file.get_key_value(bib));
    let entries: Vec<(&str, &Named)> = entries
        .flat_map(|(bib, facts)| facts.citations.iter().map(move |c| (bib.as_str(), c)))
        .collect();
    items.extend(twice(entries.iter().copied(), |name, line, file| {
        messages::citation_defined_twice(name, line, file)
    }));
    if bibliographies.iter().all(Option::is_some) {
        let bibitems = reached().flat_map(|(_, facts)| read(facts, &facts.citations));
        let mut keys: HashSet<&str> = bibitems.map(|c| c.name.as_str()).collect();
        keys.extend(entries.iter().map(|(_, c)| c.name.as_str()));
        keys.insert("*");
        items.extend(undefined(
            SymbolKind::Citation,
            |name| messages::no_citation(name),
            &keys,
        ));
    }

    let in_tex = |name: &str| {
        let name = name.rsplit('/').next().unwrap_or(name);
        let name = name.strip_suffix(".tex").unwrap_or(name);
        let inputs = &symbols.installed.inputs;
        inputs.is_empty() || inputs.binary_search_by(|i| i.as_str().cmp(name)).is_ok()
    };
    let unread = walk.missing.iter();
    let unread: Vec<_> = unread
        .filter(|(_, input)| !literal(&input.name) || !in_tex(&input.name))
        .collect();
    let missing = unread.iter().filter(|(_, input)| literal(&input.name));
    items.extend(
        missing
            .map(|(file, input)| warning(file, input.place.line, messages::no_file(&input.name))),
    );

    let slips = walk.slips.iter().filter(|(_, slip)| {
        unread.is_empty() || !matches!(slip.kind, Kind::Unbegun(_) | Kind::Unended(_))
    });
    items.extend(slips.map(|&(file, slip)| {
        let kind = if slip.kind == Kind::Unbalanced {
            Severity::Warning
        } else {
            Severity::Error
        };
        let message = slip.message.clone();
        LogItem::new(kind, Some(file.into()), Some(slip.place.line), message)
    }));
    items.sort_by(|a, b| (&a.file, a.line).cmp(&(&b.file, b.line)));
    items
}
