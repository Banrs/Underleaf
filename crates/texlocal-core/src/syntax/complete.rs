//! Completion: an argument's labels, citations, environments or files, a bibliography entry's type, or a command.
//! Commands are snippets, expanded here, so an editor only places the text and its fields.

use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use super::{SourceDocument, Text, catalog, indentation, utf16};
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
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CompletionKind {
    Command,
    Environment,
    Label,
    Citation,
    EntryType,
    File,
}

/// What the project defines that completion offers, one the session's documents share.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Symbols {
    pub citations: Vec<String>,
    pub labels: Vec<String>,
    /// The project's, from its folder, to complete a file's name.
    pub files: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Completions {
    pub start: u32,
    pub kind: CompletionKind,
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
        let offer = |start: usize, kind: CompletionKind, items: Vec<Completion>| {
            (!items.is_empty()).then(|| Completions {
                start: from + utf16(&before[..start]) as u32,
                kind,
                items,
            })
        };

        if let Some(c) = ARGUMENT.captures(&before) {
            let files: Vec<String>;
            let (names, kind): (&[String], _) = match &c[1] {
                c if catalog.cite_commands.contains(c) => {
                    (&self.symbols.citations, CompletionKind::Citation)
                }
                c if catalog.ref_commands.contains(c) => {
                    (&self.symbols.labels, CompletionKind::Label)
                }
                "begin" | "end" => (&catalog.environments, CompletionKind::Environment),
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
                    files = self
                        .symbols
                        .files
                        .iter()
                        .filter(|file| kinds.contains(&file_kind(file)))
                        .map(|file| match file.rsplit_once('.') {
                            Some((stem, _)) if bare => stem.to_owned(),
                            _ => file.clone(),
                        })
                        .collect();
                    (&files, CompletionKind::File)
                }
            };
            let start = before.rfind(['{', ',']).map_or(0, |i| i + 1);
            let start = before.len() - before[start..].trim_start().len();
            let items = words(matching(names, &before[start..], |n| n), "");
            return offer(start, kind, items);
        }
        // In a .bib file; `before` starts at the line's start unless the line is long.
        let whole_line = from == text.lines[line];
        if let Some(at) = ENTRY_TYPE.captures(&before).filter(|_| whole_line) {
            let at = at.get(1).unwrap();
            let names = matching(&catalog.bib_entry_types, &at.as_str()[1..], |t| t);
            return offer(at.start(), CompletionKind::EntryType, words(names, "@"));
        }
        let m = COMMAND.find(&before).filter(|m| m.len() > 1 || explicit)?;
        let items = matching(&catalog.commands, m.as_str(), |c| &c.0)
            .into_iter()
            .map(|(name, snippet)| {
                let (text, fields) = expand(text, caret, snippet);
                Completion {
                    label: name.clone(),
                    text,
                    fields,
                }
            })
            .collect();
        offer(m.start(), CompletionKind::Command, items)
    }
}

fn words(names: Vec<&String>, prefix: &str) -> Vec<Completion> {
    names
        .into_iter()
        .map(|name| {
            let label = format!("{prefix}{name}");
            Completion {
                text: label.clone(),
                label,
                fields: vec![],
            }
        })
        .collect()
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

    use super::{Completion, SnippetField, Symbols};
    use crate::syntax::SourceDocument;

    fn offered(before: &str, keys: &[String]) -> Vec<Completion> {
        let mut doc = SourceDocument::new(before);
        doc.set_symbols(Arc::new(Symbols {
            citations: keys.to_vec(),
            ..Symbols::default()
        }));
        let offer = doc.completions(before.encode_utf16().count() as u32, false);
        offer.map_or(vec![], |offer| offer.items)
    }

    fn labels(before: &str, keys: &[String]) -> Vec<String> {
        offered(before, keys).into_iter().map(|i| i.label).collect()
    }

    fn places(fields: &[SnippetField]) -> Vec<(u32, u32, u32)> {
        fields
            .iter()
            .map(|f| (f.start, f.length, f.index))
            .collect()
    }

    #[test]
    fn snippets_expand_with_their_fields() {
        let begin = offered("  \\beg", &[]).remove(0);
        assert_eq!(begin.text, "\\begin{env}\n    \n  \\end{env}");
        assert_eq!(places(&begin.fields), [(7, 3, 0), (16, 0, 1), (24, 3, 0)]);
        let section = offered("\\sub", &[]).remove(0);
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
        let mut doc = SourceDocument::new("");
        doc.set_symbols(Arc::new(Symbols {
            files: files.map(String::from).to_vec(),
            ..Symbols::default()
        }));
        let mut offered = |before: &str| -> Vec<String> {
            doc.edit(0, u32::MAX, before);
            let offer = doc.completions(before.encode_utf16().count() as u32, false);
            offer.map_or(vec![], |offer| {
                offer.items.into_iter().map(|i| i.label).collect()
            })
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
    fn case_matches_come_first() {
        let names = labels("\\s", &[]);
        let upper = names.iter().position(|n| n == "\\Sigma").unwrap();
        assert!(names[..upper].iter().all(|n| n.starts_with("\\s")));
    }

    #[test]
    fn keys_match_lowercased_whole() {
        let keys = ["Knuth84", "knuth86", "Émile", "émile2", "Kn"].map(String::from);
        let offered = |typed: &str| labels(&format!("\\cite{{{typed}"), &keys);
        assert_eq!(offered("kn"), ["knuth86", "Knuth84", "Kn"]);
        assert_eq!(offered("KNUTH"), ["Knuth84", "knuth86"]);
        assert_eq!(offered("knu"), ["knuth86", "Knuth84"]);
        assert_eq!(offered("é"), ["émile2", "Émile"]);
        assert_eq!(offered("ÉMILE"), ["Émile", "émile2"]);
        assert_eq!(offered("\u{212a}n"), ["Knuth84", "knuth86", "Kn"]);
    }
}
