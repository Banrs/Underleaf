//! Completion as web/src/editor.js `latexCompletions` offers it: an
//! argument's labels, citations or environments, a bibliography entry's
//! type, or a command. Commands are snippets, expanded here as CodeMirror's
//! `snippet()` expands them, so an editor only places the text and its fields.

use crate::{catalog, Text};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CompletionKind {
    Command,
    Environment,
    Label,
    Citation,
    EntryType,
}

/// A place to type in a completion's text. Fields with the same `index`
/// are one field in several places: what's typed in one goes in all.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SnippetField {
    /// From the start of the completion's text, in UTF-16 units.
    pub start: u32,
    pub length: u32,
    /// The field's place in the order Tab goes through them, from 0.
    pub index: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Completion {
    pub label: String,
    /// What it is ("sectioning"), empty for names from the project.
    pub detail: String,
    pub kind: CompletionKind,
    /// What goes in, with the fields' defaults and the line's indentation.
    pub text: String,
    /// In order of position.
    pub fields: Vec<SnippetField>,
}

/// Completions for the text from `start` to the caret, which they replace.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Completions {
    pub start: u32,
    pub items: Vec<Completion>,
}

const CITE: [&str; 8] = [
    "cite",
    "citep",
    "citet",
    "citeauthor",
    "citeyear",
    "textcite",
    "parencite",
    "autocite",
];
const REF: [&str; 7] = ["ref", "eqref", "pageref", "autoref", "cref", "Cref", "vref"];

fn is(u: u16, c: char) -> bool {
    u == c as u16
}

/// JavaScript's \w.
fn word(u: u16) -> bool {
    u < 128 && ((u as u8).is_ascii_alphanumeric() || u == b'_' as u16)
}

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
    let before = &text.units[from as usize..caret as usize];
    let typed_from = |start: usize| String::from_utf16_lossy(&before[start..]);
    let offer = |start: usize, items: Vec<Completion>| {
        (!items.is_empty()).then(|| Completions {
            start: from + start as u32,
            items,
        })
    };

    // \cite{…}, \ref{…}, \begin{…}: the innermost open argument's names.
    if let Some(command) = argument(before) {
        let start = before.len()
            - before
                .iter()
                .rev()
                .take_while(|&&u| !is(u, '{') && !is(u, ','))
                .count();
        let catalog = catalog::get();
        let (kind, names): (CompletionKind, &[String]) = match command.as_str() {
            c if CITE.contains(&c) => (CompletionKind::Citation, citations),
            c if REF.contains(&c) => (CompletionKind::Label, labels),
            "begin" | "end" => (CompletionKind::Environment, &catalog.environments),
            _ => return None,
        };
        let items = matching(names, &typed_from(start), |n| n)
            .into_iter()
            .map(|name| Completion {
                label: name.clone(),
                detail: String::new(),
                kind,
                text: name.clone(),
                fields: vec![],
            })
            .collect();
        return offer(start, items);
    }

    let trailing = before.iter().rev().take_while(|&&u| word(u)).count();
    let start = before.len() - trailing;
    let lead = start.checked_sub(1).map(|i| before[i]);

    // @article and the like, in a .bib file.
    if lead.is_some_and(|u| is(u, '@')) {
        let types = catalog::get()
            .bib_entry_types
            .iter()
            .map(|t| format!("@{t}"))
            .collect::<Vec<_>>();
        let items = matching(&types, &typed_from(start - 1), |t| t)
            .into_iter()
            .map(|t| Completion {
                label: t.clone(),
                detail: String::new(),
                kind: CompletionKind::EntryType,
                text: t.clone(),
                fields: vec![],
            })
            .collect();
        return offer(start - 1, items);
    }

    // \command, once a letter follows the backslash.
    if lead.is_some_and(|u| is(u, '\\')) && (trailing > 0 || explicit) {
        let indentation: Vec<u16> = text
            .line(line)
            .iter()
            .copied()
            .take_while(|&u| is(u, ' ') || is(u, '\t'))
            .collect();
        let items = matching(
            &catalog::get().commands,
            &typed_from(start - 1),
            |(name, _, _)| name,
        )
        .into_iter()
        .map(|(name, detail, snippet)| {
            let (text, fields) = expand(snippet, &String::from_utf16_lossy(&indentation));
            Completion {
                label: name.clone(),
                detail: detail.clone(),
                kind: CompletionKind::Command,
                text,
                fields,
            }
        })
        .collect();
        return offer(start - 1, items);
    }
    None
}

/// `\\(\w+)\*?(\[[^\]]*\])?\{[^{}\\]*$`: the command whose argument the text
/// ends in, if it ends in one.
fn argument(before: &[u16]) -> Option<String> {
    let tail = before
        .iter()
        .rev()
        .take_while(|&&u| !is(u, '{') && !is(u, '}') && !is(u, '\\'))
        .count();
    let brace = before.len().checked_sub(tail + 1)?;
    if !is(before[brace], '{') {
        return None;
    }
    let command = |mut end: usize| {
        if end > 0 && is(before[end - 1], '*') {
            end -= 1;
        }
        let name = before[..end].iter().rev().take_while(|&&u| word(u)).count();
        let start = end - name;
        (name > 0 && start > 0 && is(before[start - 1], '\\'))
            .then(|| String::from_utf16_lossy(&before[start..end]))
    };
    if brace == 0 || !is(before[brace - 1], ']') {
        return command(brace);
    }
    // An optional argument: any "[" back to the last "]" before it.
    (0..brace - 1)
        .rev()
        .take_while(|&i| !is(before[i], ']'))
        .filter(|&i| is(before[i], '['))
        .find_map(command)
}

