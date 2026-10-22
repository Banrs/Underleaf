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
    pub labels: Vec<Named>,
    pub commands: Vec<Defined>,
    pub environments: Vec<String>,
    /// The project's, from its folder, to complete a file's name.
    pub files: Vec<String>,
    /// Each .tex and .bib file's, by its name.
    pub by_file: BTreeMap<String, Arc<Facts>>,
    pub installed: Arc<Installed>,
}

/// The names, without their extensions, of the .sty, .cls, .bst and .tex files the installed TeX
/// has, each list sorted.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Installed {
    pub packages: Vec<String>,
    pub classes: Vec<String>,
    pub styles: Vec<String>,
    /// What `\input` finds outside the project.
    pub inputs: Vec<String>,
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
    pub fn completions(&mut self, caret: u32, explicit: bool) -> Option<Completions> {
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
            let installed = &self.symbols.installed;
            let (names, kind): (&[String], _) = match &c[1] {
                c if catalog.cite_commands.contains(c) => {
                    let cited = cited(&self.symbols.citations, typed);
                    return offer(start, SymbolKind::Citation, described(cited));
                }
                c if catalog.ref_commands.contains(c) => {
                    let labels = matching(&self.symbols.labels, typed, |l| &l.name);
                    return offer(start, SymbolKind::Label, described(labels));
                }
                "begin" | "end" => {
                    // The environment an \end closes comes first, for Return to complete.
                    let mut open = None;
                    if &c[1] == "end" {
                        let at = from as usize + utf16(&before[..c.get(0).unwrap().start()]);
                        let mut scanner = self.scans.resume(text, at, at).scanner;
                        scanner.run(&text.units[..at], at, &[], &mut ());
                        let mut groups = scanner.groups().into_iter().rev();
                        open = groups.find_map(|g| Some(g.end.strip_prefix("env:")?.to_owned()));
                    }
                    let own = &self.symbols.environments;
                    let others = catalog.environments.iter().filter(|e| !own.contains(e));
                    let rest = own
                        .iter()
                        .chain(others)
                        .filter(|e| Some(*e) != open.as_ref());
                    listed = open.iter().chain(rest).cloned().collect();
                    (&listed, SymbolKind::Environment)
                }
                "usepackage" | "RequirePackage" => (&installed.packages, SymbolKind::File),
                "documentclass" => (&installed.classes, SymbolKind::File),
                "bibliographystyle" => (&installed.styles, SymbolKind::File),
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

fn described(named: Vec<&Named>) -> Vec<Completion> {
    let word = |n: &Named| word(n.name.clone(), n.detail.clone());
    named.into_iter().map(word).collect()
}

/// Where in a name what was typed is found, regardless of case.
enum At {
    Start,
    Word,
    Anywhere,
}

/// ASCII names are compared in place: lowercasing a copy per key was most of a citation's offer. Others are
/// lowercased by Unicode's full mapping, which may lower a character to ASCII (the kelvin sign).
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

/// Keys that start with what was typed, then those that hold it, then those whose entry's
/// authors, year or title has a word that starts with it.
fn cited<'a>(citations: &'a [Named], typed: &str) -> Vec<&'a Named> {
    let found = finder(typed);
    let mut cited = matching(citations, typed, |c| &c.name);
    let mut others: Vec<(bool, &Named)> = citations
        .iter()
        .filter(|c| !found(&c.name, At::Start))
        .filter_map(|c| {
            let key = found(&c.name, At::Anywhere);
            let detail = || c.detail.as_deref().is_some_and(|d| found(d, At::Word));
            (key || detail()).then_some((!key, c))
        })
        .collect();
    others.sort_by_key(|&(by_detail, _)| by_detail);
    cited.extend(others.into_iter().map(|(_, c)| c));
    cited
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

    use super::{Completion, Defined, Installed, Place, SnippetField, Symbols};
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
    fn a_files_argument_offers_the_projects_or_the_installed_files_of_its_kind() {
        let files = [
            "chapters/One.TEX",
            "figs/a.png",
            "figs/b.pdf",
            "main.tex",
            "notes.txt",
            "refs.bib",
        ];
        let names = |names: &[&str]| names.iter().map(|&n| n.into()).collect();
        let offered = |before: &str| {
            let symbols = Symbols {
                files: files.map(String::from).to_vec(),
                installed: Arc::new(Installed {
                    packages: names(&["amsmath", "amsthm", "graphicx"]),
                    classes: names(&["article"]),
                    styles: names(&["plain"]),
                    ..Installed::default()
                }),
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
        assert_eq!(
            offered("\\usepackage[x]{graphicx,ams"),
            ["amsmath", "amsthm"]
        );
        assert_eq!(offered("\\RequirePackage{g"), ["graphicx"]);
        assert_eq!(offered("\\documentclass{"), ["article"]);
        assert_eq!(offered("\\bibliographystyle{"), ["plain"]);
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
            tex: None,
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
    fn an_end_offers_the_environment_it_closes_first() {
        let open =
            "\\begin{document}\n\\begin{itemize}\\begin{center}\\end{center}\n\\item x\n\\end{";
        assert_eq!(
            labels(open, Symbols::default())[..2],
            ["itemize", "document"]
        );
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
    fn a_citation_is_found_in_its_key_then_by_a_word_of_its_entry() {
        let bib = "@book{knuth84, author = {Knuth}, year = 1984, title = {The TeXbook}}\n\
            @book{texbook2, author = {Donald Knuth}, title = {Computers}}\n@misc{dk-knuth,}\n\
            @misc{lamport94, author = {Lamport}, year = 1994, title = {LaTeX}}";
        let offered = |typed: &str| {
            let symbols = Symbols {
                citations: crate::analyze::Facts::read(bib, "bib").citations,
                ..Symbols::default()
            };
            labels(&format!("\\cite{{{typed}"), symbols)
        };
        assert_eq!(offered("knuth"), ["knuth84", "dk-knuth", "texbook2"]);
        assert_eq!(offered("TEX"), ["texbook2", "knuth84"]);
        assert_eq!(offered("199"), ["lamport94"]);
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
