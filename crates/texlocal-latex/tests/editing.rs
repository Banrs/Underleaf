mod common;

use std::sync::Arc;

use common::{apply, caret, run};
use serde_json::{Value, json};
use texlocal_latex::facts::Facts;
use texlocal_latex::file_kind;
use texlocal_latex::project::Scan;
use texlocal_latex::syntax::{Source, SourceDocument, Symbols, Syntax};

fn free(command: &str, args: Value) -> Value {
    Syntax::call(command, args).expect(command)
}

#[test]
fn edits_update_the_text() {
    let mut doc = SourceDocument::new("one\ntwo");
    doc.edit(4, 3, "2");
    assert_eq!(doc.text(), "one\n2");
    assert_eq!(doc.line_count(), 2);
    assert_eq!(doc.line_at(4), 2);
}

#[test]
fn toggling_a_comment_adds_and_removes_it() {
    let mut doc = SourceDocument::new("text");
    let added = run(
        &mut doc,
        "ToggleComment",
        json!({ "selections": [caret(0)] }),
    );
    apply(&mut doc, &added[0]);
    assert_eq!(doc.text(), "% text");
    let removed = run(
        &mut doc,
        "ToggleComment",
        json!({ "selections": [caret(3)] }),
    );
    for edit in removed.as_array().unwrap() {
        apply(&mut doc, edit);
    }
    assert_eq!(doc.text(), "text");
}

#[test]
fn a_heading_changes_level_or_becomes_text() {
    let mut doc = SourceDocument::new("\\section{Intro}");
    let deeper = run(
        &mut doc,
        "SetHeading",
        json!({ "caret": 3, "command": "subsection" }),
    );
    assert_eq!(deeper["edit"]["text"], "\\subsection{Intro}");
    let plain = run(&mut doc, "SetHeading", json!({ "caret": 3, "command": "" }));
    assert_eq!(plain["edit"]["text"], "Intro");
}

#[test]
fn typing_an_opener_inserts_its_closer() {
    for (typed, inserted) in [("$", "$$"), ("{", "{}"), ("(", "()")] {
        let mut doc = SourceDocument::new("a b");
        let answer = run(
            &mut doc,
            "TypeText",
            json!({ "selection": caret(1), "text": typed, "autoPair": true }),
        );
        assert_eq!(answer["edit"]["text"], inserted, "{typed}");
        assert_eq!(answer["selection"], caret(2), "{typed}");
    }
}

#[test]
fn deleting_an_inserted_opener_deletes_its_closer() {
    let mut doc = SourceDocument::new("a");
    let typed = run(
        &mut doc,
        "TypeText",
        json!({ "selection": caret(1), "text": "{", "autoPair": true }),
    );
    apply(&mut doc, &typed["edit"]);
    let deleted = run(
        &mut doc,
        "DeleteBackward",
        json!({ "selection": caret(2), "autoPair": true }),
    );
    apply(&mut doc, &deleted["edit"]);
    assert_eq!(doc.text(), "a");
}

#[test]
fn return_after_begin_closes_the_environment() {
    let mut doc = SourceDocument::new("\\begin{itemize}");
    let answer = run(&mut doc, "InsertNewline", json!({ "selection": caret(15) }));
    apply(&mut doc, &answer["edit"]);
    assert!(doc.text().ends_with("\n\\end{itemize}"), "{}", doc.text());
}

#[test]
fn return_after_an_item_starts_another() {
    let mut doc = SourceDocument::new("\\begin{itemize}\n\\item one");
    let answer = run(&mut doc, "InsertNewline", json!({ "selection": caret(25) }));
    assert_eq!(answer["edit"]["text"], "\n\\item ");
}

#[test]
fn the_maths_under_the_caret_is_found() {
    let mut doc = SourceDocument::new("Some $x^2$ text");
    let answer = run(&mut doc, "MathAt", json!({ "caret": 7 }));
    assert_eq!(
        answer,
        json!({ "start": 5, "tex": "x^2", "display": false })
    );
    assert_eq!(run(&mut doc, "MathAt", json!({ "caret": 12 })), Value::Null);
}