/// The names that start with what's typed, those with its case first.
fn matching<'a, T>(items: &'a [T], typed: &str, name: impl Fn(&T) -> &str) -> Vec<&'a T> {
    let lower = typed.to_lowercase();
    let (mut exact, mut folded) = (Vec::new(), Vec::new());
    for item in items {
        if name(item).starts_with(typed) {
            exact.push(item);
        } else if name(item).to_lowercase().starts_with(&lower) {
            folded.push(item);
        }
    }
    exact.extend(folded);
    exact
}

/// A snippet's text and fields: "#{name}" fields show their name as their
/// text, and fields with the same name are one; a line after the first
/// takes the caret line's indentation, and each leading tab one more level
/// (two spaces, the editor's indent unit).
fn expand(snippet: &str, indentation: &str) -> (String, Vec<SnippetField>) {
    let mut names: Vec<String> = Vec::new();
    let mut fields = Vec::new();
    let mut text = String::new();
    for (n, line) in snippet.split('\n').enumerate() {
        let mut line = line;
        if n > 0 {
            text.push('\n');
            text.push_str(indentation);
            let tabs = line.len() - line.trim_start_matches('\t').len();
            text.push_str(&"  ".repeat(tabs));
            line = &line[tabs..];
        }
        let mut rest = line;
        while let Some(open) = rest.find("#{") {
            let Some(close) = rest[open..].find('}').map(|c| open + c) else {
                break;
            };
            text.push_str(&rest[..open]);
            let name = &rest[open + 2..close];
            // Unnamed fields are each their own.
            let index = match names.iter().position(|n| !name.is_empty() && n == name) {
                Some(index) => index,
                None => {
                    names.push(name.to_string());
                    names.len() - 1
                }
            };
            let start = text.encode_utf16().count() as u32;
            fields.push(SnippetField {
                start,
                length: name.encode_utf16().count() as u32,
                index: index as u32,
            });
            text.push_str(name);
            rest = &rest[close + 1..];
        }
        text.push_str(rest);
    }
    (text, fields)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SourceDocument;

    fn complete(before: &str) -> Option<Completions> {
        let doc = SourceDocument::new(before.into());
        doc.completions(
            before.encode_utf16().count() as u32,
            false,
            vec!["sec:intro".into()],
            vec!["knuth84".into()],
        )
    }

    fn labels(before: &str) -> Vec<String> {
        complete(before)
            .map(|c| c.items.into_iter().map(|i| i.label).collect())
            .unwrap_or_default()
    }

    // test/editor.test.js's cases.
    #[test]
    fn argument_completion_targets_the_innermost_open_argument() {
        assert_eq!(labels("\\footnote{see \\cite{kn"), ["knuth84"]);
        assert_eq!(labels("\\section{Proof of \\ref{"), ["sec:intro"]);
        assert_eq!(labels("\\cite[p.~5]{kn"), ["knuth84"]);
        assert_eq!(labels("\\cite[a[b]{kn"), ["knuth84"]);
        assert_eq!(labels("\\cite{a,kn"), ["knuth84"]);
        assert_eq!(
            complete("\\cite{a,kn").unwrap().start,
            "\\cite{a,".len() as u32
        );
        assert!(labels("\\begin{ite").contains(&"itemize".to_string()));
        // Another command's argument offers nothing, not even commands.
        assert!(complete("\\emph{x").is_none());
    }

    #[test]
    fn command_completion_works_inside_another_commands_argument() {
        let result = complete("\\frac{\\al").unwrap();
        assert_eq!(result.start, "\\frac{".len() as u32);
        assert!(result.items.iter().any(|i| i.label == "\\alpha"));
        // A bare backslash waits for a letter, unless asked.
        assert!(complete("x \\").is_none());
        let doc = SourceDocument::new("\\".into());
        assert!(doc.completions(1, true, vec![], vec![]).is_some());
    }

    #[test]
    fn entry_types_after_an_at_sign() {
        assert_eq!(labels("@inp"), ["@inproceedings"]);
        assert_eq!(complete("  @inp").unwrap().start, 2);
    }

    #[test]
    fn snippets_expand_with_their_fields() {
        let begin = complete("  \\beg").unwrap().items.remove(0);
        assert_eq!(begin.text, "\\begin{env}\n    \n  \\end{env}");
        let places: Vec<_> = begin
            .fields
            .iter()
            .map(|f| (f.start, f.length, f.index))
            .collect();
        // env twice (one field), then the body; the body's line is indented a level.
        assert_eq!(places, [(7, 3, 0), (16, 0, 1), (24, 3, 0)]);
        let section = complete("\\sub").unwrap().items.remove(0);
        assert_eq!(
            (section.label.as_str(), section.text.as_str()),
            ("\\subsection", "\\subsection{}")
        );
        assert_eq!(
            section.fields,
            [SnippetField {
                start: 12,
                length: 0,
                index: 0
            }]
        );
        let brace = complete("\\{").map(|c| c.items.len());
        assert_eq!(brace, None, "a symbol escape isn't a command name");
    }

    #[test]
    fn case_matches_come_first() {
        let names = labels("\\s");
        let upper = names.iter().position(|n| n == "\\Sigma").unwrap();
        assert!(names.iter().take_while(|n| n.starts_with("\\s")).count() <= upper);
    }
}
