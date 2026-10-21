//! Completion: an argument's labels, citations, environments or files, a bibliography entry's type, or a command;
//! environments and commands the project's own first.
//! Commands are snippets, expanded here, so an editor only places the text and its fields.
//! And definitions: where the project defines the name at a place.

use std::collections::BTreeMap;
use std::sync::{Arc, LazyLock};

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{SourceDocument, Text, catalog, escaped, indentation, is, letter, utf16};
use crate::analyze::{Defined, Facts, Named, Place};
use crate::paths;
use crate::projects::file_kind;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnippetField {
    pub start: u32,
    pub length: u32,
    pub index: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Completion {
    pub label: String,
    pub text: String,
    pub fields: Vec<SnippetField>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// What completion offers, and what a definition is of.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SymbolKind {
    Command,
    Environment,
    Label,
    Citation,
    EntryType,
    File,
}

/// What the project defines, one the session's documents share: the first of each name for
/// completion, and each file's facts for definitions.
#[derive(Default)]
pub struct Symbols {
    pub citations: Vec<Named>,
    pub labels: Vec<String>,
    pub commands: Vec<Defined>,
    pub environments: Vec<String>,
    /// The project's, from its folder, to complete a file's name.
    pub files: Vec<String>,
    /// Each .tex and .bib file's, by its name.
    pub by_file: BTreeMap<String, Arc<Facts>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Completions {
    pub start: u32,
    pub kind: SymbolKind,
    pub items: Vec<Completion>,
}

/// The innermost open argument's command. Its tail has no braces or
/// backslashes, so `\footnote{see \cite{` is \cite's and `\frac{\al` none's.
static ARGUMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\([0-9A-Za-z_]+)\*?(\[[^\]]*\])?\{[^{}\\]*$").unwrap());
/// A bibliography entry's type starts its line, after any indentation:
/// anywhere else an "@" is an email address's or a package command's.
static ENTRY_TYPE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(@[0-9A-Za-z_]*)$").unwrap());
static COMMAND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\[0-9A-Za-z_]*$").unwrap());
static FIELD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"#\{([^}]*)\}").unwrap());

