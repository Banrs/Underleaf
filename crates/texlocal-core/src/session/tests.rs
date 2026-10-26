//! The session's rules on tokio's paused clock, with a fake latexmk and
//! TeXpresso (`Fake`) and the folder's changes sent in by hand.

use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::oneshot;

use super::build::Fut;
use super::watch::Change;
use super::{Document, Engine, Msg, Preview, Sessions};
use crate::compile::CompileResult;
use crate::logparse::LogItem;
use crate::paths::Project;
use crate::projects::Symbols;
use crate::projects::testing::names_in;
use crate::service::Service;
use crate::texpresso::{FileBuffer, LiveEvent, Pane, Sink, Status};
use crate::{CoreError, lock};

// MARK: - A fake engine

#[derive(Default)]
struct Fake {
    calls: Mutex<Vec<String>>,
    builds: Mutex<VecDeque<oneshot::Sender<Result<CompileResult, CoreError>>>>,
    starts: Mutex<Vec<Vec<String>>>,
    updates: Mutex<Vec<(String, String)>>,
    edits: Mutex<Vec<(String, usize, usize, String)>>,
    /// The next edit's refusal.
    refusal: Mutex<Option<CoreError>>,
    sink: Mutex<Option<Sink>>,
    log: Mutex<String>,
    mark: Mutex<u64>,
}

fn status(running: bool) -> Status {
    Status {
        running,
        ..Status::default()
    }
}

fn built(pdf: bool, errors: Vec<LogItem>) -> CompileResult {
    CompileResult {
        ok: errors.is_empty(),
        duration_ms: 1,
        pdf: pdf.then(|| "build/main.pdf".into()),
        pdf_changed: pdf,
        errors,
        ..CompileResult::default()
    }
}

fn issue(line: u32, message: &str) -> LogItem {
    LogItem {
        kind: crate::logparse::Severity::Error,
        file: Some("main.tex".into()),
        line: Some(line),
        message: message.into(),
        short: message.into(),
        command: None,
        explain: None,
        fix: None,
    }
}

fn exited() -> LiveEvent {
    LiveEvent::Ended(Some("TeXpresso exited".into()))
}

impl Fake {
    fn called(&self, what: &str) -> usize {
        lock(&self.calls).iter().filter(|c| *c == what).count()
    }

    fn note(&self, what: &str) {
        lock(&self.calls).push(what.into());
    }

    fn finish_build(&self, result: CompileResult) {
        let build = lock(&self.builds).pop_front();
        let _ = build.expect("a build runs").send(Ok(result));
    }

    fn tell(&self, event: LiveEvent) {
        if let Some(sink) = lock(&self.sink).as_ref() {
            sink(event);
        }
    }
}

impl Engine for Fake {
    fn compile(&self, _project: Project, _auto: bool) -> Fut<Result<CompileResult, CoreError>> {
        self.note("compile");
        let (tx, rx) = oneshot::channel();
        lock(&self.builds).push_back(tx);
        Box::pin(async move {
            rx.await
                .unwrap_or_else(|_| Err(CoreError::internal("dropped")))
        })
    }

    fn stop_compile(&self, _root: &Path) {
        self.note("stop_compile");
        if let Some(build) = lock(&self.builds).pop_front() {
            let stopped = CompileResult {
                stopped: true,
                ..built(false, Vec::new())
            };
            let _ = build.send(Ok(stopped));
        }
    }

    fn clean(&self, _build: PathBuf) -> Fut<Result<(), CoreError>> {
        self.note("clean");
        Box::pin(async { Ok(()) })
    }
}

impl Preview for Fake {
    fn start(
        &self,
        _owner: u64,
        _project: &Project,
        files: &[FileBuffer],
        _path_env: &str,
        _pane: &Pane,
        sink: Sink,
    ) -> Result<Status, CoreError> {
        self.note("live_start");
        lock(&self.starts).push(files.iter().map(|f| f.path.clone()).collect());
        *lock(&self.sink) = Some(sink);
        Ok(status(true))
    }

    fn update(&self, _owner: u64, path: &str, text: &str) -> Result<(), CoreError> {
        lock(&self.updates).push((path.to_owned(), text.to_owned()));
        Ok(())
    }

    fn edit(
        &self,
        _owner: u64,
        path: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<(), CoreError> {
        if let Some(refusal) = lock(&self.refusal).take() {
            return Err(refusal);
        }
        lock(&self.edits).push((path.to_owned(), start, remove, text.to_owned()));
        Ok(())
    }

    fn view(&self, _owner: u64, _first: u32, _last: u32) -> Result<(), CoreError> {
        self.note("live_view");
        Ok(())
    }

    fn caret(&self, _owner: u64, _path: &str, _offset: usize) -> Result<(), CoreError> {
        self.note("live_caret");
        Ok(())
    }

    fn rescan(&self, _owner: u64) -> Result<(), CoreError> {
        self.note("live_rescan");
        Ok(())
    }

    fn mark(&self, _owner: u64, mark: u64) -> Result<(), CoreError> {
        *lock(&self.mark) = mark;
        Ok(())
    }

    fn tex_log(&self, _owner: u64) -> Option<String> {
        Some(lock(&self.log).clone())
    }

    fn status(&self, _owner: u64) -> Result<Status, CoreError> {
        Ok(Status {
            log: lock(&self.log).clone(),
            output: "TeX's output".into(),
            ..status(true)
        })
    }

    fn stop_request(&self, _owner: u64) -> Status {
        self.note("live_stop");
        self.tell(LiveEvent::Ended(None));
        status(false)
    }

    fn stop(&self, _root: &Path) -> Result<(), CoreError> {
        self.tell(LiveEvent::Ended(None));
        Ok(())
    }
}

// MARK: - A session to drive

struct Rig {
    _data: tempfile::TempDir,
    root: PathBuf,
    sessions: Arc<Sessions>,
    fake: Arc<Fake>,
    seen: Arc<Mutex<Vec<Value>>>,
    session: u64,
    marks: u64,
}

impl Rig {
    async fn new(auto_compile: bool) -> Self {
        Self::watching(auto_compile, false).await
    }

    async fn watching(auto_compile: bool, watch: bool) -> Self {
        let data = tempfile::tempdir().unwrap();
        crate::projects::create_project(data.path(), "P", "blank", None).unwrap();
        let root = std::fs::canonicalize(data.path().join("P")).unwrap();
        fs::write(root.join("main.tex"), "Hello").unwrap();
        let service = Arc::new(Service::new(data.path().to_path_buf()));
        // As if `status` had found TeX, which automatic builds wait for.
        service.tex_found.send_replace(true);
        let fake = Arc::new(Fake {
            log: Mutex::new("TeX's log".into()),
            ..Fake::default()
        });
        let (engine, preview) = (Arc::clone(&fake), Arc::clone(&fake));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        let listen = Box::new(move |event: &Value| lock(&sink).push(event.clone()));
        let sessions = Arc::new(Sessions::with_engine(
            service, engine, preview, watch, listen,
        ));
        let session = 1;
        let args = json!({ "id": "P", "session": session, "autoCompile": auto_compile });
        sessions.call("session_open", args).await.unwrap();
        Self {
            _data: data,
            root,
            sessions,
            fake,
            seen,
            session,
            marks: 0,
        }
    }

    async fn call(&self, name: &str, mut args: Value) -> Result<Value, CoreError> {
        args["session"] = self.session.into();
        let command = format!("session_{name}");
        self.sessions.call(&command, args).await
    }

    async fn ok(&self, name: &str, args: Value) -> Value {
        self.call(name, args).await.unwrap()
    }

    async fn open(&self, path: &str) -> Document {
        self.ok("open_document", json!({ "path": path })).await;
        self.sessions.document(self.session, path).unwrap()
    }

    /// Every event since the last call, once the session has taken what was sent before.
    async fn events(&mut self) -> Vec<Value> {
        self.state().await;
        self.marks += 1;
        let mark = json!({ "type": "mark", "n": self.marks });
        let queued = crate::events::Queued::Event(mark.clone());
        self.sessions.hub.queue.send(queued).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let mut seen = lock(&self.seen);
            if let Some(at) = seen.iter().position(|e| *e == mark) {
                let mut events: Vec<Value> = seen.drain(..=at).collect();
                events.pop();
                return events;
            }
            drop(seen);
            assert!(std::time::Instant::now() < deadline, "events arrive");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    async fn of_type(&mut self, kind: &str) -> Vec<Value> {
        let events = self.events().await;
        events.into_iter().filter(|e| e["type"] == kind).collect()
    }

    fn disk(&self, path: &str) -> String {
        fs::read_to_string(self.root.join(path)).unwrap()
    }

    fn write_elsewhere(&self, path: &str, text: &str) {
        fs::write(self.root.join(path), text).unwrap();
        self.changed(path, false);
    }

    fn changed(&self, path: &str, structural: bool) {
        let path = self.root.join(path);
        let changes = Msg::Fs(vec![Change { path, structural }]);
        let _ = lock(&self.sessions.open)[&self.session].tx.send(changes);
    }

    async fn state(&self) -> Value {
        self.ok("state", json!({})).await
    }

    async fn resolve(&self, answer: &str) {
        let args = json!({ "path": "main.tex", "answer": answer });
        self.ok("resolve", args).await;
    }
}

fn mistaken(event: &Value) -> bool {
    ["conflict", "document_reload", "tree"].contains(&event["type"].as_str().unwrap())
}

async fn wait(ms: u64) {
    tokio::time::sleep(Duration::from_millis(ms)).await;
}

// MARK: - Autosave

#[tokio::test(start_paused = true)]
async fn the_autosave_writes_700_ms_after_the_last_edit() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " world", None, false);
    wait(600).await;
    doc.edit(11, 0, "!", None, false);
    wait(600).await;
    assert_eq!(rig.disk("main.tex"), "Hello");
    // The open's alone: Not Saved is for an error or Cancel, so edits and saves change
    // nothing a `document` event tells.
    assert_eq!(rig.of_type("document").await.len(), 1);
    assert_eq!(rig.state().await["documents"][0]["dirty"], true);
    wait(150).await;
    assert_eq!(rig.disk("main.tex"), "Hello world!");
    let events = rig.events().await;
    let saved = json!({ "type": "saved", "session": rig.session, "path": "main.tex" });
    assert!(events.contains(&saved));
    assert!(!events.iter().any(|e| e["type"] == "document"));
    assert_eq!(rig.state().await["documents"][0]["dirty"], false);
    assert_eq!(rig.fake.called("compile"), 0);
}

