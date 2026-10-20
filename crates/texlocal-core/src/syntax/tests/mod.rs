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
    doc.edit(10, 5, "!");
    assert_eq!(doc.text(), "c!");
}

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
    doc.set_symbols(std::sync::Arc::new(Symbols {
        labels: owned(&["fig:one", "sec:two"]),
        citations: owned(&["smith2020", "jones"]),
        ..Symbols::default()
    }));
    assert_eq!(offered(&mut doc, 8), ["smith2020"]);
    assert_eq!(offered(&mut doc, 18), ["fig:one"]);
    doc.edit(0, 0, "x ");
    assert_eq!(offered(&mut doc, 10), ["smith2020"]);
    doc.set_symbols(std::sync::Arc::new(Symbols {
        citations: owned(&["smyth"]),
        ..Symbols::default()
    }));
    assert_eq!(offered(&mut doc, 10), ["smyth"]);
    assert!(offered(&mut doc, 20).is_empty());
}

/// The project's other files as last scanned, this one as it is now: its last scan's label is
/// gone, the label typed since is found.
#[test]
fn a_definition_is_found_for_each_kind_of_name() {
    use crate::analyze::Facts;
    let text = "\\ref{sec:a} \\cite{x, knuth} \\pair{1}{2}\n\
        \\begin{thm} \\input{chapters/one} \\includegraphics{figs/plot}\n\
        prose \\label{own}\\ref{own}";
    let mut doc = SourceDocument::named(text, "main.tex");
    let defs =
        "\\label{sec:a}\n\\newcommand{\\pair}[2]{}\n\\newenvironment{thm}{}{}\n\\label{sec:a}";
    let by_file = [
        ("defs.tex", Facts::read(defs, "tex")),
        ("main.tex", Facts::read("\\label{own}", "tex")),
        ("refs.bib", Facts::read("@book{knuth,\n}", "bib")),
    ];
    let files = ["chapters/One.tex", "figs/plot.eps", "figs/plot.png"];
    doc.set_symbols(std::sync::Arc::new(Symbols {
        by_file: by_file
            .map(|(file, facts)| (file.into(), facts.into()))
            .into(),
        files: files.map(String::from).to_vec(),
        ..Symbols::default()
    }));
    let mut definition = |name: &str| {
        let at = units(&text[..text.rfind(name).unwrap()]) + 1;
        let answer = doc
            .call("definition", &format!(r#"{{"at": {at}}}"#))
            .unwrap();
        serde_json::from_str::<serde_json::Value>(&answer).unwrap()
    };
    let answer = |kind: &str, name: &str, places: &[(&str, u32, u32, u32)]| {
        let places = places.iter().map(|&(file, line, column, length)| {
            serde_json::json!({ "file": file, "line": line, "column": column, "length": length })
        });
        let places: Vec<_> = places.collect();
        serde_json::json!({ "kind": kind, "name": name, "places": places })
    };
    let label = [("defs.tex", 1, 7, 5), ("defs.tex", 4, 7, 5)];
    assert_eq!(definition("sec:a"), answer("label", "sec:a", &label));
    let cited = [("refs.bib", 1, 6, 5)];
    assert_eq!(definition("knuth"), answer("citation", "knuth", &cited));
    let pair = [("defs.tex", 2, 12, 5)];
    assert_eq!(definition("pair"), answer("command", "\\pair", &pair));
    let thm = [("defs.tex", 3, 16, 3)];
    assert_eq!(definition("thm"), answer("environment", "thm", &thm));
    let input = [("chapters/One.tex", 1, 0, 0)];
    assert_eq!(definition("one"), answer("file", "chapters/one", &input));
    let graphic = [("figs/plot.png", 1, 0, 0)];
    assert_eq!(definition("plot"), answer("file", "figs/plot", &graphic));
    let own = [("main.tex", 3, 13, 3)];
    assert_eq!(definition("own"), answer("label", "own", &own));
    assert_eq!(
        definition("x,"),
        serde_json::Value::Null,
        "an undefined key"
    );
    assert_eq!(definition("prose"), serde_json::Value::Null);
}

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
