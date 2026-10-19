//! The editing logic through `SourceDocument`'s commands: its lines and
//! offsets here, and in the files beside this one what the editors ask of it.

use super::*;

mod answers;
mod editing;
mod typing;

fn units(s: &str) -> u32 {
    utf16(s) as u32
}

#[test]
fn line_starts_follow_edits() {
    let mut doc = SourceDocument::new("a\nb\nc");
    assert_eq!(doc.line_count(), 3);
    doc.edit(1, 2, "x\ny\nz"); // "a" + "x\ny\nz" + "\nc"
    assert_eq!(doc.text(), "ax\ny\nz\nc");
    assert_eq!(
        (0..4).map(|l| doc.line_start(l + 1)).collect::<Vec<_>>(),
        [0, 3, 5, 7]
    );
    doc.edit(0, 7, "");
    assert_eq!(doc.text(), "c");
    assert_eq!(doc.line_count(), 1);
    assert_eq!(doc.line_at(1), 1);
    // Past the end: cut to the text, never a panic.
    doc.edit(10, 5, "!");
    assert_eq!(doc.text(), "c!");
}

/// The labels and citations are the document's, set when they change
/// rather than sent with each completions call: offered until set again,
/// and none on a new document.
#[test]
fn completions_offer_the_symbols_set_on_the_document() {
    let offered = |doc: &mut SourceDocument, caret: u32| -> Vec<String> {
        let answer = doc.call("completions", &format!(r#"{{"caret": {caret}}}"#));
        let value: serde_json::Value = serde_json::from_str(&answer.unwrap()).unwrap();
        value["items"].as_array().map_or(vec![], |items| {
            items
                .iter()
                .map(|i| i["label"].as_str().unwrap().to_owned())
                .collect()
        })
    };
    let owned = |names: &[&str]| names.iter().map(|&n| n.to_owned()).collect();
    let mut doc = SourceDocument::new("\\cite{sm} \\ref{fig");
    assert!(offered(&mut doc, 8).is_empty(), "a new document has none");
    doc.set_symbols(
        owned(&["fig:one", "sec:two"]),
        owned(&["smith2020", "jones"]),
    );
    assert_eq!(offered(&mut doc, 8), ["smith2020"]);
    assert_eq!(offered(&mut doc, 18), ["fig:one"]);
    // Kept through edits, and replaced whole.
    doc.edit(0, 0, "x ");
    assert_eq!(offered(&mut doc, 10), ["smith2020"]);
    doc.set_symbols(vec![], owned(&["smyth"]));
    assert_eq!(offered(&mut doc, 10), ["smyth"]);
    assert!(offered(&mut doc, 20).is_empty());
}

/// An undefined command is found where its line has it: not a longer one
/// that starts with it, nor a comment's, nor one after an escaped backslash.
#[test]
fn a_command_is_found_on_its_line() {
    let found = |line: &str, command: &str| -> Vec<(u32, u32)> {
        let doc = SourceDocument::new(&format!("first\n{line}\nlast"));
        let ranges = doc.command_ranges(2, command);
        ranges.iter().map(|r| (r.start, r.length)).collect()
    };
    assert_eq!(found("a \\foo b \\foo{c}", "\\foo"), [(2, 4), (9, 4)]);
    assert_eq!(found("\\foobar \\foo@ \\\\foo \\foo1", "\\foo"), [(20, 4)]);
    assert_eq!(found("\\foo % \\foo", "\\foo"), [(0, 4)]);
    assert_eq!(found("50\\% \\foo", "\\foo"), [(5, 4)]);
    assert_eq!(found("a\\;b \\\\;", "\\;"), [(1, 2)]);
    assert!(found("no such command", "\\foo").is_empty());
    let doc = SourceDocument::new("\\foo");
    assert!(doc.command_ranges(2, "\\foo").is_empty(), "no such line");
    assert!(doc.command_ranges(1, "").is_empty());
}

/// Both checkers pass over command names, an escape's too, and what
/// isn't prose; only spelling checks a comment.
#[test]
fn checkers_leave_code_alone() {
    let text = "Prose \\emph{word} $x$ 50\\% % note";
    let mut doc = SourceDocument::new(text);
    let all = range(0, utf16(text) as u32);
    let mut ranges = |checker| -> Vec<(u32, u32)> {
        let found = doc.code_ranges(all, checker);
        found.iter().map(|r| (r.start, r.length)).collect()
    };
    let code = [(6, 5), (18, 3), (24, 2)];
    assert_eq!(ranges(Checker::Spelling), code);
    assert_eq!(
        ranges(Checker::WritingTools),
        [&code[..], &[(27, 6)]].concat()
    );
}

#[test]
fn offsets_are_utf16() {
    let mut doc = SourceDocument::new("é😀\nx");
    assert_eq!(doc.line_start(2), 4); // é is one unit, the emoji two, then the line feed
    doc.edit(1, 2, "");
    assert_eq!(doc.text(), "é\nx");
}