#[tokio::test(start_paused = true)]
async fn an_autosave_builds_when_auto_compile_is_on() {
    let mut rig = Rig::new(true).await;
    wait(1).await;
    assert_eq!(rig.fake.called("compile"), 1);
    rig.fake.finish_build(built(true, Vec::new()));
    let doc = rig.open("main.tex").await;
    doc.edit(0, 5, "Bye", None, false);
    wait(800).await;
    rig.state().await;
    assert_eq!(rig.disk("main.tex"), "Bye");
    assert_eq!(rig.fake.called("compile"), 2);
    let automatic = |build: &Value| build["compiling"] == true && build["auto"] == true;
    assert!(rig.of_type("build").await.iter().any(automatic));
}

/// The host builds after a fix, once it has applied the fix's edits.
#[tokio::test(start_paused = true)]
async fn a_fix_that_changes_a_setting_leaves_the_build_to_the_host() {
    let rig = Rig::new(true).await;
    wait(1).await;
    rig.fake.finish_build(built(true, Vec::new()));
    rig.ok("fix", json!({ "id": "engine:xelatex" })).await;
    rig.ok("compile", json!({})).await;
    rig.fake.finish_build(built(true, Vec::new()));
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
}

#[tokio::test(start_paused = true)]
async fn ime_composition_holds_the_autosave_until_it_ends() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    let composing = |on| rig.ok("composing", json!({ "path": "main.tex", "composing": on }));
    composing(true).await;
    doc.edit(5, 0, "ka", None, false);
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "Hello");
    doc.edit(5, 2, "か", None, false);
    composing(false).await;
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "Helloか");
}

// MARK: - Builds

#[tokio::test(start_paused = true)]
async fn requests_during_a_build_queue_one_more_and_stop_drops_it() {
    let mut rig = Rig::new(false).await;
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.fake.called("compile"), 1);
    rig.ok("compile", json!({ "auto": true })).await;
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.state().await["build"]["queued"], true);
    rig.fake.finish_build(built(true, Vec::new()));
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
    let events = rig.events().await;
    let of = |kind: &'static str| events.iter().filter(move |e| e["type"] == kind);
    let finished: Vec<&Value> = of("build_finished").collect();
    assert_eq!(finished.len(), 1);
    assert_eq!(finished[0]["auto"], false);
    assert!(of("build").all(|b| b["compiling"] == true), "{events:?}");
    rig.ok("compile", json!({})).await;
    rig.ok("stop_compile", json!({})).await;
    rig.state().await;
    assert_eq!(rig.fake.called("stop_compile"), 1);
    assert!(lock(&rig.fake.builds).is_empty());
    let state = rig.state().await;
    assert_eq!(state["build"]["compiling"], false);
    assert_eq!(state["build"]["queued"], false);
    assert_eq!(rig.fake.called("compile"), 2);
}

#[tokio::test(start_paused = true)]
async fn a_build_saves_first_and_the_preview_is_out_of_date_after_edits_made_during_it() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, "1", None, false);
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.disk("main.tex"), "Hello1");
    doc.edit(6, 0, "2", None, false);
    rig.state().await;
    rig.fake.finish_build(built(true, Vec::new()));
    let finished = rig.of_type("build_finished").await;
    assert_eq!(finished[0]["outdated"], true);
    assert_eq!(rig.state().await["build"]["outdated"], true);
    rig.ok("compile", json!({})).await;
    rig.fake.finish_build(built(true, Vec::new()));
    rig.state().await;
    assert_eq!(rig.state().await["build"]["outdated"], false);
    doc.edit(0, 0, "x", None, false);
    let builds = rig.of_type("build").await;
    assert_eq!(builds.last().unwrap()["outdated"], true);
}

#[tokio::test(start_paused = true)]
async fn issues_mark_unedited_documents_and_go_with_an_edit() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    let errors = vec![issue(3, "Undefined"), issue(3, "Again"), issue(9, "Late")];
    rig.fake.finish_build(built(true, errors));
    let issues = rig.of_type("issues").await;
    assert_eq!(issues.len(), 1);
    let lines = issues[0]["lines"].as_array().unwrap();
    assert_eq!(lines[0]["line"], 3);
    assert_eq!(lines[0]["message"], "Undefined");
    assert_eq!(lines[0]["others"], json!(["Again"]));
    let indices: Vec<&Value> = lines.iter().map(|line| &line["index"]).collect();
    assert_eq!(indices, [0, 2]);
    doc.edit(0, 0, "x", None, false);
    let cleared = rig.of_type("issues").await;
    let none = json!({ "type": "issues", "session": rig.session, "path": "main.tex", "lines": [] });
    assert_eq!(cleared, [none]);
}

#[tokio::test(start_paused = true)]
async fn an_undefined_commands_issue_says_where_its_line_has_it() {
    let mut rig = Rig::new(false).await;
    let text = "Hello\n\\foo and \\foobar % \\foo\n";
    fs::write(rig.root.join("main.tex"), text).unwrap();
    rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    let mut undefined = issue(2, "Undefined control sequence: \\foo");
    undefined.command = Some("\\foo".into());
    rig.fake
        .finish_build(built(true, vec![undefined, issue(1, "Other")]));
    let issues = rig.of_type("issues").await;
    let lines = issues[0]["lines"].as_array().unwrap();
    assert_eq!(lines[0]["compact"], Value::Null);
    assert_eq!(lines[0]["tokens"], json!([]));
    assert_eq!(lines[1]["compact"], "Undefined: \\foo");
    assert_eq!(lines[1]["tokens"], json!([{ "start": 0, "length": 4 }]));
}

#[tokio::test(start_paused = true)]
async fn the_outline_has_heading_styles_from_the_document_as_edited() {
    let mut rig = Rig::new(false).await;
    let text = "\\documentclass{book}\n\\chapter{A}\n\\section{B}\n\\section{}\n";
    rig.write_elsewhere("main.tex", text);
    let chapters = |outline: &Value| {
        let levels = outline["headingStyles"].as_array().unwrap();
        levels.iter().any(|l| l["command"] == "chapter")
    };
    outline_until(&mut rig, chapters).await;
    let doc = rig.open("main.tex").await;
    doc.edit(15, 4, "article", None, false);
    outline_until(&mut rig, |outline| !chapters(outline)).await;
}

/// The shown document's, by when it was shown rather than opened: one a failed save kept open
/// has its outline again when it shows again.
#[tokio::test(start_paused = true)]
async fn the_outline_is_the_document_shown_again() {
    let mut rig = Rig::new(false).await;
    rig.write_elsewhere("main.tex", "\\section{Main}\n");
    fs::write(rig.root.join("loose.tex"), "\\section{Loose}\n").unwrap();
    rig.changed("loose.tex", true);
    for (shown, title) in [
        ("main.tex", "Main"),
        ("loose.tex", "Loose"),
        ("main.tex", "Main"),
    ] {
        rig.open(shown).await;
        outline_until(&mut rig, |outline| outline["tree"][0]["title"] == title).await;
    }
}

/// The first `outline` event that passes `test`, which a scan sends perhaps a scan or two later.
async fn outline_until(rig: &mut Rig, test: impl Fn(&Value) -> bool) -> Value {
    loop {
        let events = until_sent(rig, "outline").await;
        let outlines = events.into_iter().filter(|e| e["type"] == "outline");
        if let Some(found) = outlines.filter(&test).last() {
            return found;
        }
    }
}

#[tokio::test(start_paused = true)]
async fn a_document_edited_since_the_build_shows_no_marks_when_it_opens_again() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    rig.fake
        .finish_build(built(true, vec![issue(1, "Undefined")]));
    assert_eq!(rig.of_type("issues").await.len(), 1);
    doc.edit(0, 0, "\n", None, false);
    rig.ok("close_document", json!({ "path": "main.tex" }))
        .await;
    rig.events().await;
    rig.open("main.tex").await;
    assert_eq!(rig.of_type("issues").await, Vec::<Value>::new());
    rig.ok("compile", json!({})).await;
    rig.fake
        .finish_build(built(true, vec![issue(2, "Undefined")]));
    let issues = rig.of_type("issues").await;
    assert_eq!(issues[0]["lines"][0]["line"], 2);
}

/// The events up to one of `kind`, which a scan beside the session sends perhaps a scan or two
/// later.
async fn until_sent(rig: &mut Rig, kind: &str) -> Vec<Value> {
    let mut events = Vec::new();
    for _ in 0..500 {
        events.extend(rig.events().await);
        if events.iter().any(|e| e["type"] == kind) {
            return events;
        }
        wait(10).await;
        std::thread::sleep(Duration::from_millis(1));
    }
    panic!("no {kind} came");
}

