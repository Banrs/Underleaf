mod common;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

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
grep -q slowly "$main" && sleep 30
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
            .block_on(service.call("SetTexDir", json!({ "dir": bin })))
            .unwrap();
    })
    .join()
    .unwrap();
}

fn wait_until(why: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "{why}");
        std::thread::sleep(Duration::from_millis(20));
    }
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
    let open = json!({ "id": rig.id, "autoCompile": false });
    let again = rig.try_call("OpenProject", open.clone());
    assert_eq!(again.unwrap_err().kind, ErrorKind::Conflict);
    let second = rig.call_to(2, "OpenProject", open);
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
    let doc = rig.open_document("main.tex");
    assert_eq!(doc.with(|d| d.text()), MAIN);
    doc.edit(0, 0, "% note\n", None, false);
    assert_eq!(rig.call("Save", json!({ "reporting": true })), true);
    let disk = fs::read_to_string(rig.root().join("main.tex")).unwrap();
    assert_eq!(disk, format!("% note\n{MAIN}"));
}

#[tokio::test(flavor = "multi_thread")]
async fn two_sessions_save_at_once() {
    let rig = project().await;
    let other = rig.library.create("Q", "blank").await;
    rig.call_to(
        2,
        "OpenProject",
        json!({ "id": other, "autoCompile": false }),
    );
    rig.call_to(2, "OpenDocument", json!({ "path": "main.tex" }));
    let docs = [
        rig.open_document("main.tex"),
        rig.sessions.document(2, "main.tex").unwrap(),
    ];
    for doc in &docs {
        doc.edit(0, 0, "% both\n", None, false);
    }
    let saves = [SESSION, 2].map(|session| rig.send(session, "Save", json!({ "reporting": true })));
    for save in saves {
        assert_eq!(rig.reply(save).unwrap(), true);
    }
    for root in [rig.root(), rig.library.project_root(&other)] {
        assert!(
            fs::read_to_string(root.join("main.tex"))
                .unwrap()
                .starts_with("% both")
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn replies_follow_the_events_sent_before_them() {
    let rig = project().await;
    let answered_after = |kind: &str, command: &str, args: Value| {
        rig.forget();
        rig.call(command, args);
        assert!(
            rig.heard(kind),
            "{command} answered before its {kind} event"
        );
    };
    let draft = rig.call("SaveVersion", json!({ "name": "Draft" }));
    std::thread::sleep(Duration::from_millis(300));
    fs::remove_file(rig.root().join("main.tex")).unwrap();
    rig.event("tree", |e| !e["tree"].to_string().contains("main.tex"));
    answered_after("live", "StartLive", json!({}));
    let restore = json!({ "id": draft["id"], "paths": ["main.tex"] });
    answered_after("tree", "RestoreVersion", restore);
    let main = json!({ "patch": { "mainFile": "ch.tex" } });
    answered_after("tree", "SetSettings", main);
    let entry = json!({ "folder": "", "name": "new.tex", "dir": false });
    answered_after("tree", "CreateEntry", entry);
    let rename = json!({ "from": "new.tex", "to": "old.tex" });
    answered_after("tree", "Rename", rename);
    let doc = rig.open_document("ch.tex");
    doc.edit(0, 0, "mine ", None, false);
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    answered_after("conflict", "Save", json!({ "reporting": true }));
    let revert = json!({ "path": "ch.tex", "answer": "revert" });
    answered_after("document_reload", "Resolve", revert);
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_saves_and_ends_the_session() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    doc.edit(0, 0, "% last\n", None, false);
    assert_eq!(rig.call("CloseProject", json!({})), true);
    assert!(
        fs::read_to_string(rig.root().join("ch.tex"))
            .unwrap()
            .starts_with("% last")
    );
    let after = rig.try_call("Save", json!({ "reporting": true }));
    assert_eq!(after.unwrap_err().kind, ErrorKind::NotFound);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_file_not_in_utf8_is_refused() {
    let rig = project().await;
    fs::write(rig.root().join("latin.tex"), b"caf\xe9").unwrap();
    let refused = rig.try_call("OpenDocument", json!({ "path": "latin.tex" }));
    assert_eq!(refused.unwrap_err().kind, ErrorKind::Invalid);
}

#[tokio::test(flavor = "multi_thread")]
async fn search_reads_unsaved_text() {
    let rig = project().await;
    let doc = rig.open_document("main.tex");
    doc.edit(0, 0, "a cat\n", None, false);
    let search = |query: &str, whole_word: bool| {
        let asked = json!({ "query": query, "matchCase": false, "wholeWord": whole_word });
        rig.call("Search", asked)
    };
    let found = search("cat", false);
    assert_eq!(names(&found, "file"), ["ch.tex", "main.tex"]);
    let hit = &found[1]["hits"][0];
    assert_eq!(
        (hit["line"].clone(), hit["column"].clone()),
        (json!(1), json!(2))
    );
    assert_eq!(search("ca", true), json!([]));
}

#[tokio::test(flavor = "multi_thread")]
async fn replace_writes_closed_files_and_answers_the_open_documents_edits() {
    let rig = Rig::open(&[("main.tex", "cat\n"), ("ch.tex", "cat cat\n")]).await;
    rig.open_document("main.tex");
    let replaced = rig.call(
        "Replace",
        json!({ "query": "cat", "replacement": "dog", "matchCase": false, "wholeWord": false }),
    );
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
    rig.open_document("main.tex");
    let renamed = rig.call(
        "RenameSymbol",
        json!({ "kind": "label", "from": "sec:intro", "to": "sec:start" }),
    );
    assert_eq!(renamed["edits"]["edits"].as_array().unwrap().len(), 2);
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        "\\ref{sec:start}\n"
    );
    let taken = rig.try_call(
        "RenameSymbol",
        json!({ "kind": "label", "from": "nothing", "to": "x" }),
    );
    assert_eq!(taken.unwrap_err().kind, ErrorKind::NotFound);
}

#[tokio::test(flavor = "multi_thread")]
async fn open_quickly_finds_files_headings_and_labels() {
    let rig = project().await;
    rig.event("outline", |e| {
        e["tree"].as_array().is_some_and(|t| t.len() == 2)
    });
    let found = rig.call("QuickOpen", json!({ "query": "intro" }));
    assert_eq!(names(&found, "kind"), ["heading", "label"]);
    let files = rig.call("QuickOpen", json!({ "query": "" }));
    assert_eq!(names(&files, "title"), ["ch.tex", "main.tex"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn usages_and_quick_help_describe_a_label() {
    let rig = project().await;
    rig.open_document("main.tex");
    rig.event("outline", |_| true);
    let offset = MAIN.find("\\ref{sec").unwrap() + 6;
    let at = json!({ "path": "main.tex", "offset": offset });
    let usages = rig.call("FindUsages", at.clone());
    assert_eq!(usages["name"], "\\label{sec:intro}");
    assert_eq!(usages["groups"][0]["hits"].as_array().unwrap().len(), 2);
    let help = rig.call("LookUp", at);
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
    let doc = rig.open_document("main.tex");
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
    let entry = |name: &str, dir: bool| json!({ "folder": "", "name": name, "dir": dir });
    let first = rig.call("CreateEntry", entry("untitled.tex", false));
    let second = rig.call("CreateEntry", entry("untitled.tex", false));
    assert_eq!(
        (first, second),
        (json!("untitled.tex"), json!("untitled 2.tex"))
    );
    let folder = rig.call("CreateEntry", entry("figs", true));
    assert!(rig.root().join(folder.as_str().unwrap()).is_dir());
    for name in [".texlocal.json", "../outside.tex"] {
        let refused = rig.try_call("CreateEntry", entry(name, false));
        assert_eq!(refused.unwrap_err().kind, ErrorKind::Invalid, "{name}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn renaming_the_main_file_keeps_it_the_main_file() {
    let rig = project().await;
    let renamed = rig.call("Rename", json!({ "from": "main.tex", "to": "thesis.tex" }));
    assert_eq!(renamed["to"], "thesis.tex");
    assert_eq!(renamed["mainFile"], "thesis.tex");
    assert!(rig.root().join("thesis.tex").is_file());
    let moved = rig.call(
        "Rename",
        json!({ "from": "ch.tex", "to": "chapters/ch.tex" }),
    );
    assert_eq!(moved["mainFile"], "thesis.tex");
    assert!(rig.root().join("chapters/ch.tex").is_file());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_main_file_is_never_prepared_for_deletion() {
    let rig = project().await;
    let refused = rig.try_call("PrepareDelete", json!({ "path": "main.tex" }));
    assert_eq!(refused.unwrap_err().kind, ErrorKind::Conflict);
    assert_eq!(rig.call("PrepareDelete", json!({ "path": "ch.tex" })), true);
    fs::remove_file(rig.root().join("ch.tex")).unwrap();
    rig.call("Deleted", json!({ "path": "ch.tex", "trashed": true }));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_named_version_is_listed_compared_and_restored() {
    let rig = project().await;
    let saved = rig.call("SaveVersion", json!({ "name": "Draft" }));
    assert_eq!(rig.call("ListVersions", json!({}))[0]["name"], "Draft");
    fs::write(rig.root().join("ch.tex"), "changed\n").unwrap();
    let id = saved["id"].clone();
    let rows = rig.call("CompareVersion", json!({ "id": id, "path": "ch.tex" }));
    let rows = rows.as_array().unwrap();
    assert!(rows.contains(&json!({ "type": "removed", "value": "words about a cat" })));
    assert!(rows.contains(&json!({ "type": "added", "value": "changed" })));
    rig.call("RestoreVersion", json!({ "id": id, "paths": ["ch.tex"] }));
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        CHAPTER
    );
    let empty = rig.try_call("SaveVersion", json!({ "name": " " }));
    assert_eq!(empty.unwrap_err().kind, ErrorKind::Invalid);
}

#[tokio::test(flavor = "multi_thread")]
async fn settings_change_and_bad_ones_are_refused() {
    let rig = project().await;
    let settings = rig.call("SetSettings", json!({ "patch": { "engine": "xelatex" } }));
    assert_eq!(settings["engine"], "xelatex");
    let refused = rig.try_call("SetSettings", json!({ "patch": { "engine": "word" } }));
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
    let opened = rig.call_to(
        2,
        "OpenProject",
        json!({ "id": rig.id, "autoCompile": false }),
    );
    assert_eq!(opened["settings"]["shellEscape"], false);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_on_disk_reaches_a_document_without_edits() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
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
    let doc = rig.open_document("ch.tex");
    doc.edit(0, 0, "mine ", None, false);
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    let conflict = rig.event("conflict", |e| e["path"] == "ch.tex");
    assert_eq!(conflict["kind"], "changed");
    assert_eq!(rig.call("CloseProject", json!({})), false);
    rig.call("Resolve", json!({ "path": "ch.tex", "answer": "save" }));
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        format!("mine {CHAPTER}")
    );
    assert_eq!(rig.call("CloseProject", json!({})), true);
}

#[tokio::test(flavor = "multi_thread")]
async fn revert_takes_the_disks_text() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    doc.edit(0, 0, "mine ", None, false);
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    rig.event("conflict", |e| e["path"] == "ch.tex");
    rig.call("Resolve", json!({ "path": "ch.tex", "answer": "revert" }));
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
    rig.open_document("main.tex");
    rig.call("Compile", json!({ "auto": false }));
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
    rig.call("Compile", json!({ "auto": false }));
    let started = rig.event("build", |e| e["compiling"] == true);
    assert_eq!(started["auto"], false);
    let finished = rig.event("build_finished", |_| true);
    assert_eq!(finished["result"]["ok"], true);
    assert_eq!(finished["result"]["errors"], json!([]));
    rig.call("Clean", json!({}));
    assert!(!rig.root().join("build").exists());
}

async fn compiling_slowly() -> Rig {
    let main = "\\documentclass{article}\n% slowly\n\\begin{document}\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    rig.call("Compile", json!({ "auto": false }));
    rig.event("build", |e| e["compiling"] == true);
    rig
}

#[tokio::test(flavor = "multi_thread")]
async fn kill_all_stops_the_builds_under_way() {
    let rig = compiling_slowly().await;
    rig.library.call("KillAll", json!({})).await;
    let finished = rig.event("build_finished", |_| true);
    assert_eq!(finished["result"]["stopped"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn stop_compile_stops_the_sessions_build() {
    let rig = compiling_slowly().await;
    wait_until("latexmk never started", || {
        rig.root().join("build").is_dir()
    });
    rig.call("StopCompile", json!({}));
    let finished = rig.event("build_finished", |_| true);
    assert_eq!(finished["result"]["stopped"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn turning_auto_compile_on_builds_after_a_save() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    rig.call("SetOptions", json!({ "autoCompile": true }));
    rig.open_document("ch.tex")
        .edit(0, 0, "% more\n", None, false);
    rig.call("Save", json!({ "reporting": true }));
    let started = rig.event("build", |e| e["compiling"] == true);
    assert_eq!(started["auto"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn autosave_waits_while_text_is_composed() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    let composing = |on: bool| rig.call("Composing", json!({ "path": "ch.tex", "composing": on }));
    let disk = || fs::read_to_string(rig.root().join("ch.tex")).unwrap();
    composing(true);
    doc.edit(0, 0, "ü", None, false);
    std::thread::sleep(Duration::from_millis(1200));
    assert_eq!(disk(), CHAPTER);
    composing(false);
    wait_until("the composed text was never saved", || disk() != CHAPTER);
    assert_eq!(disk(), format!("ü{CHAPTER}"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_projects_latexmkrc_is_read_only_with_shell_escape_granted() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    let args = || fs::read_to_string(rig.root().join("build/args")).unwrap();
    rig.call("Compile", json!({ "auto": false }));
    rig.event("build_finished", |_| true);
    assert!(args().lines().any(|a| a == "-norc"));
    assert!(!args().contains("-shell-escape"));
    rig.forget();
    rig.call("SetSettings", json!({ "patch": { "shellEscape": true } }));
    rig.call("Compile", json!({ "auto": false }));
    rig.event("build_finished", |_| true);
    assert!(args().lines().any(|a| a == "-shell-escape"));
    assert!(!args().lines().any(|a| a == "-norc"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_fix_adds_the_package_a_command_needs() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\toprule\n\\end{document}\n";
    let rig = Rig::open(&[("main.tex", main)]).await;
    rig.open_document("main.tex");
    let fixed = rig.call("ApplyFix", json!({ "id": "package:booktabs" }));
    let edit = &fixed["edits"]["edits"][0];
    assert_eq!(edit["text"], "\n\\usepackage{booktabs}");
    assert_eq!(edit["start"], "\\documentclass{article}".len());
    let unknown = rig.try_call("ApplyFix", json!({ "id": "format:disk" }));
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
