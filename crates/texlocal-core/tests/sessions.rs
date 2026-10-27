mod common;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

use common::{Library, Rig, SESSION};
use serde_json::{Value, json};
use texlocal_core::ErrorKind;

const MAIN: &str = "\\documentclass{article}\n\\begin{document}\n\\section{Intro}\\label{sec:intro}\nSee \\ref{sec:intro}.\n\\input{ch}\n\\end{document}\n";
const CHAPTER: &str = "\\section{Chapter}\nwords about a cat\n";

async fn project() -> Rig {
    Rig::open(&[("main.tex", MAIN), ("ch.tex", CHAPTER)]).await
}

const LATEXMK: &str = r#"#!/bin/sh
[ "$1" = -version ] && { echo "Latexmk, John Collins, 4 Jan 2026. Version 4.86"; exit 0; }
for arg in "$@"; do
  case "$arg" in -outdir=*) out="${arg#-outdir=}";; ./*) main="${arg#./}";; esac
done
mkdir -p "$out"
printf '%s\n' "$@" > "$out/args"
stem="${main%.tex}"
printf '%%PDF-1.4\n' > "$out/$stem.pdf"
line=$(grep -n 'undefinedcommand' "$main" | head -1 | cut -d: -f1)
if [ -n "$line" ]; then
  printf './%s:%s: Undefined control sequence.\nl.%s \\undefinedcommand\n' "$main" "$line" "$line" > "$out/$stem.log"
  exit 12
fi
printf 'Output written on %s.pdf (1 page).\n' "$stem" > "$out/$stem.log"
"#;

fn stub_tex(library: &Library) {
    let tex = library.path("tex");
    let bin = tex.join("bin");
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir(tex.join("texmf-dist")).unwrap();
    let ls_r = "./tex/latex/base:\narticle.cls\nsample2e.tex\n";
    fs::write(tex.join("texmf-dist/ls-R"), ls_r).unwrap();
    let latexmk = bin.join("latexmk");
    fs::write(&latexmk, LATEXMK).unwrap();
    fs::set_permissions(&latexmk, fs::Permissions::from_mode(0o755)).unwrap();
    let service = std::sync::Arc::clone(&library.service);
    std::thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(service.call("set_tex_dir", json!({ "dir": bin })))
            .unwrap();
    })
    .join()
    .unwrap();
}

fn names(list: &Value, key: &str) -> Vec<String> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|item| item[key].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn opening_answers_the_project_and_its_number_is_taken() {
    let rig = project().await;
    let again = rig
        .try_call("session_open", json!({ "id": rig.id, "session": SESSION }))
        .await;
    assert_eq!(again.unwrap_err().kind, ErrorKind::Conflict);
    let second = rig
        .call("session_open", json!({ "id": rig.id, "session": 2 }))
        .await;
    assert_eq!(second["name"], "P");
    assert_eq!(second["settings"]["mainFile"], "main.tex");
    assert_eq!(second["settings"]["shellEscape"], false);
    assert_eq!(names(&second["tree"], "name"), ["ch.tex", "main.tex"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn checks_find_undefined_labels_and_unclosed_environments() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\ref{nowhere}\n\\begin{itemize}\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    let checks = rig.event("checks", |e| {
        e["items"].as_array().is_some_and(|i| i.len() == 2)
    });
    let items = &checks["items"];
    assert_eq!(items[0]["type"], "warning");
    assert_eq!(items[0]["line"], 3);
    assert_eq!(items[1]["type"], "error");
    assert_eq!(items[1]["line"], 5);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_outline_follows_inputs_and_counts_words() {
    let rig = project().await;
    let outline = rig.event("outline", |e| {
        e["tree"].as_array().is_some_and(|t| t.len() == 2)
    });
    assert_eq!(names(&outline["tree"], "title"), ["Intro", "Chapter"]);
    assert_eq!(names(&outline["tree"], "file"), ["main.tex", "ch.tex"]);
    assert_eq!(outline["tree"][1]["words"], 5);
    let levels = names(&outline["headingStyles"], "command");
    assert!(
        !levels.contains(&"chapter".to_owned()),
        "an article has no chapters"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_edit_is_saved_to_disk() {
    let rig = project().await;
    let doc = rig.open_document("main.tex").await;
    assert_eq!(doc.with(|d| d.text()), MAIN);
    doc.edit(0, 0, "% note\n", None, false);
    assert_eq!(rig.call("session_save", json!({})).await["saved"], true);
    let disk = fs::read_to_string(rig.root().join("main.tex")).unwrap();
    assert_eq!(disk, format!("% note\n{MAIN}"));
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_saves_and_ends_the_session() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex").await;
    doc.edit(0, 0, "% last\n", None, false);
    assert_eq!(rig.call("session_close", json!({})).await["saved"], true);
    assert!(
        fs::read_to_string(rig.root().join("ch.tex"))
            .unwrap()
            .starts_with("% last")
    );
    let after = rig.try_call("session_save", json!({})).await;
    assert_eq!(after.unwrap_err().kind, ErrorKind::NotFound);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_file_not_in_utf8_is_refused() {
    let rig = project().await;
    fs::write(rig.root().join("latin.tex"), b"caf\xe9").unwrap();
    let refused = rig
        .try_call("session_open_document", json!({ "path": "latin.tex" }))
        .await;
    assert_eq!(refused.unwrap_err().kind, ErrorKind::Invalid);
}

#[tokio::test(flavor = "multi_thread")]
async fn search_reads_unsaved_text() {
    let rig = project().await;
    let doc = rig.open_document("main.tex").await;
    doc.edit(0, 0, "a cat\n", None, false);
    let found = rig.call("session_search", json!({ "query": "cat" })).await;
    assert_eq!(names(&found, "file"), ["ch.tex", "main.tex"]);
    let hit = &found[1]["hits"][0];
    assert_eq!(
        (hit["line"].clone(), hit["column"].clone()),
        (json!(1), json!(2))
    );
    let whole = rig
        .call(
            "session_search",
            json!({ "query": "ca", "wholeWord": true }),
        )
        .await;
    assert_eq!(whole, json!([]));
}

#[tokio::test(flavor = "multi_thread")]
async fn replace_writes_closed_files_and_answers_the_open_documents_edits() {
    let rig = Rig::open(&[("main.tex", "cat\n"), ("ch.tex", "cat cat\n")]).await;
    rig.open_document("main.tex").await;
    let replaced = rig
        .call(
            "session_replace",
            json!({ "query": "cat", "replacement": "dog" }),
        )
        .await;
    assert_eq!(
        replaced["written"],
        json!([{ "file": "ch.tex", "count": 2 }])
    );
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        "dog dog\n"
    );
    assert_eq!(replaced["edits"]["path"], "main.tex");
    assert_eq!(replaced["edits"]["edits"][0]["text"], "dog");
    assert_eq!(
        fs::read_to_string(rig.root().join("main.tex")).unwrap(),
        "cat\n"
    );
    assert!(replaced["snapshot"].is_string());
}

#[tokio::test(flavor = "multi_thread")]
async fn renaming_a_label_changes_every_reference() {
    let rig = Rig::open(&[("main.tex", MAIN), ("ch.tex", "\\ref{sec:intro}\n")]).await;
    rig.open_document("main.tex").await;
    let renamed = rig
        .call(
            "session_rename_symbol",
            json!({ "kind": "label", "from": "sec:intro", "to": "sec:start" }),
        )
        .await;
    assert_eq!(renamed["edits"]["edits"].as_array().unwrap().len(), 2);
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        "\\ref{sec:start}\n"
    );
    let taken = rig
        .try_call(
            "session_rename_symbol",
            json!({ "kind": "label", "from": "nothing", "to": "x" }),
        )
        .await;
    assert_eq!(taken.unwrap_err().kind, ErrorKind::NotFound);
}

#[tokio::test(flavor = "multi_thread")]
async fn open_quickly_finds_files_headings_and_labels() {
    let rig = project().await;
    rig.event("outline", |e| {
        e["tree"].as_array().is_some_and(|t| t.len() == 2)
    });
    let found = rig
        .call("session_quick_open", json!({ "query": "intro" }))
        .await;
    assert_eq!(names(&found, "kind"), ["heading", "label"]);
    let files = rig.call("session_quick_open", json!({ "query": "" })).await;
    assert_eq!(names(&files, "title"), ["ch.tex", "main.tex"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn usages_and_quick_help_describe_a_label() {
    let rig = project().await;
    rig.open_document("main.tex").await;
    rig.event("outline", |_| true);
    let offset = MAIN.find("\\ref{sec").unwrap() + 6;
    let usages = rig
        .call(
            "session_usages",
            json!({ "path": "main.tex", "offset": offset }),
        )
        .await;
    assert_eq!(usages["name"], "\\label{sec:intro}");
    assert_eq!(usages["groups"][0]["hits"].as_array().unwrap().len(), 2);
    let help = rig
        .call(
            "session_quick_help",
            json!({ "path": "main.tex", "offset": offset }),
        )
        .await;
    assert_eq!(help["title"], "sec:intro");
    assert_eq!(help["place"]["line"], 3);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reference_completes_with_the_projects_labels() {
    let rig = Rig::open(&[
        ("main.tex", "\\input{ch}\n\\ref{"),
        ("ch.tex", "\\label{fig:plot}\n"),
    ])
    .await;
    let doc = rig.open_document("main.tex").await;
    rig.event("outline", |_| true);
    std::thread::sleep(Duration::from_millis(500));
    let answer = doc
        .with(|d| d.call("completions", r#"{"caret": 16, "explicit": true}"#))
        .unwrap();
    assert!(answer.contains("fig:plot"), "{answer}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_entry_is_numbered_past_a_taken_name() {
    let rig = project().await;
    let first = rig
        .call("session_create_entry", json!({ "name": "untitled.tex" }))
        .await;
    let second = rig
        .call("session_create_entry", json!({ "name": "untitled.tex" }))
        .await;
    assert_eq!(
        (first["path"].clone(), second["path"].clone()),
        (json!("untitled.tex"), json!("untitled 2.tex"))
    );
    let folder = rig
        .call(
            "session_create_entry",
            json!({ "name": "figs", "dir": true }),
        )
        .await;
    assert!(rig.root().join(folder["path"].as_str().unwrap()).is_dir());
    for name in [".texlocal.json", "../outside.tex"] {
        let refused = rig
            .try_call("session_create_entry", json!({ "name": name }))
            .await;
        assert_eq!(refused.unwrap_err().kind, ErrorKind::Invalid, "{name}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn renaming_the_main_file_keeps_it_the_main_file() {
    let rig = project().await;
    let renamed = rig
        .call(
            "session_rename",
            json!({ "from": "main.tex", "to": "thesis.tex" }),
        )
        .await;
    assert_eq!(renamed["to"], "thesis.tex");
    assert_eq!(renamed["mainFile"], "thesis.tex");
    assert!(rig.root().join("thesis.tex").is_file());
    let moved = rig
        .call(
            "session_rename",
            json!({ "from": "ch.tex", "to": "chapters/ch.tex" }),
        )
        .await;
    assert_eq!(moved["mainFile"], "thesis.tex");
    assert!(rig.root().join("chapters/ch.tex").is_file());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_main_file_is_never_prepared_for_deletion() {
    let rig = project().await;
    let refused = rig
        .try_call("session_prepare_delete", json!({ "path": "main.tex" }))
        .await;
    assert_eq!(refused.unwrap_err().kind, ErrorKind::Conflict);
    let ready = rig
        .call("session_prepare_delete", json!({ "path": "ch.tex" }))
        .await;
    assert_eq!(ready["ready"], true);
    fs::remove_file(rig.root().join("ch.tex")).unwrap();
    rig.call("session_deleted", json!({ "path": "ch.tex" }))
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_named_version_is_listed_compared_and_restored() {
    let rig = project().await;
    let saved = rig
        .call("session_history_save", json!({ "name": "Draft" }))
        .await;
    assert_eq!(
        rig.call("session_history_list", json!({})).await[0]["name"],
        "Draft"
    );
    fs::write(rig.root().join("ch.tex"), "changed\n").unwrap();
    let id = saved["id"].clone();
    let rows = rig
        .call(
            "session_history_compare",
            json!({ "id": id, "path": "ch.tex" }),
        )
        .await;
    assert!(
        rows.as_array()
            .unwrap()
            .iter()
            .any(|row| row["removed"] == "words about a cat")
    );
    assert!(
        rows.as_array()
            .unwrap()
            .iter()
            .any(|row| row["added"] == "changed")
    );
    rig.call(
        "session_history_restore",
        json!({ "id": id, "paths": ["ch.tex"] }),
    )
    .await;
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        CHAPTER
    );
    let empty = rig
        .try_call("session_history_save", json!({ "name": " " }))
        .await;
    assert_eq!(empty.unwrap_err().kind, ErrorKind::Invalid);
}

#[tokio::test(flavor = "multi_thread")]
async fn settings_change_and_bad_ones_are_refused() {
    let rig = project().await;
    let settings = rig
        .call(
            "session_set_settings",
            json!({ "patch": { "engine": "xelatex" } }),
        )
        .await;
    assert_eq!(settings["engine"], "xelatex");
    let refused = rig
        .try_call(
            "session_set_settings",
            json!({ "patch": { "engine": "word" } }),
        )
        .await;
    assert_eq!(refused.unwrap_err().kind, ErrorKind::Invalid);
    let stored = fs::read_to_string(rig.root().join(".texlocal.json")).unwrap();
    assert!(stored.contains("xelatex"));
}

#[tokio::test(flavor = "multi_thread")]
async fn shell_escape_in_a_projects_own_settings_is_not_granted() {
    let rig = Rig::open_with(&[("main.tex", MAIN)], |library| {
        let root = library.project_root("P");
        fs::write(root.join(".texlocal.json"), r#"{"shellEscape": true}"#).unwrap();
    })
    .await;
    let opened = rig
        .call("session_open", json!({ "id": rig.id, "session": 2 }))
        .await;
    assert_eq!(opened["settings"]["shellEscape"], false);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_on_disk_reaches_a_document_without_edits() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex").await;
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    let reload = rig.event("document_reload", |e| e["path"] == "ch.tex");
    assert_eq!(reload["text"], "theirs\n");
    assert!(doc.reload("theirs\n"));
    assert_eq!(doc.with(|d| d.text()), "theirs\n");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_on_disk_under_edits_is_asked_about_and_save_keeps_the_edits() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex").await;
    doc.edit(0, 0, "mine ", None, false);
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    let conflict = rig.event("conflict", |e| e["path"] == "ch.tex");
    assert_eq!(conflict["kind"], "changed");
    assert_eq!(rig.call("session_close", json!({})).await["saved"], false);
    let resolved = rig
        .call(
            "session_resolve",
            json!({ "path": "ch.tex", "answer": "save" }),
        )
        .await;
    assert_eq!(resolved["saved"], true);
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        format!("mine {CHAPTER}")
    );
    assert_eq!(rig.call("session_close", json!({})).await["saved"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn revert_takes_the_disks_text() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex").await;
    doc.edit(0, 0, "mine ", None, false);
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    rig.event("conflict", |e| e["path"] == "ch.tex");
    rig.call(
        "session_resolve",
        json!({ "path": "ch.tex", "answer": "revert" }),
    )
    .await;
    let reload = rig.event("document_reload", |e| e["path"] == "ch.tex");
    assert_eq!(reload["text"], "theirs\n");
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        "theirs\n"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn another_apps_files_reach_the_tree() {
    let rig = project().await;
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("new.tex"), "x").unwrap();
    let tree = rig.event("tree", |e| e["tree"].to_string().contains("new.tex"));
    assert_eq!(
        names(&tree["tree"], "name"),
        ["ch.tex", "main.tex", "new.tex"]
    );
    fs::write(rig.root().join("ch.tex"), "y").unwrap();
    rig.event("files_changed", |e| {
        e["paths"].as_array().unwrap().contains(&json!("ch.tex"))
    });
}

#[tokio::test(flavor = "multi_thread")]
async fn a_build_shows_its_pdf_and_marks_its_errors() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\undefinedcommand\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    rig.open_document("main.tex").await;
    rig.call("session_compile", json!({})).await;
    let finished = rig.event("build_finished", |_| true);
    let result = &finished["result"];
    assert_eq!(result["ok"], false);
    assert!(result["pdf"].as_str().unwrap().ends_with("main.pdf"));
    assert_eq!(result["errors"][0]["line"], 3);
    assert_eq!(result["errors"][0]["file"], "main.tex");
    let issues = rig.event("issues", |e| {
        e["lines"].as_array().is_some_and(|l| !l.is_empty())
    });
    assert_eq!(issues["path"], "main.tex");
    assert_eq!(issues["lines"][0]["line"], 3);
    assert_eq!(issues["lines"][0]["error"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_clean_build_has_no_errors() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    rig.call("session_compile", json!({})).await;
    let started = rig.event("build", |e| e["compiling"] == true);
    assert_eq!(started["auto"], false);
    let finished = rig.event("build_finished", |_| true);
    assert_eq!(finished["result"]["ok"], true);
    assert_eq!(finished["result"]["errors"], json!([]));
    rig.call("session_clean", json!({})).await;
    assert!(!rig.root().join("build").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_projects_latexmkrc_is_read_only_with_shell_escape_granted() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    let args = || fs::read_to_string(rig.root().join("build/args")).unwrap();
    rig.call("session_compile", json!({})).await;
    rig.event("build_finished", |_| true);
    assert!(args().lines().any(|a| a == "-norc"));
    assert!(!args().contains("-shell-escape"));
    rig.forget();
    rig.call(
        "session_set_settings",
        json!({ "patch": { "shellEscape": true } }),
    )
    .await;
    rig.call("session_compile", json!({})).await;
    rig.event("build_finished", |_| true);
    assert!(args().lines().any(|a| a == "-shell-escape"));
    assert!(!args().lines().any(|a| a == "-norc"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_fix_adds_the_package_a_command_needs() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\toprule\n\\end{document}\n";
    let rig = Rig::open(&[("main.tex", main)]).await;
    rig.open_document("main.tex").await;
    let fixed = rig
        .call("session_fix", json!({ "id": "package:booktabs" }))
        .await;
    let edit = &fixed["edits"]["edits"][0];
    assert_eq!(edit["text"], "\n\\usepackage{booktabs}");
    assert_eq!(edit["start"], "\\documentclass{article}".len());
    let unknown = rig
        .try_call("session_fix", json!({ "id": "format:disk" }))
        .await;
    assert_eq!(unknown.unwrap_err().kind, ErrorKind::Invalid);
}

#[tokio::test(flavor = "multi_thread")]
async fn checks_find_duplicates_missing_files_and_open_groups() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\label{a}\\label{a}\n\\cite{nokey}\n\\input{missing}\n$x\n\nnext {\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    let checks = rig.event("checks", |e| {
        e["items"].as_array().is_some_and(|i| i.len() == 5)
    });
    let lines: Vec<u64> = checks["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["line"].as_u64().unwrap())
        .collect();
    assert_eq!(lines, [3, 4, 5, 6, 8]);
}