/// They come as the session opens and as they change, by file and then line; they follow the
/// build's issues in the session's list and on a line, and come back after an edit's save. One on
/// a line the build has an issue on joins that issue's line, and isn't listed again.
#[tokio::test(start_paused = true)]
async fn the_checks_follow_the_builds_issues_and_come_back_once_an_edit_is_saved() {
    let mut rig = Rig::new(false).await;
    let checks = |events: Vec<Value>| -> Vec<Value> {
        let checks = events.into_iter().filter(|e| e["type"] == "checks");
        checks.map(|e| e["items"].clone()).collect()
    };
    assert_eq!(checks(until_sent(&mut rig, "checks").await), [json!([])]);
    fs::write(rig.root.join("main.tex"), "\\input{a}\n\\ref{nowhere}\n").unwrap();
    fs::write(rig.root.join("a.tex"), "x}\n").unwrap();
    rig.changed("a.tex", true);
    let items = checks(until_sent(&mut rig, "checks").await).remove(0);
    let undefined = "No label “nowhere” is defined.";
    let check = json!({ "type": "warning", "file": "main.tex", "line": 2, "message": undefined });
    assert_eq!(items[0]["file"], "a.tex");
    assert_eq!(items[1], check);
    let doc = rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    rig.fake
        .finish_build(built(true, vec![issue(2, "Undefined")]));
    let events = rig.events().await;
    assert_eq!(checks(events.clone()), [json!([items[0]])]);
    let issues = events.iter().rfind(|e| e["type"] == "issues");
    let line = &issues.unwrap()["lines"][0];
    assert_eq!(
        (&line["message"], &line["others"]),
        (&json!("Undefined"), &json!([undefined]))
    );
    doc.edit(24, 0, "x", None, false);
    assert_eq!(rig.of_type("issues").await[0]["lines"], json!([]));
    wait(850).await;
    let events = until_sent(&mut rig, "issues").await;
    let issues = events.iter().find(|e| e["type"] == "issues").unwrap();
    let line = &issues["lines"][0];
    assert_eq!(
        (&line["message"], &line["others"]),
        (&json!(undefined), &json!([]))
    );
}

#[tokio::test(start_paused = true)]
async fn an_automatic_build_announces_only_when_its_errors_change_and_a_stopped_one_never() {
    let mut rig = Rig::new(false).await;
    rig.ok("compile", json!({ "auto": true })).await;
    rig.fake.finish_build(built(true, vec![issue(1, "a")]));
    rig.ok("compile", json!({ "auto": true })).await;
    rig.fake.finish_build(built(true, vec![issue(2, "b")]));
    rig.ok("compile", json!({})).await;
    rig.ok("stop_compile", json!({})).await;
    let finished = rig.of_type("build_finished").await;
    let announced: Vec<bool> = finished.iter().map(|f| f["announce"] == true).collect();
    assert_eq!(announced, [true, false, false]);
}

// MARK: - Changes on disk

#[tokio::test(start_paused = true)]
async fn another_apps_change_to_a_clean_document_reloads_it_and_the_pdf_is_out_of_date() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    rig.fake.finish_build(built(true, Vec::new()));
    rig.write_elsewhere("main.tex", "From elsewhere");
    wait(300).await;
    let reloads = rig.of_type("document_reload").await;
    assert_eq!(reloads.len(), 1);
    assert_eq!(reloads[0]["text"], "From elsewhere");
    doc.reload("From elsewhere");
    let state = rig.state().await;
    assert_eq!(state["documents"][0]["dirty"], false);
    assert_eq!(state["build"]["outdated"], true);
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "From elsewhere");
}

#[tokio::test(start_paused = true)]
async fn keys_typed_before_a_reload_reaches_the_editor_refuse_it_and_ask_about_the_change() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.write_elsewhere("main.tex", "From elsewhere");
    wait(300).await;
    assert_eq!(rig.of_type("document_reload").await.len(), 1);
    doc.edit(5, 0, "!", None, false);
    assert!(!doc.reload("From elsewhere"));
    assert_eq!(doc.snapshot().0, "Hello!");
    assert_eq!(rig.of_type("conflict").await[0]["kind"], "changed");
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "From elsewhere");
}

#[tokio::test(start_paused = true)]
async fn the_sessions_own_save_is_not_another_apps_change() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, "!", None, false);
    wait(800).await;
    rig.changed("main.tex", true);
    rig.changed(".texlocal-tmp", true);
    rig.changed("main.tex", false);
    wait(300).await;
    let events = rig.events().await;
    assert!(!events.iter().any(mistaken), "{events:?}");
}

async fn in_conflict(rig: &Rig) -> Document {
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine", None, false);
    rig.write_elsewhere("main.tex", "theirs");
    wait(300).await;
    doc
}

#[tokio::test(start_paused = true)]
async fn a_change_under_unsaved_edits_is_asked_about_and_save_anyway_keeps_them() {
    let mut rig = Rig::new(false).await;
    in_conflict(&rig).await;
    let asked = json!({
        "type": "conflict", "session": rig.session, "path": "main.tex", "kind": "changed"
    });
    assert_eq!(rig.of_type("conflict").await, [asked]);
    // Nothing writes over theirs while it is asked about.
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "theirs");
    rig.resolve("save").await;
    assert_eq!(rig.disk("main.tex"), "Hello mine");
}

#[tokio::test(start_paused = true)]
async fn revert_shows_and_writes_back_the_disks_text() {
    let mut rig = Rig::new(false).await;
    let doc = in_conflict(&rig).await;
    rig.resolve("revert").await;
    let reloads = rig.of_type("document_reload").await;
    assert_eq!(reloads[0]["text"], "theirs");
    doc.reload("theirs");
    let state = rig.state().await;
    assert_eq!(state["documents"][0]["dirty"], false);
    assert_eq!(state["documents"][0]["conflict"], Value::Null);
    assert_eq!(rig.disk("main.tex"), "theirs");
}

#[tokio::test(start_paused = true)]
async fn cancel_leaves_the_edits_unsaved_until_a_save_is_asked_for() {
    let mut rig = Rig::new(false).await;
    let doc = in_conflict(&rig).await;
    rig.resolve("cancel").await;
    let state = rig.state().await;
    assert_eq!(state["documents"][0]["held"], true);
    rig.events().await;
    doc.edit(0, 0, "x", None, false);
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "theirs");
    assert!(rig.of_type("conflict").await.is_empty());
    // A save someone asks for asks again.
    let saved = rig.ok("save", json!({})).await;
    assert_eq!(saved["saved"], false);
    assert_eq!(rig.of_type("conflict").await.len(), 1);
}

#[tokio::test(start_paused = true)]
async fn a_close_refused_by_a_save_keeps_the_session_and_its_edits() {
    let rig = Rig::new(false).await;
    let doc = in_conflict(&rig).await;
    let text = doc.snapshot().0;
    assert_eq!(rig.ok("close", json!({})).await["saved"], false);
    assert_eq!(rig.state().await["documents"].as_array().unwrap().len(), 1);
    assert_eq!(
        rig.sessions
            .document(rig.session, "main.tex")
            .unwrap()
            .snapshot()
            .0,
        text
    );
    assert_eq!(rig.disk("main.tex"), "theirs");
    rig.resolve("save").await;
    assert_eq!(rig.ok("close", json!({})).await["saved"], true);
    assert_eq!(rig.disk("main.tex"), text);
    assert!(rig.sessions.document(rig.session, "main.tex").is_none());
}

#[tokio::test(start_paused = true)]
async fn a_deleted_file_closes_and_one_with_unsaved_edits_is_asked_about_not_put_back() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    rig.open("ch.tex").await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine", None, false);
    for path in ["ch.tex", "main.tex"] {
        fs::remove_file(rig.root.join(path)).unwrap();
        rig.changed(path, true);
    }
    wait(300).await;
    let events = rig.events().await;
    let of = |kind: &'static str| events.iter().filter(move |e| e["type"] == kind);
    let closed: Vec<&Value> = of("document_closed").collect();
    let gone = json!({ "type": "document_closed", "session": rig.session, "path": "ch.tex", "reason": "gone" });
    assert_eq!(closed, [&gone]);
    assert!(rig.sessions.document(rig.session, "ch.tex").is_none());
    assert_eq!(of("tree").count(), 1);
    assert_eq!(of("conflict").next().unwrap()["kind"], "gone");
    wait(800).await;
    assert!(!rig.root.join("main.tex").exists());
    rig.resolve("save").await;
    assert_eq!(rig.disk("main.tex"), "Hello mine");
}

/// A folder that can't be read for now, as another app's lock leaves it, is no deletion.
#[tokio::test(start_paused = true)]
async fn a_file_that_cant_be_read_for_now_shows_not_saved_and_isnt_taken_as_gone() {
    use std::os::unix::fs::PermissionsExt;
    let mut rig = Rig::new(false).await;
    fs::create_dir(rig.root.join("ch")).unwrap();
    fs::write(rig.root.join("ch/a.tex"), "chapter").unwrap();
    let doc = rig.open("ch/a.tex").await;
    doc.edit(7, 0, " mine", None, false);
    fs::write(rig.root.join("ch/a.tex"), "theirs").unwrap();
    let folder = rig.root.join("ch");
    let locked = |mode| fs::set_permissions(&folder, fs::Permissions::from_mode(mode));
    locked(0o000).unwrap();
    rig.changed("ch/a.tex", false);
    wait(300).await;
    let events = rig.events().await;
    locked(0o755).unwrap();
    assert!(
        !events.iter().any(|e| e["type"] == "conflict"),
        "{events:?}"
    );
    let shown = events.iter().rfind(|e| e["type"] == "document");
    assert!(shown.unwrap()["error"].is_string(), "{events:?}");
}

#[tokio::test(start_paused = true)]
async fn a_new_file_changes_the_tree_and_a_changed_unopened_file_is_told_of() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("refs.bib"), "@book{a,").unwrap();
    rig.changed("refs.bib", true);
    wait(300).await;
    let trees = rig.of_type("tree").await;
    let tree = trees[0]["tree"].as_array().unwrap();
    assert!(tree.iter().any(|n| n["path"] == "refs.bib"));
    rig.write_elsewhere("refs.bib", "@book{b,");
    wait(300).await;
    let changed = rig.of_type("files_changed").await;
    assert_eq!(changed[0]["paths"], json!(["refs.bib"]));
}

