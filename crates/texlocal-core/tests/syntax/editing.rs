//! The editing logic against the expected answers in fixtures/editing.json:
//! maths at a place, the maths to preview, completions, headings and blocks.

use serde::Deserialize;
use serde_json::{Value, json};
use texlocal_core::syntax::{Insertion, SourceDocument, TextRange};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    math_mode: Vec<(String, bool, String)>,
    headings: Vec<(String, String, String, u32)>,
    math_at: Vec<(String, Value)>,
    completions: Vec<Offer>,
    blocks: Vec<(String, String, String, Fields)>,
    by_line: Vec<ByLine>,
}

/// The text before the caret, whether asked for, and the offer's start, an
/// item it has and its kind.
#[derive(Deserialize)]
struct Offer(String, bool, Option<u32>, Option<String>, Option<Value>);

/// The text, "comment", "indent" or "outdent", the selections, the edits and
/// what the case shows.
#[derive(Deserialize)]
struct ByLine(String, String, Fields, Vec<(u32, u32, String)>, String);

/// Each field's (or selection's) start and length, in Tab's order.
type Fields = Vec<(u32, u32)>;

fn fixture() -> Fixture {
    serde_json::from_str(include_str!("fixtures/editing.json")).unwrap()
}

fn units(s: &str) -> u32 {
    s.encode_utf16().count() as u32
}

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
}

/// Whether the end of `before` is in maths, as a symbol put there finds it.
fn in_maths(before: &str) -> bool {
    let at = range(units(before), 0);
    SourceDocument::new(before)
        .insert_symbol("\\x", at)
        .edit
        .text
        == "\\x"
}

/// The document without the "|" that marks a position, and that position.
fn marked(source: &str) -> (SourceDocument, u32) {
    let at = units(&source[..source.find('|').unwrap()]);
    (SourceDocument::new(&source.replacen('|', "", 1)), at)
}

#[test]
fn math_mode_is_known_at_a_place() {
    let mut cases = fixture().math_mode;
    // In each display environment, after it and before it.
    for name in "equation align gather multline eqnarray alignat flalign".split(' ') {
        for name in [name.to_owned(), format!("{name}*")] {
            let (begin, end) = (format!("\\begin{{{name}}}"), format!("\\end{{{name}}}"));
            cases.extend([
                (format!("{begin}\n  a |= b\n{end}"), true, name.clone()),
                (format!("{begin}\n  a = b\n{end}\n|"), false, name.clone()),
                (format!("|{begin}a{end}"), false, name),
            ]);
        }
    }
    for (source, expected, note) in cases {
        let before = &source[..source.find('|').unwrap()];
        assert_eq!(in_maths(before), expected, "{source} {note}");
    }
    // \verb's delimiter is the fixture's marker, so these are here. An unclosed
    // \verb ends with its line, and the maths it was in goes on; a line feed
    // straight after \verb ends it; closed, it's skipped, delimiters and all.
    assert!(
        !in_maths("\\verb|$| x") && !in_maths("\\verb|$"),
        "inside \\verb"
    );
    for text in ["$ \\verb|x\ny", "\\verb\n$y", "\\verb*+x+ $a"] {
        assert!(in_maths(text), "{text}");
    }
}

#[test]
fn the_maths_to_preview_is_found_around_a_place() {
    for (source, expected) in fixture().math_at {
        let (mut doc, at) = marked(&source);
        let found = serde_json::to_value(doc.math_at(at)).unwrap();
        assert_eq!(found, expected, "{source}");
    }
}

#[test]
fn completions_are_offered_for_what_is_typed() {
    for Offer(before, explicit, start, offered, kind) in fixture().completions {
        let mut doc = SourceDocument::new(&before);
        doc.set_symbols(vec!["sec:intro".into()], vec!["knuth84".into()]);
        let args = json!({ "caret": units(&before), "explicit": explicit });
        let found = doc.call("completions", &args.to_string()).unwrap();
        let found: Value = serde_json::from_str(&found).unwrap();
        // Where it starts, and what its items are, all of them.
        let place = (!found.is_null()).then(|| (found["start"].clone(), found["kind"].clone()));
        assert_eq!(place, start.map(Value::from).zip(kind), "{before}");
        let items = found["items"].as_array().cloned().unwrap_or_default();
        let labels: Vec<_> = items.iter().map(|i| i["label"].as_str().unwrap()).collect();
        assert!(offered.is_none_or(|o| labels.contains(&&*o)), "{before}");
    }
}

#[test]
fn a_line_becomes_a_heading() {
    for (line, command, text, cursor) in fixture().headings {
        let mut doc = SourceDocument::new(&format!("above\n{line}\nbelow"));
        let Insertion { edit, caret, .. } = doc.set_heading(7, &command);
        let found = (edit.start, edit.length, edit.text, caret);
        let expected = (6, units(&line), text, 6 + cursor);
        assert_eq!(found, expected, "{line} as {command}");
    }
}

#[test]
fn blocks_go_in_with_their_fields() {
    for (before, id, text, fields) in fixture().blocks {
        let mut doc = SourceDocument::new(&before);
        let end = units(&before);
        let block = doc.insert_block(&id, range(end, 0)).unwrap();
        assert_eq!(block.caret, end + block.fields[0].start, "{id}");
        let found: Vec<_> = block.fields.iter().map(|f| (f.start, f.length)).collect();
        let expected = (text, fields);
        assert_eq!((block.edit.text, found), expected, "{id} after {before:?}");
    }
    let nothing = SourceDocument::new("").insert_block("nothing", range(0, 0));
    assert!(nothing.is_none());
}

#[test]
fn comments_and_indentation_go_by_line() {
    for ByLine(text, command, selections, edits, note) in fixture().by_line {
        let mut doc = SourceDocument::new(&text);
        let selections: Vec<_> = selections.into_iter().map(|(s, l)| range(s, l)).collect();
        let found = match command.as_str() {
            "comment" => doc.toggle_comment(&selections),
            more => doc.indent(&selections, more == "indent"),
        };
        let found: Vec<_> = found
            .into_iter()
            .map(|e| (e.start, e.length, e.text))
            .collect();
        assert_eq!(found, edits, "{command} {text:?}: {note}");
    }
}

#[test]
fn symbols_go_in_as_maths() {
    let mut doc = SourceDocument::new("text $x$ and $");
    let in_text = doc.insert_symbol("\\alpha", range(5, 0));
    assert_eq!((in_text.edit.text, in_text.caret), ("$\\alpha$".into(), 13));
    let in_maths = doc.insert_symbol("\\alpha", range(14, 0));
    assert_eq!(in_maths.edit.text, "\\alpha");
}
