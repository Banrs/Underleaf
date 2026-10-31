use std::collections::{BTreeMap, HashSet};
use std::sync::{Arc, LazyLock};

use regex::Regex;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::scan::{self, Group, Scanner};
use super::{INDENT, Insertion, SourceDocument, Text, catalog, edit, indentation};
use crate::facts::{Defined, Definitions, Facts, FilePlace, Input, Named, Place};
use crate::utf16;
use crate::{FileKind, file_kind, fold_case, segments};

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct SnippetField {
    pub(crate) start: u32,
    pub(crate) length: u32,
    pub(crate) index: u32,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Completion {
    pub(crate) label: String,
    pub(crate) text: String,
    pub(crate) fields: Vec<SnippetField>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) detail: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum SymbolKind {
    #[schemars(title = "Command")]
    Command,
    #[schemars(title = "Environment")]
    Environment,
    #[schemars(title = "Label")]
    Label,
    #[schemars(title = "Citation")]
    Citation,
    #[schemars(title = "Entry Type")]
    EntryType,
    #[schemars(title = "File")]
    File,
}

#[derive(Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Symbols {
    pub files: Vec<String>,
    pub by_file: BTreeMap<String, Arc<Definitions>>,
    pub installed: Arc<Installed>,
}

impl Symbols {
    pub fn spelt(&self, rel: &str) -> Option<String> {
        let rel = fold_case(&segments(rel)?.join("/"));
        let mut files = self.files.iter();
        files.find(|file| fold_case(file) == rel).cloned()
    }

    pub fn labels(&self) -> impl Iterator<Item = &Named> {
        self.by_file.values().flat_map(|defined| &defined.labels)
    }

    pub(crate) fn commands(&self) -> impl Iterator<Item = &Defined> {
        self.by_file.values().flat_map(|defined| &defined.commands)
    }

    fn firsts<'a, T>(
        &'a self,
        list: impl Fn(&'a Definitions) -> &'a [T],
        name: impl Fn(&T) -> &str,
    ) -> Vec<&'a T> {
        let mut seen = HashSet::new();
        let all = self.by_file.values().flat_map(|defined| list(defined));
        all.filter(|item| seen.insert(name(item))).collect()
    }
}

#[derive(Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Installed {
    pub packages: Vec<String>,
    pub classes: Vec<String>,
    pub styles: Vec<String>,
    pub inputs: Vec<String>,
}

impl Installed {
    pub fn from_ls_r(ls_r: &str) -> Self {
        let mut installed = Self::default();
        let mut loaded = false;
        for line in ls_r.lines() {
            if let Some(folder) = line.strip_suffix(':') {
                loaded = folder.starts_with("./tex/") || folder.starts_with("./bibtex/");
                continue;
            }
            let (name, list) = match line.rsplit_once('.') {
                _ if !loaded => continue,
                Some((name, "sty")) => (name, &mut installed.packages),
                Some((name, "cls")) => (name, &mut installed.classes),
                Some((name, "bst")) => (name, &mut installed.styles),
                Some((name, "tex")) => (name, &mut installed.inputs),
                _ => continue,
            };
            list.push(name.to_owned());
        }
        for list in [
            &mut installed.packages,
            &mut installed.classes,
            &mut installed.styles,
            &mut installed.inputs,
        ] {
            list.sort_unstable();
            list.dedup();
        }
        installed
    }
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Completions {
    pub(crate) start: u32,
    pub(crate) kind: SymbolKind,
    pub(crate) items: Vec<Completion>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct SymbolName {
    kind: SymbolKind,
    name: String,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Definition {
    kind: SymbolKind,
    name: String,
    places: Vec<FilePlace>,
}

static ARGUMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\([0-9A-Za-z_]+)\*?(\[[^\]]*\])?\{[^{}\\]*$").unwrap());
static ENTRY_TYPE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(@[0-9A-Za-z_]*)$").unwrap());
static COMMAND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\[0-9A-Za-z_]*$").unwrap());
static FIELD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"#\{([^}]*)\}").unwrap());

impl SourceDocument {
    pub(crate) fn complete(&mut self, caret: u32, explicit: bool) -> Option<&Completions> {
        self.typing.offered = self.completions(caret, explicit);
        self.typing.offered.as_ref()
    }

    pub(crate) fn accept_completion(&mut self, index: u32, caret: u32) -> Option<Insertion> {
        let Completions { start, items, .. } = self.typing.offered.take()?;
        let typed = caret.min(self.text.len()).checked_sub(start)?;
        let item = items.into_iter().nth(index as usize)?;
        Some(Insertion {
            caret: start + utf16::len(&item.text) as u32,
            edit: edit(start, typed, item.text),
            fields: item.fields,
        })
    }