#[tokio::test(start_paused = true)]
async fn external_dependencies_mark_the_pdf_stale_and_queue_one_automatic_build() {
    for auto in [false, true] {
        let mut rig = Rig::new(auto).await;
        fs::write(rig.root.join("refs.bib"), "@book{first,}").unwrap();
        rig.changed("refs.bib", true);
        wait(300).await;
        if !auto {
            rig.ok("compile", json!({ "auto": false })).await;
        }
        // Finish the initial build and any request queued while it was running.
        while rig.state().await["build"]["compiling"] == true {
            rig.fake.finish_build(built(true, Vec::new()));
            rig.events().await;
        }
        let before = rig.fake.called("compile");
        rig.write_elsewhere("refs.bib", "@book{second,}");
        rig.write_elsewhere("refs.bib", "@book{third,}");
        wait(300).await;
        assert_eq!(rig.state().await["build"]["outdated"], true);
        assert_eq!(rig.fake.called("compile"), before + usize::from(auto));
        if auto {
            // Another external edit during the build must not be declared up to date by it.
            rig.write_elsewhere("refs.bib", "@book{fourth,}");
            wait(300).await;
            rig.fake.finish_build(built(true, Vec::new()));
            assert_eq!(rig.state().await["build"]["outdated"], true);
            assert_eq!(rig.fake.called("compile"), before + 2);
            rig.fake.finish_build(built(true, Vec::new()));
            rig.events().await;
            assert_eq!(rig.state().await["build"]["outdated"], false);
        }
    }
}

#[tokio::test(start_paused = true)]
async fn a_watcher_rescan_reports_unopened_files_and_changed_settings() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("paper.tex"), "Paper").unwrap();
    rig.changed("paper.tex", true);
    wait(300).await;
    rig.events().await;
    fs::write(
        rig.root.join(".texlocal.json"),
        r#"{ "mainFile": "paper.tex" }"#,
    )
    .unwrap();
    fs::write(
        rig.root.join("paper.tex"),
        "Changed without an individual notification",
    )
    .unwrap();
    rig.changed("", true);
    wait(300).await;
    let events = rig.events().await;
    assert!(events.iter().any(|e| e["type"] == "files_changed"
        && e["paths"].as_array().unwrap().contains(&json!("paper.tex"))));
    assert!(events.iter().any(|e| {
        e["type"] == "tree"
            && e["tree"]
                .as_array()
                .unwrap()
                .iter()
                .any(|file| file["path"] == "paper.tex" && file["main"] == true)
    }));
}

/// Chosen here or by another app (by hand, by git or by a sync client), the main file is marked
/// in the tree and built.
#[tokio::test(start_paused = true)]
async fn the_tree_marks_the_main_file_and_another_chosen_anywhere_is_marked_and_built() {
    let mut rig = Rig::new(true).await;
    fs::write(rig.root.join("paper.tex"), "").unwrap();
    rig.changed("paper.tex", true);
    wait(300).await;
    rig.events().await;
    let patch = json!({ "patch": { "mainFile": "paper.tex" } });
    rig.ok("set_settings", patch).await;
    let trees = rig.of_type("tree").await;
    let nodes = trees[0]["tree"].as_array().unwrap().iter();
    let marks: Vec<_> = nodes
        .map(|n| (n["path"].clone(), n.get("main").cloned()))
        .collect();
    let paper = (json!("paper.tex"), Some(json!(true)));
    assert_eq!(marks, [(json!("main.tex"), None), paper]);
    let builds = rig.fake.called("compile");
    // A fold's write keeps the main file, so the folder isn't walked for files it didn't hear of.
    fs::write(rig.root.join("unheard.tex"), "").unwrap();
    let folds = r#"{ "mainFile": "paper.tex", "ui": { "foldedHeadings": ["a"] } }"#;
    fs::write(rig.root.join(".texlocal.json"), folds).unwrap();
    rig.changed(".texlocal.json", false);
    wait(300).await;
    assert!(rig.of_type("tree").await.is_empty());
    let settings = r#"{ "mainFile": "main.tex" }"#;
    fs::write(rig.root.join(".texlocal.json"), settings).unwrap();
    rig.changed(".texlocal.json", false);
    wait(300).await;
    let trees = rig.of_type("tree").await;
    assert_eq!(trees[0]["tree"][0]["main"], true);
    assert_eq!(rig.fake.called("compile"), builds + 1);
}

#[tokio::test(start_paused = true)]
async fn a_document_holds_line_feeds_and_saves_the_files_own_line_ends() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("main.tex"), "a\r\nb\r\n").unwrap();
    let doc = rig.open("main.tex").await;
    assert_eq!(doc.snapshot().0, "a\nb\n");
    doc.edit(4, 0, "c\r\nd\re", None, false);
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "a\r\nb\r\nc\r\nd\r\ne");
    // Another app changing only the line ends changes no text, and the next save keeps its.
    rig.write_elsewhere("main.tex", "a\nb\nc\nd\ne");
    wait(300).await;
    assert!(rig.of_type("document_reload").await.is_empty());
    doc.edit(10, 0, "!", None, false);
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "a\nb\nc\nd\ne!");
}

#[tokio::test(start_paused = true)]
async fn a_file_too_large_to_edit_doesnt_open() {
    let rig = Rig::new(false).await;
    let data = fs::File::create(rig.root.join("data.txt")).unwrap();
    data.set_len(super::actor::MAX_EDITED + 1).unwrap();
    let refused = rig
        .call("open_document", json!({ "path": "data.txt" }))
        .await;
    assert!(refused.unwrap_err().message.contains("too large to edit"));
}

#[tokio::test(start_paused = true)]
async fn a_file_that_isnt_utf8_neither_opens_nor_is_written_over() {
    let mut rig = Rig::new(false).await;
    let latin = b"caf\xe9";
    fs::write(rig.root.join("latin.tex"), latin).unwrap();
    let refused = rig
        .call("open_document", json!({ "path": "latin.tex" }))
        .await;
    assert_eq!(refused.unwrap_err().kind, crate::ErrorKind::Invalid);
    rig.open("main.tex").await;
    fs::write(rig.root.join("main.tex"), latin).unwrap();
    rig.changed("main.tex", false);
    wait(300).await;
    let closed = rig.of_type("document_closed").await;
    assert_eq!(closed[0]["reason"], "gone");
    fs::write(rig.root.join("main.tex"), "Hello").unwrap();
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine", None, false);
    fs::write(rig.root.join("main.tex"), latin).unwrap();
    rig.changed("main.tex", false);
    wait(300).await;
    assert_eq!(rig.of_type("conflict").await[0]["kind"], "changed");
    wait(800).await;
    rig.resolve("revert").await;
    assert!(rig.sessions.document(rig.session, "main.tex").is_none());
    assert_eq!(fs::read(rig.root.join("main.tex")).unwrap(), latin);
}

// MARK: - Files

/// So a host selects the entry in a tree that has it, with no tree of its own to read.
#[tokio::test(start_paused = true)]
async fn a_new_or_renamed_entry_is_answered_after_the_tree_that_lists_it() {
    let rig = Rig::new(false).await;
    let listed = |path: &str| {
        let seen = lock(&rig.seen);
        let last = seen.iter().rfind(|e| e["type"] == "tree");
        last.is_some_and(|tree| tree.to_string().contains(path))
    };
    let made = rig.ok("create_entry", json!({ "folder": "ch", "name": "a.tex" }));
    assert_eq!(made.await["path"], "ch/a.tex");
    assert!(listed("ch/a.tex"));
    let renamed = rig.ok("rename", json!({ "from": "ch/a.tex", "name": "b.tex" }));
    assert_eq!(renamed.await["to"], "ch/b.tex");
    assert!(listed("ch/b.tex"));
}

/// Its edits are saved first; a rename only in case moves it rather than closing it.
#[tokio::test(start_paused = true)]
async fn a_rename_moves_the_open_document_and_its_saves() {
    let mut rig = Rig::new(false).await;
    fs::create_dir(rig.root.join("chapters")).unwrap();
    fs::write(rig.root.join("chapters/Ch.tex"), "chapter").unwrap();
    let doc = rig.open("chapters/Ch.tex").await;
    doc.edit(0, 0, "A ", None, false);
    let to_lower = json!({ "from": "chapters/Ch.tex", "to": "chapters/ch.tex" });
    assert_eq!(rig.ok("rename", to_lower).await["to"], "chapters/ch.tex");
    rig.ok("rename", json!({ "from": "chapters", "to": "Chapters" }))
        .await;
    let events = rig.events().await;
    assert!(!events.iter().any(|e| e["type"] == "document_closed"));
    let moved = events.iter().filter(|e| e["type"] == "document_renamed");
    let moved: Vec<_> = moved.map(|e| e["to"].clone()).collect();
    assert_eq!(moved, ["chapters/ch.tex", "Chapters/ch.tex"]);
    let found = rig.sessions.document(rig.session, "Chapters/ch.tex");
    assert!(found.is_some());
    doc.edit(0, 0, "B", None, false);
    wait(800).await;
    assert_eq!(rig.disk("Chapters/ch.tex"), "BA chapter");
}

#[tokio::test(start_paused = true)]
async fn a_file_tex_names_in_another_case_is_spelt_as_the_disk_spells_it() {
    let mut rig = Rig::new(false).await;
    fs::create_dir(rig.root.join("chapters")).unwrap();
    fs::write(rig.root.join("chapters/intro.tex"), "\\section{Intro}\n").unwrap();
    if !rig.root.join("Chapters/Intro.tex").exists() {
        return; // A volume that compares case, where TeX wouldn't find the file either.
    }
    fs::write(rig.root.join("main.tex"), "\\input{Chapters/Intro}\n").unwrap();
    rig.changed("chapters", true);
    let outline = outline_until(&mut rig, |outline| outline["tree"][0].is_object()).await;
    assert_eq!(outline["tree"][0]["file"], "chapters/intro.tex");
    rig.ok("compile", json!({})).await;
    let mut error = issue(1, "Undefined");
    error.file = Some("Chapters/Intro.tex".into());
    rig.fake.finish_build(built(true, vec![error]));
    let finished = rig.of_type("build_finished").await;
    let file = &finished[0]["result"]["errors"][0]["file"];
    assert_eq!(file, "chapters/intro.tex");
    rig.ok("open_document", json!({ "path": "Chapters/Intro.tex" }))
        .await;
    let issues = rig.of_type("issues").await;
    assert_eq!(issues[0]["path"], "chapters/intro.tex");
    let doc = rig.sessions.document(rig.session, "chapters/intro.tex");
    doc.unwrap().edit(0, 0, "% ", None, false);
    wait(800).await;
    assert_eq!(rig.disk("chapters/intro.tex"), "% \\section{Intro}\n");
    assert_eq!(names_in(&rig.root.join("chapters")), ["intro.tex"]);
}

