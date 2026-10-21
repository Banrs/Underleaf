//! The editing logic through `SourceDocument`'s commands: its lines and
//! offsets here, and in the files beside this one what the editors ask of it.

use super::*;

mod answers;
mod editing;
mod typing;

fn units(s: &str) -> u32 {
    utf16(s) as u32
}

/// Citations as a .bib file's entries of these keys, with nothing to say of them.
pub(crate) fn cited(keys: &[&str]) -> Vec<crate::analyze::Named> {
    let bib: String = keys
        .iter()
        .map(|key| format!("@misc{{{key},}}\n"))
        .collect();
    crate::analyze::Facts::read(&bib, "bib").citations
}

#[test]
fn line_starts_follow_edits_in_utf16_units() {
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
    // é is one unit, the emoji two, then the line feed.
    let mut doc = SourceDocument::new("é😀\nx");
    assert_eq!(doc.line_start(2), 4);
    doc.edit(1, 2, "");
    assert_eq!(doc.text(), "é\nx");
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
    let own = answer("label", "own", &[("main.tex", 3, 13, 3)]);
    assert_eq!(definition("own"), own);
    assert_eq!(definition("own}\\ref"), own, "at the label itself");
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
