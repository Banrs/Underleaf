//! Completion as web/src/editor.js `latexCompletions` offers it: an
//! argument's labels, citations or environments, a bibliography entry's
//! type, or a command. Commands are snippets, expanded here as CodeMirror's
//! `snippet()` expands them, so an editor only places the text and its fields.

use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::{catalog, utf16, Text};

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

/// Completions for the text from `start` to the caret, which they replace.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Completions {
    pub start: u32,
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
    // As CodeMirror's matchBefore: the caret's line, at most 250 units back.
    let from = text.lines[line].max(caret.saturating_sub(250));
    let before = String::from_utf16_lossy(&text.units[from as usize..caret as usize]);
    let catalog = &*catalog::CATALOG;
    let offer = |start: usize, items: Vec<Completion>| {
        (!items.is_empty()).then(|| Completions {
            start: from + utf16(&before[..start]) as u32,
            items,
        })
    };
    let listed = |list: &[String], name: &str| list.iter().any(|n| n == name);

    if let Some(c) = ARGUMENT.captures(&before) {
        let names = match &c[1] {
            c if listed(&catalog.cite_commands, c) => citations,
            c if listed(&catalog.ref_commands, c) => labels,
            "begin" | "end" => &catalog.environments,
            _ => return None,
        };
        let start = before.rfind(['{', ',']).map_or(0, |i| i + 1);
        return offer(start, words(matching(names, &before[start..], |n| n)));
    }
    // @article and the like, in a .bib file.
    if let Some(m) = ENTRY_TYPE.find(&before) {
        let types: Vec<String> = catalog
            .bib_entry_types
            .iter()
            .map(|t| format!("@{t}"))
            .collect();
        return offer(m.start(), words(matching(&types, m.as_str(), |t| t)));
    }
    // \command, once a letter follows the backslash.
    let m = COMMAND.find(&before).filter(|m| m.len() > 1 || explicit)?;
    let indentation: String = String::from_utf16_lossy(text.line(line))
        .chars()
        .take_while(|&c| c == ' ' || c == '\t')
        .collect();
    let items = matching(&catalog.commands, m.as_str(), |c| &c.0)
        .into_iter()
        .map(|(name, _, snippet)| {
            let (text, fields) = expand(snippet, &indentation);
            Completion {
                label: name.clone(),
                text,
                fields,
            }
        })
        .collect();
    offer(m.start(), items)
}

/// Names that go in as they are.
fn words(names: Vec<&String>) -> Vec<Completion> {
    names
        .into_iter()
        .map(|name| Completion {
            label: name.clone(),
            text: name.clone(),
            fields: vec![],
        })
        .collect()
}

/// The items whose names start with what's typed, those with its case first.
fn matching<'a, T>(items: &'a [T], typed: &str, name: impl Fn(&T) -> &String) -> Vec<&'a T> {
    let lower = typed.to_lowercase();
    let (mut exact, folded): (Vec<_>, Vec<_>) = items
        .iter()
        .filter(|i| name(i).to_lowercase().starts_with(&lower))
        .partition(|i| name(i).starts_with(typed));
    exact.extend(folded);
    exact
}

/// A snippet's text and fields: "#{name}" fields show their name as their
/// text, and fields with the same name are one; a line after the first
/// takes the caret line's indentation, and each leading tab one more level
/// (two spaces, the editor's indent unit).
fn expand(snippet: &str, indentation: &str) -> (String, Vec<SnippetField>) {
    let (mut text, mut fields, mut names) = (String::new(), Vec::new(), Vec::<&str>::new());
    for (n, line) in snippet.split('\n').enumerate() {
        let tabs = if n == 0 {
            0
        } else {
            line.len() - line.trim_start_matches('\t').len()
        };
        if n > 0 {
            text += &format!("\n{indentation}{}", "  ".repeat(tabs));
        }
        let line = &line[tabs..];
        let mut last = 0;
        for c in FIELD.captures_iter(line) {
            let (whole, name) = (c.get(0).unwrap(), c.get(1).unwrap().as_str());
            text += &line[last..whole.start()];
            // Unnamed fields are each their own.
            let index = match names.iter().position(|&n| !name.is_empty() && n == name) {
                Some(index) => index,
                None => {
                    names.push(name);
                    names.len() - 1
                }
            };
            fields.push(SnippetField {
                start: utf16(&text) as u32,
                length: utf16(name) as u32,
                index: index as u32,
            });
            text += name;
            last = whole.end();
        }
        text += &line[last..];
    }
    (text, fields)
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
}