#[test]
fn bold_wraps_a_selection_and_reports_how_to_take_it_off() {
    let mut doc = SourceDocument::new("bold word");
    let wrapped = run(
        &mut doc,
        "ToggleStyle",
        json!({ "selections": [{ "start": 0, "length": 4 }], "style": "bold" }),
    );
    apply(&mut doc, &wrapped["edits"][0]);
    assert_eq!(doc.text(), "\\textbf{bold} word");
    let styles = run(
        &mut doc,
        "StylesAt",
        json!({ "selection": { "start": 9, "length": 2 } }),
    );
    assert!(styles["bold"].is_array());
    assert!(styles["italic"].is_null());
}

#[test]
fn a_brace_finds_its_partner() {
    let mut doc = SourceDocument::new("\\textbf{a{b}c}");
    assert_eq!(run(&mut doc, "Partner", json!({ "at": 7 })), 13);
}

#[test]
fn lines_move_duplicate_and_delete() {
    let mut doc = SourceDocument::new("one\ntwo");
    let moved = run(
        &mut doc,
        "MoveLines",
        json!({ "selections": [caret(5)], "up": true }),
    );
    assert_eq!(moved["edits"][0]["text"], "two\none");
    let duplicated = run(
        &mut doc,
        "DuplicateLines",
        json!({ "selections": [caret(0)] }),
    );
    apply(&mut doc, &duplicated["edits"][0]);
    assert_eq!(doc.text(), "one\none\ntwo");
    let deleted = run(&mut doc, "DeleteLines", json!({ "selections": [caret(0)] }));
    apply(&mut doc, &deleted["edits"][0]);
    assert_eq!(doc.text(), "one\ntwo");
}

#[test]
fn tab_indents_every_selected_line() {
    let mut doc = SourceDocument::new("a\nb");
    let answer = run(
        &mut doc,
        "InsertTab",
        json!({ "selections": [{ "start": 0, "length": 3 }], "step": 1 }),
    );
    assert_eq!(answer["edits"].as_array().unwrap().len(), 2);
}

#[test]
fn a_section_folds_to_the_next_heading() {
    let mut doc = SourceDocument::new("\\section{A}\ntext\n\\section{B}\nmore\n");
    assert_eq!(
        run(&mut doc, "Folds", json!({})),
        json!([{ "line": 1, "end": 2 }, { "line": 3, "end": 4 }])
    );
}

#[test]
fn a_reference_leads_to_its_label() {
    let mut doc = SourceDocument::new("\\label{a} \\ref{a}");
    let answer = run(&mut doc, "DefinitionAt", json!({ "at": 15 }));
    assert_eq!(answer["kind"], "label");
    assert_eq!(answer["places"][0]["column"], 7);
}

#[test]
fn the_symbol_under_the_caret_is_read_from_its_paragraph_alone() {
    let text = "Intro \\ref{one}.\n\n\\label{fig:a} see \\cite{knuth,\n  lamport} é\n\nPlain \\input{ch} text.";
    let mut doc = SourceDocument::named(text, "main.tex");
    let whole = Facts::read(text, file_kind("main.tex"));
    for at in 0..=text.encode_utf16().count() as u32 {
        let read = doc
            .symbol_at(&whole, at)
            .map(|(kind, name, _)| json!({ "kind": kind, "name": name }));
        let answer = run(&mut doc, "SymbolAt", json!({ "at": at }));
        assert_eq!(answer, read.unwrap_or_default(), "at {at}");
    }
    let at = |find: &str| json!({ "at": text.find(find).unwrap() + 1 });
    let label = json!({ "kind": "label", "name": "fig:a" });
    assert_eq!(run(&mut doc, "SymbolAt", at("fig:a")), label);
    let lamport = json!({ "kind": "citation", "name": "lamport" });
    assert_eq!(run(&mut doc, "SymbolAt", at("lamport")), lamport);
    assert_eq!(run(&mut doc, "SymbolAt", at("Intro")), Value::Null);
}

