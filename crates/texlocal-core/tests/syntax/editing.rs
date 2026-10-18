//! The editing logic against the expected answers in fixtures/editing.json:
//! maths at a place, the maths to preview, completions, headings and blocks.

use serde::Deserialize;
use serde_json::Value;
use texlocal_core::syntax::{Insertion, SourceDocument, math_mode_at};

use super::{range, units};

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

/// The document without the "|" that marks a position, and that position.
fn marked(source: &str) -> (SourceDocument, u32) {
    let at = units(&source[..source.find('|').unwrap()]);
    (SourceDocument::new(&source.replacen('|', "", 1)), at)
}

#[test]
fn math_mode_is_known_at_a_place() {
    for (source, expected, note) in fixture().math_mode {
        let before: Vec<u16> = source[..source.find('|').unwrap()].encode_utf16().collect();
        assert_eq!(math_mode_at(&before), expected, "{source} {note}");
    }
    // \verb's delimiter is the fixture's marker, so these are here.
    let verb: Vec<u16> = "\\verb|$| x".encode_utf16().collect();
    assert!(!math_mode_at(&verb));
    assert!(!math_mode_at(&verb[..7]), "inside \\verb");
}

#[test]
fn the_maths_to_preview_is_found_around_a_place() {
    for (source, expected) in fixture().math_at {
        let (doc, at) = marked(&source);
        let found = serde_json::to_value(doc.math_at(at)).unwrap();
        assert_eq!(found, expected, "{source}");
    }
}

#[test]
fn completions_are_offered_for_what_is_typed() {
    let (labels, citations) = (["sec:intro".to_string()], ["knuth84".to_string()]);
    for Offer(before, explicit, start, offered, kind) in fixture().completions {
        let doc = SourceDocument::new(&before);
        let found = doc.completions(units(&before), explicit, &labels, &citations);
        // Where it starts, and what its items are, all of them.
        let place = found
            .as_ref()
            .map(|c| (c.start, serde_json::to_value(c.kind).unwrap()));
        assert_eq!(place, start.zip(kind), "{before}");
        let labels: Vec<_> = found
            .iter()
            .flat_map(|c| &c.items)
            .map(|i| &i.label)
            .collect();
        assert!(offered.is_none_or(|o| labels.contains(&&o)), "{before}");
    }
}

#[test]
fn a_line_becomes_a_heading() {
    for (line, command, text, cursor) in fixture().headings {
        let doc = SourceDocument::new(&format!("above\n{line}\nbelow"));
        let Insertion { edit, caret, .. } = doc.set_heading(7, &command);
        let found = (edit.start, edit.length, edit.text, caret);
        let expected = (6, units(&line), text, 6 + cursor);
        assert_eq!(found, expected, "{line} as {command}");
    }
    // A CRLF line keeps its CR.
    let doc = SourceDocument::new("Intro\r\nbelow");
    let Insertion { edit, .. } = doc.set_heading(0, "section");
    assert_eq!(
        (edit.start, edit.length, edit.text.as_str()),
        (0, 5, "\\section{Intro}")
    );
}

#[test]
fn blocks_go_in_with_their_fields() {
    for (before, id, text, fields) in fixture().blocks {
        let doc = SourceDocument::new(&before);
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
        let doc = SourceDocument::new(&text);
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