    fn completions(&mut self, caret: u32, explicit: bool) -> Option<Completions> {
        let (text, caret) = (&self.text, caret.min(self.text.len()));
        let line = text.line_index(caret);
        let from = text.lines[line].max(caret.saturating_sub(250));
        let before = String::from_utf16_lossy(&text.units[from as usize..caret as usize]);
        let catalog = &*catalog::CATALOG;
        let offer = |start: usize, kind: SymbolKind, items: Vec<Completion>| {
            (!items.is_empty()).then(|| Completions {
                start: from + utf16::len(&before[..start]) as u32,
                kind,
                items,
            })
        };

        if let Some(c) = ARGUMENT.captures(&before) {
            let start = before.rfind(['{', ',']).map_or(0, |i| i + 1);
            let start = before.len() - before[start..].trim_start().len();
            let typed = &before[start..];
            let listed: Vec<String>;
            let installed = &self.symbols.installed;
            let (names, kind): (&[String], _) = match &c[1] {
                c if catalog.cite_commands.contains(c) => {
                    let citations = self.symbols.firsts(|d| &d.citations, |c| &c.name);
                    let cited = cited(&citations, typed);
                    return offer(start, SymbolKind::Citation, described(cited));
                }
                c if catalog.ref_commands.contains(c) => {
                    let labels = self.symbols.firsts(|d| &d.labels, |l| &l.name);
                    let labels = matching(&labels, typed, |l| &l.name).into_iter().copied();
                    return offer(start, SymbolKind::Label, described(labels.collect()));
                }
                "begin" | "end" => {
                    let at = from as usize + utf16::len(&before[..c.get(0).unwrap().start()]);
                    let scanner = (&c[1] == "end").then(|| self.scanned_to(at));
                    let mut groups = scanner.iter().flat_map(Scanner::groups);
                    let open = groups.find_map(Group::environment);
                    let own = self.symbols.firsts(|d| &d.environments, |e| &e.name);
                    let own: Vec<&str> = own.iter().map(|e| e.name.as_str()).collect();
                    let others = catalog.environments.iter().map(String::as_str);
                    let rest = own
                        .iter()
                        .copied()
                        .chain(others.filter(|e| !own.contains(e)));
                    let rest = rest.filter(|&e| Some(e) != open);
                    listed = open.into_iter().chain(rest).map(str::to_owned).collect();
                    (&listed, SymbolKind::Environment)
                }
                "usepackage" | "RequirePackage" => (&installed.packages, SymbolKind::File),
                "documentclass" => (&installed.classes, SymbolKind::File),
                "bibliographystyle" => (&installed.styles, SymbolKind::File),
                command => {
                    let (kinds, bare): (&[FileKind], _) = match command {
                        "input" | "include" | "subfile" => (&[FileKind::Tex], true),
                        "includegraphics" => (&[FileKind::Image, FileKind::Pdf], false),
                        "bibliography" => (&[FileKind::Bib], true),
                        "addbibresource" => (&[FileKind::Bib], false),
                        _ => return None,
                    };
                    listed = self
                        .symbols
                        .files
                        .iter()
                        .filter(|file| kinds.contains(&file_kind(file)))
                        .map(|file| match file.rsplit_once('.') {
                            Some((stem, _)) if bare => stem.to_owned(),
                            _ => file.clone(),
                        })
                        .collect();
                    (&listed, SymbolKind::File)
                }
            };
            let items = matching(names, typed, |n| n).into_iter();
            return offer(start, kind, items.map(|n| word(n.clone(), None)).collect());
        }
        let entry = from == text.lines[line] && file_kind(&self.path) == FileKind::Bib;
        if let Some(at) = ENTRY_TYPE.captures(&before).filter(|_| entry) {
            let at = at.get(1).unwrap();
            let names = matching(&catalog.bib_entry_types, &at.as_str()[1..], |t| t).into_iter();
            let items = names.map(|name| word(format!("@{name}"), None));
            return offer(at.start(), SymbolKind::EntryType, items.collect());
        }
        let m = COMMAND.find(&before).filter(|m| m.len() > 1 || explicit)?;
        let complete = |name: &String, snippet: &str| {
            let (text, fields) = expand(text, caret, snippet);
            Completion {
                label: name.clone(),
                text,
                fields,
                detail: None,
            }
        };
        let own = self.symbols.firsts(|d| &d.commands, |c| &c.name);
        let mut items: Vec<Completion> = matching(&own, m.as_str(), |c| &c.name)
            .into_iter()
            .map(|c| {
                complete(
                    &c.name,
                    &format!("{}{}", c.name, "{#{}}".repeat(c.arguments)),
                )
            })
            .collect();
        let others = matching(&catalog.commands, m.as_str(), |c| &c.0).into_iter();
        let others = others.filter(|(name, _)| !own.iter().any(|c| c.name == *name));
        items.extend(others.map(|(name, snippet)| complete(name, snippet)));
        offer(m.start(), SymbolKind::Command, items)
    }

