mod common;

use std::sync::Arc;

use common::{apply, caret, run};
use serde_json::{Value, json};
use texlocal_latex::facts::Facts;
use texlocal_latex::file_kind;
use texlocal_latex::project::Scan;
use texlocal_latex::syntax::{Source, SourceDocument, Syntax};

fn free(command: &str, args: Value) -> Value {
    Syntax::call(command, args).expect(command)
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
fn typing_over_an_inserted_closer_closes_the_completions() {
    let mut doc = SourceDocument::new("\\ref");
    let typed = run(
        &mut doc,
        "TypeText",
        json!({ "selection": caret(4), "text": "{", "autoPair": true }),
    );
    apply(&mut doc, &typed["edit"]);
    let over = run(
        &mut doc,
        "TypeText",
        json!({ "selection": caret(5), "text": "}", "autoPair": true }),
    );
    assert_eq!(over["selection"], caret(6));
    assert_eq!(over["completions"], "close");
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
fn return_after_begin_keeps_an_existing_end_beyond_the_mirroring_limit() {
    let text = format!(
        "\\begin{{itemize}}\n{}\\end{{itemize}}",
        "word ".repeat(6000)
    );
    let mut doc = SourceDocument::new(&text);
    let answer = run(&mut doc, "InsertNewline", json!({ "selection": caret(15) }));
    assert_eq!(answer["edit"]["text"], "\n  ");
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
fn a_selection_is_a_commands_name_after_a_backslash_that_is_not_escaped() {
    let mut doc = SourceDocument::new("\\section{a} \\\\word");
    let mut selects = |start: u32, length: u32| {
        let selection = json!({ "start": start, "length": length });
        run(
            &mut doc,
            "SelectsCommand",
            json!({ "selection": selection }),
        )
    };
    assert_eq!(selects(1, 7), true);
    assert_eq!(selects(0, 1), true);
    assert_eq!(selects(9, 1), false);
    assert_eq!(selects(14, 4), false);
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
fn a_reference_leads_to_its_label_once_a_scan_has_read_it() {
    let text = "\\label{a} \\ref{a}";
    let mut doc = SourceDocument::named(text, "main.tex");
    let at = json!({ "at": 15 });
    assert_eq!(run(&mut doc, "DefinitionAt", at.clone()), Value::Null);
    let read = Arc::new(Facts::read(text, file_kind("main.tex")));
    let files = vec!["main.tex".to_owned()];
    let read = [(files[0].clone(), read)].into();
    doc.set_symbols(Scan::new(read, files, Arc::default()).symbols);
    let answer = run(&mut doc, "DefinitionAt", at);
    assert_eq!(answer["kind"], "label");
    assert_eq!(answer["places"][0]["column"], 7);
}

#[test]
fn a_bibtex_cross_reference_after_a_blank_line_leads_to_its_parent() {
    let text = "@book{child,
  title={Child},

  crossref={parent}
}

@book{parent, title={Parent}}";
    let path = "refs.bib";
    let mut doc = SourceDocument::named(text, path);
    let read = Arc::new(Facts::read(text, file_kind(path)));
    let files = vec![path.to_owned()];
    let read = [(path.to_owned(), read)].into();
    doc.set_symbols(Scan::new(read, files, Arc::default()).symbols);
    let answer = run(
        &mut doc,
        "DefinitionAt",
        json!({ "at": text.find("parent").unwrap() + 1 }),
    );
    assert_eq!(answer["kind"], "citation");
    assert_eq!(answer["name"], "parent");
    assert_eq!(
        answer["places"],
        json!([{ "file": path, "line": 7, "column": 6, "length": 6 }])
    );
}

#[test]
fn the_symbol_under_the_caret_is_read_from_its_paragraph_alone() {
    let text = "Intro \\ref{one}.\n\n\\label{fig:a} see \\cite{knuth,\n  lamport} é\n\nPlain \\input{ch} text.";
    for text in [
        text,
        "\\begin{verbatim}\nx\n\n\\ref{y}\n\\end{verbatim}\n",
        "\\begin{comment}\nx\n\n\\ref{y}\n\\end{comment}\n",
        "\\begin{verbatim}\n\n\\ref{y}\n\\end{verbatim}\n\\ref{z}",
        "\\begin{verbatim}\n\n\\ref{y}\n\\end{verbatim}\\ref{z}",
        "\\begin{verbatim}\n\n\\ref{y}\\end{verbatim}\\ref{z}",
    ] {
        let mut doc = SourceDocument::named(text, "main.tex");
        let whole = Facts::read(text, file_kind("main.tex"));
        for at in 0..=text.encode_utf16().count() as u32 {
            let read = doc
                .symbol_in(&whole, 0, at)
                .map(|(kind, name, _)| json!({ "kind": kind, "name": name }));
            let answer = run(&mut doc, "SymbolAt", json!({ "at": at }));
            assert_eq!(answer, read.unwrap_or_default(), "{text:?} at {at}");
        }
    }
    let mut doc = SourceDocument::named(text, "main.tex");
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
    let mut doc = SourceDocument::named(files[1].1, "main.tex");
    doc.set_symbols(symbols);
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
    let drawn = |tex: &str| {
        free(
            "RenderMath",
            json!({ "tex": tex, "display": false, "size": 13 }),
        )
    };
    assert!(drawn("\\alpha + \\text{é}")["svg"].is_string());
    for tex in ["\\text{中}", "😀", "x + \\text{Ω😀}"] {
        assert_eq!(drawn(tex), Value::Null, "{tex}");
    }
    let sane = |tex: &str| {
        let svg = drawn(tex);
        let (width, height) = (svg["width"].as_f64()?, svg["height"].as_f64()?);
        let sane = |v: f64| v > 0.0 && v < 1000.0;
        assert!(sane(width) && sane(height), "{tex}: {width} by {height}");
        Some(())
    };
    for tex in [
        "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}",
        "\\begin{cases} 1 & x > 0 \\\\ 0 & \\text{otherwise} \\end{cases}",
        "\\begin{gathered} a + b \\\\ c \\end{gathered}",
    ] {
        assert!(sane(tex).is_some(), "{tex}");
    }
    let text = "\\newcommand{\\pair}[2][0]{(#1, #2)} \\newcommand{\\R}{\\mathbb{R}} $\\pair{x} + \\pair[y]{z} \\in \\R$";
    let facts = Arc::new(Facts::read(text, file_kind("main.tex")));
    let names = vec!["main.tex".to_owned()];
    let symbols = Scan::new(
        [("main.tex".to_owned(), facts)].into(),
        names,
        Arc::default(),
    )
    .symbols;
    let mut doc = SourceDocument::named(text, "main.tex");
    doc.set_symbols(symbols);
    let caret = text.find("+ ").unwrap();
    let math = run(&mut doc, "MathAt", json!({ "caret": caret }));
    let tex = math["tex"].as_str().unwrap();
    assert!(tex.contains("\\texlocal@optional"), "{tex}");
    assert!(sane(tex).is_some(), "{tex}");
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

fn table(cells: &str) -> Value {
    free(
        "Tabular",
        json!({ "cells": cells, "indent": "", "booktabs": false }),
    )
}

fn lines(lines: &[&str]) -> Value {
    Value::from(lines.join("\n"))
}

#[test]
fn spreadsheet_cells_become_a_tabular_ruled_under_its_header_with_numbers_on_the_right() {
    let tabular = lines(&[
        "\\begin{tabular}{lr}",
        "  \\hline",
        "  Name & Score \\\\",
        "  \\hline",
        "  Ada & 10 \\\\",
        "  Bob & 9.5 \\\\",
        "  \\hline",
        "\\end{tabular}",
    ]);
    assert_eq!(table("Name\tScore\nAda\t10\nBob\t9.5"), tabular);
    assert_eq!(table("Name\tScore\nAda\t10\nBob\t9.5\n"), tabular);
    assert_eq!(table("Name\tScore\r\nAda\t10\r\nBob\t9.5\r\n"), tabular);
    assert_eq!(table("Name\tScore\rAda\t10\rBob\t9.5\r"), tabular);
    assert_eq!(table("\n\nName\tScore\nAda\t10\nBob\t9.5\n\t\n\n"), tabular);
}

#[test]
fn a_tabular_takes_booktabs_rules_and_the_lines_indentation_when_asked() {
    let tabular = free(
        "Tabular",
        json!({ "cells": "a\tb\nx\t2\n", "indent": "    ", "booktabs": true }),
    );
    let expected = lines(&[
        "\\begin{tabular}{lr}",
        "      \\toprule",
        "      a & b \\\\",
        "      \\midrule",
        "      x & 2 \\\\",
        "      \\bottomrule",
        "    \\end{tabular}",
    ]);
    assert_eq!(tabular, expected);
}

#[test]
fn a_single_row_is_ruled_above_and_below_and_aligned_by_its_own_cells() {
    let tabular = lines(&[
        "\\begin{tabular}{rl}",
        "  \\hline",
        "  1 & x \\\\",
        "  \\hline",
        "\\end{tabular}",
    ]);
    assert_eq!(table("1\tx\n"), tabular);
}

#[test]
fn a_cells_latex_specials_are_escaped() {
    let tabular = table("a & b\t50% of $5 for #1_x\n{y}\t~ ^ \\ end\n");
    let row = |n: usize| tabular.as_str().unwrap().lines().nth(n).unwrap().to_owned();
    assert_eq!(row(2), "  a \\& b & 50\\% of \\$5 for \\#1\\_x \\\\");
    assert_eq!(
        row(4),
        "  \\{y\\} & \\textasciitilde{} \\textasciicircum{} \\textbackslash{} end \\\\"
    );
}

#[test]
fn ragged_rows_are_padded_and_empty_cells_leave_no_doubled_space() {
    let tabular = lines(&[
        "\\begin{tabular}{lll}",
        "  \\hline",
        "  a & b & c \\\\",
        "  \\hline",
        "  d & & \\\\",
        "  & & \\\\",
        "  & e & \\\\",
        "  \\hline",
        "\\end{tabular}",
    ]);
    assert_eq!(table("a\tb\tc\nd\n\t\t\n  \t e \t\n"), tabular);
}

#[test]
fn quoted_fields_keep_their_separators_and_quotes_and_line_breaks_become_a_space() {
    let csv = "name,note\n\"Smith, J.\",\"said \"\"hi\"\"\nthen left\"\r\nLee,\"\"\n";
    let tabular = lines(&[
        "\\begin{tabular}{ll}",
        "  \\hline",
        "  name & note \\\\",
        "  \\hline",
        "  Smith, J. & said \"hi\" then left \\\\",
        "  Lee & \\\\",
        "  \\hline",
        "\\end{tabular}",
    ]);
    assert_eq!(table(csv), tabular);
    let excel = table("a\t\"two\nlines\"\nb\t\"x\ty\"\n");
    let rows = "  a & two lines \\\\\n  \\hline\n  b & x y \\\\";
    assert!(excel.as_str().unwrap().contains(rows), "{excel}");
}

#[test]
fn tabs_separate_cells_before_commas_do() {
    let tabular = table("x, y\tz\n1,5\t2\n");
    let tabular = tabular.as_str().unwrap();
    assert!(tabular.starts_with("\\begin{tabular}{rr}"), "{tabular}");
    assert!(tabular.contains("  x, y & z \\\\"), "{tabular}");
}

#[test]
fn a_column_is_numeric_when_every_filled_cell_below_the_header_is_a_number() {
    let columns = |cells: &[&str]| {
        let rows: Vec<String> = cells.iter().map(|cell| format!("{cell}\tx")).collect();
        let tabular = table(&format!("Head\tx\n{}", rows.join("\n")));
        tabular.as_str().unwrap()["\\begin{tabular}{".len()..][..2].to_owned()
    };
    for numbers in [
        &["-1,234.5", "12%", "$3", "1e-3", "\u{2212}2", ".5", "+7"][..],
        &["1", "", "2"],
        &["€4.00", "£5", "1E6"],
    ] {
        assert_eq!(columns(numbers), "rl", "{numbers:?}");
    }
    for words in [
        &["1", "N/A"][..],
        &["", ""],
        &["2024-01-05"],
        &["12:30"],
        &["-"],
        &["e5"],
        &["1e"],
        &["5 kg"],
    ] {
        assert_eq!(columns(words), "ll", "{words:?}");
    }
}

#[test]
fn text_of_fewer_than_two_columns_is_no_table() {
    for text in ["", "\n\n", "one line", "one\ntwo\n", "\"a,b\"\n\"c\td\"\n"] {
        assert_eq!(table(text), Value::Null, "{text:?}");
    }
}
