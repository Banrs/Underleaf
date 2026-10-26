use serde_json::{Value, json};
use texlocal_core::syntax::{self, SourceDocument};

fn run(doc: &mut SourceDocument, command: &str, args: Value) -> Value {
    let answer = doc.call(command, &args.to_string()).expect(command);
    serde_json::from_str(&answer).unwrap()
}

fn caret(at: u32) -> Value {
    json!({ "start": at, "length": 0 })
}

fn apply(doc: &mut SourceDocument, edit: &Value) {
    let start = edit["start"].as_u64().unwrap() as u32;
    let length = edit["length"].as_u64().unwrap() as u32;
    doc.apply_edit(start, length, edit["text"].as_str().unwrap(), None, false);
}

fn kinds(doc: &mut SourceDocument) -> Vec<(String, String)> {
    let text: Vec<u16> = doc.text().encode_utf16().collect();
    doc.highlights(0, text.len() as u32)
        .iter()
        .map(|h| {
            let (start, end) = (h.start as usize, (h.start + h.length) as usize);
            (
                String::from_utf16_lossy(&text[start..end]),
                format!("{:?}", h.kind),
            )
        })
        .collect()
}

#[test]
fn highlighting_marks_commands_maths_and_comments() {
    let mut doc = SourceDocument::new("\\emph{a} $x$ % note");
    let found = kinds(&mut doc);
    assert!(found.contains(&("\\emph".into(), "Command".into())));
    assert!(found.contains(&("x".into(), "Maths".into())));
    assert!(found.contains(&("% note".into(), "Comment".into())));
}