#[tokio::test(start_paused = true)]
async fn the_main_file_cant_go_to_the_trash_and_nothing_puts_a_trashed_file_back() {
    let rig = Rig::new(false).await;
    for path in ["main.tex", "MAIN.tex"] {
        let refused = rig.call("prepare_delete", json!({ "path": path })).await;
        assert_eq!(refused.unwrap_err().kind, crate::ErrorKind::Conflict);
    }
    fs::write(rig.root.join("old.tex"), "old").unwrap();
    let doc = rig.open("old.tex").await;
    doc.edit(0, 0, "x", None, false);
    let ready = rig.ok("prepare_delete", json!({ "path": "old.tex" })).await;
    assert_eq!(ready["ready"], true);
    assert_eq!(rig.disk("old.tex"), "xold");
    doc.edit(0, 0, "y", None, false);
    fs::remove_file(rig.root.join("old.tex")).unwrap();
    wait(800).await;
    assert!(!rig.root.join("old.tex").exists());
    rig.ok("deleted", json!({ "path": "old.tex" })).await;
    assert!(rig.sessions.document(rig.session, "old.tex").is_none());
}

/// `command`'s answer, with `typed` put at the start of `doc` while the save before it
/// waits for the project's lock: the two saves show it came after that save's snapshot.
async fn typed_during_a_save(rig: &mut Rig, doc: &Document, typed: &str, command: &str) -> Value {
    let (held_tx, held) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel::<()>();
    let service = Arc::clone(&rig.sessions.service);
    let holder = std::thread::spawn(move || {
        service.with_project("P", |_| {
            held_tx.send(()).unwrap();
            let _ = release_rx.recv();
            Ok(())
        })
    });
    held.recv().unwrap();
    let args = json!({ "session": rig.session, "path": "old.tex" });
    let answer = rig
        .sessions
        .call(&format!("session_{command}"), args.clone());
    wait(100).await;
    doc.edit(0, 0, typed, None, false);
    release.send(()).unwrap();
    holder.join().unwrap().unwrap();
    let answer = answer.await.unwrap();
    let saves = rig.of_type("saved").await;
    assert_eq!(saves.len(), 2, "{saves:?}");
    answer
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn text_typed_during_a_save_is_saved_before_a_build_or_a_trash_goes_on() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("old.tex"), "old").unwrap();
    let doc = rig.open("old.tex").await;
    doc.edit(0, 0, "a", None, false);
    typed_during_a_save(&mut rig, &doc, "b", "compile").await;
    assert_eq!(rig.fake.called("compile"), 1);
    assert_eq!(rig.disk("old.tex"), "baold");
    rig.fake.finish_build(built(true, Vec::new()));
    doc.edit(0, 0, "c", None, false);
    let ready = typed_during_a_save(&mut rig, &doc, "d", "prepare_delete").await;
    assert_eq!(ready["ready"], true);
    assert_eq!(rig.disk("old.tex"), "dcbaold");
}

// MARK: - Live preview

async fn live(rig: &Rig) -> Value {
    let started = rig.ok("live_start", json!({})).await;
    assert_eq!(started["phase"], "running");
    assert_eq!(started["engine"], "xelatex");
    started
}

#[tokio::test(start_paused = true)]
async fn live_preview_is_remembered_as_asked_and_not_as_its_session_closes() {
    let rig = Rig::new(false).await;
    live(&rig).await;
    rig.ok("close", json!({})).await;
    let args = json!({ "id": "P", "session": 2 });
    let opened = rig.sessions.call("session_open", args).await.unwrap();
    assert_eq!(opened["ui"]["livePreview"], true);
    let args = json!({ "session": 2 });
    rig.sessions.call("session_live_stop", args).await.unwrap();
    let ui = rig.sessions.service.project("P").unwrap().ui;
    assert!(!crate::settings::read_ui(&ui).live_preview);
}

#[tokio::test(start_paused = true)]
async fn keys_go_to_texpresso_as_made_and_a_refused_one_sends_the_whole_text() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    assert_eq!(lock(&rig.fake.starts)[0], ["main.tex"]);
    doc.edit(5, 0, "!", None, false);
    rig.state().await;
    assert_eq!(lock(&rig.fake.edits).len(), 1);
    *lock(&rig.fake.refusal) = Some(CoreError::unfit("unfit"));
    doc.edit(6, 0, "?", None, false);
    rig.state().await;
    let updates = lock(&rig.fake.updates).clone();
    assert_eq!(updates, [("main.tex".to_string(), "Hello!?".to_string())]);
    doc.edit(7, 0, ".", None, false);
    rig.state().await;
    assert_eq!(lock(&rig.fake.edits).len(), 2);
}

fn phases(events: &[Value]) -> Vec<&str> {
    let lives = events.iter().filter(|e| e["type"] == "live");
    lives.map(|e| e["phase"].as_str().unwrap()).collect()
}

#[tokio::test(start_paused = true)]
async fn a_file_changed_on_disk_goes_to_texpresso_unless_too_large_to_send() {
    let rig = Rig::new(false).await;
    for file in ["ch.tex", "big.tex"] {
        fs::write(rig.root.join(file), "x").unwrap();
        rig.changed(file, true);
    }
    wait(300).await;
    live(&rig).await;
    let big = "x".repeat(super::live::MAX_FILE as usize + 1);
    for (file, text) in [("ch.tex", "chapter"), ("big.tex", big.as_str())] {
        rig.write_elsewhere(file, text);
    }
    wait(1000).await;
    rig.state().await;
    let updates = lock(&rig.fake.updates).clone();
    assert_eq!(updates, [("ch.tex".to_string(), "chapter".to_string())]);
    assert!(rig.fake.called("live_rescan") > 0);
}

#[tokio::test(start_paused = true)]
async fn a_stopped_run_is_halted_only_once_it_has_lasted_a_second() {
    let rig = Rig::new(false).await;
    live(&rig).await;
    let ended = |run: &str| LiveEvent::Done(run.into());
    rig.fake.tell(ended("stopped"));
    wait(500).await;
    rig.fake.tell(ended("complete"));
    wait(1000).await;
    assert_eq!(rig.state().await["live"]["halted"], false);
    rig.fake.tell(ended("stopped"));
    wait(1100).await;
    assert_eq!(rig.state().await["live"]["halted"], true);
    rig.fake.tell(ended("complete"));
    wait(1).await;
    assert_eq!(rig.state().await["live"]["halted"], false);
}

#[tokio::test(start_paused = true)]
async fn documents_and_pages_go_to_the_host_as_they_come_and_none_of_a_start_before() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    let earlier = lock(&rig.fake.sink).take();
    rig.ok("live_stop", json!({})).await;
    live(&rig).await;
    let page = |path: &str| LiveEvent::Page {
        page: 1,
        path: path.into(),
    };
    earlier.unwrap()(page("/tmp/stale.pdf"));
    rig.fake.tell(LiveEvent::Document {
        path: "/tmp/live.pdf".into(),
        pages: 4,
        run: "partial".into(),
        changed: vec![[1, 1]],
    });
    rig.fake.tell(page("/tmp/page.pdf"));
    let events = rig.events().await;
    let shown = events
        .iter()
        .filter(|e| e["type"].as_str().is_some_and(|t| t.starts_with("live_")));
    let shown: Vec<&Value> = shown.collect();
    let session = rig.session;
    assert_eq!(
        shown,
        [
            &json!({ "type": "live_document", "session": session, "path": "/tmp/live.pdf",
                "pages": 4, "changed": [[1, 1]], "complete": false }),
            &json!({ "type": "live_page", "session": session, "page": 1, "path": "/tmp/page.pdf" }),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn a_preview_that_ends_by_itself_is_reported_and_not_started_again() {
    let rig = Rig::new(false).await;
    live(&rig).await;
    rig.fake.tell(exited());
    wait(1).await;
    let state = rig.state().await;
    assert_eq!(state["live"]["phase"], "stopped");
    assert_eq!(state["live"]["failure"], "TeXpresso exited");
    assert_eq!(lock(&rig.fake.starts).len(), 1);
}

#[tokio::test(start_paused = true)]
async fn automatic_builds_wait_while_live_preview_runs() {
    let rig = Rig::new(true).await;
    wait(1).await;
    rig.fake.finish_build(built(true, Vec::new()));
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    doc.edit(0, 0, "x", None, false);
    wait(800).await;
    rig.state().await;
    assert_eq!(rig.disk("main.tex"), "xHello");
    assert_eq!(rig.fake.called("compile"), 1);
    rig.ok("live_stop", json!({})).await;
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
}

#[tokio::test(start_paused = true)]
async fn a_build_done_during_live_preview_has_texpresso_read_its_files_again() {
    let rig = Rig::new(false).await;
    live(&rig).await;
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.fake.called("live_rescan"), 0);
    rig.fake.finish_build(built(true, Vec::new()));
    rig.state().await;
    assert_eq!(rig.fake.called("live_rescan"), 1);
}

#[tokio::test(start_paused = true)]
async fn the_live_event_carries_the_log_while_the_host_shows_it() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    fn logs(events: Vec<Value>) -> Vec<Value> {
        events.iter().map(|event| event["log"].clone()).collect()
    }
    let log = "TeX's log\n\nTeX's output";
    let failed = "TeXpresso exited\n\nTeX's log\n\nTeX's output";
    assert!(logs(rig.of_type("live").await).iter().all(Value::is_null));
    rig.ok("live_log", json!({ "shown": true })).await;
    assert_eq!(logs(rig.of_type("live").await), [log]);
    rig.fake.tell(exited());
    wait(1).await;
    assert_eq!(logs(rig.of_type("live").await).last().unwrap(), failed);
    // Hidden, the log is no longer sent, but with an alert, which opens it.
    rig.ok("live_log", json!({ "shown": false })).await;
    live(&rig).await;
    assert!(logs(rig.of_type("live").await).iter().all(Value::is_null));
    rig.fake.tell(exited());
    wait(1).await;
    let lives = rig.of_type("live").await;
    let (alerts, others): (Vec<Value>, Vec<Value>) =
        lives.into_iter().partition(|event| event["alert"] == true);
    assert_eq!(logs(alerts), [failed]);
    assert!(logs(others).iter().all(Value::is_null));
}