impl SourceDocument {
    pub fn completions(&self, caret: u32, explicit: bool) -> Option<Completions> {
        let (text, caret) = (&self.text, caret.min(self.text.len()));
        let line = text.line_index(caret);
        let from = text.lines[line].max(caret.saturating_sub(250));
        let before = String::from_utf16_lossy(&text.units[from as usize..caret as usize]);
        let catalog = &*catalog::CATALOG;
        let offer = |start: usize, kind: SymbolKind, items: Vec<Completion>| {
            (!items.is_empty()).then(|| Completions {
                start: from + utf16(&before[..start]) as u32,
                kind,
                items,
            })
        };

        if let Some(c) = ARGUMENT.captures(&before) {
            let start = before.rfind(['{', ',']).map_or(0, |i| i + 1);
            let start = before.len() - before[start..].trim_start().len();
            let typed = &before[start..];
            let listed: Vec<String>;
            let (names, kind): (&[String], _) = match &c[1] {
                c if catalog.cite_commands.contains(c) => {
                    let cited = matching(&self.symbols.citations, typed, |c| &c.name).into_iter();
                    let items = cited.map(|c| word(c.name.clone(), c.detail.clone()));
                    return offer(start, SymbolKind::Citation, items.collect());
                }
                c if catalog.ref_commands.contains(c) => (&self.symbols.labels, SymbolKind::Label),
                "begin" | "end" => {
                    let own = &self.symbols.environments;
                    let others = catalog.environments.iter().filter(|e| !own.contains(e));
                    listed = own.iter().chain(others).cloned().collect();
                    (&listed, SymbolKind::Environment)
                }
                command => {
                    // \input's and \bibliography's names go without their extension, as LaTeX
                    // takes them.
                    let (kinds, bare): (&[&str], _) = match command {
                        "input" | "include" | "subfile" => (&["tex"], true),
                        "includegraphics" => (&["image", "pdf"], false),
                        "bibliography" => (&["bib"], true),
                        "addbibresource" => (&["bib"], false),
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
        // In a .bib file; `before` starts at the line's start unless the line is long.
        let whole_line = from == text.lines[line];
        if let Some(at) = ENTRY_TYPE.captures(&before).filter(|_| whole_line) {
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
        let own = &self.symbols.commands;
        let mut items: Vec<Completion> = matching(own, m.as_str(), |c| &c.name)
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

    /// The name at `at` and where the project defines it: a label, citation, environment or
    /// command, from the last scan and this document as it is now, or the file an input or a
    /// graphic names, from its start. None where no name is, or nothing defines it.
    pub fn definition(&self, at: u32) -> Option<Value> {
        let (text, at) = (&self.text, at.min(self.text.len()));
        let own = Facts::read(&self.text(), file_kind(&self.path));
        let line = text.line_index(at);
        let column = at - text.lines[line];
        let holds = |place: &Place| {
            place.line as usize == line + 1
                && (place.column..=place.column + place.length).contains(&column)
        };
        let found = |rel: &str| {
            let rel = paths::fold_case(&paths::rel_key(rel).ok()?);
            let mut files = self.symbols.files.iter();
            files.find(|file| paths::fold_case(file) == rel).cloned()
        };
        let start = |file: Option<String>| -> Vec<Value> {
            let start = |file| json!({ "file": file, "line": 1, "column": 0, "length": 0 });
            file.map(start).into_iter().collect()
        };
        let (kind, name, places) =
            if let Some(input) = own.inputs.iter().find(|input| holds(&input.place)) {
                let parent = self.path.rsplit_once('/').map_or("", |(parent, _)| parent);
                // The folder an \import gave this file isn't known here: the main file's is the
                // likeliest, then the file's own.
                let file = input.resolve(&self.path, "", found);
                let file = file.or_else(|| input.resolve(&self.path, parent, found));
                let places = start(file.map(|(file, _)| file));
                (SymbolKind::File, input.name.clone(), places)
            } else if let Some(used) = own.uses.iter().find(|used| holds(&used.place)) {
                let name = &used.name;
                let places = match used.kind {
                    SymbolKind::File => {
                        let graphic = GRAPHICS.iter().find_map(|ext| found(&(name.clone() + ext)));
                        start(graphic)
                    }
                    kind => self.defined(&own, kind, name),
                };
                (used.kind, name.clone(), places)
            } else if let Some((kind, named)) = [
                (SymbolKind::Label, &own.labels),
                (SymbolKind::Citation, &own.citations),
            ]
            .into_iter()
            .find_map(|(kind, list)| Some((kind, list.iter().find(|n| holds(&n.place))?)))
            {
                // At a definition itself, so Rename can start there as from a reference.
                (
                    kind,
                    named.name.clone(),
                    self.defined(&own, kind, &named.name),
                )
            } else {
                let units = &text.units;
                let at = at as usize;
                // The backslash is the command's too.
                let at = at + usize::from(units.get(at).is_some_and(|&u| is(u, '\\')));
                let start = at - units[..at].iter().rev().take_while(|&&u| letter(u)).count();
                let end = at + units[at..].iter().take_while(|&&u| letter(u)).count();
                let slash = start.checked_sub(1).filter(|&slash| {
                    start < end && is(units[slash], '\\') && !escaped(units, slash)
                })?;
                let name = String::from_utf16_lossy(&units[slash..end]);
                let places = self.defined(&own, SymbolKind::Command, &name);
                (SymbolKind::Command, name, places)
            };
        (!places.is_empty()).then(|| json!({ "kind": kind, "name": name, "places": places }))
    }

    /// Where each file defines `name` as a `kind`, the files in the order of their names, this
    /// one as it is now, `own`.
    fn defined(&self, own: &Facts, kind: SymbolKind, name: &str) -> Vec<Value> {
        let others = self.symbols.by_file.iter();
        let others = others.filter(|(file, _)| **file != self.path);
        let mut files: Vec<(&str, &Facts)> =
            others.map(|(file, facts)| (&**file, &**facts)).collect();
        files.push((&self.path, own));
        files.sort_by_key(|&(file, _)| file);
        let named = |list: &[Named]| -> Vec<Place> {
            let list = list.iter().filter(|named| named.name == name);
            list.map(|named| named.place).collect()
        };
        let places = files.into_iter().flat_map(|(file, facts)| {
            let places = match kind {
                SymbolKind::Label => named(&facts.labels),
                SymbolKind::Citation => named(&facts.citations),
                SymbolKind::Environment => named(&facts.environments),
                _ => {
                    let commands = facts.commands.iter().filter(|c| c.name == name);
                    commands.map(|c| c.place).collect()
                }
            };
            places.into_iter().map(move |at| {
                json!({ "file": file, "line": at.line, "column": at.column, "length": at.length })
            })
        });
        places.collect()
    }
}

/// A graphic named without its extension is looked for with pdfTeX's, in its order.
const GRAPHICS: [&str; 6] = ["", ".pdf", ".png", ".jpg", ".jpeg", ".eps"];

/// An item that is the name it shows, as an argument's names are.
fn word(label: String, detail: Option<String>) -> Completion {
    Completion {
        text: label.clone(),
        label,
        fields: vec![],
        detail,
    }
}

fn matching<'a, T>(items: &'a [T], typed: &str, name: impl Fn(&T) -> &String) -> Vec<&'a T> {
    let (lower, ascii) = (typed.to_lowercase(), typed.is_ascii());
    // ASCII names are compared in place: lowercasing a copy per key was most of a citation's offer. Others are
    // lowercased by Unicode's full mapping, which may lower a character to ASCII (the kelvin sign).
    let starts = |n: &str| {
        if ascii && n.is_ascii() {
            let head = n.as_bytes().get(..typed.len());
            head.is_some_and(|head| head.eq_ignore_ascii_case(typed.as_bytes()))
        } else {
            n.to_lowercase().starts_with(&lower)
        }
    };
    let (mut exact, folded): (Vec<_>, Vec<_>) = items
        .iter()
        .filter(|i| starts(name(i)))
        .partition(|i| name(i).starts_with(typed));
    exact.extend(folded);
    exact
}

/// Fields named "#{name}" show their name as text, and fields with the same name are one; later lines take `at`'s
/// line's indentation, each leading tab one more level (two spaces).
pub(crate) fn expand(source: &Text, at: u32, snippet: &str) -> (String, Vec<SnippetField>) {
    let line = source.line(source.line_index(at));
    let indentation = String::from_utf16_lossy(&line[..indentation(line)]);
    let snippet = snippet
        .replace('\t', "  ")
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
            start: (utf16(&snippet[..whole.start()]) - 3 * fields.len()) as u32,
            length: utf16(name) as u32,
            index: index as u32,
        });
        name.to_owned()
    });
    (text.into_owned(), fields)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::{Completion, Defined, Place, SnippetField, Symbols};
    use crate::syntax::SourceDocument;
    use crate::syntax::tests::cited;

