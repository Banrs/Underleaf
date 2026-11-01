mod common;

use std::collections::BTreeMap;
use std::sync::Arc;

use common::{apply, caret, run};
use serde_json::{Value, json};
use texlocal_latex::facts::Facts;
use texlocal_latex::syntax::{Installed, SourceDocument, Symbols, TextRange};
use texlocal_latex::{file_kind, utf16};

fn kinds(doc: &mut SourceDocument) -> Vec<(String, String)> {
    let text: Vec<u16> = doc.text().encode_utf16().collect();
    let runs = doc.highlights(0, text.len() as u32).into_iter();
    let run = |start: u32, length: u32| {
        String::from_utf16_lossy(&text[start as usize..][..length as usize])
    };
    runs.map(|h| (run(h.start, h.length), format!("{:?}", h.kind)))
        .collect()
}

fn pairs(found: &[(&str, &str)]) -> Vec<(String, String)> {
    let pair = |&(text, kind): &(&str, &str)| (text.to_owned(), kind.to_owned());
    found.iter().map(pair).collect()
}

fn labels(answer: &Value) -> Value {
    let items = answer["items"].as_array().unwrap().iter();
    items.map(|item| item["label"].clone()).collect()
}

fn typed(doc: &mut SourceDocument, start: u32, length: u32, text: &str) {
    for mirror in doc.apply_edit(start, length, text, None, false) {
        doc.apply_edit(mirror.start, mirror.length, &mirror.text, None, true);
    }
}

fn complete(doc: &mut SourceDocument, caret: usize) -> Value {
    run(
        doc,
        "Complete",
        json!({ "caret": caret, "explicit": false }),
    )
}

#[test]
fn highlighting_marks_commands_names_maths_comments_and_stray_closers() {
    let mut doc = SourceDocument::new("\\emph{a} \\ref{fig} $x^2$ } % note");
    let found = [
        ("\\emph", "Command"),
        ("\\ref", "Command"),
        ("fig", "Argument"),
        ("$", "Maths"),
        ("x", "Maths"),
        ("^", "Command"),
        ("2", "Maths"),
        ("$", "Maths"),
        ("}", "Invalid"),
        ("% note", "Comment"),
    ];
    assert_eq!(kinds(&mut doc), pairs(&found));
}

#[test]
fn a_named_argument_is_marked_after_options_and_the_options_are_not() {
    let text = "\\documentclass{article} \\usepackage[T1]{fontenc} \\cite[see]{knuth}";
    let found = [
        ("\\documentclass", "Command"),
        ("article", "Argument"),
        ("\\usepackage", "Command"),
        ("fontenc", "Argument"),
        ("\\cite", "Command"),
        ("knuth", "Argument"),
    ];
    assert_eq!(kinds(&mut SourceDocument::new(text)), pairs(&found));
}

#[test]
fn a_percent_in_an_address_is_not_a_comment() {
    let mut doc = SourceDocument::new("\\url{a%20b} \\href{c%d}{e} % note");
    let found = [
        ("\\url", "Command"),
        ("\\href", "Command"),
        ("% note", "Comment"),
    ];
    assert_eq!(kinds(&mut doc), pairs(&found));
}

#[test]
fn control_symbols_are_commands_in_text_and_maths() {
    let mut doc = SourceDocument::new("caf\\'e $a \\\\ b \\: c$");
    let found = [
        ("\\'", "Command"),
        ("$", "Maths"),
        ("a", "Maths"),
        ("\\\\", "Command"),
        ("b", "Maths"),
        ("\\:", "Command"),
        ("c", "Maths"),
        ("$", "Maths"),
    ];
    assert_eq!(kinds(&mut doc), pairs(&found));
}

#[test]
fn highlighting_carries_maths_and_verbatim_across_lines_and_follows_edits() {
    let mut doc = SourceDocument::new("\\[\na\n\\]\nb");
    let maths = [("\\[", "Maths"), ("a", "Maths"), ("\\]", "Maths")];
    assert_eq!(kinds(&mut doc), pairs(&maths));
    doc.apply_edit(0, 2, "", None, false);
    assert_eq!(kinds(&mut doc), pairs(&[("\\]", "Command")]));
    let mut doc = SourceDocument::new("\\begin{verbatim}\n$x$ % no\n\\end{verbatim}");
    let found = [
        ("\\begin", "Command"),
        ("verbatim", "Argument"),
        ("\\end", "Command"),
        ("verbatim", "Argument"),
    ];
    assert_eq!(kinds(&mut doc), pairs(&found));
}

