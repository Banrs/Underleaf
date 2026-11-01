mod common;

use std::fs;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{FakePreview, Library, Rig, SESSION, names, write};
use serde_json::{Value, json};
use texlocal_core::ErrorKind;
use texlocal_core::session::{LiveEvent, RunEnd};
use texlocal_latex::syntax::Source;

const MAIN: &str = "\\documentclass{article}\n\\begin{document}\n\\section{Intro}\\label{sec:intro}\nSee \\ref{sec:intro}.\n\\input{ch}\n\\end{document}\n";
const CHAPTER: &str = "\\section{Chapter}\nwords about a cat\n";
const BROKEN: &str =
    "\\documentclass{article}\n\\begin{document}\n\\undefinedcommand\n\\end{document}\n";

async fn project() -> Rig {
    Rig::open(&[("main.tex", MAIN), ("ch.tex", CHAPTER)]).await
}

const LATEXMK: &str = r#"#!/bin/sh
[ "$1" = -version ] && { echo "Latexmk, John Collins, 4 Jan 2026. Version 4.86"; exit 0; }
for arg in "$@"; do
  case "$arg" in -outdir=*) out="${arg#-outdir=}";; ./*) main="${arg#./}";; esac
done
mkdir -p "$out"
: > "$out/${main%.tex}.fdb_latexmk"
stem="${main%.tex}"
if grep -q slowly "$main"; then
  echo partial > "$out/$stem.aux"
  grep -q 'slowly over' "$main" && echo partial > "$out/$stem.pdf"
  sleep 30 &
  echo $! > "$out/child"
  : > "$out/started"
  wait
fi
printf '%s\n' "$@" > "$out/args"
printf '%%PDF-1.4\n' > "$out/$stem.pdf"
line=$(grep -n 'undefinedcommand' "$main" | head -1 | cut -d: -f1)
if [ -n "$line" ]; then
  printf './%s:%s: Undefined control sequence.\nl.%s \\undefinedcommand\n' "$main" "$line" "$line" > "$out/$stem.log"
  exit 12
fi
printf 'Output written on %s.pdf (1 page).\n' "$stem" > "$out/$stem.log"
"#;

fn program(path: &Path, script: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let written = std::process::Command::new("sh")
        .args(["-c", r#"printf %s "$1" > "$0" && chmod 755 "$0""#])
        .arg(path)
        .arg(script)
        .status();
    assert!(written.unwrap().success());
}

fn app_settings(library: &Library, settings: Value) {
    let file = library.path("state/.texlocal-app.json");
    fs::write(file, settings.to_string()).unwrap();
}

fn stub_tex(library: &Library) {
    let tex = library.path("tex");
    fs::create_dir_all(tex.join("texmf-dist")).unwrap();
    let ls_r = "./tex/latex/base:\narticle.cls\nsample2e.tex\n";
    fs::write(tex.join("texmf-dist/ls-R"), ls_r).unwrap();
    program(&tex.join("bin/latexmk"), LATEXMK);
    app_settings(library, json!({ "texDir": tex.join("bin") }));
}

fn wait_until(why: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "{why}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn zip_names(path: &Path) -> Vec<String> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    let mut names: Vec<String> = archive
        .file_names()
        .map(|name| name.unwrap().into_owned())
        .collect();
    names.sort();
    let _ = archive.by_index(0).unwrap().read(&mut [0; 1]);
    names
}

fn every_section_then_the_reply(rig: &Rig) {
    let protocol = texlocal_core::protocol::protocol();
    let every = protocol.outbound["SessionSection"]["oneOf"]
        .as_array()
        .unwrap();
    let mut every: Vec<&str> = every
        .iter()
        .map(|case| case["properties"]["type"]["const"].as_str().unwrap())
        .collect();
    let mut said = rig.said();
    assert_eq!(said.pop().as_deref(), Some("reply"));
    said.sort_unstable();
    every.sort_unstable();
    assert_eq!(said, every);
}

#[tokio::test(flavor = "multi_thread")]
async fn opening_sends_every_section_before_its_reply_and_its_number_is_taken() {
    let rig = project().await;
    every_section_then_the_reply(&rig);
    let project = rig.section("project", |_| true);
    assert_eq!(project["name"], "P");
    assert_eq!(project["settings"]["mainFile"], "main.tex");
    let tree = rig.section("tree", |_| true);
    assert_eq!(names(&tree, "name"), ["ch.tex", "main.tex"]);
    let documents = rig.section("documents", |_| true);
    assert_eq!(names(&documents, "path"), ["main.tex"]);
    assert_eq!(rig.section("outline", |_| true), Value::Null);
    let open = json!({ "id": rig.id, "autoCompile": false });
    assert_eq!(rig.refuse("OpenProject", open), ErrorKind::Conflict);
}

#[tokio::test(flavor = "multi_thread")]
async fn reattaching_sends_every_section_again_as_it_is_now_before_its_reply() {
    let rig = project().await;
    rig.open_document("ch.tex");
    rig.forget();
    rig.call("Reattach", json!({}));
    every_section_then_the_reply(&rig);
    assert_eq!(rig.section("openFile", |_| true)["path"], "ch.tex");
    let documents = rig.section("documents", |_| true);
    assert_eq!(names(&documents, "path"), ["ch.tex"]);
    rig.forget();
    assert!(rig.ask_library("Resync", json!({})).is_ok());
    let tex = |e: &Value| e["type"] == "library" && e["value"]["type"] == "tex";
    assert_eq!(rig.find(tex)["value"]["value"], rig.tex);
    assert_eq!(rig.said().last().map(String::as_str), Some("reply"));
}

#[tokio::test(flavor = "multi_thread")]
async fn opening_reopens_the_last_open_file_before_its_reply_or_else_the_main_file() {
    let last = |file: &'static str| {
        move |library: &Library| {
            let ui = json!({ "ui": { "file": file } });
            let settings = library.project_root("P").join(".texlocal.json");
            fs::write(settings, ui.to_string()).unwrap();
        }
    };
    let reopened = |rig: Rig| {
        let said = rig.said();
        assert_eq!(said.last().map(String::as_str), Some("reply"));
        assert_eq!(said_of(&rig, &["openFile"]), ["openFile"]);
        let documents = rig.section("documents", |_| true);
        let open = rig.section("openFile", |_| true)["path"].take();
        (open, json!(names(&documents, "path")))
    };
    let both = [("main.tex", MAIN), ("ch.tex", CHAPTER)];
    let rig = Rig::open_with(&both, last("ch.tex")).await;
    assert_eq!(reopened(rig), (json!("ch.tex"), json!(["ch.tex"])));
    let rig = Rig::open_with(&both, last("gone.tex")).await;
    assert_eq!(reopened(rig), (json!("main.tex"), json!(["main.tex"])));
    let rig = Rig::open_with(&[("ch.tex", CHAPTER)], last("gone.tex")).await;
    assert_eq!(reopened(rig), (Value::Null, json!([])));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_section_is_sent_again_only_when_it_changes() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    rig.section("outline", |o| !o.is_null());
    let engine = rig.section("project", |_| true)["settings"]["engine"].clone();
    rig.forget();
    doc.edit(0, 0, "% more\n", None, false);
    rig.call("Save", json!({ "reporting": true }));
    rig.call("Open", json!({ "path": "ch.tex" }));
    rig.call("ReloadTree", json!({}));
    rig.call("SetSettings", json!({ "patch": { "engine": engine } }));
    assert_eq!(rig.said(), ["reply"; 4]);
    rig.forget();
    rig.call("SetSettings", json!({ "patch": { "engine": "xelatex" } }));
    assert_eq!(rig.said(), ["project", "reply"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_corrupt_settings_file_is_reported_at_open_and_left_as_it_is() {
    let corrupt = |library: &Library| {
        let root = library.project_root("P");
        fs::write(root.join(".texlocal.json"), "{ not json").unwrap();
    };
    let rig = Rig::open_with(&[("main.tex", MAIN)], corrupt).await;
    let project = rig.section("project", |_| true);
    let problem = &project["problem"];
    assert_eq!(problem["id"], "unreadable", "{problem}");
    assert_eq!(problem["args"]["name"], ".texlocal.json");
    assert_eq!(project["settings"]["mainFile"], "main.tex");
    let engine = json!({ "patch": { "engine": "xelatex" } });
    assert_eq!(rig.refuse("SetSettings", engine), ErrorKind::Conflict);
    let settings = rig.root().join(".texlocal.json");
    assert_eq!(fs::read_to_string(&settings).unwrap(), "{ not json");
    fs::write(&settings, r#"{ "engine": "lualatex" }"#).unwrap();
    let fixed = rig.section("project", |p| p["problem"].is_null());
    assert_eq!(fixed["settings"]["engine"], "lualatex");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_setting_lands_in_an_opened_folders_own_file_without_its_ui() {
    let rig = project().await;
    let folder = rig.library.path("Thesis");
    let own = r#"{"mainFile":"main.tex"}"#;
    write(&folder, &[("main.tex", MAIN), (".texlocal.json", own)]);
    let opened = rig.ask_library("OpenPath", json!({ "path": folder }));
    let id = opened.unwrap()["project"]["id"].clone();
    rig.call_to(2, "OpenProject", json!({ "id": id, "autoCompile": false }));
    rig.call_to(
        2,
        "SetSettings",
        json!({ "patch": { "engine": "xelatex" } }),
    );
    let file = fs::read_to_string(folder.join(".texlocal.json")).unwrap();
    let file: Value = serde_json::from_str(&file).unwrap();
    assert_eq!(file["engine"], "xelatex");
    assert_eq!(file["mainFile"], "main.tex");
    assert!(file["ui"].is_null(), "{file}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_setting_that_landed_is_shown_before_the_grant_that_failed_is_reported() {
    let rig = project().await;
    let folder = rig.library.path("Thesis");
    let own = r#"{"mainFile":"main.tex"}"#;
    let files = [
        ("main.tex", MAIN),
        ("ch.tex", CHAPTER),
        (".texlocal.json", own),
    ];
    write(&folder, &files);
    let opened = rig
        .ask_library("OpenPath", json!({ "path": folder }))
        .unwrap();
    let id = opened["project"]["id"].as_str().unwrap();
    rig.call_to(2, "OpenProject", json!({ "id": id, "autoCompile": false }));
    let ui = rig.library.service.project(id).unwrap().ui;
    fs::write(&ui, "{}").unwrap();
    fs::set_permissions(&ui, fs::Permissions::from_mode(0o444)).unwrap();
    rig.forget();
    let patch = json!({ "patch": { "mainFile": "ch.tex", "shellEscape": true } });
    let refused = rig.reply(rig.send(2, "SetSettings", patch)).unwrap_err();
    assert_eq!(refused.kind, ErrorKind::Denied);
    let said = ["project", "reply"];
    assert_eq!(said_of(&rig, &said), said);
    let project = rig.section_in(2, "project", |_| true);
    assert_eq!(project["settings"]["mainFile"], "ch.tex");
    assert_eq!(project["settings"]["shellEscape"], false);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_library_is_pushed_before_the_reply_that_changed_it_and_an_open_project_keeps_its_place()
 {
    let rig = project().await;
    rig.section("outline", |o| !o.is_null());
    rig.forget();
    rig.ask_library("ReloadProjects", json!({})).unwrap();
    assert_eq!(rig.said(), ["library", "reply"]);
    assert_eq!(names(&rig.listed(|_| true), "id"), ["P"]);
    rig.forget();
    rig.ask_library("ReloadProjects", json!({})).unwrap();
    let renamed = rig.ask_library("RenameProject", json!({ "id": "P", "name": "Q" }));
    assert_eq!(renamed.unwrap_err().kind, ErrorKind::Conflict);
    assert_eq!(rig.said(), ["reply", "reply"]);
    let folder = rig.library.path("Thesis");
    write(&folder, &[("main.tex", MAIN)]);
    let opened = rig
        .ask_library("OpenPath", json!({ "path": folder }))
        .unwrap();
    assert_eq!(rig.said(), ["reply", "reply", "library", "reply"]);
    let id = opened["project"]["id"].clone();
    rig.call_to(2, "OpenProject", json!({ "id": id, "autoCompile": false }));
    let forget = json!({ "id": id });
    let refused = rig.ask_library("ForgetFolder", forget.clone()).unwrap_err();
    assert_eq!(refused.kind, ErrorKind::Conflict);
    assert_eq!(rig.call_to(2, "CloseProject", json!({})), true);
    rig.ask_library("ForgetFolder", forget).unwrap();
    assert_eq!(
        names(&rig.listed(|l| l.as_array().unwrap().len() == 1), "id"),
        ["P"]
    );
    assert_eq!(rig.call("CloseProject", json!({})), true);
    rig.forget();
    rig.ask_library("RenameProject", json!({ "id": "P", "name": "Q" }))
        .unwrap();
    assert_eq!(rig.said(), ["library", "reply"]);
    assert_eq!(names(&rig.listed(|_| true), "id"), ["Q"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_library_that_cant_be_listed_after_a_change_is_logged_before_the_reply() {
    let rig = project().await;
    let data = rig.library.path("data");
    let mode = |mode| fs::set_permissions(&data, fs::Permissions::from_mode(mode)).unwrap();
    rig.section("outline", |o| !o.is_null());
    rig.forget();
    mode(0o300);
    let made = rig.ask_library("CreateProject", json!({ "name": "Q", "template": "blank" }));
    mode(0o755);
    assert_eq!(made.unwrap()["id"], "Q");
    assert_eq!(rig.said(), ["log", "reply"]);
    let log = rig.find(|e| e["type"] == "log")["value"].take();
    assert_eq!(log["level"], "error");
    let text = log["text"].as_str().unwrap();
    assert!(
        text.starts_with("The projects couldn’t be listed: "),
        "{text}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn checks_find_undefined_labels_and_unclosed_environments() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\ref{nowhere}\n\\begin{itemize}\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    let build = rig.section("build", |b| b["issues"].as_array().unwrap().len() == 2);
    let items = &build["issues"];
    assert_eq!(items[0]["kind"], "warning");
    assert_eq!(items[0]["line"], 3);
    assert_eq!(items[1]["kind"], "error");
    assert_eq!(items[1]["line"], 5);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_outline_follows_inputs_and_counts_words() {
    let rig = project().await;
    let outline = rig.section("outline", |e| {
        e["tree"].as_array().is_some_and(|t| t.len() == 2)
    });
    let heading = |key: &str| [0, 1].map(|i| outline["tree"][i]["heading"][key].clone());
    assert_eq!(heading("title"), ["Intro", "Chapter"]);
    assert_eq!(heading("file"), ["main.tex", "ch.tex"]);
    assert_eq!(outline["tree"][1]["words"], 5);
    let levels = names(&outline["headingStyles"], "command");
    assert!(
        !levels.contains(&"chapter".to_owned()),
        "an article has no chapters"
    );
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
    rig.call_to(2, "Open", json!({ "path": "main.tex" }));
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
    let saved = |root: &Path| fs::read_to_string(root.join("main.tex")).unwrap();
    assert_eq!(saved(&rig.root()), format!("% both\n{MAIN}"));
    assert!(saved(&rig.library.project_root(&other)).starts_with("% both\n"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_project_or_a_folder_in_or_around_it_opens_in_one_session_at_a_time() {
    let rig = project().await;
    let open = |id: &Value| json!({ "id": id, "autoCompile": false });
    let refused = |session, id: &Value| {
        let refused = rig.reply(rig.send(session, "OpenProject", open(id)));
        let refused = refused.unwrap_err();
        assert_eq!(refused.kind, ErrorKind::Conflict);
        refused.message
    };
    let id = json!(rig.id);
    assert_eq!(refused(2, &id)["id"], "project_open");
    assert_eq!(rig.call("Open", json!({ "path": "ch.tex" })), "ch.tex");
    assert_eq!(rig.call("CloseProject", json!({})), true);
    rig.call_to(3, "OpenProject", open(&id));
    assert_eq!(
        rig.call_to(3, "Open", json!({ "path": "main.tex" })),
        "main.tex"
    );
    let folder = rig.library.path("Papers");
    write(&folder, &[("main.tex", MAIN), ("thesis/main.tex", MAIN)]);
    let [outer, inner] = [folder.clone(), folder.join("thesis")].map(|path| {
        let opened = rig.ask_library("OpenPath", json!({ "path": path }));
        opened.unwrap()["project"]["id"].clone()
    });
    rig.call_to(4, "OpenProject", open(&inner));
    let around = refused(5, &outer);
    assert_eq!(around["id"], "shares_folder");
    assert_eq!(around["args"]["name"], "thesis");
    assert_eq!(rig.call_to(4, "CloseProject", json!({})), true);
    rig.call_to(5, "OpenProject", open(&outer));
    assert_eq!(refused(6, &inner)["args"]["name"], "Papers");
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
    rig.section("tree", |e| !e.to_string().contains("main.tex"));
    answered_after("live", "StartLive", json!({}));
    let restore = json!({ "id": draft["id"], "paths": ["main.tex"] });
    answered_after("tree", "RestoreVersion", restore);
    let main = json!({ "patch": { "mainFile": "ch.tex" } });
    answered_after("project", "SetSettings", main);
    let entry = json!({ "folder": "", "name": "new.tex", "dir": false });
    answered_after("tree", "CreateEntry", entry);
    let doc = rig.open_document("ch.tex");
    doc.edit(0, 0, "mine ", None, false);
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    answered_after("conflict", "Save", json!({ "reporting": true }));
    let revert = json!({ "path": "ch.tex", "answer": "revert" });
    answered_after("documentReload", "Resolve", revert);
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
    let after = rig.refuse("Save", json!({ "reporting": true }));
    assert_eq!(after, ErrorKind::NotFound);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_open_file_is_one_at_a_time_and_a_closed_documents_edits_are_refused() {
    let rig = project().await;
    let ch = rig.open_document("ch.tex");
    rig.open_document("main.tex");
    rig.section("openFile", |f| {
        f["path"] == "main.tex" && f["kind"] == "tex"
    });
    rig.section("documents", |d| names(d, "path") == ["main.tex"]);
    assert!(!ch.editable());
    assert!(ch.edit(0, 0, "late ", None, false).is_none());
    rig.forget();
    write(&rig.root(), &[("fig.png", "x")]);
    assert_eq!(rig.call("Open", json!({ "path": "fig.png" })), "fig.png");
    assert_eq!(rig.section("openFile", |_| true)["kind"], "image");
    assert_eq!(rig.section("documents", |_| true), json!([]));
    rig.forget();
    fs::remove_file(rig.root().join("fig.png")).unwrap();
    rig.section("openFile", Value::is_null);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_open_that_a_later_one_supersedes_is_dropped() {
    let rig = project().await;
    assert_eq!(rig.call("CloseProject", json!({})), true);
    rig.forget();
    let again = 2;
    let open = json!({ "id": rig.id, "autoCompile": false });
    rig.send(again, "OpenProject", open);
    let opens = ["ch.tex", "main.tex"].map(|path| rig.send(again, "Open", json!({ "path": path })));
    let opened = opens.map(|id| rig.reply(id).unwrap());
    assert_eq!(opened, [Value::Null, json!("main.tex")]);
    assert_eq!(said_of(&rig, &["openFile"]), ["openFile"]);
    assert_eq!(rig.section("openFile", |_| true)["path"], "main.tex");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_file_not_in_utf8_is_refused() {
    let rig = project().await;
    fs::write(rig.root().join("latin.tex"), b"caf\xe9").unwrap();
    let refused = rig.refuse("Open", json!({ "path": "latin.tex" }));
    assert_eq!(refused, ErrorKind::Invalid);
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
    let before = json!({ "id": replaced["snapshot"], "path": "ch.tex" });
    let rows = rig.call("CompareVersion", before);
    assert!(
        rows.as_array()
            .unwrap()
            .contains(&json!({ "type": "removed", "value": "cat cat" }))
    );
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
    let taken = rig.refuse(
        "RenameSymbol",
        json!({ "kind": "label", "from": "nothing", "to": "x" }),
    );
    assert_eq!(taken, ErrorKind::NotFound);
}

#[tokio::test(flavor = "multi_thread")]
async fn open_quickly_finds_files_headings_and_labels() {
    let rig = project().await;
    rig.section("outline", |e| {
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
    rig.section("outline", |o| !o.is_null());
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
    rig.section("outline", |o| !o.is_null());
    std::thread::sleep(Duration::from_millis(500));
    let complete = json!({ "caret": 16, "explicit": true });
    let answer = doc.with(|d| Source::call(d, "Complete", complete)).unwrap();
    assert_eq!(answer["items"][0]["label"], "fig:plot", "{answer}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_entry_is_numbered_past_a_taken_name() {
    let rig = project().await;
    let entry = |name: &str, dir: bool| json!({ "folder": "", "name": name, "dir": dir });
    let first = rig.call("CreateEntry", entry("untitled.tex", false));
    let second = rig.call("CreateEntry", entry("untitled.tex", false));
    assert_eq!(
        (first, second),
        (json!("untitled.tex"), json!("untitled-2.tex"))
    );
    let folders = [(); 2].map(|()| rig.call("CreateEntry", entry("figs", true)));
    assert_eq!(folders, [json!("figs"), json!("figs-2")]);
    assert!(rig.root().join("figs-2").is_dir());
    for name in [".texlocal.json", "../outside.tex"] {
        let refused = rig.refuse("CreateEntry", entry(name, false));
        assert_eq!(refused, ErrorKind::Invalid, "{name}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rename_sends_its_paths_and_the_open_files_sections_before_the_reply() {
    let rig = project().await;
    rig.open_document("main.tex");
    rig.section("outline", |o| !o.is_null());
    rig.forget();
    let renamed = rig.call("Rename", json!({ "from": "main.tex", "to": "thesis.tex" }));
    assert_eq!(renamed["to"], "thesis.tex");
    assert!(rig.root().join("thesis.tex").is_file());
    let said = [
        "renamed",
        "documents",
        "tree",
        "project",
        "openFile",
        "reply",
    ];
    assert_eq!(rig.said(), said);
    let renamed = rig.event("renamed", |_| true);
    assert_eq!(renamed, json!({ "from": "main.tex", "to": "thesis.tex" }));
    let project = rig.section("project", |_| true);
    assert_eq!(project["settings"]["mainFile"], "thesis.tex");
    let documents = rig.section("documents", |_| true);
    assert_eq!(names(&documents, "path"), ["thesis.tex"]);
    assert_eq!(rig.section("openFile", |_| true)["path"], "thesis.tex");
    rig.forget();
    rig.call("Rename", json!({ "from": "ch.tex", "to": "parts/ch.tex" }));
    let renamed = rig.event("renamed", |_| true);
    assert_eq!(renamed, json!({ "from": "ch.tex", "to": "parts/ch.tex" }));
}

#[tokio::test(flavor = "multi_thread")]
async fn renaming_the_open_file_to_another_kind_closes_or_opens_its_document() {
    let rig = project().await;
    rig.open_document("ch.tex");
    let rename = |from: &str, to: &str| {
        rig.forget();
        rig.call("Rename", json!({ "from": from, "to": to }));
        let open = rig.section("openFile", |_| true);
        let documents = rig.section("documents", |_| true);
        (
            open["kind"].as_str().unwrap().to_owned(),
            names(&documents, "path"),
        )
    };
    assert_eq!(rename("ch.tex", "ch.png"), ("image".into(), vec![]));
    assert_eq!(
        rename("ch.png", "ch.tex"),
        ("tex".into(), vec!["ch.tex".to_owned()])
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_trashed_file_closes_and_comes_back_but_the_main_file_stays() {
    let rig = project().await;
    let chapter = rig.open_document("ch.tex");
    chapter.edit(0, 0, "% mine\n", None, false);
    let refused = rig.refuse("Trash", json!({ "path": "main.tex" }));
    assert_eq!(refused, ErrorKind::Conflict);
    let trashed = rig.call("Trash", json!({ "path": "ch.tex" }));
    assert!(!rig.root().join("ch.tex").exists());
    rig.section("openFile", |f| f["path"] == "main.tex");
    rig.section("documents", |d| names(d, "path") == ["main.tex"]);
    rig.section("tree", |t| !t.to_string().contains("ch.tex"));
    let back = json!({ "path": "ch.tex", "trashed": trashed });
    rig.call("PutBack", back.clone());
    rig.section("tree", |t| t.to_string().contains("ch.tex"));
    let text = fs::read_to_string(rig.root().join("ch.tex")).unwrap();
    assert_eq!(text, format!("% mine\n{CHAPTER}"));
    assert_eq!(rig.refuse("PutBack", back), ErrorKind::NotFound);
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
    let empty = rig.refuse("SaveVersion", json!({ "name": " " }));
    assert_eq!(empty, ErrorKind::Invalid);
}

fn replace_cat() -> Value {
    json!({ "query": "cat", "replacement": "dog", "matchCase": false, "wholeWord": false })
}

#[tokio::test(flavor = "multi_thread")]
async fn a_version_a_snapshot_and_an_export_hold_the_edits_not_yet_saved() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    rig.call("Composing", json!({ "path": "ch.tex", "composing": true }));
    let holds_the_edits = |id: &Value| {
        let rows = rig.call("CompareVersion", json!({ "id": id, "path": "ch.tex" }));
        rows.as_array()
            .unwrap()
            .iter()
            .all(|row| row["type"] == "same")
    };
    doc.edit(0, 0, "% one\n", None, false);
    let draft = rig.call("SaveVersion", json!({ "name": "Draft" }));
    assert!(holds_the_edits(&draft["id"]));
    doc.edit(0, 0, "% two\n", None, false);
    let replaced = rig.call("Replace", replace_cat());
    assert!(holds_the_edits(&replaced["snapshot"]));
    doc.edit(0, 0, "% three\n", None, false);
    let dest = rig.library.path("P.zip");
    rig.call("ExportZip", json!({ "dest": dest, "forArxiv": false }));
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let mut exported = String::new();
    let mut chapter = archive.by_name("ch.tex").unwrap();
    chapter.read_to_string(&mut exported).unwrap();
    assert_eq!(exported, format!("% three\n% two\n% one\n{CHAPTER}"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_version_a_snapshot_or_an_export_is_refused_while_edits_cant_be_saved() {
    let rig = project().await;
    let dest = rig.library.path("P.zip");
    let asked = [
        ("SaveVersion", json!({ "name": "Draft" })),
        ("Replace", replace_cat()),
        ("ExportZip", json!({ "dest": dest, "forArxiv": false })),
    ];
    let refusals = || {
        asked
            .clone()
            .map(|(command, args)| rig.refuse(command, args))
    };
    let main = rig.root().join("main.tex");
    let doc = rig.open_document("main.tex");
    fs::set_permissions(&main, fs::Permissions::from_mode(0o444)).unwrap();
    doc.edit(0, 0, "% typed\n", None, false);
    assert_eq!(refusals(), [ErrorKind::Denied; 3]);
    fs::set_permissions(&main, fs::Permissions::from_mode(0o644)).unwrap();
    fs::write(&main, "theirs\n").unwrap();
    assert_eq!(refusals(), [ErrorKind::Conflict; 3]);
    let versions = rig.call("ListVersions", json!({}));
    let auto = |version: &Value| version["name"].is_null() && version["reason"].is_null();
    assert!(versions.as_array().unwrap().iter().all(auto));
    assert_eq!(
        fs::read_to_string(rig.root().join("ch.tex")).unwrap(),
        CHAPTER
    );
    assert!(!dest.exists());
    rig.call("Resolve", json!({ "path": "main.tex", "answer": "revert" }));
}

#[tokio::test(flavor = "multi_thread")]
async fn settings_change_and_bad_ones_are_refused() {
    let rig = project().await;
    rig.call("SetSettings", json!({ "patch": { "engine": "xelatex" } }));
    rig.section("project", |p| p["settings"]["engine"] == "xelatex");
    let refused = rig.refuse("SetSettings", json!({ "patch": { "engine": "word" } }));
    assert_eq!(refused, ErrorKind::Invalid);
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
    let project = rig.section("project", |_| true);
    assert_eq!(project["settings"]["shellEscape"], false);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_on_disk_reloads_a_document_without_edits_and_its_old_view_is_refused() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    rig.event("documentReload", |e| e == "ch.tex");
    assert_eq!(doc.with(|d| d.text()), "theirs\n");
    assert!(doc.edit(0, 0, "stale ", None, false).is_none());
    let shown = rig.sessions.document(SESSION, "ch.tex").unwrap();
    assert!(shown.edit(0, 0, "mine ", None, false).is_some());
    assert_eq!(doc.with(|d| d.text()), "mine theirs\n");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_on_disk_under_edits_is_asked_about_held_and_saved_with_the_edits() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    doc.edit(0, 0, "mine ", None, false);
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    let conflict = rig.event("conflict", |e| e["path"] == "ch.tex");
    assert_eq!(conflict["kind"], "changed");
    assert_eq!(rig.call("CloseProject", json!({})), false);
    rig.call("Resolve", json!({ "path": "ch.tex", "answer": "cancel" }));
    rig.section("documents", |d| d[0]["held"] == "changed");
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
    rig.event("documentReload", |e| e == "ch.tex");
    assert_eq!(doc.with(|d| d.text()), "theirs\n");
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
    let tree = rig.section("tree", |e| e.to_string().contains("new.tex"));
    assert_eq!(names(&tree, "name"), ["ch.tex", "main.tex", "new.tex"]);
    fs::write(rig.root().join("ch.tex"), "y").unwrap();
    rig.event("filesChanged", |e| {
        e.as_array().unwrap().contains(&json!("ch.tex"))
    });
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reloaded_tree_marks_the_main_file_and_hides_dotfiles() {
    let rig = project().await;
    write(&rig.root(), &[(".latexmkrc", ""), ("figs/a.png", "png")]);
    rig.forget();
    rig.call("ReloadTree", json!({}));
    assert!(rig.heard("tree"));
    let tree = rig.section("tree", |e| e.to_string().contains("figs"));
    assert_eq!(names(&tree, "name"), ["ch.tex", "figs", "main.tex"]);
    let main = &tree[2];
    assert_eq!(
        (&main["main"], &main["kind"]),
        (&json!(true), &json!("tex"))
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn files_are_imported_into_the_tree_and_a_name_taken_is_asked_about() {
    let rig = project().await;
    let image = rig.library.path("plot.png");
    fs::write(&image, "png").unwrap();
    let args = json!({ "dir": "figs", "paths": [image] });
    rig.forget();
    assert_eq!(rig.call("ImportFiles", args.clone())["existing"], json!([]));
    assert_eq!(fs::read(rig.root().join("figs/plot.png")).unwrap(), b"png");
    assert!(rig.heard("tree"));
    let second = rig.call("ImportFiles", args.clone());
    assert_eq!(
        second["existing"],
        json!([{ "path": "plot.png", "keepBoth": "plot-2.png" }])
    );
    let mut keep = args;
    keep["conflict"] = json!("keepBoth");
    rig.call("ImportFiles", keep);
    assert!(rig.root().join("figs/plot-2.png").is_file());
}

#[tokio::test(flavor = "multi_thread")]
async fn an_export_holds_the_sources_and_opens_as_a_new_project() {
    let rig = Rig::open(&[
        ("main.tex", MAIN),
        ("ch.tex", CHAPTER),
        ("build/main.pdf", "pdf"),
        (".git/HEAD", "x"),
    ])
    .await;
    let dest = rig.library.path("Shared.zip");
    rig.call("ExportZip", json!({ "dest": dest, "forArxiv": false }));
    assert_eq!(zip_names(&dest), ["ch.tex", "main.tex"]);
    let opened = rig.library.call("OpenPath", json!({ "path": dest })).await;
    assert_eq!(opened["project"]["name"], "Shared");
    assert!(rig.library.project_root("Shared").join("ch.tex").is_file());
}

#[tokio::test(flavor = "multi_thread")]
async fn an_arxiv_export_adds_its_readme_and_refuses_lualatex() {
    let rig = project().await;
    let dest = rig.library.path("arxiv.zip");
    rig.call("ExportZip", json!({ "dest": dest, "forArxiv": true }));
    assert!(zip_names(&dest).contains(&"00README.json".to_owned()));
    rig.call("SetSettings", json!({ "patch": { "engine": "lualatex" } }));
    let again = json!({ "dest": rig.library.path("b.zip"), "forArxiv": true });
    let refused = rig.refuse("ExportZip", again);
    assert_eq!(refused, ErrorKind::Conflict);
}

#[tokio::test(flavor = "multi_thread")]
async fn ui_state_is_written_to_the_state_folder_before_the_close_and_never_to_the_library() {
    let rig = project().await;
    let settings = rig.root().join(".texlocal.json");
    let modified = || fs::metadata(&settings).unwrap().modified().unwrap();
    let before = (fs::read(&settings).unwrap(), modified());
    let zoom = json!({ "type": "scale", "value": 1.5 });
    let place = json!({ "file": "ch.tex", "line": 12, "zoom": zoom });
    let patch = |patch| json!({ "patch": patch });
    rig.send(SESSION, "SetUiState", patch(json!({ "place": place })));
    let folders = json!({ "expandedFolders": ["figs"] });
    rig.send(SESSION, "SetUiState", patch(folders));
    let folds = json!({ "foldedHeadings": ["main.tex\tIntro"] });
    rig.send(SESSION, "SetUiState", patch(folds));
    assert_eq!(rig.call("CloseProject", json!({})), true);
    assert!((fs::read(&settings).unwrap(), modified()) == before);
    assert!(!rig.library.path("data/.ui").exists());
    let ui = &read_json(&rig.library.path("state/.ui/P.json"))["ui"];
    assert_eq!(
        (&ui["file"], &ui["line"], &ui["zoom"]),
        (&json!("ch.tex"), &json!(12), &json!(1.5))
    );
    assert_eq!(ui["expandedFolders"], json!(["figs"]));
    assert_eq!(ui["foldedHeadings"], json!(["main.tex\tIntro"]));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_old_files_place_and_grant_move_out_at_open_and_leave_it_at_a_settings_write() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], |library| {
        let root = library.project_root("P");
        let folder = fs::metadata(&root).unwrap();
        let old = json!({
            "mainFile": "main.tex",
            "theirs": 1,
            "shellEscapeFor": [folder.dev(), folder.ino()],
            "ui": { "file": "ch.tex", "line": 3, "openFile": "ch.tex" },
        });
        fs::write(root.join(".texlocal.json"), old.to_string()).unwrap();
    })
    .await;
    let settings = rig.root().join(".texlocal.json");
    let old = fs::read(&settings).unwrap();
    assert_eq!(rig.section("openFile", |_| true)["path"], "ch.tex");
    let project = rig.section("project", |_| true);
    assert_eq!(project["settings"]["shellEscape"], true);
    let moved = read_json(&rig.library.path("state/.ui/P.json"));
    assert_eq!(moved["ui"]["line"], 3);
    assert_eq!(moved["ui"]["openFile"], "ch.tex");
    assert!(moved["shellEscapeFor"].is_array());
    assert_eq!(moved["theirs"], Value::Null);
    let folders = json!({ "patch": { "expandedFolders": ["figs"] } });
    rig.call("SetUiState", folders);
    assert_eq!(fs::read(&settings).unwrap(), old);
    rig.call("SetSettings", json!({ "patch": { "engine": "xelatex" } }));
    let facts = json!({
        "mainFile": "main.tex",
        "engine": "xelatex",
        "stopOnFirstError": false,
        "theirs": 1,
    });
    assert_eq!(read_json(&settings), facts);
    let project = rig.section("project", |p| p["settings"]["engine"] == "xelatex");
    assert_eq!(project["settings"]["shellEscape"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_renamed_project_keeps_its_place_and_grant() {
    let rig = project().await;
    let place = json!({ "patch": { "place": { "file": "ch.tex" } } });
    rig.call("SetSettings", json!({ "patch": { "shellEscape": true } }));
    rig.call("SetUiState", place);
    rig.call("CloseProject", json!({}));
    let renamed = rig.ask_library("RenameProject", json!({ "id": "P", "name": "Q" }));
    assert_eq!(renamed.unwrap()["id"], "Q");
    assert!(!rig.library.path("state/.ui/P.json").exists());
    rig.call_to(2, "OpenProject", json!({ "id": "Q", "autoCompile": false }));
    assert_eq!(rig.section_in(2, "openFile", |_| true)["path"], "ch.tex");
    let project = rig.section_in(2, "project", |_| true);
    assert_eq!(project["settings"]["shellEscape"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_trashed_project_comes_back_with_its_place_and_grant_but_not_while_open() {
    let rig = project().await;
    let place = json!({ "patch": { "place": { "file": "ch.tex" } } });
    rig.call("SetSettings", json!({ "patch": { "shellEscape": true } }));
    rig.call("SetUiState", place);
    let trash = json!({ "id": "P" });
    let refused = rig.ask_library("TrashProject", trash.clone());
    assert_eq!(refused.unwrap_err().kind, ErrorKind::Conflict);
    rig.call("CloseProject", json!({}));
    let trashed = rig.ask_library("TrashProject", trash).unwrap();
    rig.listed(|projects| projects.as_array().unwrap().is_empty());
    rig.ask_library("ReloadProjects", json!({})).unwrap();
    let back = json!({ "id": "P", "trashed": trashed });
    rig.ask_library("PutBackProject", back).unwrap();
    rig.listed(|projects| names(projects, "id") == ["P"]);
    rig.call_to(2, "OpenProject", json!({ "id": "P", "autoCompile": false }));
    assert_eq!(rig.section_in(2, "openFile", |_| true)["path"], "ch.tex");
    let project = rig.section_in(2, "project", |_| true);
    assert_eq!(project["settings"]["shellEscape"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_copy_keeps_the_place_not_the_grant_and_a_new_project_at_a_gone_name_starts_afresh() {
    let rig = project().await;
    let place = json!({ "patch": { "place": { "file": "ch.tex" } } });
    rig.call("SetSettings", json!({ "patch": { "shellEscape": true } }));
    rig.call("SetUiState", place);
    let copy = rig.ask_library("DuplicateProject", json!({ "id": "P", "name": "P copy" }));
    let id = copy.unwrap()["id"].clone();
    rig.call_to(2, "OpenProject", json!({ "id": id, "autoCompile": false }));
    assert_eq!(rig.section_in(2, "openFile", |_| true)["path"], "ch.tex");
    let project = rig.section_in(2, "project", |_| true);
    assert_eq!(project["settings"]["shellEscape"], false);
    let copied = rig.library.path("state/.ui/P copy.json");
    assert!(read_json(&copied)["shellEscapeFor"].is_null());
    rig.call_to(2, "CloseProject", json!({}));
    fs::remove_dir_all(rig.library.path("data/P copy")).unwrap();
    rig.ask_library("ReloadProjects", json!({})).unwrap();
    assert!(copied.exists());
    let made = json!({ "name": "P copy", "template": "blank" });
    rig.ask_library("CreateProject", made).unwrap();
    assert!(!copied.exists() && rig.library.path("state/.ui/P.json").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_forward_match_reads_the_open_documents_text() {
    let rig = Rig::open(&[("main.tex", "the \\emph{world} turns\n")]).await;
    let pages = json!([{ "page": 3, "text": "the world and the world turns", "near": [] }]);
    let at = |line| json!({ "file": "main.tex", "line": line, "column": 11, "pages": pages });
    let hit = json!({ "page": 3, "start": 18, "end": 23 });
    assert_eq!(rig.call("SynctexMatch", at(1)), hit);
    rig.open_document("main.tex")
        .edit(0, 0, "\\section{Intro}\n", None, false);
    assert_eq!(rig.call("SynctexMatch", at(2)), hit);
    let forward = json!({ "file": "main.tex", "line": 2 });
    let unbuilt = rig.refuse("SynctexForward", forward);
    assert_eq!(unbuilt, ErrorKind::NotFound);
}

fn said_of(rig: &Rig, kinds: &[&str]) -> Vec<String> {
    let said = rig.said().into_iter();
    said.filter(|kind| kinds.contains(&kind.as_str())).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_build_sends_its_sections_and_its_log_before_it_finishes_and_its_pdf_follows_main() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    rig.section("outline", |o| !o.is_null());
    rig.forget();
    rig.call("Compile", json!({ "auto": false }));
    rig.event("buildFinished", |_| true);
    let said = [
        "build",
        "reply",
        "build",
        "buildLog",
        "shownPdf",
        "buildFinished",
    ];
    assert_eq!(rig.said(), said);
    let build = rig.section("build", |b| !b["result"].is_null());
    assert_eq!(build["result"]["ok"], true);
    assert_eq!(build["result"].get("log"), None);
    assert_eq!(build["issues"], json!([]));
    let log = rig.section("buildLog", |_| true);
    assert!(log.as_str().unwrap().contains("Output written on main.pdf"));
    let pdf = rig.section("shownPdf", |_| true);
    assert_eq!((&pdf["version"], &pdf["live"]), (&json!(1), &json!(false)));
    let path = pdf["path"].clone();
    assert!(path.as_str().unwrap().ends_with("build/main.pdf"));
    let main_file = |main: &str| {
        rig.forget();
        let patch = json!({ "patch": { "mainFile": main } });
        rig.call("SetSettings", patch);
        rig.section("shownPdf", |_| true)["path"].take()
    };
    assert_eq!(main_file("ch.tex"), Value::Null);
    assert_eq!(main_file("main.tex"), path);
    assert!(rig.root().join("build/main.fdb_latexmk").exists());
    rig.forget();
    rig.call("Clean", json!({}));
    assert_eq!(rig.said(), ["build", "buildLog", "shownPdf", "reply"]);
    assert_eq!(rig.section("build", |_| true)["result"], Value::Null);
    assert_eq!(rig.section("buildLog", |_| true), "");
    assert!(!rig.root().join("build").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_builds_error_is_listed_and_marks_its_line_in_one_section() {
    let rig = Rig::open_with(&[("main.tex", BROKEN)], stub_tex).await;
    let doc = rig.open_document("main.tex");
    rig.forget();
    rig.call("Compile", json!({ "auto": false }));
    rig.event("buildFinished", |_| true);
    let kinds = ["build", "shownPdf", "buildFinished", "reply"];
    let said = ["build", "reply", "build", "shownPdf", "buildFinished"];
    assert_eq!(said_of(&rig, &kinds), said);
    let build = rig.section("build", |b| !b["result"].is_null());
    assert_eq!(build["result"]["ok"], false);
    assert!(!rig.root().join("build/main.fdb_latexmk").exists());
    let issue = &build["issues"][0];
    assert_eq!(
        (&issue["file"], &issue["line"]),
        (&json!("main.tex"), &json!(3))
    );
    let line = &build["lines"]["main.tex"][0];
    assert_eq!((&line["line"], &line["error"]), (&json!(3), &json!(true)));
    assert_eq!(line["index"], 0);
    rig.forget();
    doc.edit(0, 0, "% more\n", None, false);
    let edited = rig.section("build", |_| true);
    assert_eq!(
        (&edited["outdated"], &edited["lines"]),
        (&json!(true), &json!({}))
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn live_pages_show_the_live_pdf_and_its_errors_mark_their_lines() {
    let preview = Arc::new(FakePreview::default());
    let rig = Rig::previewing(&[("main.tex", BROKEN)], |_| {}, Arc::clone(&preview)).await;
    let doc = rig.open_document("main.tex");
    rig.call("StartLive", json!({}));
    *preview.log.lock().unwrap() =
        "./main.tex:3: Undefined control sequence.\nl.3 \\undefinedcommand\n".into();
    rig.forget();
    preview.send(LiveEvent::Document {
        path: "live.pdf".into(),
        pages: 1,
        run: RunEnd::Complete,
        changed: Vec::new(),
    });
    preview.send(LiveEvent::Page {
        page: 0,
        pdf: "JVBERi0=".into(),
    });
    let live = rig.section("live", |l| !l["lines"]["main.tex"].is_null());
    assert_eq!(live["lines"]["main.tex"][0]["line"], 3);
    let kinds = ["shownPdf", "liveDocument", "livePage", "live"];
    assert_eq!(said_of(&rig, &kinds), kinds);
    assert_eq!(rig.section("shownPdf", |_| true)["live"], true);
    doc.edit(0, 0, "% more\n", None, false);
    rig.section("live", |l| l["lines"]["main.tex"][0]["line"] == 4);
    rig.forget();
    rig.call("StopLive", json!({}));
    assert!(!preview.running());
    let kinds = ["live", "shownPdf", "reply"];
    assert_eq!(said_of(&rig, &kinds), kinds);
    assert_eq!(rig.section("shownPdf", |_| true)["live"], false);
    let stopped = rig.section("live", |l| l["phase"] == "stopped");
    assert_eq!(stopped["lines"], json!({}));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_live_error_is_placed_by_its_root_relative_name_with_the_main_file_in_a_folder() {
    let preview = Arc::new(FakePreview::default());
    let files = [("sub/main.tex", MAIN), ("ch.tex", BROKEN)];
    let rig = Rig::previewing(&files, |_| {}, Arc::clone(&preview)).await;
    let main = json!({ "patch": { "mainFile": "sub/main.tex" } });
    rig.call("SetSettings", main);
    rig.open_document("ch.tex");
    rig.call("StartLive", json!({}));
    *preview.log.lock().unwrap() =
        "(sub/main.tex (ch.tex\n! Undefined control sequence.\nl.3 \\undefinedcommand\n".into();
    preview.send(LiveEvent::Done(RunEnd::Complete));
    let live = rig.section("live", |l| !l["lines"]["ch.tex"].is_null());
    assert_eq!(live["lines"]["ch.tex"][0]["line"], 3);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_remembered_live_preview_starts_at_open_and_only_compile_builds_beside_it() {
    let main = "\\documentclass{article}\n\\begin{document}\nHi.\n\\end{document}\n";
    let preview = Arc::new(FakePreview::default());
    let rig = Rig::previewing(&[("main.tex", main)], stub_tex, Arc::clone(&preview)).await;
    rig.call("StartLive", json!({}));
    rig.call("CloseProject", json!({}));
    assert!(!preview.running());
    rig.forget();
    let again = 2;
    rig.call_to(
        again,
        "OpenProject",
        json!({ "id": rig.id, "autoCompile": true }),
    );
    rig.section("live", |l| l["phase"] == "running");
    rig.call_to(again, "Open", json!({ "path": "main.tex" }));
    let doc = rig.sessions.document(again, "main.tex").unwrap();
    doc.edit(0, 0, "% more\n", None, false);
    rig.call_to(again, "Save", json!({ "reporting": true }));
    assert_eq!(said_of(&rig, &["build"]), ["build"]);
    rig.call_to(again, "Compile", json!({ "auto": false }));
    rig.section("build", |b| b["compiling"] == true);
}

async fn compiling_slowly() -> Rig {
    let main = "\\documentclass{article}\n% slowly\n\\begin{document}\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    rig.call("Compile", json!({ "auto": false }));
    rig
}

const SLEEPS: &str = "#!/bin/sh\necho $$ > \"$0.pid\"\nexec sleep 30\n";

fn alive(pid: &Path) -> bool {
    let pid = fs::read_to_string(pid).unwrap();
    let alive = std::process::Command::new("kill")
        .args(["-0", pid.trim()])
        .stderr(std::process::Stdio::null())
        .status();
    alive.unwrap().success()
}

#[tokio::test(flavor = "multi_thread")]
async fn kill_all_ends_every_child_and_starts_none_after() {
    let rig = compiling_slowly().await;
    program(&rig.library.path("tex/bin/tlmgr"), SLEEPS);
    program(&rig.library.path("slow/latexmk"), SLEEPS);
    let (build, tlmgr, probe) = (
        rig.root().join("build/child"),
        rig.library.path("tex/bin/tlmgr.pid"),
        rig.library.path("slow/latexmk.pid"),
    );
    let install = rig.send(SESSION, "ApplyFix", json!({ "id": "install:x.sty" }));
    wait_until("the install starts", || tlmgr.exists());
    let checked = rig.send_library("SetTexDir", json!({ "dir": rig.library.path("slow") }));
    wait_until("the probe starts", || build.exists() && probe.exists());
    rig.library.call("KillAll", json!({})).await;
    wait_until("every child ends", || {
        ![&build, &tlmgr, &probe]
            .map(|pid| alive(pid))
            .contains(&true)
    });
    let built = rig.section("build", |b| !b["result"].is_null());
    assert_eq!(built["result"]["stopped"], true);
    assert!(rig.reply(install).is_err());
    assert_eq!(rig.reply(checked).unwrap()["available"], false);
    fs::remove_file(&probe).unwrap();
    rig.ask_library("CheckTex", json!({})).unwrap();
    assert!(!probe.exists(), "a probe started after KillAll");
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_a_project_ends_the_install_it_started() {
    let rig = Rig::open_with(&[("main.tex", MAIN)], stub_tex).await;
    program(&rig.library.path("tex/bin/tlmgr"), SLEEPS);
    let tlmgr = rig.library.path("tex/bin/tlmgr.pid");
    let install = rig.send(SESSION, "ApplyFix", json!({ "id": "install:x.sty" }));
    wait_until("the install starts", || tlmgr.exists());
    assert_eq!(rig.call("CloseProject", json!({})), true);
    wait_until("the install ends", || !alive(&tlmgr));
    assert!(rig.reply(install).is_err());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stopped_build_discards_what_it_wrote_and_leaves_other_projects_building() {
    let main = "\\documentclass{article}\n% slowly over\n\\begin{document}\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    let other = rig.library.create("Other", "blank").await;
    let other_build = rig.library.project_root(&other).join("build");
    write(&rig.library.project_root(&other), &[("main.tex", main)]);
    rig.call_to(
        2,
        "OpenProject",
        json!({ "id": other, "autoCompile": false }),
    );
    rig.call("Compile", json!({ "auto": false }));
    rig.call_to(2, "Compile", json!({ "auto": false }));
    let build = rig.root().join("build");
    wait_until("both builds start", || {
        build.join("started").exists() && other_build.join("started").exists()
    });
    rig.call("StopCompile", json!({}));
    rig.event_in(SESSION, "buildFinished", |_| true);
    let result = &rig.section_in(SESSION, "build", |b| !b["result"].is_null())["result"];
    assert_eq!(result["stopped"], true);
    for partial in ["main.aux", "main.pdf", "main.fdb_latexmk"] {
        assert!(!build.join(partial).exists(), "{partial} is discarded");
    }
    wait_until("the build's own processes end", || {
        !alive(&build.join("child"))
    });
    assert!(
        alive(&other_build.join("child")),
        "the other project still builds"
    );
    assert!(other_build.join("main.aux").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stopped_build_keeps_the_last_pdf_it_did_not_touch() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    rig.call("Compile", json!({ "auto": false }));
    rig.section("build", |b| b["result"]["ok"] == true);
    let main = "\\documentclass{article}\n% slowly\n\\begin{document}\n\\end{document}\n";
    write(&rig.root(), &[("main.tex", main)]);
    rig.forget();
    rig.call("Compile", json!({ "auto": false }));
    let build = rig.root().join("build");
    wait_until("the build starts", || build.join("started").exists());
    rig.call("StopCompile", json!({}));
    rig.section("build", |b| b["result"]["stopped"] == true);
    assert!(!build.join("main.aux").exists());
    assert_eq!(
        fs::read_to_string(build.join("main.pdf")).unwrap(),
        "%PDF-1.4\n"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_answers_once_the_build_it_stopped_has_ended() {
    let rig = compiling_slowly().await;
    rig.forget();
    assert_eq!(rig.call("CloseProject", json!({})), true);
    let said = said_of(&rig, &["lifecycle", "buildFinished", "library", "reply"]);
    assert_eq!(said[..2], ["lifecycle", "buildFinished"]);
    assert_eq!(said[2..], ["lifecycle", "library", "reply"]);
    rig.section("lifecycle", |l| l["type"] == "closing");
    rig.section("lifecycle", |l| l["type"] == "closed");
}

#[tokio::test(flavor = "multi_thread")]
async fn turning_auto_compile_on_builds_after_a_save() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    rig.call("SetOptions", json!({ "autoCompile": true }));
    rig.open_document("ch.tex")
        .edit(0, 0, "% more\n", None, false);
    rig.call("Save", json!({ "reporting": true }));
    let started = rig.section("build", |b| b["compiling"] == true);
    assert_eq!(started["auto"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn tex_is_looked_for_at_start_so_an_auto_build_waits_on_no_client() {
    let rig = Rig::open_with(&[("main.tex", MAIN)], stub_tex).await;
    assert_eq!(rig.tex["available"], true);
    rig.call("CloseProject", json!({}));
    let auto = json!({ "id": rig.id, "autoCompile": true });
    rig.call_to(2, "OpenProject", auto);
    let started = rig.section_in(2, "build", |b| b["compiling"] == true);
    assert_eq!(started["auto"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn tex_commands_run_in_the_order_sent_so_the_last_one_says_if_tex_is_found() {
    let rig = Rig::open_with(&[("main.tex", MAIN)], |library| {
        stub_tex(library);
        let slow = library.path("slow");
        program(&slow.join("latexmk"), "#!/bin/sh\nsleep 1\nexit 1\n");
        app_settings(library, json!({ "texDir": slow }));
    })
    .await;
    let checked = rig.send_library("CheckTex", json!({}));
    let set = rig.send_library("SetTexDir", json!({ "dir": rig.library.path("tex/bin") }));
    let id = |e: &Value| e["value"]["id"].clone();
    let first = rig.find(|e| e["type"] == "reply" && (id(e) == checked || id(e) == set));
    assert_eq!(id(&first), checked);
    assert_eq!(rig.reply(set).unwrap()["available"], true);
    rig.call("SetOptions", json!({ "autoCompile": true }));
    rig.call("SetSettings", json!({ "patch": {} }));
    rig.section("build", |b| b["compiling"] == true);
}

#[tokio::test(flavor = "multi_thread")]
async fn tex_status_is_sent_again_only_when_it_changes_and_before_the_reply_that_changed_it() {
    let rig = Rig::open_with(&[("main.tex", MAIN)], stub_tex).await;
    let failing = rig.library.path("failing");
    program(&failing.join("latexmk"), "#!/bin/sh\nexit 1\n");
    rig.forget();
    rig.ask_library("SetTexDir", json!({ "dir": failing }))
        .unwrap();
    let library = ["library", "reply"];
    assert_eq!(said_of(&rig, &library), library);
    let tex = rig.find(|e| e["type"] == "library")["value"]["value"].take();
    assert_eq!(tex["available"], false);
    assert_eq!(tex["texDir"], json!(failing));
    rig.forget();
    rig.ask_library("CheckTex", json!({})).unwrap();
    assert_eq!(said_of(&rig, &library), ["reply"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn tex_folders_chosen_together_both_land_and_keep_what_the_file_already_had() {
    let rig = Rig::open_with(&[("main.tex", MAIN)], |library| {
        stub_tex(library);
        program(&library.path("texpresso/texpresso"), "#!/bin/sh\n");
        app_settings(library, json!({ "later": true }));
    })
    .await;
    let (texpresso, tex) = (rig.library.path("texpresso"), rig.library.path("tex/bin"));
    let sent = [
        rig.send_library("SetTexpressoDir", json!({ "dir": texpresso })),
        rig.send_library("SetTexDir", json!({ "dir": tex })),
    ];
    for id in sent {
        rig.reply(id).unwrap();
    }
    let file = fs::read(rig.library.path("state/.texlocal-app.json")).unwrap();
    let stored: Value = serde_json::from_slice(&file).unwrap();
    let expected = json!({ "later": true, "texDir": tex, "texpressoDir": texpresso });
    assert_eq!(stored, expected);
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
    rig.event("buildFinished", |_| true);
    assert!(args().lines().any(|a| a == "-norc"));
    assert!(!args().contains("-shell-escape"));
    rig.forget();
    rig.call("SetSettings", json!({ "patch": { "shellEscape": true } }));
    rig.call("Compile", json!({ "auto": false }));
    rig.event("buildFinished", |_| true);
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
    let unknown = rig.refuse("ApplyFix", json!({ "id": "format:disk" }));
    assert_eq!(unknown, ErrorKind::Invalid);
}