    pub(crate) fn definition(&self, at: u32) -> Option<Definition> {
        let own = Facts::read(&self.text(), file_kind(&self.path));
        let (kind, name, file) = self.symbol_at(&own, at)?;
        let places = match kind {
            SymbolKind::File => {
                let start = Place {
                    line: 1,
                    column: 0,
                    length: 0,
                };
                file.map(|file| (file, start)).into_iter().collect()
            }
            kind => self.defined(&own, kind, &name),
        };
        let places: Vec<FilePlace> = places
            .into_iter()
            .map(|(file, at)| at.in_file(file))
            .collect();
        (!places.is_empty()).then_some(Definition { kind, name, places })
    }

    pub(crate) fn symbol(&self, at: u32) -> Option<SymbolName> {
        let text = &self.text;
        let line = text.line_index(at.min(text.len()));
        let blank = |&index: &usize| scan::blank_line(text.line(index));
        let first = line.saturating_sub(PARAGRAPH);
        let first = (first..line)
            .rev()
            .find(blank)
            .map_or(first, |blank| blank + 1);
        let last = (line + 1..text.lines.len()).take(PARAGRAPH).find(blank);
        let window = (line + PARAGRAPH).min(text.lines.len() - 1);
        let end = last.map_or_else(|| text.bounds(window).end, |last| text.lines[last] as usize);
        let paragraph = utf16::lossy(&text.units[text.lines[first] as usize..end]);
        let own = Facts::read(&paragraph, file_kind(&self.path));
        let (kind, name, _) = self.symbol_in(&own, first, at)?;
        Some(SymbolName { kind, name })
    }

    pub fn symbol_at(&self, own: &Facts, at: u32) -> Option<(SymbolKind, String, Option<String>)> {
        self.symbol_in(own, 0, at)
    }

    fn symbol_in(
        &self,
        own: &Facts,
        first: usize,
        at: u32,
    ) -> Option<(SymbolKind, String, Option<String>)> {
        let (text, at) = (&self.text, at.min(self.text.len()));
        let line = text.line_index(at);
        let column = at - text.lines[line];
        let holds = |place: &Place| {
            place.line as usize + first == line + 1
                && (place.column..=place.column + place.length).contains(&column)
        };
        let found = |rel: &str| self.symbols.spelt(rel);
        if let Some(input) = own.inputs.iter().find(|input| holds(&input.place)) {
            let file = input_file(input, &self.path, found);
            return Some((SymbolKind::File, input.name.clone(), file));
        }
        let uses = own.uses.iter().rev();
        let mut names = uses
            .chain(&own.defined.labels)
            .chain(&own.defined.citations);
        let named = names.find(|named| holds(&named.place))?;
        let file = (named.kind == SymbolKind::File)
            .then(|| graphic(&named.name, found))
            .flatten();
        Some((named.kind, named.name.clone(), file))
    }