#[test]
fn a_maths_environment_is_maths_until_its_own_end() {
    let text =
        "\\begin{align*}\nx^2 \\end{aligned}\n\n\\end{align*} y \\begin{equation}a\\end{equation}";
    let mut doc = SourceDocument::new(text);
    let found = [
        ("\\begin", "Command"),
        ("align*", "Argument"),
        ("x", "Maths"),
        ("^", "Command"),
        ("2", "Maths"),
        ("\\end", "Command"),
        ("aligned", "Maths"),
        ("\\end", "Command"),
        ("align", "Argument"),
        ("*", "Argument"),
        ("\\begin", "Command"),
        ("equation", "Argument"),
        ("a", "Maths"),
        ("\\end", "Command"),
        ("equation", "Argument"),
    ];
    assert_eq!(kinds(&mut doc), pairs(&found));
}

#[test]
fn the_scanner_knows_where_maths_is() {
    let cases = [
        ("$a$ \\(", true),
        ("\\begin{align} x", true),
        ("\\url{a%b} $", true),
        ("$a\n\n", false),
        ("% $", false),
        ("\\verb|$| ", false),
        ("\\begin{verbatim}$\\end{verbatim} ", false),
        ("\\[ \\text{if ", false),
    ];
    for (text, maths) in cases {
        let mut doc = SourceDocument::new(text);
        let at = utf16::len(text);
        let symbol = json!({ "command": "\\alpha", "selection": caret(at as u32) });
        let inserted = run(&mut doc, "InsertSymbol", symbol)["edit"]["text"].clone();
        let expected = if maths { "\\alpha" } else { "$\\alpha$" };
        assert_eq!(inserted, expected, "{text:?}");
    }
}

#[test]
fn the_scanner_stays_right_far_into_a_long_document_after_edits() {
    let text = format!("\\begin{{align}}\n{}", "word ".repeat(2000));
    let mut doc = SourceDocument::new(&text);
    let symbol = |doc: &mut SourceDocument| {
        let at = utf16::len(&doc.text()) as u32;
        let symbol = json!({ "command": "\\alpha", "selection": caret(at) });
        run(doc, "InsertSymbol", symbol)["edit"]["text"].clone()
    };
    assert_eq!(symbol(&mut doc), "\\alpha");
    doc.apply_edit(5000, 0, "\\end{align}", None, false);
    assert_eq!(symbol(&mut doc), "$\\alpha$");
    doc.apply_edit(5000, 11, "", None, false);
    assert_eq!(symbol(&mut doc), "\\alpha");
}

#[test]
fn a_command_completes_from_the_project_before_the_catalogue() {
    let mut doc = SourceDocument::new("\\newcommand{\\vect}[1]{\\mathbf{#1}}\n\\ve");
    let facts = Facts::read(&doc.text(), file_kind("main.tex"));
    doc.set_symbols(Arc::new(Symbols {
        by_file: BTreeMap::from([("main.tex".into(), facts.defined)]),
        ..Symbols::default()
    }));
    let answer = complete(&mut doc, 38);
    assert_eq!(
        (answer["kind"].clone(), answer["start"].clone()),
        (json!("command"), json!(35))
    );
    assert_eq!(
        labels(&answer),
        json!(["\\vect", "\\verb", "\\vec", "\\vee"])
    );
    let items = &answer["items"];
    assert_eq!(items[0]["text"], "\\vect{}");
    assert_eq!(
        items[0]["fields"],
        json!([{ "start": 6, "length": 0, "index": 0 }])
    );
    let mut doc = SourceDocument::new("\\fr");
    let answer = complete(&mut doc, 3);
    assert_eq!(answer["items"][0]["text"], "\\frac{}{}");
    let fields =
        json!([{ "start": 6, "length": 0, "index": 0 }, { "start": 8, "length": 0, "index": 1 }]);
    assert_eq!(answer["items"][0]["fields"], fields);
}

