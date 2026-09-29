//! The editing commands against the cases the web's tests also check
//! (fixtures/editing.json; test/mathmode.test.js and test/editor.test.js).

use serde::Deserialize;
use texlocal_syntax::{math_mode_at, SourceDocument, TextEdit, TextRange};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    math_mode: Vec<(String, bool, String)>,
    headings: Vec<(String, String, String, u32)>,
}

fn fixture() -> Fixture {
    serde_json::from_str(include_str!("fixtures/editing.json")).unwrap()
}

fn units(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

#[test]
fn math_mode_matches_the_web() {
    for (source, expected, note) in fixture().math_mode {
        let at = source.find('|').unwrap();
        let before = units(&source[..at]);
        assert_eq!(math_mode_at(&before), expected, "{source} {note}");
    }
    // \verb's delimiter is the fixture's marker, so these are here.
    assert!(!math_mode_at(&units("\\verb|$| x")));
    assert!(!math_mode_at(&units("\\verb|$")), "inside \\verb");
}

#[test]
fn headings_match_the_web() {
    for (line, command, text, cursor) in fixture().headings {
        let doc = SourceDocument::new(format!("above\n{line}\nbelow"));
        let insertion = doc.set_heading(7, command.clone());
        assert_eq!(insertion.edit.text, text, "{line} as {command}");
        assert_eq!(
            (insertion.edit.start, insertion.edit.length),
            (6, units(&line).len() as u32)
        );
        assert_eq!(insertion.caret, 6 + cursor, "{line} as {command}");
    }
}

#[test]
fn a_block_starts_a_line_of_its_own() {
    let doc = SourceDocument::new("Some text".into());
    let at_end = TextRange {
        start: 9,
        length: 0,
    };
    let block = doc.insert_block("equation".into(), at_end).unwrap();
    assert_eq!(
        block.edit.text,
        "\n\\begin{equation}\n  \n  \\label{eq:}\n\\end{equation}\n"
    );
    assert_eq!(block.caret, 9 + "\n\\begin{equation}\n  ".len() as u32);
    // At a line's start (or after its indentation) it goes straight in.
    let doc = SourceDocument::new("  ".into());
    let block = doc
        .insert_block(
            "itemize".into(),
            TextRange {
                start: 2,
                length: 0,
            },
        )
        .unwrap();
    assert!(block.edit.text.starts_with("\\begin{itemize}"));
    assert!(doc.insert_block("nothing".into(), at_end).is_none());
}

#[test]
fn comments_toggle_by_line() {
    let doc = SourceDocument::new("a\n  b\n\nc".into());
    let all = TextRange {
        start: 0,
        length: 8,
    };
    let on = doc.toggle_comment(vec![all]);
    let insert = |start| TextEdit {
        start,
        length: 0,
        text: "% ".into(),
    };
    assert_eq!(
        on,
        [insert(0), insert(2), insert(7)],
        "blank lines stay as they are"
    );
    let doc = SourceDocument::new("% a\n  %b\n".into());
    let off = doc.toggle_comment(vec![TextRange {
        start: 0,
        length: 9,
    }]);
    let delete = |start, length| TextEdit {
        start,
        length,
        text: String::new(),
    };
    assert_eq!(off, [delete(0, 2), delete(6, 1)]);
    // A selection that ends at a line's start leaves that line alone.
    let doc = SourceDocument::new("a\nb".into());
    assert_eq!(
        doc.toggle_comment(vec![TextRange {
            start: 0,
            length: 2
        }]),
        [insert(0)]
    );
}

#[test]
fn symbols_go_in_as_maths() {
    let doc = SourceDocument::new("text $x$ and $".into());
    let in_text = doc.insert_symbol(
        "\\alpha".into(),
        TextRange {
            start: 5,
            length: 0,
        },
    );
    assert_eq!(
        (in_text.edit.text.as_str(), in_text.caret),
        ("$\\alpha$", 13)
    );
    let in_maths = doc.insert_symbol(
        "\\alpha".into(),
        TextRange {
            start: 14,
            length: 0,
        },
    );
    assert_eq!(in_maths.edit.text, "\\alpha");
}
