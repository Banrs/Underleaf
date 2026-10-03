//! The editing logic against the cases the web's tests also check
//! (fixtures/editing.json; test/mathmode.test.js and test/editor.test.js).

use serde::Deserialize;
use texlocal_syntax::{math_mode_at, SourceDocument, TextEdit, TextRange};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    math_mode: Vec<(String, bool, String)>,
    headings: Vec<(String, String, String, u32)>,
    math_at: Vec<(String, serde_json::Value)>,
    completions: Vec<(String, bool, Option<u32>, Option<String>)>,
    blocks: Vec<(String, String, String, Fields)>,
}

/// Each field's start and length, from the block's start, in Tab's order.
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

/// The document without the "|" that marks a position, and that position.
fn marked(source: &str) -> (SourceDocument, u32) {
    let at = units(&source[..source.find('|').unwrap()]);
    (SourceDocument::new(&source.replacen('|', "", 1)), at)
}

#[test]
fn math_mode_matches_the_web() {
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
fn the_maths_to_preview_matches_the_web() {
    for (source, expected) in fixture().math_at {
        let (doc, at) = marked(&source);
        assert_eq!(
            serde_json::to_value(doc.math_at(at)).unwrap(),
            expected,
            "{source}"
        );
    }
}

#[test]
fn completions_match_the_web() {
    let (labels, citations) = (["sec:intro".to_string()], ["knuth84".to_string()]);
    for (before, explicit, start, offered) in fixture().completions {
        let doc = SourceDocument::new(&before);
        let found = doc.completions(units(&before), explicit, &labels, &citations);
        assert_eq!(found.as_ref().map(|c| c.start), start, "{before}");
        let labels: Vec<_> = found
            .iter()
            .flat_map(|c| &c.items)
            .map(|i| &i.label)
            .collect();
        assert!(offered.is_none_or(|o| labels.contains(&&o)), "{before}");
    }
}

#[test]
fn headings_match_the_web() {
    for (line, command, text, cursor) in fixture().headings {
        let doc = SourceDocument::new(&format!("above\n{line}\nbelow"));
        let insertion = doc.set_heading(7, &command);
        assert_eq!(
            insertion.edit,
            TextEdit {
                start: 6,
                length: units(&line),
                text
            },
            "{line} as {command}"
        );
        assert_eq!(insertion.caret, 6 + cursor, "{line} as {command}");
    }
}

#[test]
fn blocks_match_the_web() {
    for (before, id, text, fields) in fixture().blocks {
        let doc = SourceDocument::new(&before);
        let end = units(&before);
        let block = doc.insert_block(&id, range(end, 0)).unwrap();
        let found: Vec<_> = block.fields.iter().map(|f| (f.start, f.length)).collect();
        assert_eq!(
            (block.edit.text, found),
            (text, fields),
            "{id} after {before:?}"
        );
        assert_eq!(block.caret, end + block.fields[0].start, "{id}");
    }
    assert!(SourceDocument::new("")
        .insert_block("nothing", range(0, 0))
        .is_none());
}

#[test]
fn comments_and_indentation_go_by_line() {
    let edit = |start, length, text: &str| TextEdit {
        start,
        length,
        text: text.into(),
    };
    let on = SourceDocument::new("a\n  b\n\nc").toggle_comment(&[range(0, 8)]);
    assert_eq!(
        on,
        [edit(0, 0, "% "), edit(2, 0, "% "), edit(7, 0, "% ")],
        "blank lines stay as they are"
    );
    let off = SourceDocument::new("% a\n  %b\n").toggle_comment(&[range(0, 9)]);
    assert_eq!(off, [edit(0, 2, ""), edit(6, 1, "")]);
    let indented = SourceDocument::new("a\n b\n").indent(&[range(0, 3), range(5, 0)], true);
    assert_eq!(
        indented,
        [edit(0, 0, "  "), edit(2, 0, "  "), edit(5, 0, "  ")]
    );
    let outdented = SourceDocument::new("   a\nb").indent(&[range(0, 6)], false);
    assert_eq!(outdented, [edit(1, 2, "")]);
    // A selection that ends at a line's start leaves that line alone.
    assert_eq!(
        SourceDocument::new("a\nb").toggle_comment(&[range(0, 2)]),
        [edit(0, 0, "% ")]
    );
}

#[test]
fn symbols_go_in_as_maths() {
    let doc = SourceDocument::new("text $x$ and $");
    let in_text = doc.insert_symbol("\\alpha", range(5, 0));
    assert_eq!(
        (in_text.edit.text.as_str(), in_text.caret),
        ("$\\alpha$", 13)
    );
    assert_eq!(
        doc.insert_symbol("\\alpha", range(14, 0)).edit.text,
        "\\alpha"
    );
}