#[test]
fn an_argument_completes_what_the_command_takes() {
    let tex = "\\label{fig:plot} \\label{eq:sum}";
    let bib = "@book{knuth, title={The Art of Computer Programming}, author={Knuth}}\n@misc{lamport, title={LaTeX}}";
    let (tex, bib) = (
        Facts::read(tex, file_kind("main.tex")),
        Facts::read(bib, file_kind("refs.bib")),
    );
    let symbols = Arc::new(Symbols {
        by_file: BTreeMap::from([
            ("main.tex".into(), tex.defined),
            ("refs.bib".into(), bib.defined),
        ]),
        files: ["main.tex", "ch/intro.tex", "fig.png"]
            .map(String::from)
            .to_vec(),
        installed: Arc::new(Installed {
            packages: vec!["amsmath".into(), "amsthm".into(), "graphicx".into()],
            ..Installed::default()
        }),
    });
    let offered = |text: &str| {
        let mut doc = SourceDocument::new(text);
        doc.set_symbols(symbols.clone());
        let answer = complete(&mut doc, utf16::len(text));
        json!([answer["kind"], labels(&answer)])
    };
    assert_eq!(offered("\\ref{fig"), json!(["label", ["fig:plot"]]));
    assert_eq!(offered("\\cite{lam"), json!(["citation", ["lamport"]]));
    assert_eq!(offered("\\cite{art"), json!(["citation", ["knuth"]]));
    let packages = json!(["file", ["amsmath", "amsthm"]]);
    assert_eq!(offered("\\usepackage{ams"), packages);
    assert_eq!(offered("\\input{"), json!(["file", ["main", "ch/intro"]]));
    assert_eq!(offered("\\includegraphics{"), json!(["file", ["fig.png"]]));
    let end = offered("\\begin{itemize}\n\\begin{enumerate}\n\\end{");
    assert_eq!(end[1][0], "enumerate");
    let mut doc = SourceDocument::named("@art", "refs.bib");
    assert_eq!(labels(&complete(&mut doc, 4)), json!(["@article"]));
    let mut doc = SourceDocument::named("@a", "main.tex");
    assert_eq!(complete(&mut doc, 2), Value::Null);
}

#[test]
fn a_completion_is_accepted_from_the_list_offered_over_what_was_typed_since() {
    let mut doc = SourceDocument::new("a \\fr");
    let offered = complete(&mut doc, 5);
    let accept = |doc: &mut SourceDocument, index: u32, caret: u32| {
        run(
            doc,
            "AcceptCompletion",
            json!({ "index": index, "caret": caret }),
        )
    };
    doc.apply_edit(5, 0, "a", None, false);
    let accepted = accept(&mut doc, 0, 6);
    let edit = json!({ "start": 2, "length": 4, "text": "\\frac{}{}" });
    assert_eq!((&accepted["edit"], &accepted["caret"]), (&edit, &json!(11)));
    assert_eq!(accepted["fields"], offered["items"][0]["fields"]);
    assert_eq!(accept(&mut doc, 0, 6), Value::Null);
    complete(&mut doc, 6);
    assert_eq!(accept(&mut doc, 999, 6), Value::Null);
    complete(&mut doc, 6);
    assert_eq!(accept(&mut doc, 0, 1), Value::Null);
}

#[test]
fn words_leave_out_commands_names_maths_and_comments() {
    let text = "See \\cite{knuth} and \\ref{fig} on $x^2$ % a note\n";
    let mut doc = SourceDocument::new(text);
    let words = |doc: &mut SourceDocument, start: usize, end: usize| {
        let selection = json!({ "start": start, "length": end - start });
        run(doc, "Words", json!({ "selection": selection }))
    };
    assert_eq!(words(&mut doc, 0, utf16::len(text)), 3);
    assert_eq!(words(&mut doc, 0, 8), 1);
    let text = format!("{}\\cite{{alpha,beta}} two words", "word ".repeat(818));
    let mut doc = SourceDocument::new(&text);
    assert_eq!(words(&mut doc, 4096, utf16::len(&text)), 2);
}