/// A rename stops the preview, which starts again once the change settles. It shows only as
/// `starting` meanwhile, as a host told it stopped would show the build's PDF.
#[tokio::test(start_paused = true)]
async fn a_rename_restarts_the_preview_once_it_settles_showing_it_as_starting_meanwhile() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    live(&rig).await;
    rig.events().await;
    rig.ok("rename", json!({ "from": "ch.tex", "to": "one.tex" }))
        .await;
    wait(100).await;
    let started = rig.ok("live_start", json!({})).await;
    assert_eq!(started["phase"], "starting");
    assert_eq!(lock(&rig.fake.starts).len(), 1);
    wait(100).await;
    assert_eq!(phases(&rig.events().await), ["starting", "running"]);
    rig.ok("rename", json!({ "from": "one.tex", "to": "ch.tex" }))
        .await;
    rig.ok("live_stop", json!({})).await;
    live(&rig).await;
    wait(200).await;
    assert_eq!(lock(&rig.fake.starts).len(), 3);
}

#[tokio::test(start_paused = true)]
async fn the_log_follows_tex_at_most_five_times_a_second() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    rig.ok("live_log", json!({ "shown": true })).await;
    rig.events().await;
    for line in 0..20 {
        *lock(&rig.fake.log) = format!("line {line}");
        rig.fake.tell(LiveEvent::Log);
        wait(20).await;
    }
    wait(200).await;
    let lives = rig.of_type("live").await;
    assert_eq!(lives.len(), 2, "{lives:?}");
    assert_eq!(lives[1]["log"], "line 19\n\nTeX's output");
}

#[tokio::test(start_paused = true)]
async fn the_caret_is_told_once_it_settles() {
    let rig = Rig::new(false).await;
    rig.open("main.tex").await;
    live(&rig).await;
    let move_to = async |offsets: &[usize]| {
        for &offset in offsets {
            let caret = json!({ "path": "main.tex", "offset": offset });
            rig.ok("live_caret", caret).await;
            wait(50).await;
        }
    };
    move_to(&[0, 1, 2, 3, 4]).await;
    assert_eq!(rig.fake.called("live_caret"), 0);
    wait(200).await;
    rig.state().await;
    assert_eq!(rig.fake.called("live_caret"), 1);
    move_to(&[0, 4]).await;
    wait(200).await;
    rig.state().await;
    assert_eq!(rig.fake.called("live_caret"), 1, "away and back is no move");
}

fn issue_lines(events: Vec<Value>) -> Vec<Vec<u64>> {
    let lines = |event: &Value| {
        let lines = event["lines"].as_array().unwrap().iter();
        lines.map(|line| line["line"].as_u64().unwrap()).collect()
    };
    events.iter().map(lines).collect()
}

fn run_done() -> LiveEvent {
    LiveEvent::Done("complete".into())
}

/// TeXpresso's log, as TeX writes it, of a run that met `\foo` on main.tex's `lines`.
fn undefined_on(lines: &[u32]) -> String {
    let errors = lines
        .iter()
        .map(|line| format!("! Undefined control sequence.\nl.{line} \\foo\n\n"));
    format!("**\n(main.tex\n{})\n", errors.collect::<String>())
}

#[tokio::test(start_paused = true)]
async fn live_errors_go_on_their_lines_once_texpresso_has_every_edit_and_follow_edits_above() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("main.tex"), "Hello\n\\foo\n").unwrap();
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    *lock(&rig.fake.log) = undefined_on(&[2]);
    rig.fake.tell(run_done());
    wait(900).await;
    assert!(rig.of_type("live_issues").await.is_empty());
    wait(200).await;
    let shown = rig.of_type("live_issues").await;
    assert_eq!(issue_lines(shown.clone()), [[2]]);
    assert_eq!(shown[0]["lines"][0]["compact"], "Undefined: \\foo");
    // Its log is of the text before the edit until TeXpresso says it has read it.
    doc.edit(0, 0, "\n", None, false);
    rig.fake.tell(run_done());
    wait(1100).await;
    assert_eq!(issue_lines(rig.of_type("live_issues").await), [[3]]);
    rig.fake.tell(LiveEvent::Synced(*lock(&rig.fake.mark)));
    *lock(&rig.fake.log) = undefined_on(&[]);
    rig.fake.tell(run_done());
    wait(1100).await;
    assert_eq!(issue_lines(rig.of_type("live_issues").await), [[0; 0]]);
}

#[tokio::test(start_paused = true)]
async fn a_live_error_shows_in_a_document_opened_after_and_goes_with_its_line_or_the_preview() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("main.tex"), "Hello\n\\foo\n\\foo\n").unwrap();
    live(&rig).await;
    *lock(&rig.fake.log) = undefined_on(&[2, 3]);
    rig.fake.tell(run_done());
    wait(1100).await;
    let doc = rig.open("main.tex").await;
    assert_eq!(issue_lines(rig.of_type("live_issues").await), [[2, 3]]);
    // Line 2's break and backslash: its error goes, and line 3's moves up.
    doc.edit(5, 2, "", None, false);
    assert_eq!(issue_lines(rig.of_type("live_issues").await), [[2]]);
    rig.ok("live_stop", json!({})).await;
    assert_eq!(issue_lines(rig.of_type("live_issues").await), [[0; 0]]);
}

#[tokio::test(start_paused = true)]
async fn closing_saves_and_stops_the_preview() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    doc.edit(0, 0, "x", None, false);
    let closed = rig.ok("close", json!({})).await;
    assert_eq!(closed["saved"], true);
    assert_eq!(rig.disk("main.tex"), "xHello");
    assert_eq!(rig.fake.called("live_stop"), 1);
    assert_eq!(
        rig.call("state", json!({})).await.unwrap_err().kind,
        crate::ErrorKind::NotFound
    );
}

// MARK: - The folder's watcher, for real

fn until_event(seen: &Mutex<Vec<Value>>, found: impl Fn(&Value) -> bool) -> Option<Value> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        if let Some(event) = lock(seen).iter().find(|e| found(e)) {
            return Some(event.clone());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_folders_watcher_tells_another_apps_changes() {
    let rig = Rig::watching(false, true).await;
    rig.open("main.tex").await;
    fs::write(rig.root.join("main.tex"), "theirs").unwrap();
    fs::write(rig.root.join("new.tex"), "").unwrap();
    let reload = until_event(&rig.seen, |e| e["type"] == "document_reload");
    assert_eq!(reload.expect("reloaded")["text"], "theirs");
    assert!(until_event(&rig.seen, |e| e["type"] == "tree").is_some());
}

#[tokio::test]
async fn a_host_numbers_its_sessions_and_a_number_open_already_is_refused() {
    let mut rig = Rig::new(true).await;
    let events = rig.events().await;
    let build = events.iter().find(|e| e["type"] == "build");
    assert_eq!(build.expect("the build is told")["session"], rig.session);
    let again = json!({ "id": "P", "session": rig.session });
    let taken = rig.sessions.call("session_open", again).await.unwrap_err();
    assert_eq!(taken.kind, crate::ErrorKind::Conflict);
    assert_eq!(rig.state().await["build"]["compiling"], true);
}

#[tokio::test(start_paused = true)]
async fn automatic_builds_wait_for_tex_to_be_found() {
    let rig = Rig::new(false).await;
    let service = &rig.sessions.service;
    service.tex_found.send_replace(false);
    rig.ok("set_options", json!({ "autoCompile": true })).await;
    rig.ok("compile", json!({ "auto": true })).await;
    assert_eq!(rig.fake.called("compile"), 0, "no TeX: no automatic build");
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.fake.called("compile"), 1, "one asked for still runs");
    rig.fake.finish_build(built(false, Vec::new()));
    service.tex_found.send_replace(true);
    wait(1).await;
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
}

// MARK: - The edges

/// Another app's write the watcher hasn't told of yet (its changes settle for 250 ms) is
/// asked about, not written over by the autosave.
#[tokio::test(start_paused = true)]
async fn a_write_elsewhere_just_before_the_autosave_is_asked_about_not_written_over() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine", None, false);
    wait(550).await;
    rig.write_elsewhere("main.tex", "theirs");
    wait(200).await;
    assert_eq!(rig.disk("main.tex"), "theirs");
    let conflicts = rig.of_type("conflict").await;
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0]["kind"], "changed");
    wait(300).await;
    assert!(rig.of_type("conflict").await.is_empty());
    assert_eq!(rig.disk("main.tex"), "theirs");
}

#[tokio::test(start_paused = true)]
async fn cleans_asked_for_together_are_all_answered() {
    let rig = Rig::new(false).await;
    rig.ok("compile", json!({})).await;
    let clean = || {
        let args = json!({ "session": rig.session });
        rig.sessions.call("session_clean", args.clone())
    };
    let (first, second) = (clean(), clean());
    first.await.unwrap();
    second.await.unwrap();
    assert_eq!(rig.fake.called("clean"), 1);
}

#[tokio::test(start_paused = true)]
async fn a_build_asked_for_during_a_clean_starts_once_it_is_over() {
    let mut rig = Rig::new(false).await;
    let cleaned = rig
        .sessions
        .call("session_clean", json!({ "session": rig.session }));
    rig.ok("compile", json!({})).await;
    cleaned.await.unwrap();
    let events = rig.events().await;
    let at = |test: &dyn Fn(&Value) -> bool| events.iter().position(test);
    let started = at(&|e| e["type"] == "build" && e["compiling"] == true);
    let cleaned = at(&|e| e["type"] == "build_cleaned");
    assert!(cleaned.unwrap() < started.unwrap(), "{events:?}");
}

