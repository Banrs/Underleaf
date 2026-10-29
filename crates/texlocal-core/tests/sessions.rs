mod common;

use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{FakePreview, Library, Rig, SESSION, names, write};
use serde_json::{Value, json};
use texlocal_core::ErrorKind;
use texlocal_core::session::LiveEvent;
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

fn zip_names(path: &Path) -> Vec<String> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    let mut names: Vec<String> = archive.file_names().map(str::to_owned).collect();
    names.sort();
    let _ = archive.by_index(0).unwrap().read(&mut [0; 1]);
    names
}

#[tokio::test(flavor = "multi_thread")]
async fn opening_sends_every_section_before_its_reply_and_its_number_is_taken() {
    let rig = project().await;
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
    let project = rig.section("project", |_| true);
    assert_eq!(project["name"], "P");
    assert_eq!(project["settings"]["mainFile"], "main.tex");
    let tree = rig.section("tree", |_| true);
    assert_eq!(names(&tree, "name"), ["ch.tex", "main.tex"]);
    assert_eq!(rig.section("documents", |_| true), json!([]));
    assert_eq!(rig.section("outline", |_| true), Value::Null);
    let open = json!({ "id": rig.id, "autoCompile": false });
    assert_eq!(rig.refuse("OpenProject", open), ErrorKind::Conflict);
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
    rig.call("OpenDocument", json!({ "path": "ch.tex" }));
    rig.call("ReloadTree", json!({}));
    rig.call("SetSettings", json!({ "patch": { "engine": engine } }));
    assert_eq!(rig.said(), ["reply"; 4]);
    rig.forget();
    rig.call("SetSettings", json!({ "patch": { "engine": "xelatex" } }));
    assert_eq!(rig.said(), ["project", "reply"]);
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
    let saved = |root: &Path| fs::read_to_string(root.join("main.tex")).unwrap();
    assert_eq!(saved(&rig.root()), format!("% both\n{MAIN}"));
    assert!(saved(&rig.library.project_root(&other)).starts_with("% both\n"));
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
async fn a_file_not_in_utf8_is_refused() {
    let rig = project().await;
    fs::write(rig.root().join("latin.tex"), b"caf\xe9").unwrap();
    let refused = rig.refuse("OpenDocument", json!({ "path": "latin.tex" }));
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
        (json!("untitled.tex"), json!("untitled 2.tex"))
    );
    let folder = rig.call("CreateEntry", entry("figs", true));
    assert!(rig.root().join(folder.as_str().unwrap()).is_dir());
    for name in [".texlocal.json", "../outside.tex"] {
        let refused = rig.refuse("CreateEntry", entry(name, false));
        assert_eq!(refused, ErrorKind::Invalid, "{name}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn renaming_the_open_main_file_sends_its_event_and_sections_before_the_reply() {
    let rig = project().await;
    rig.open_document("main.tex");
    rig.section("outline", |o| !o.is_null());
    rig.forget();
    let renamed = rig.call("Rename", json!({ "from": "main.tex", "to": "thesis.tex" }));
    assert_eq!(renamed["to"], "thesis.tex");
    assert!(rig.root().join("thesis.tex").is_file());
    let said = ["documentRenamed", "documents", "tree", "project", "reply"];
    assert_eq!(rig.said(), said);
    let project = rig.section("project", |_| true);
    assert_eq!(project["settings"]["mainFile"], "thesis.tex");
    let documents = rig.section("documents", |_| true);
    assert_eq!(names(&documents, "path"), ["thesis.tex"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_main_file_is_never_prepared_for_deletion() {
    let rig = project().await;
    let refused = rig.refuse("PrepareDelete", json!({ "path": "main.tex" }));
    assert_eq!(refused, ErrorKind::Conflict);
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
    let empty = rig.refuse("SaveVersion", json!({ "name": " " }));
    assert_eq!(empty, ErrorKind::Invalid);
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
async fn a_change_on_disk_reaches_a_document_without_edits() {
    let rig = project().await;
    let doc = rig.open_document("ch.tex");
    std::thread::sleep(Duration::from_millis(300));
    fs::write(rig.root().join("ch.tex"), "theirs\n").unwrap();
    let reload = rig.event("documentReload", |e| e["path"] == "ch.tex");
    assert_eq!(reload["text"], "theirs\n");
    assert!(doc.reload("theirs\n"));
    assert_eq!(doc.with(|d| d.text()), "theirs\n");
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
    let reload = rig.event("documentReload", |e| e["path"] == "ch.tex");
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
        json!([{ "path": "plot.png", "keepBoth": "plot 2.png" }])
    );
    let mut keep = args;
    keep["conflict"] = json!("keepBoth");
    rig.call("ImportFiles", keep);
    assert!(rig.root().join("figs/plot 2.png").is_file());
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
async fn ui_state_is_written_before_the_close_and_keeps_what_it_is_not_given() {
    let rig = Rig::open_with(&[("main.tex", MAIN)], |library| {
        let file = library.project_root("P").join(".texlocal.json");
        fs::write(
            file,
            r#"{"mainFile": "main.tex", "ui": {"openFile": "main.tex"}}"#,
        )
        .unwrap();
    })
    .await;
    let zoom = json!({ "type": "scale", "value": 1.5 });
    let place = json!({ "file": "main.tex", "line": 12, "zoom": zoom, "panel": true });
    let patch = |patch| json!({ "patch": patch });
    rig.send(SESSION, "SetUiState", patch(json!({ "place": place })));
    let folders = json!({ "expandedFolders": ["figs"] });
    rig.send(SESSION, "SetUiState", patch(folders));
    assert_eq!(rig.call("CloseProject", json!({})), true);
    let file = fs::read(rig.root().join(".texlocal.json")).unwrap();
    let ui = &serde_json::from_slice::<Value>(&file).unwrap()["ui"];
    assert_eq!(
        (&ui["openFile"], &ui["line"], &ui["zoom"]),
        (&json!("main.tex"), &json!(12), &json!(1.5))
    );
    assert_eq!(ui["expandedFolders"], json!(["figs"]));
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
async fn a_build_sends_its_sections_before_it_finishes_and_its_pdf_follows_the_main_file() {
    let rig = Rig::open_with(&[("main.tex", MAIN), ("ch.tex", CHAPTER)], stub_tex).await;
    rig.section("outline", |o| !o.is_null());
    rig.forget();
    rig.call("Compile", json!({ "auto": false }));
    rig.event("buildFinished", |_| true);
    let said = ["build", "reply", "build", "shownPdf", "buildFinished"];
    assert_eq!(rig.said(), said);
    let build = rig.section("build", |b| !b["result"].is_null());
    assert_eq!(build["result"]["ok"], true);
    assert_eq!(build["issues"], json!([]));
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
    rig.forget();
    rig.call("Clean", json!({}));
    assert_eq!(rig.said(), ["build", "shownPdf", "reply"]);
    assert_eq!(rig.section("build", |_| true)["result"], Value::Null);
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
        run: "done".into(),
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
    let kinds = ["live", "shownPdf", "reply"];
    assert_eq!(said_of(&rig, &kinds), ["live", "live", "shownPdf", "reply"]);
    assert_eq!(rig.section("shownPdf", |_| true)["live"], false);
    let stopped = rig.section("live", |l| l["phase"] == "stopped");
    assert_eq!(stopped["lines"], json!({}));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_remembered_live_preview_starts_at_open_and_only_compile_builds_beside_it() {
    let main = "\\documentclass{article}\n\\begin{document}\nHi.\n\\end{document}\n";
    let preview = Arc::new(FakePreview::default());
    let rig = Rig::previewing(&[("main.tex", main)], stub_tex, preview).await;
    rig.call("StartLive", json!({}));
    rig.call("CloseProject", json!({}));
    rig.forget();
    let again = 2;
    rig.call_to(
        again,
        "OpenProject",
        json!({ "id": rig.id, "autoCompile": true }),
    );
    rig.section("live", |l| l["phase"] == "running");
    rig.call_to(again, "OpenDocument", json!({ "path": "main.tex" }));
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

#[tokio::test(flavor = "multi_thread")]
async fn kill_all_stops_the_builds_under_way() {
    let rig = compiling_slowly().await;
    rig.library.call("KillAll", json!({})).await;
    rig.event("buildFinished", |_| true);
    let build = rig.section("build", |b| !b["result"].is_null());
    assert_eq!(build["result"]["stopped"], true);
}

#[tokio::test(flavor = "multi_thread")]
async fn stop_compile_stops_the_sessions_build() {
    let rig = compiling_slowly().await;
    rig.call("StopCompile", json!({}));
    rig.event("buildFinished", |_| true);
    let build = rig.section("build", |b| !b["result"].is_null());
    assert_eq!(build["result"]["stopped"], true);
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

#[tokio::test(flavor = "multi_thread")]
async fn checks_find_duplicates_missing_files_and_open_groups() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\label{a}\\label{a}\n\\cite{nokey}\n\\input{missing}\n$x\n\nnext {\n\\end{document}\n";
    let rig = Rig::open_with(&[("main.tex", main)], stub_tex).await;
    let build = rig.section("build", |b| b["issues"].as_array().unwrap().len() == 5);
    let lines: Vec<u64> = build["issues"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["line"].as_u64().unwrap())
        .collect();
    assert_eq!(lines, [3, 4, 5, 6, 8]);
}
