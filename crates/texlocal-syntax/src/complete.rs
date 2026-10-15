//! Completion: an argument's labels, citations or environments, a
//! bibliography entry's type, or a command. Commands are snippets, expanded
//! here, so an editor only places the text and its fields.

use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::{Text, catalog, is, utf16};

/// A place to type in a completion's text. Fields with the same `index`
/// are one field in several places: what's typed in one goes in all.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SnippetField {
    /// From the start of the completion's text, in UTF-16 units.
    pub start: u32,
    pub length: u32,
    /// The field's place in the order Tab goes through them, from 0.
    pub index: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Completion {
    pub label: String,
    /// What goes in, with the fields' defaults and the line's indentation.
    pub text: String,
    /// In order of position.
    pub fields: Vec<SnippetField>,
}

/// What an offer's items are, all of them: the list they were drawn from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CompletionKind {
    Command,
    Environment,
    Label,
    Citation,
    EntryType,
}

/// Completions for the text from `start` to the caret, which they replace.
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
static ENTRY_TYPE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"@[0-9A-Za-z_]*$").unwrap());
static COMMAND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\[0-9A-Za-z_]*$").unwrap());
static FIELD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"#\{([^}]*)\}").unwrap());

pub fn completions(
    text: &Text,
    caret: u32,
    explicit: bool,
    labels: &[String],
    citations: &[String],
) -> Option<Completions> {
    let line = text.line_index(caret);
    // The caret's line, at most 250 units back.
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
    let listed = |list: &[String], name: &str| list.iter().any(|n| n == name);

    if let Some(c) = ARGUMENT.captures(&before) {
        let (names, kind) = match &c[1] {
            c if listed(&catalog.cite_commands, c) => (citations, CompletionKind::Citation),
            c if listed(&catalog.ref_commands, c) => (labels, CompletionKind::Label),
            "begin" | "end" => (&catalog.environments[..], CompletionKind::Environment),
            _ => return None,
        };
        let start = before.rfind(['{', ',']).map_or(0, |i| i + 1);
        let items = words(matching(names, &before[start..], |n| n), "");
        return offer(start, kind, items);
    }
    // @article and the like, in a .bib file.
    if let Some(m) = ENTRY_TYPE.find(&before) {
        let names = matching(&catalog.bib_entry_types, &m.as_str()[1..], |t| t);
        return offer(m.start(), CompletionKind::EntryType, words(names, "@"));
    }
    // \command, once a letter follows the backslash.
    let m = COMMAND.find(&before).filter(|m| m.len() > 1 || explicit)?;
    let items = matching(&catalog.commands, m.as_str(), |c| &c.0)
        .into_iter()
        .map(|(name, _, snippet)| {
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

/// Literal names, with `@` prefixed for bibliography entry types.
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

/// The items whose names start with what's typed, those with its case first.
fn matching<'a, T>(items: &'a [T], typed: &str, name: impl Fn(&T) -> &String) -> Vec<&'a T> {
    let (lower, ascii) = (typed.to_lowercase(), typed.is_ascii());
    // ASCII names, as the catalog's and most keys are, are compared in
    // place: lowercasing a copy of each, at every key typed, was most of a
    // citation's offer. Others are lowercased whole, by Unicode's full
    // mapping, which may lower a character to ASCII (the kelvin sign to k).
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

/// A snippet's text and fields as it goes in at `at`: "#{name}" fields show
/// their name as their text, and fields with the same name are one; a line
/// after the first takes `at`'s line's indentation, and each leading tab one
/// more level (two spaces, the editor's indent unit).
pub(crate) fn expand(source: &Text, at: u32, snippet: &str) -> (String, Vec<SnippetField>) {
    let line = source.line(source.line_index(at));
    let indent = line
        .iter()
        .take_while(|&&u| is(u, ' ') || is(u, '\t'))
        .count();
    let indentation = String::from_utf16_lossy(&line[..indent]);
    // Catalog tabs are indentation; preserve any tabs in the source's indent.
    let snippet = snippet
        .replace('\t', "  ")
        .replace('\n', &format!("\n{indentation}"));
    let mut names = Vec::new();
    let mut fields = Vec::new();
    let text = FIELD.replace_all(&snippet, |c: &regex::Captures| {
        let (whole, name) = (c.get_match(), &c[1]);
        // Unnamed fields are each their own.
        let index = names
            .iter()
            .position(|previous| !name.is_empty() && previous == name)
            .unwrap_or_else(|| {
                names.push(name.to_owned());
                names.len() - 1
            });
        fields.push(SnippetField {
            // Each earlier field lost its three delimiters: "#{" and "}".
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
    use crate::SourceDocument;

    fn complete(before: &str) -> crate::Completion {
        let doc = SourceDocument::new(before);
        let caret = before.encode_utf16().count() as u32;
        doc.completions(caret, false, &[], &[])
            .unwrap()
            .items
            .remove(0)
    }

    #[test]
    fn snippets_expand_with_their_fields() {
        let begin = complete("  \\beg");
        assert_eq!(begin.text, "\\begin{env}\n    \n  \\end{env}");
        let places: Vec<_> = begin
            .fields
            .iter()
            .map(|f| (f.start, f.length, f.index))
            .collect();
        // env twice (one field), then the body; the body's line is indented a level.
        assert_eq!(places, [(7, 3, 0), (16, 0, 1), (24, 3, 0)]);
        let section = complete("\\sub");
        assert_eq!(
            (section.label.as_str(), section.text.as_str()),
            ("\\subsection", "\\subsection{}")
        );
        assert_eq!(
            section
                .fields
                .iter()
                .map(|f| (f.start, f.length))
                .collect::<Vec<_>>(),
            [(12, 0)]
        );
        let (text, fields) =
            super::expand(&crate::Text::new("\t\\beg"), 5, "#{😀}\n\t#{}#{é}#{😀}#{}");
        assert_eq!(text, "😀\n\t  é😀");
        assert_eq!(
            fields
                .iter()
                .map(|f| (f.start, f.length, f.index))
                .collect::<Vec<_>>(),
            [(0, 2, 0), (6, 0, 1), (6, 1, 2), (7, 2, 0), (9, 0, 3)]
        );
    }

    #[test]
    fn an_offer_says_what_its_items_are() {
        use crate::CompletionKind::*;
        let kind = |before: &str| {
            let (labels, citations) = (["sec:a".to_owned()], ["knuth84".to_owned()]);
            let caret = before.encode_utf16().count() as u32;
            SourceDocument::new(before)
                .completions(caret, false, &labels, &citations)
                .map(|offer| offer.kind)
        };
        assert_eq!(kind("\\sec"), Some(Command));
        assert_eq!(kind("\\begin{ite"), Some(Environment));
        assert_eq!(kind("\\ref{"), Some(Label));
        assert_eq!(kind("\\cite{kn"), Some(Citation));
        assert_eq!(kind("@art"), Some(EntryType));
    }

    #[test]
    fn case_matches_come_first() {
        let doc = SourceDocument::new("\\s");
        let names: Vec<_> = doc
            .completions(2, false, &[], &[])
            .unwrap()
            .items
            .into_iter()
            .map(|i| i.label)
            .collect();
        let upper = names.iter().position(|n| n == "\\Sigma").unwrap();
        assert!(names[..upper].iter().all(|n| n.starts_with("\\s")));
    }

    #[test]
    fn keys_match_lowercased_whole() {
        let keys = ["Knuth84", "knuth86", "Émile", "émile2", "Kn"].map(String::from);
        let offered = |typed: &str| -> Vec<String> {
            let before = format!("\\cite{{{typed}");
            let caret = before.encode_utf16().count() as u32;
            SourceDocument::new(&before)
                .completions(caret, false, &[], &keys)
                .map_or(vec![], |offer| {
                    offer.items.into_iter().map(|i| i.label).collect()
                })
        };
        assert_eq!(offered("kn"), ["knuth86", "Knuth84", "Kn"]);
        assert_eq!(offered("KNUTH"), ["Knuth84", "knuth86"]);
        assert_eq!(offered("knu"), ["knuth86", "Knuth84"]);
        assert_eq!(offered("é"), ["émile2", "Émile"]);
        assert_eq!(offered("ÉMILE"), ["Émile", "émile2"]);
        // The kelvin sign lowers to an ASCII k.
        assert_eq!(offered("\u{212a}n"), ["Knuth84", "knuth86", "Kn"]);
    }
}