    pub fn defined(&self, own: &Facts, kind: SymbolKind, name: &str) -> Vec<(String, Place)> {
        let others = self.symbols.by_file.iter();
        let others = others.filter(|(file, _)| **file != self.path);
        let mut files: Vec<(&str, &Definitions)> = others
            .map(|(file, defined)| (&**file, &**defined))
            .collect();
        files.push((&self.path, &own.defined));
        files.sort_by_key(|&(file, _)| file);
        let places = files.into_iter().flat_map(|(file, defined)| {
            let places = definitions(defined, kind, name).into_iter();
            places.map(move |at| (file.to_owned(), at))
        });
        places.collect()
    }
}

pub fn definitions(defined: &Definitions, kind: SymbolKind, name: &str) -> Vec<Place> {
    let named = |list: &[Named]| -> Vec<Place> {
        let list = list.iter().filter(|named| named.name == name);
        list.map(|named| named.place).collect()
    };
    match kind {
        SymbolKind::Label => named(&defined.labels),
        SymbolKind::Citation => named(&defined.citations),
        SymbolKind::Environment => named(&defined.environments),
        _ => {
            let commands = defined.commands.iter().filter(|c| c.name == name);
            commands.map(|c| c.place).collect()
        }
    }
}

pub fn usages(
    facts: &Facts,
    file: &str,
    kind: SymbolKind,
    name: &str,
    found: impl Fn(&str) -> Option<String>,
) -> Vec<Place> {
    let mut places = if kind == SymbolKind::File {
        let inputs = facts
            .inputs
            .iter()
            .filter(|input| input_file(input, file, &found).as_deref() == Some(name));
        let graphics = facts.uses.iter().filter(|used| {
            used.kind == kind && graphic(&used.name, &found).as_deref() == Some(name)
        });
        let places = inputs.map(|input| input.place);
        places.chain(graphics.map(|used| used.place)).collect()
    } else {
        let used = facts
            .uses
            .iter()
            .filter(|used| used.kind == kind && used.name == name);
        let mut places = definitions(&facts.defined, kind, name);
        places.extend(used.map(|used| used.place));
        places
    };
    places.sort_by_key(|place| (place.line, place.column));
    places.dedup();
    places
}

fn input_file(input: &Input, file: &str, found: impl Fn(&str) -> Option<String>) -> Option<String> {
    let parent = file.rsplit_once('/').map_or("", |(parent, _)| parent);
    let named = input.resolve(file, "", &found);
    let named = named.or_else(|| input.resolve(file, parent, &found));
    named.map(|(named, _)| named)
}

fn graphic(name: &str, found: impl Fn(&str) -> Option<String>) -> Option<String> {
    GRAPHICS
        .iter()
        .find_map(|ext| found(&format!("{name}{ext}")))
}

const PARAGRAPH: usize = 32;

const GRAPHICS: [&str; 6] = ["", ".pdf", ".png", ".jpg", ".jpeg", ".eps"];

fn word(label: String, detail: Option<String>) -> Completion {
    Completion {
        text: label.clone(),
        label,
        fields: vec![],
        detail,
    }
}

fn described(named: Vec<&Named>) -> Vec<Completion> {
    let word = |n: &Named| word(n.name.clone(), n.detail.clone());
    named.into_iter().map(word).collect()
}

enum At {
    Start,
    Word,
    Anywhere,
}

fn finder(typed: &str) -> impl Fn(&str, At) -> bool + '_ {
    let lower = typed.to_lowercase();
    move |name, at| {
        let folded;
        let (name, typed) = if typed.is_ascii() && name.is_ascii() {
            (name, typed)
        } else {
            folded = name.to_lowercase();
            (folded.as_str(), lower.as_str())
        };
        let here = |i: usize| {
            let part = name.as_bytes().get(i..i + typed.len());
            part.is_some_and(|part| part.eq_ignore_ascii_case(typed.as_bytes()))
        };
        let word = |i: usize| {
            let before = name.get(..i).map(|before| before.chars().next_back());
            before.is_some_and(|c| c.is_none_or(|c| !c.is_alphanumeric()))
        };
        match at {
            At::Start => here(0),
            At::Word => (0..=name.len()).any(|i| word(i) && here(i)),
            At::Anywhere => (0..=name.len()).any(here),
        }
    }
}

fn matching<'a, T>(items: &'a [T], typed: &str, name: impl Fn(&T) -> &String) -> Vec<&'a T> {
    let found = finder(typed);
    let (mut exact, folded): (Vec<_>, Vec<_>) = items
        .iter()
        .filter(|i| found(name(i), At::Start))
        .partition(|i| name(i).starts_with(typed));
    exact.extend(folded);
    exact
}

fn cited<'a>(citations: &[&'a Named], typed: &str) -> Vec<&'a Named> {
    let found = finder(typed);
    let starts = matching(citations, typed, |c| &c.name).into_iter().copied();
    let others = citations
        .iter()
        .copied()
        .filter(|c| !found(&c.name, At::Start));
    let (keys, others): (Vec<_>, Vec<_>) = others.partition(|c| found(&c.name, At::Anywhere));
    let detailed = |c: &&Named| c.detail.as_deref().is_some_and(|d| found(d, At::Word));
    starts
        .chain(keys)
        .chain(others.into_iter().filter(detailed))
        .collect()
}

pub(crate) fn expand(source: &Text, at: u32, snippet: &str) -> (String, Vec<SnippetField>) {
    let line = source.line(source.line_index(at));
    let indentation = String::from_utf16_lossy(&line[..indentation(line)]);
    let snippet = snippet
        .replace('\t', INDENT)
        .replace('\n', &format!("\n{indentation}"));
    let mut names = Vec::new();
    let mut fields = Vec::new();
    let text = FIELD.replace_all(&snippet, |c: &regex::Captures| {
        let (whole, name) = (c.get_match(), &c[1]);
        let index = names
            .iter()
            .position(|previous| !name.is_empty() && previous == name)
            .unwrap_or_else(|| {
                names.push(name.to_owned());
                names.len() - 1
            });
        fields.push(SnippetField {
            start: (utf16::len(&snippet[..whole.start()]) - 3 * fields.len()) as u32,
            length: utf16::len(name) as u32,
            index: index as u32,
        });
        name.to_owned()
    });
    (text.into_owned(), fields)
}