#[test]
fn the_projects_symbols_reach_the_engine_as_data() {
    let files = [
        ("ch.tex", "\\label{sum} \\newcommand{\\R}{\\mathbb{R}}"),
        ("main.tex", "\\ref{sum} $\\R$"),
        ("refs.bib", "@book{knuth, title={TAOCP}}"),
    ];
    let read = files.map(|(file, text)| {
        (
            file.to_owned(),
            Arc::new(Facts::read(text, file_kind(file))),
        )
    });
    let names = files.map(|(file, _)| file.to_owned()).to_vec();
    let symbols = Scan::new(read.into(), names, Arc::default()).symbols;
    let sent: Symbols = serde_json::from_str(&serde_json::to_string(&symbols).unwrap()).unwrap();
    assert_eq!(sent, *symbols);
    let mut doc = SourceDocument::named(files[1].1, "main.tex");
    doc.set_symbols(Arc::new(sent));
    let answer = run(&mut doc, "DefinitionAt", json!({ "at": 6 }));
    assert_eq!(
        answer["places"],
        json!([{ "file": "ch.tex", "line": 1, "column": 7, "length": 3 }])
    );
    let math = run(&mut doc, "MathAt", json!({ "caret": 13 }));
    assert!(math["tex"].as_str().unwrap().starts_with("\\def\\R{"));
    doc.edit(0, 16, "\\cite{");
    let cited = run(
        &mut doc,
        "Complete",
        json!({ "caret": 6, "explicit": false }),
    );
    assert_eq!(cited["items"][0]["label"], "knuth");
}

#[test]
fn selections_move_with_the_edits_before_them() {
    let mut doc = SourceDocument::new("");
    let mapped = run(
        &mut doc,
        "MapSelections",
        json!({
            "edits": [{ "start": 0, "length": 1, "text": "abc" }, { "start": 4, "length": 2, "text": "" }],
            "selections": [caret(2), { "start": 3, "length": 4 }, caret(5), caret(8)],
        }),
    );
    assert_eq!(
        mapped,
        json!([caret(4), { "start": 5, "length": 2 }, caret(6), caret(8)])
    );
}

#[test]
fn unknown_commands_and_bad_arguments_are_refused() {
    let mut doc = SourceDocument::new("");
    assert!(Source::call(&mut doc, "NoSuchCommand", json!({})).is_err());
    assert!(Source::call(&mut doc, "Partner", json!({ "at": "x" })).is_err());
    assert!(Source::call(&mut doc, "Partner", json!({ "at": 0, "more": 1 })).is_err());
}

#[test]
fn maths_renders_as_svg_or_nothing() {
    let svg = free(
        "RenderMath",
        json!({ "tex": "x^2", "display": false, "size": 13 }),
    );
    assert!(svg["svg"].as_str().unwrap().starts_with("<svg"));
    assert!(svg["width"].as_f64().unwrap() > 0.0);
    let broken = free(
        "RenderMath",
        json!({ "tex": "\\frac{", "display": false, "size": 13 }),
    );
    assert_eq!(broken, Value::Null);
}

#[test]
fn the_menus_and_heading_levels_are_listed() {
    let menus = free("ListMenus", json!({}));
    assert!(menus["templates"]["insert"].is_array());
    assert!(menus["symbolGroups"].is_array());
    let levels = free("HeadingStyles", json!({}));
    assert_eq!(levels[0], json!({ "title": "Normal Text", "command": "" }));
    assert_eq!(levels[3]["command"], "section");
}

#[test]
fn a_dropped_figure_is_included_only_where_tex_reads_it() {
    let include =
        |path: &str, into: &str| free("IncludeGraphics", json!({ "path": path, "into": into }));
    assert_eq!(
        include("figs/plot.png", "main.tex"),
        "\\includegraphics{figs/plot.png}"
    );
    assert_eq!(
        include("Shot.JPG", "ch/intro.tex"),
        "\\includegraphics{Shot.JPG}"
    );
    assert_eq!(include("a.pdf", "main.tex"), "\\includegraphics{a.pdf}");
    assert_eq!(
        include("a b_{c}.png", "main.tex"),
        "\\includegraphics{a b_{c}.png}"
    );
    assert_eq!(include("a.pdf", "refs.bib"), Value::Null);
    for path in [
        "logo.svg", "ch1.tex", "png", "50%.png", "a#1.png", "a\\b.png", "a}{.png", "a{.png",
    ] {
        assert_eq!(include(path, "main.tex"), Value::Null, "{path}");
    }
}