/// Until the document's symbols pass `test`, perhaps a scan or two later.
async fn until(doc: &Document, test: impl Fn(&Symbols) -> bool) -> bool {
    for _ in 0..500 {
        if test(&doc.symbols()) {
            return true;
        }
        wait(10).await;
        std::thread::sleep(Duration::from_millis(1));
    }
    false
}

#[tokio::test(start_paused = true)]
async fn citations_and_files_another_app_writes_reach_completion() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    fs::write(rig.root.join("refs.bib"), "@book{first,").unwrap();
    rig.changed("refs.bib", true);
    // The file list comes with the tree's own rescan, perhaps one scan after the key.
    let cited = |symbols: &Symbols, key| {
        symbols.citations.iter().any(|cited| cited.name == key)
            && symbols.files == ["main.tex", "refs.bib"]
    };
    assert!(until(&doc, |s| cited(s, "first")).await, "a new file's");
    rig.write_elsewhere("refs.bib", "@book{second,");
    assert!(until(&doc, |s| cited(s, "second")).await, "a listed file's");
}

#[tokio::test(start_paused = true)]
async fn the_symbol_scan_and_a_search_read_an_open_document_as_the_editor_has_it() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    // Marked text holds the autosave, so the label never reaches the disk.
    let composing = json!({ "path": "main.tex", "composing": true });
    rig.ok("composing", composing).await;
    doc.edit(5, 0, " \\label{typed}", None, false);
    fs::write(rig.root.join("b.tex"), "").unwrap();
    rig.changed("b.tex", true);
    let typed = |symbols: &Symbols| matches!(&symbols.labels[..], [l] if l.name == "typed");
    assert!(until(&doc, typed).await);
    let found = rig.ok("search", json!({ "query": "typed" })).await;
    assert_eq!(found[0]["hits"][0]["file"], "main.tex");
    assert_eq!(found[0]["hits"][0]["column"], 13);
    let exact = json!({ "query": "Typed", "matchCase": true, "wholeWord": true });
    assert_eq!(rig.ok("search", exact).await, json!([]));
    assert_eq!(rig.disk("main.tex"), "Hello");
}

#[tokio::test(start_paused = true)]
async fn an_open_documents_definitions_are_placed_under_its_name_once_it_moves() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("a.tex"), "").unwrap();
    let doc = rig.open("a.tex").await;
    doc.edit(0, 0, "\\label{typed} \\ref{typed}", None, false);
    let renamed = json!({ "from": "a.tex", "to": "b.tex" });
    rig.ok("rename", renamed).await;
    // Other files are as the last scan found them, which may be the old name's.
    assert!(until(&doc, |symbols| !symbols.by_file.contains_key("a.tex")).await);
    let answer = doc.with(|source| source.call("definition", r#"{"at": 20}"#));
    let answer: Value = serde_json::from_str(&answer.unwrap()).unwrap();
    assert_eq!(answer["places"][0]["file"], "b.tex");
}

/// Every match in a file goes; one that isn't UTF-8 refuses them all, as writing it would change
/// its bytes.
#[tokio::test(start_paused = true)]
async fn a_replace_answers_the_open_documents_edits_and_writes_the_rest_keeping_their_line_ends() {
    let rig = Rig::new(false).await;
    // Each line as it ended, though the first's ending isn't the second's.
    fs::write(rig.root.join("ch.tex"), "a cat\nand a cat\r\n").unwrap();
    fs::write(rig.root.join("latin.tex"), b"cat caf\xe9").unwrap();
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " cat", None, false);
    let replace = || rig.call("replace", json!({ "query": "Cat", "replacement": "dog" }));
    let refused = replace().await.unwrap_err();
    assert!(refused.kind == crate::ErrorKind::Invalid && refused.message.contains("latin.tex"));
    assert_eq!(rig.disk("ch.tex"), "a cat\nand a cat\r\n");
    fs::remove_file(rig.root.join("latin.tex")).unwrap();
    let edit = json!({ "start": 6, "length": 3, "text": "dog" });
    let answer = json!({
        "edits": { "path": "main.tex", "version": 1, "edits": [edit] },
        "written": [{ "file": "ch.tex", "count": 2 }],
    });
    let mut answered = replace().await.unwrap();
    let snapshot = answered
        .as_object_mut()
        .unwrap()
        .remove("snapshot")
        .unwrap();
    assert_eq!(answered, answer);
    assert_eq!(rig.disk("ch.tex"), "a dog\nand a dog\r\n");
    // As a host whose editor was typed in since puts back the rest, not to leave it half replaced.
    let restore = json!({ "id": snapshot, "paths": ["ch.tex"] });
    rig.ok("history_restore", restore).await;
    assert_eq!(rig.disk("ch.tex"), "a cat\nand a cat\r\n");
}

/// A label's definition and each reference to it, the open document's as the editor has it, but
/// not one in a comment, by file as a search's hits.
#[tokio::test(start_paused = true)]
async fn usages_are_where_the_name_at_an_offset_is_defined_and_used_as_a_search_lists_them() {
    let rig = Rig::new(false).await;
    fs::write(
        rig.root.join("ch.tex"),
        "% \\ref{fig:a}\nSee \\ref{fig:a}.\n",
    )
    .unwrap();
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " \\label{fig:a}", None, false);
    let usages = rig
        .ok("usages", json!({ "path": "main.tex", "offset": 15 }))
        .await;
    let hit = |file, line, column, before, after| {
        let hit = json!({
            "file": file, "line": line, "column": column, "length": 5,
            "before": before, "match": "fig:a", "after": after,
        });
        json!({ "file": file, "hits": [hit] })
    };
    let groups = [
        hit("ch.tex", 2, 9, "See \\ref{", "}."),
        hit("main.tex", 1, 13, "Hello \\label{", "}"),
    ];
    let answer = json!({ "name": "\\label{fig:a}", "groups": groups });
    assert_eq!(usages, answer);
}

/// A citation's .bib entry, the key of a list that names it and an entry's crossref; refused
/// for a key TeX couldn't read, one nothing defines and one taken.
#[tokio::test(start_paused = true)]
async fn a_rename_answers_the_open_documents_edits_and_writes_the_definition_on_disk() {
    let rig = Rig::new(false).await;
    let bib = "@book{knuth,\n  title = {The {TeX}book},\n}\n@misc{lamport, crossref = {knuth}}\n";
    fs::write(rig.root.join("refs.bib"), bib).unwrap();
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, "\\cite{x, knuth}", None, false);
    let rename = |from: &str, to: &str| {
        let args = json!({ "kind": "citation", "from": from, "to": to });
        rig.call("rename_symbol", args)
    };
    let refusals = [
        ("knuth", "knuth 84", crate::ErrorKind::Invalid),
        ("nobody", "x", crate::ErrorKind::NotFound),
        ("knuth", "lamport", crate::ErrorKind::Conflict),
    ];
    for (from, to, kind) in refusals {
        assert_eq!(rename(from, to).await.unwrap_err().kind, kind, "{to}");
    }
    let mut renamed = rename("knuth", "knuth84").await.unwrap();
    renamed.as_object_mut().unwrap().remove("snapshot");
    let edit = json!({ "start": 14, "length": 5, "text": "knuth84" });
    let answer = json!({
        "edits": { "path": "main.tex", "version": 1, "edits": [edit] },
        "written": [{ "file": "refs.bib", "count": 2 }],
    });
    assert_eq!(renamed, answer);
    assert_eq!(rig.disk("refs.bib"), bib.replace("knuth", "knuth84"));
}

/// After the preamble's last `\usepackage`, written on disk or answered as the open main file's
/// edits, and not again once it is loaded; in the main file however the settings spell it. The
/// fix answers the settings too.
#[tokio::test(start_paused = true)]
async fn a_package_is_added_after_the_last_one_the_main_file_loads_unless_it_loads_it() {
    let rig = Rig::new(false).await;
    let main =
        "\\documentclass{article}\n\\usepackage[utf8]{inputenc,\n  amsmath}\n\\begin{document}\n";
    fs::write(rig.root.join("main.tex"), main).unwrap();
    let patch = json!({ "patch": { "mainFile": "Main.tex" } });
    rig.ok("set_settings", patch).await;
    let add = |name: &str| rig.call("fix", json!({ "id": format!("package:{name}") }));
    let written = add("graphicx").await.unwrap();
    assert_eq!(written["edits"], Value::Null);
    assert_eq!(written["settings"]["mainFile"], "Main.tex");
    let added = main.replace("amsmath}\n", "amsmath}\n\\usepackage{graphicx}\n");
    assert_eq!(rig.disk("main.tex"), added);
    assert_eq!(add("amsmath").await.unwrap()["edits"], Value::Null);
    assert_eq!(rig.disk("main.tex"), added);
    rig.open("main.tex").await;
    let at = added.find("\n\\begin").unwrap();
    let edit = json!({ "start": at, "length": 0, "text": "\n\\usepackage{xcolor}" });
    let edits = json!({ "path": "main.tex", "version": 0, "edits": [edit] });
    assert_eq!(add("xcolor").await.unwrap()["edits"], edits);
}

#[tokio::test(start_paused = true)]
async fn nothing_is_renamed_or_replaced_while_a_change_on_disk_is_unsettled() {
    let rig = Rig::new(false).await;
    in_conflict(&rig).await;
    let rename = json!({ "kind": "label", "from": "a", "to": "b" });
    let replace = json!({ "query": "Hello", "replacement": "Bye" });
    for (command, args) in [("rename_symbol", rename), ("replace", replace)] {
        let refused = rig.call(command, args).await.unwrap_err();
        let unsettled = refused.kind == crate::ErrorKind::Conflict
            && refused.message.contains("changed on disk");
        assert!(unsettled, "{command}");
    }
}

