//! Completion: an argument's labels, citations or environments, a
//! bibliography entry's type, or a command. Commands are snippets, expanded
//! here, so an editor only places the text and its fields.

use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use super::{Text, catalog::CATALOG, is, utf16};

/// A place to type in a completion's text. Fields with the same `index`
/// are one field in several places: what's typed in one goes in all.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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

/// What to offer at the caret, if anything: commands after a backslash (only
/// once a letter follows unless `explicit`, asked for by the user), the labels,
/// citations or environments an argument takes, or a bibliography entry's type
/// after "@".
pub(crate) fn completions(
    text: &mut Text,
    (caret, explicit): (u32, bool),
    (labels, citations): (&[String], &[String]),
) -> Option<Completions> {
    let caret = caret.min(text.len());
    text.reach_line(caret);
    // The caret's line, at most 250 units back.
    let line = text.line_start(text.line_index(caret));
    let from = line.max(caret.saturating_sub(250));
    let before = String::from_utf16_lossy(&text.units()[from as usize..caret as usize]);
    let offer = |start: usize, kind, items: Vec<Completion>| {
        let start = from + utf16(&before[..start]) as u32;
        (!items.is_empty()).then_some(Completions { start, kind, items })
    };
    let listed = |list: &[String], name: &str| list.iter().any(|n| n == name);
    if let Some(c) = ARGUMENT.captures(&before) {
        let (names, kind) = match &c[1] {
            c if listed(&CATALOG.cite_commands, c) => (citations, CompletionKind::Citation),
            c if listed(&CATALOG.ref_commands, c) => (labels, CompletionKind::Label),
            "begin" | "end" => (&CATALOG.environments[..], CompletionKind::Environment),
            _ => return None,
        };
        let start = before.rfind(['{', ',']).map_or(0, |i| i + 1);
        let names = matching(names, &before[start..], |n| n);
        return offer(start, kind, words(names, ""));
    }
    // @article and the like, in a .bib file.
    if let Some(m) = ENTRY_TYPE.find(&before) {
        let names = matching(&CATALOG.bib_entry_types, &m.as_str()[1..], |t| t);
        return offer(m.start(), CompletionKind::EntryType, words(names, "@"));
    }
    // \command, once a letter follows the backslash.
    let m = COMMAND.find(&before).filter(|m| m.len() > 1 || explicit)?;
    let commands = matching(&CATALOG.commands, m.as_str(), |c| &c.0).into_iter();
    let items = commands.map(|(name, _, snippet)| {
        let (text, fields) = expand(text, caret, snippet);
        Completion {
            label: name.clone(),
            text,
            fields,
        }
    });
    offer(m.start(), CompletionKind::Command, items.collect())
}

/// Literal names, with `@` prefixed for bibliography entry types.
fn words(names: Vec<&String>, prefix: &str) -> Vec<Completion> {
    let word = |name| {
        let label = format!("{prefix}{name}");
        Completion {
            text: label.clone(),
            label,
            fields: vec![],
        }
    };
    names.into_iter().map(word).collect()
}

/// The items whose names start with what's typed, those with its case first.
fn matching<'a, T>(items: &'a [T], typed: &str, name: impl Fn(&T) -> &String) -> Vec<&'a T> {
    let (lower, t) = (typed.to_lowercase(), typed.as_bytes());
    // ASCII names, as the catalog's and most keys are, are compared in
    // place: lowercasing a copy of each, at every key typed, was most of a
    // citation's offer. Others are lowercased whole, by Unicode's full
    // mapping, which may lower a character to ASCII (the kelvin sign to k).
    let starts = |n: &str| match typed.is_ascii() && n.is_ascii() {
        true => n.len() >= t.len() && n.as_bytes()[..t.len()].eq_ignore_ascii_case(t),
        false => n.to_lowercase().starts_with(&lower),
    };
    let found = items.iter().filter(|i| starts(name(i)));
    let (mut exact, folded): (Vec<_>, Vec<_>) = found.partition(|i| name(i).starts_with(typed));
    exact.extend(folded);
    exact
}

/// A snippet's text and fields as it goes in at `at` (reached): "#{name}"
/// fields show their name as their text, and fields with the same name are
/// one; a line after the first takes `at`'s line's indentation, and each
/// leading tab one more level (two spaces, the editor's indent unit).
pub(crate) fn expand(source: &Text, at: u32, snippet: &str) -> (String, Vec<SnippetField>) {
    let line = source.line(source.line_index(at));
    let blank = |&&u: &&u16| is(u, ' ') || is(u, '\t');
    let indentation = String::from_utf16_lossy(&line[..line.iter().take_while(blank).count()]);
    // Catalog tabs are indentation; preserve any tabs in the source's indent.
    let snippet = snippet.replace('\t', "  ");
    let snippet = snippet.replace('\n', &format!("\n{indentation}"));
    let (mut names, mut fields) = (Vec::new(), Vec::new());
    let text = FIELD.replace_all(&snippet, |c: &regex::Captures| {
        let (whole, name) = (c.get_match(), &c[1]);
        // Unnamed fields are each their own.
        let same = names.iter().position(|n| !name.is_empty() && n == name);
        let index = same.unwrap_or_else(|| {
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
    use crate::syntax::Text;

    #[test]
    fn snippets_expand_with_their_fields() {
        // 😀 twice (one field), then the others, the line indented a level.
        let snippet = "#{😀}\n\t#{}#{é}#{😀}#{}";
        let (text, fields) = super::expand(&Text::new("\t\\beg"), 5, snippet);
        assert_eq!(text, "😀\n\t  é😀");
        let places = Vec::from_iter(fields.iter().map(|f| (f.start, f.length, f.index)));
        let expected = [(0, 2, 0), (6, 0, 1), (6, 1, 2), (7, 2, 0), (9, 0, 3)];
        assert_eq!(places, expected);
    }

    #[test]
    fn matches_with_the_typed_case_come_first() {
        let offered = |before: &str, keys: &[String]| -> Vec<String> {
            let caret = before.encode_utf16().count() as u32;
            let offer = super::completions(&mut Text::new(before), (caret, false), (&[], keys));
            offer.map_or(vec![], |o| o.items.into_iter().map(|i| i.label).collect())
        };
        let names = offered("\\s", &[]);
        let upper = names.iter().position(|n| n == "\\Sigma").unwrap();
        assert!(names[..upper].iter().all(|n| n.starts_with("\\s")));
        let keys = ["Knuth84", "knuth86", "Émile", "émile2", "Kn"].map(String::from);
        let cited = |typed: &str| offered(&format!("\\cite{{{typed}"), &keys).join(" ");
        assert_eq!(cited("kn"), "knuth86 Knuth84 Kn");
        assert_eq!(cited("KNUTH"), "Knuth84 knuth86");
        assert_eq!(cited("é"), "émile2 Émile");
        assert_eq!(cited("ÉMILE"), "Émile émile2");
        // Others are lowered whole: the kelvin sign lowers to an ASCII k.
        assert_eq!(cited("\u{212a}n"), "Knuth84 knuth86 Kn");
    }
}