    fn offered(before: &str, symbols: Symbols) -> Vec<Completion> {
        let mut doc = SourceDocument::new(before);
        doc.set_symbols(Arc::new(symbols));
        let offer = doc.completions(before.encode_utf16().count() as u32, false);
        offer.map_or(vec![], |offer| offer.items)
    }

    fn labels(before: &str, symbols: Symbols) -> Vec<String> {
        offered(before, symbols)
            .into_iter()
            .map(|i| i.label)
            .collect()
    }

    fn places(fields: &[SnippetField]) -> Vec<(u32, u32, u32)> {
        fields
            .iter()
            .map(|f| (f.start, f.length, f.index))
            .collect()
    }

    #[test]
    fn snippets_expand_with_their_fields() {
        let begin = offered("  \\beg", Symbols::default()).remove(0);
        assert_eq!(begin.text, "\\begin{env}\n    \n  \\end{env}");
        assert_eq!(places(&begin.fields), [(7, 3, 0), (16, 0, 1), (24, 3, 0)]);
        let section = offered("\\sub", Symbols::default()).remove(0);
        assert_eq!(
            (section.label.as_str(), section.text.as_str()),
            ("\\subsection", "\\subsection{}")
        );
        assert_eq!(places(&section.fields), [(12, 0, 0)]);
        let (text, fields) = super::expand(
            &crate::syntax::Text::new("\t\\beg"),
            5,
            "#{😀}\n\t#{}#{é}#{😀}#{}",
        );
        assert_eq!(text, "😀\n\t  é😀");
        assert_eq!(
            places(&fields),
            [(0, 2, 0), (6, 0, 1), (6, 1, 2), (7, 2, 0), (9, 0, 3)]
        );
    }