/// Two files on their way to the Trash at once: the first's end leaves the second held.
#[tokio::test(start_paused = true)]
async fn two_trashes_under_way_each_keep_their_file_from_being_saved_again() {
    let rig = Rig::new(false).await;
    for name in ["a.tex", "b.tex"] {
        fs::write(rig.root.join(name), name).unwrap();
    }
    let b = rig.open("b.tex").await;
    rig.ok("prepare_delete", json!({ "path": "a.tex" })).await;
    rig.ok("prepare_delete", json!({ "path": "b.tex" })).await;
    fs::remove_file(rig.root.join("a.tex")).unwrap();
    rig.ok("deleted", json!({ "path": "a.tex" })).await;
    b.edit(0, 0, "x", None, false);
    wait(800).await;
    assert_eq!(rig.disk("b.tex"), "b.tex");
}

#[tokio::test(start_paused = true)]
async fn an_automatic_build_whose_saves_are_held_shows_nothing() {
    let mut rig = Rig::new(false).await;
    in_conflict(&rig).await;
    rig.resolve("cancel").await;
    rig.events().await;
    rig.ok("compile", json!({ "auto": true })).await;
    assert_eq!(rig.of_type("build").await, Vec::<Value>::new());
    assert_eq!(rig.fake.called("compile"), 0);
}

/// A panic ends the session loudly: held edits are written, each document says nothing more
/// is saved, and waiting commands are told the session stopped.
#[tokio::test(start_paused = true)]
async fn a_panic_ends_the_session_with_its_edits_written_and_the_host_told() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine", None, false);
    let args = json!({ "session": rig.session });
    let panicked = rig.sessions.call("session_panic", args.clone());
    let behind = rig.sessions.call("session_state", args.clone());
    assert_eq!(panicked.await.unwrap_err().kind, crate::ErrorKind::Internal);
    assert_eq!(behind.await.unwrap_err().kind, crate::ErrorKind::Internal);
    assert_eq!(rig.disk("main.tex"), "Hello mine");
    let told = until_event(&rig.seen, |e| {
        e["type"] == "document" && e["error"].as_str().is_some_and(|e| e.contains("saved"))
    });
    assert!(told.is_some());
    assert_eq!(
        rig.call("state", json!({})).await.unwrap_err().kind,
        crate::ErrorKind::NotFound
    );
}

// MARK: - History

#[tokio::test(start_paused = true)]
async fn a_replace_all_keeps_the_files_as_they_were_first() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "a cat").unwrap();
    rig.ok("replace", json!({ "query": "cat", "replacement": "dog" }))
        .await;
    let before = &rig.ok("history_list", json!({})).await[0];
    assert_eq!(before["reason"], "Before Replace All");
    let compare = json!({ "id": before["id"], "path": "ch.tex" });
    let compared = rig.ok("history_compare", compare).await;
    assert_eq!(
        compared,
        json!([{ "removed": "a cat" }, { "added": "a dog" }])
    );
}

#[tokio::test(start_paused = true)]
async fn a_comparison_is_with_the_open_document_as_edited_and_the_others_on_disk() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "one").unwrap();
    let draft = rig.ok("history_save", json!({ "name": " Draft " })).await;
    assert_eq!(draft["name"], "Draft");
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " world", None, false);
    fs::write(rig.root.join("new.tex"), "new").unwrap();
    fs::remove_file(rig.root.join("ch.tex")).unwrap();
    let compare = |path: &str| {
        let args = json!({ "id": draft["id"], "path": path });
        rig.call("history_compare", args)
    };
    for (path, rows) in [
        (
            "main.tex",
            json!([{ "removed": "Hello" }, { "added": "Hello world" }]),
        ),
        ("new.tex", json!([{ "added": "new" }])),
        ("ch.tex", json!([{ "removed": "one" }])),
    ] {
        assert_eq!(compare(path).await.unwrap(), rows, "{path}");
    }
    assert_eq!(
        compare("figure.png").await.unwrap_err().kind,
        crate::ErrorKind::Invalid
    );
}

/// A file added since is left alone.
#[tokio::test(start_paused = true)]
async fn a_restore_writes_changed_and_deleted_files_back_after_keeping_them_as_they_were() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "one").unwrap();
    fs::write(rig.root.join("gone.tex"), "gone").unwrap();
    let draft = rig.ok("history_save", json!({ "name": "Draft" })).await;
    fs::write(rig.root.join("ch.tex"), "two").unwrap();
    fs::remove_file(rig.root.join("gone.tex")).unwrap();
    fs::write(rig.root.join("new.tex"), "new").unwrap();
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " world", None, false);

    let restore = |paths: Option<[&str; 1]>| {
        let args = json!({ "id": draft["id"], "paths": paths });
        rig.ok("history_restore", args)
    };
    let gone = restore(Some(["gone.tex"])).await;
    assert_eq!(gone, json!({ "edits": null }));
    let edit = json!({ "start": 5, "length": 6, "text": "" });
    let edits = json!({ "path": "main.tex", "version": 1, "edits": [edit] });
    let all = restore(None).await;
    assert_eq!(all, json!({ "edits": edits }));
    let disk = ["ch.tex", "gone.tex", "new.tex"].map(|path| rig.disk(path));
    assert_eq!(disk, ["one", "gone", "new"]);

    let list = rig.ok("history_list", json!({})).await;
    let change = |path: &str, change: &str| json!({ "path": path, "change": change });
    let changed = json!([
        change("ch.tex", "changed"),
        change("gone.tex", "deleted"),
        change("new.tex", "added"),
    ]);
    assert_eq!(list[1]["reason"], "Before Restore");
    assert_eq!(list[1]["changed"], changed);
    assert_eq!(list[0]["changed"], json!([change("gone.tex", "added")]));
}

// MARK: - Navigation

/// Every file, and the headings and labels of the files the main file reaches; a match at a
/// word's start before one inside a word, though its title is longer.
#[tokio::test(start_paused = true)]
async fn open_quickly_lists_files_headings_and_labels_best_first() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("main.tex"), "\\input{ch}\n").unwrap();
    let ch = "\\section{Introduction}\\label{sec:intro}\n";
    fs::write(rig.root.join("ch.tex"), ch).unwrap();
    fs::create_dir(rig.root.join("chapters")).unwrap();
    fs::write(rig.root.join("chapters/intro.tex"), "").unwrap();
    rig.changed("chapters", true);
    outline_until(&mut rig, |outline| outline["tree"][0].is_object()).await;
    let listed = rig.ok("quick_open", json!({ "query": "" })).await;
    let listed = listed.as_array().unwrap().iter();
    let paths: Vec<&str> = listed.map(|item| item["path"].as_str().unwrap()).collect();
    assert_eq!(paths, ["ch.tex", "chapters/intro.tex", "main.tex"]);
    let found = rig.ok("quick_open", json!({ "query": "IN" })).await;
    let answer = json!([
        { "kind": "label", "title": "sec:intro", "detail": "Introduction",
            "path": "ch.tex", "line": 1 },
        { "kind": "heading", "title": "Introduction", "detail": "Section · ch.tex",
            "path": "ch.tex", "line": 1 },
        { "kind": "file", "title": "intro.tex", "detail": "chapters",
            "path": "chapters/intro.tex", "line": null },
        { "kind": "file", "title": "main.tex", "detail": "", "path": "main.tex", "line": null },
    ]);
    assert_eq!(found, answer);
}

#[tokio::test(start_paused = true)]
async fn quick_help_tells_of_a_citation_a_label_and_a_command() {
    let rig = Rig::new(false).await;
    let bib = "@book{knuth,\n  author = {Knuth, Donald E. and Lamport, Leslie},\n  \
        title = {The {TeX}book},\n  year = 1984,\n  publisher = {Addison-Wesley},\n}\n";
    fs::write(rig.root.join("refs.bib"), bib).unwrap();
    rig.changed("refs.bib", true);
    let doc = rig.open("main.tex").await;
    let text = "\\newcommand{\\R}{\\mathbb{R}}\n\\section{Intro}\\label{sec:a}\n\
        See \\ref{sec:a}, \\cite{knuth}, \\R and \\toprule.";
    doc.edit(0, 5, text, None, false);
    assert!(until(&doc, |symbols| symbols.by_file.contains_key("refs.bib")).await);
    let help = async |name: &str| {
        let offset = text.rfind(name).unwrap() + 1;
        let args = json!({ "path": "main.tex", "offset": offset });
        rig.ok("quick_help", args).await
    };
    fn help_of(title: &str, detail: &str, place: Value) -> Value {
        json!({ "title": title, "detail": detail, "place": place })
    }
    fn at(file: &str, line: u32, column: u32, length: u32) -> Value {
        json!({ "file": file, "line": line, "column": column, "length": length })
    }
    let entry = "Donald E. Knuth, Leslie Lamport\nThe TeXbook\n1984\nAddison-Wesley";
    let cited = help_of("knuth", entry, at("refs.bib", 1, 6, 5));
    assert_eq!(help("knuth").await, cited);
    let label = |number| {
        help_of(
            "sec:a",
            &format!("{number}\nIntro"),
            at("main.tex", 2, 22, 5),
        )
    };
    assert_eq!(help("sec:a").await, label("Compile to number it"));
    fs::create_dir(rig.root.join("build")).unwrap();
    let aux = "\\relax\n\\newlabel{sec:a@cref}{{[section][1][]1}{[1][3][]3}}\n\
        \\newlabel{sec:a}{{1}{3}{Intro}{section.1}{}}\n";
    fs::write(rig.root.join("build/main.aux"), aux).unwrap();
    assert_eq!(help("sec:a").await, label("1 on page 3"));
    // An `\include`d file's labels are in its own .aux, which the main one inputs.
    let included = "\\newlabel{sec:a}{{2}{5}{Intro}{section.2}{}}\n";
    fs::write(rig.root.join("build/ch.aux"), included).unwrap();
    fs::write(rig.root.join("build/main.aux"), "\\@input{ch.aux}\n").unwrap();
    assert_eq!(help("sec:a").await, label("2 on page 5"));
    let defined = help_of(
        "\\R",
        "\\newcommand{\\R}{\\mathbb{R}}",
        at("main.tex", 1, 12, 2),
    );
    assert_eq!(help("\\R ").await, defined);
    let known = help_of("\\toprule", "From the booktabs package", Value::Null);
    assert_eq!(help("\\toprule").await, known);
    assert_eq!(help("See").await, Value::Null);
}