#[test]
fn code_ranges_leave_prose_to_the_checkers() {
    let mut doc = SourceDocument::new("\\emph{word} and $x$ % note");
    let ranges = |doc: &mut SourceDocument, start: u32, length: u32, checker: &str| {
        let selection = json!({ "start": start, "length": length });
        run(
            doc,
            "CodeRanges",
            json!({ "selection": selection, "checker": checker }),
        )
    };
    let code = json!([{ "start": 0, "length": 5 }, { "start": 16, "length": 3 }]);
    assert_eq!(ranges(&mut doc, 0, 26, "spelling"), code);
    let with_comment = json!([{ "start": 0, "length": 5 }, { "start": 16, "length": 3 }, { "start": 20, "length": 6 }]);
    assert_eq!(ranges(&mut doc, 0, 26, "writingTools"), with_comment);
    assert_eq!(
        ranges(&mut doc, 6, 13, "spelling"),
        json!([{ "start": 16, "length": 3 }])
    );
}

#[test]
fn a_snippet_tabs_from_field_to_field_until_it_ends() {
    let mut doc = SourceDocument::new("");
    let block = run(
        &mut doc,
        "InsertBlock",
        json!({ "id": "figure", "selection": caret(0) }),
    );
    assert!(
        block["edit"]["text"]
            .as_str()
            .unwrap()
            .starts_with("\\begin{figure}")
    );
    apply(&mut doc, &block["edit"]);
    let fields = &block["fields"];
    assert_eq!(fields.as_array().unwrap().len(), 3);
    let place = |i: usize| json!({ "start": fields[i]["start"], "length": fields[i]["length"] });
    let first = run(
        &mut doc,
        "StartSnippet",
        json!({ "fields": fields, "at": 0 }),
    );
    assert_eq!(first, place(0));
    let tab = |doc: &mut SourceDocument, step: i64| {
        run(
            doc,
            "InsertTab",
            json!({ "selections": [first], "step": step }),
        )
    };
    assert_eq!(tab(&mut doc, 1)["field"], place(1));
    assert_eq!(tab(&mut doc, -1)["field"], place(0));
    assert_eq!(run(&mut doc, "EndSnippet", json!({})), true);
    assert_eq!(run(&mut doc, "EndSnippet", json!({})), false);
    assert_eq!(tab(&mut doc, 1)["field"], Value::Null);
}

#[test]
fn typing_in_a_completed_environment_mirrors_its_name() {
    let mut doc = SourceDocument::new("\\begin");
    let item = complete(&mut doc, 6)["items"][0].clone();
    assert_eq!(item["label"], "\\begin");
    apply(
        &mut doc,
        &json!({ "start": 0, "length": 6, "text": item["text"] }),
    );
    let first = run(
        &mut doc,
        "StartSnippet",
        json!({ "fields": item["fields"], "at": 0 }),
    );
    assert_eq!(first, json!({ "start": 7, "length": 3 }));
    typed(&mut doc, 7, 3, "itemize");
    assert_eq!(doc.text(), "\\begin{itemize}\n  \n\\end{itemize}");
}

#[test]
fn renaming_an_environment_renames_its_end() {
    let mut doc = SourceDocument::new("\\begin{itemize}\n\\item a\n\\end{itemize}");
    let inside = TextRange {
        start: 9,
        length: 0,
    };
    doc.select(inside, false);
    typed(&mut doc, 7, 7, "enumerate");
    assert_eq!(doc.text(), "\\begin{enumerate}\n\\item a\n\\end{enumerate}");
}

#[test]
fn renaming_an_environment_from_its_end_renames_its_begin() {
    let mut doc = SourceDocument::new("\\begin{itemize}\n\\item a\n\\end{itemize}");
    for start in [9, 31] {
        doc.select(TextRange { start, length: 0 }, false);
    }
    typed(&mut doc, 29, 7, "enumerate");
    assert_eq!(doc.text(), "\\begin{enumerate}\n\\item a\n\\end{enumerate}");
}