    #[test]
    fn a_files_argument_offers_the_projects_files_of_its_kind() {
        let files = [
            "chapters/One.TEX",
            "figs/a.png",
            "figs/b.pdf",
            "main.tex",
            "notes.txt",
            "refs.bib",
        ];
        let offered = |before: &str| {
            let symbols = Symbols {
                files: files.map(String::from).to_vec(),
                ..Symbols::default()
            };
            labels(before, symbols)
        };
        assert_eq!(offered("\\input{"), ["chapters/One", "main"]);
        assert_eq!(offered("\\include{ch"), ["chapters/One"]);
        let graphics = offered("\\includegraphics[width=0.5\\linewidth]{");
        assert_eq!(graphics, ["figs/a.png", "figs/b.pdf"]);
        assert_eq!(offered("\\bibliography{main,"), ["refs"]);
        assert_eq!(offered("\\addbibresource{"), ["refs.bib"]);
        assert!(offered("\\usepackage{").is_empty());
    }

    #[test]
    fn the_projects_own_commands_and_environments_come_first_with_their_arguments() {
        let defined = |name: &str, arguments| Defined {
            name: name.into(),
            arguments,
            place: Place {
                line: 1,
                column: 0,
                length: 0,
            },
        };
        let symbols = || Symbols {
            commands: vec![defined("\\pair", 2), defined("\\frac", 1)],
            environments: vec!["thm".into(), "theorem".into()],
            ..Symbols::default()
        };
        let pair = offered("\\pa", symbols()).remove(0);
        assert_eq!(
            (pair.label.as_str(), pair.text.as_str()),
            ("\\pair", "\\pair{}{}")
        );
        assert_eq!(places(&pair.fields), [(6, 0, 0), (8, 0, 1)]);
        let fracs = offered("\\fra", symbols());
        assert_eq!(fracs.iter().filter(|c| c.label == "\\frac").count(), 1);
        assert_eq!(fracs[0].text, "\\frac{}");
        let names = labels("\\begin{th", symbols());
        assert_eq!(names, ["thm", "theorem", "thebibliography"]);
    }

    #[test]
    fn case_matches_come_first() {
        let names = labels("\\s", Symbols::default());
        let upper = names.iter().position(|n| n == "\\Sigma").unwrap();
        assert!(names[..upper].iter().all(|n| n.starts_with("\\s")));
    }

    #[test]
    fn keys_match_lowercased_whole() {
        let keys = ["Knuth84", "knuth86", "Émile", "émile2", "Kn"];
        let offered = |typed: &str| {
            let symbols = Symbols {
                citations: cited(&keys),
                ..Symbols::default()
            };
            labels(&format!("\\cite{{{typed}"), symbols)
        };
        assert_eq!(offered("kn"), ["knuth86", "Knuth84", "Kn"]);
        assert_eq!(offered("KNUTH"), ["Knuth84", "knuth86"]);
        assert_eq!(offered("knu"), ["knuth86", "Knuth84"]);
        assert_eq!(offered("é"), ["émile2", "Émile"]);
        assert_eq!(offered("ÉMILE"), ["Émile", "émile2"]);
        assert_eq!(offered("\u{212a}n"), ["Knuth84", "knuth86", "Kn"]);
    }

    #[test]
    fn a_citation_says_what_its_entry_is() {
        let bib = "@book{knuth, author = {Knuth}, year = 1984}\n@misc{kn,}";
        let symbols = Symbols {
            citations: crate::analyze::Facts::read(bib, "bib").citations,
            ..Symbols::default()
        };
        let items = offered("\\cite{kn", symbols);
        let item = |i: usize| serde_json::to_value(&items[i]).unwrap();
        assert_eq!(item(0)["detail"], "Knuth · 1984");
        assert_eq!(item(1).get("detail"), None, "none to say");
    }
}