#[test]
fn highlighting_marks_names_and_a_stray_brace() {
    let mut doc = SourceDocument::new("\\ref{fig} \\cite{key} }");
    let found = kinds(&mut doc);
    assert!(found.contains(&("fig".into(), "Argument".into())));
    assert!(found.contains(&("key".into(), "Argument".into())));
    assert!(found.contains(&("}".into(), "Invalid".into())));
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
fn a_command_completes_with_its_argument() {
    let mut doc = SourceDocument::new("\\sec");
    let answer = run(
        &mut doc,
        "completions",
        json!({ "caret": 4, "explicit": false }),
    );
    assert_eq!(answer["kind"], "command");
    assert_eq!(answer["start"], 0);
    assert!(
        answer["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["label"] == "\\section" && item["text"] == "\\section{}")
    );
}

#[test]
fn toggling_a_comment_adds_and_removes_it() {
    let mut doc = SourceDocument::new("text");
    let added = run(
        &mut doc,
        "toggle_comment",
        json!({ "selections": [caret(0)] }),
    );
    apply(&mut doc, &added[0]);
    assert_eq!(doc.text(), "% text");
    let removed = run(
        &mut doc,
        "toggle_comment",
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
        "set_heading",
        json!({ "caret": 3, "command": "subsection" }),
    );
    assert_eq!(deeper["edit"]["text"], "\\subsection{Intro}");
    let plain = run(
        &mut doc,
        "set_heading",
        json!({ "caret": 3, "command": "" }),
    );
    assert_eq!(plain["edit"]["text"], "Intro");
}

#[test]
fn typing_an_opener_inserts_its_closer() {
    for (typed, inserted) in [("$", "$$"), ("{", "{}"), ("(", "()")] {
        let mut doc = SourceDocument::new("a b");
        let answer = run(
            &mut doc,
            "type",
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
        "type",
        json!({ "selection": caret(1), "text": "{", "autoPair": true }),
    );
    apply(&mut doc, &typed["edit"]);
    let deleted = run(
        &mut doc,
        "delete_backward",
        json!({ "selection": caret(2), "autoPair": true }),
    );
    apply(&mut doc, &deleted["edit"]);
    assert_eq!(doc.text(), "a");
}

#[test]
fn return_after_begin_closes_the_environment() {
    let mut doc = SourceDocument::new("\\begin{itemize}");
    let answer = run(
        &mut doc,
        "insert_newline",
        json!({ "selection": caret(15) }),
    );
    apply(&mut doc, &answer["edit"]);
    assert!(doc.text().ends_with("\n\\end{itemize}"), "{}", doc.text());
}

#[test]
fn return_after_an_item_starts_another() {
    let mut doc = SourceDocument::new("\\begin{itemize}\n\\item one");
    let answer = run(
        &mut doc,
        "insert_newline",
        json!({ "selection": caret(25) }),
    );
    assert_eq!(answer["edit"]["text"], "\n\\item ");
}

#[test]
fn prose_words_leave_out_commands_maths_and_comments() {
    let mut doc = SourceDocument::new("\\section{Intro}\nSome $x^2$ text % a note\n");
    let answer = run(&mut doc, "words", json!({ "start": 0, "length": 40 }));
    assert_eq!(answer["words"], 3);
}

#[test]
fn the_maths_under_the_caret_is_found() {
    let mut doc = SourceDocument::new("Some $x^2$ text");
    let answer = run(&mut doc, "math_at", json!({ "caret": 7 }));
    assert_eq!(
        answer,
        json!({ "start": 5, "tex": "x^2", "display": false })
    );
    assert_eq!(
        run(&mut doc, "math_at", json!({ "caret": 12 })),
        Value::Null
    );
}

#[test]
fn bold_wraps_a_selection_and_reports_how_to_take_it_off() {
    let mut doc = SourceDocument::new("bold word");
    let wrapped = run(
        &mut doc,
        "toggle_style",
        json!({ "selections": [{ "start": 0, "length": 4 }], "style": "bold" }),
    );
    apply(&mut doc, &wrapped["edits"][0]);
    assert_eq!(doc.text(), "\\textbf{bold} word");
    let styles = run(
        &mut doc,
        "text_styles",
        json!({ "selection": { "start": 9, "length": 2 } }),
    );
    assert!(styles["bold"].is_array());
    assert!(styles["italic"].is_null());
}

#[test]
fn a_brace_finds_its_partner() {
    let mut doc = SourceDocument::new("\\textbf{a{b}c}");
    assert_eq!(run(&mut doc, "partner", json!({ "at": 7 })), 13);
}

#[test]
fn lines_move_duplicate_and_delete() {
    let mut doc = SourceDocument::new("one\ntwo");
    let moved = run(
        &mut doc,
        "move_lines",
        json!({ "selections": [caret(5)], "up": true }),
    );
    assert_eq!(moved["edits"][0]["text"], "two\none");
    let duplicated = run(
        &mut doc,
        "duplicate_lines",
        json!({ "selections": [caret(0)] }),
    );
    apply(&mut doc, &duplicated["edits"][0]);
    assert_eq!(doc.text(), "one\none\ntwo");
    let deleted = run(
        &mut doc,
        "delete_lines",
        json!({ "selections": [caret(0)] }),
    );
    apply(&mut doc, &deleted["edits"][0]);
    assert_eq!(doc.text(), "one\ntwo");
}

#[test]
fn tab_indents_every_selected_line() {
    let mut doc = SourceDocument::new("a\nb");
    let answer = run(
        &mut doc,
        "tab",
        json!({ "selections": [{ "start": 0, "length": 3 }], "step": 1 }),
    );
    assert_eq!(answer["edits"].as_array().unwrap().len(), 2);
}

#[test]
fn spelling_leaves_out_commands_and_maths() {
    let mut doc = SourceDocument::new("\\emph{word} and $x$");
    let ranges = run(
        &mut doc,
        "code_ranges",
        json!({ "selection": { "start": 0, "length": 19 }, "for": "spelling" }),
    );
    assert_eq!(
        ranges,
        json!([{ "start": 0, "length": 5 }, { "start": 16, "length": 3 }])
    );
}

#[test]
fn a_section_folds_to_the_next_heading() {
    let mut doc = SourceDocument::new("\\section{A}\ntext\n\\section{B}\nmore\n");
    assert_eq!(
        run(&mut doc, "folds", json!({})),
        json!([{ "line": 1, "end": 2 }, { "line": 3, "end": 4 }])
    );
}

#[test]
fn a_symbol_outside_maths_goes_in_dollars() {
    let mut doc = SourceDocument::new("");
    let answer = run(
        &mut doc,
        "insert_symbol",
        json!({ "command": "\\alpha", "selection": caret(0) }),
    );
    assert_eq!(answer["edit"]["text"], "$\\alpha$");
}

#[test]
fn a_figure_block_leaves_fields_to_fill() {
    let mut doc = SourceDocument::new("");
    let answer = run(
        &mut doc,
        "insert_block",
        json!({ "id": "figure", "selection": caret(0) }),
    );
    assert!(
        answer["edit"]["text"]
            .as_str()
            .unwrap()
            .starts_with("\\begin{figure}")
    );
    assert_eq!(answer["fields"].as_array().unwrap().len(), 3);
}

#[test]
fn a_reference_leads_to_its_label() {
    let mut doc = SourceDocument::new("\\label{a} \\ref{a}");
    let answer = run(&mut doc, "definition", json!({ "at": 15 }));
    assert_eq!(answer["kind"], "label");
    assert_eq!(answer["places"][0]["column"], 7);
}

#[test]
fn unknown_commands_and_bad_arguments_answer_nothing() {
    let mut doc = SourceDocument::new("");
    assert_eq!(doc.call("no_such_command", "{}"), None);
    assert_eq!(doc.call("partner", r#"{"at": "x"}"#), None);
}

#[test]
fn maths_renders_as_svg_or_says_why_not() {
    let svg: Value = serde_json::from_str(
        &syntax::call("math_svg", r#"{"tex":"x^2","display":false,"size":13}"#).unwrap(),
    )
    .unwrap();
    assert!(svg["svg"].as_str().unwrap().starts_with("<svg"));
    assert!(svg["width"].as_f64().unwrap() > 0.0);
    let broken: Value = serde_json::from_str(
        &syntax::call("math_svg", r#"{"tex":"\\frac{","display":false,"size":13}"#).unwrap(),
    )
    .unwrap();
    assert!(broken["error"].is_string());
}

#[test]
fn the_menus_and_heading_levels_are_listed() {
    let menus: Value = serde_json::from_str(&syntax::call("menus", "{}").unwrap()).unwrap();
    assert!(menus["templates"]["insert"].is_array());
    assert!(menus["symbolGroups"].is_array());
    let levels: Value =
        serde_json::from_str(&syntax::call("heading_styles", "{}").unwrap()).unwrap();
    assert_eq!(levels[0], json!({ "title": "Normal Text", "command": "" }));
    assert_eq!(levels[3]["command"], "section");
}
