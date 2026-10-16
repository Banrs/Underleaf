//! The session's rules on tokio's paused clock, with a fake latexmk and
//! TeXpresso (`Fake`) and the folder's changes sent in by hand.

use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::engine::Fut;
use super::watch::Change;
use super::{Document, Engine, Msg, Sessions, Timings};
use crate::CoreError;
use crate::compile::CompileResult;
use crate::logparse::LogItem;
use crate::service::Service;
use crate::texpresso::{Document as LiveDocument, Events, FileBuffer, Pane, RunEnd, Status};

// MARK: - A fake engine

type News = Result<Events, CoreError>;

#[derive(Default)]
struct Fake {
    calls: Mutex<Vec<String>>,
    builds: Mutex<VecDeque<oneshot::Sender<Result<CompileResult, CoreError>>>>,
    starts: Mutex<Vec<(Vec<String>, Option<String>)>>,
    /// Whether each start gave TeXpresso the host's pane, rather than its own window.
    panes: Mutex<Vec<bool>>,
    updates: Mutex<Vec<(String, String)>>,
    edits: Mutex<Vec<(String, usize, usize, String)>>,
    /// What the next edits answer; Ok once none is left.
    edit_answers: Mutex<VecDeque<Result<u64, CoreError>>>,
    news: Mutex<Option<Arc<tokio::sync::Mutex<mpsc::UnboundedReceiver<News>>>>>,
    news_tx: Mutex<Option<mpsc::UnboundedSender<News>>>,
    tokens: Mutex<u64>,
}

fn status(running: bool, token: Option<String>) -> Status {
    Status {
        available: true,
        running,
        log: String::new(),
        output: String::new(),
        error: None,
        revision: 1,
        session: token,
    }
}

fn built(pdf: bool, errors: Vec<LogItem>) -> CompileResult {
    CompileResult {
        ok: errors.is_empty(),
        stopped: false,
        duration_ms: 1,
        pdf: pdf.then(|| "build/main.pdf".into()),
        pdf_changed: pdf,
        errors,
        warnings: Vec::new(),
        log: String::new(),
    }
}

fn issue(kind: &'static str, line: u32, message: &str) -> LogItem {
    LogItem {
        kind,
        file: Some("main.tex".into()),
        line: Some(line),
        message: message.into(),
        short: message.into(),
        command: None,
    }
}

fn news(running: bool) -> Events {
    Events {
        seq: 1,
        running,
        error: None,
        live: Some(1),
        revision: 1,
        synced: 0,
        pdf: None,
        pages: Vec::new(),
        done: None,
    }
}

impl Fake {
    fn called(&self, what: &str) -> usize {
        let calls = self.calls.lock().unwrap();
        calls.iter().filter(|c| *c == what).count()
    }

    fn log(&self, what: &str) {
        self.calls.lock().unwrap().push(what.into());
    }

    fn finish_build(&self, result: CompileResult) {
        let build = self.builds.lock().unwrap().pop_front();
        let _ = build.expect("a build runs").send(Ok(result));
    }

    fn send_news(&self, events: News) {
        let tx = self.news_tx.lock().unwrap();
        tx.as_ref().expect("a preview runs").send(events).unwrap();
    }
}

impl Engine for Fake {
    fn compile(&self, _root: PathBuf) -> Fut<Result<CompileResult, CoreError>> {
        self.log("compile");
        let (tx, rx) = oneshot::channel();
        self.builds.lock().unwrap().push_back(tx);
        Box::pin(async move {
            rx.await
                .unwrap_or_else(|_| Err(CoreError::internal("dropped")))
        })
    }

    fn stop_compile(&self, _root: &Path) {
        self.log("stop_compile");
        if let Some(build) = self.builds.lock().unwrap().pop_front() {
            let mut stopped = built(false, Vec::new());
            stopped.stopped = true;
            let _ = build.send(Ok(stopped));
        }
    }

    fn clean(&self, _root: PathBuf) -> Fut<Result<(), CoreError>> {
        self.log("clean");
        Box::pin(async { Ok(()) })
    }

    fn live_start(
        &self,
        _root: PathBuf,
        files: Vec<FileBuffer>,
        expected: Option<String>,
        pane: Option<Pane>,
    ) -> Fut<Result<Status, CoreError>> {
        self.log("live_start");
        self.panes.lock().unwrap().push(pane.is_some());
        let paths = files.into_iter().map(|f| f.path).collect();
        self.starts.lock().unwrap().push((paths, expected));
        let (tx, rx) = mpsc::unbounded_channel();
        *self.news_tx.lock().unwrap() = Some(tx);
        *self.news.lock().unwrap() = Some(Arc::new(tokio::sync::Mutex::new(rx)));
        let mut tokens = self.tokens.lock().unwrap();
        *tokens += 1;
        let token = format!("t{tokens}");
        Box::pin(async move { Ok(status(true, Some(token))) })
    }

    fn live_update(
        &self,
        _root: PathBuf,
        path: String,
        text: String,
        _token: String,
    ) -> Fut<Result<u64, CoreError>> {
        self.updates.lock().unwrap().push((path, text));
        Box::pin(async { Ok(1) })
    }

    fn live_edit(
        &self,
        _token: &str,
        path: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<u64, CoreError> {
        let answer = self.edit_answers.lock().unwrap().pop_front();
        if answer.as_ref().is_none_or(Result::is_ok) {
            let edit = (path.to_owned(), start, remove, text.to_owned());
            self.edits.lock().unwrap().push(edit);
        }
        answer.unwrap_or(Ok(1))
    }

    fn live_view(&self, _token: &str, _first: u32, _last: u32) {
        self.log("live_view");
    }

    fn live_caret(&self, _token: &str, _path: &str, _offset: usize) {
        self.log("live_caret");
    }

    fn live_wait(&self, _root: PathBuf, _token: String, _after: u64) -> Fut<News> {
        let news = self.news.lock().unwrap().clone();
        Box::pin(async move {
            let Some(news) = news else {
                return std::future::pending().await;
            };
            let next = news.lock().await.recv().await;
            match next {
                Some(next) => next,
                None => std::future::pending().await,
            }
        })
    }

    fn live_stop(&self, _root: PathBuf, _token: String) -> Fut<Result<Status, CoreError>> {
        self.log("live_stop");
        Box::pin(async { Ok(status(false, None)) })
    }

    fn live_rescan(&self, _root: PathBuf, token: String) -> Fut<Result<Status, CoreError>> {
        self.log("live_rescan");
        Box::pin(async move { Ok(status(true, Some(token))) })
    }

    fn live_status(&self, _root: &Path, token: Option<&str>) -> Result<Status, CoreError> {
        Ok(status(token.is_some(), token.map(str::to_owned)))
    }
}

// MARK: - A session to drive

struct Rig {
    _data: tempfile::TempDir,
    root: PathBuf,
    sessions: Sessions,
    fake: Arc<Fake>,
    seen: Arc<Mutex<Vec<Value>>>,
    session: u64,
    marks: u64,
}

impl Rig {
    async fn new(auto_compile: bool) -> Rig {
        let data = tempfile::tempdir().unwrap();
        crate::projects::create_project(data.path(), "P", "blank").unwrap();
        let root = dunce::canonicalize(data.path().join("P")).unwrap();
        fs::write(root.join("main.tex"), "Hello").unwrap();
        let service = Arc::new(Service::new(data.path().to_path_buf()));
        let fake = Arc::new(Fake::default());
        let timings = Timings {
            watch: false,
            ..Timings::default()
        };
        let engine = Arc::clone(&fake) as Arc<dyn Engine>;
        let sessions = Sessions::with_engine(service, engine, timings);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        sessions.set_listener(Some(Box::new(move |event| {
            sink.lock().unwrap().push(event.clone())
        })));
        let args = json!({ "id": "P", "autoCompile": auto_compile });
        let opened = sessions.call("session_open", &args).await.unwrap();
        let session = opened["session"].as_u64().unwrap();
        Rig {
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
        self.sessions.call(&command, &args).await
    }

    /// Answers once every message sent before it has been handled.
    async fn ok(&self, name: &str, args: Value) -> Value {
        self.call(name, args).await.unwrap()
    }

    async fn open(&self, path: &str) -> Document {
        self.ok("open_document", json!({ "path": path })).await;
        self.sessions.document(self.session, path).unwrap()
    }

    /// The events since the last look.
    async fn events(&mut self) -> Vec<Value> {
        self.ok("state", json!({})).await;
        self.marks += 1;
        let mark = self.marks;
        self.sessions
            .hub()
            .emit(json!({ "type": "mark", "n": mark }));
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let mut seen = self.seen.lock().unwrap();
            if let Some(at) = seen
                .iter()
                .position(|e| e["type"] == "mark" && e["n"] == mark)
            {
                let events: Vec<Value> = seen.drain(..=at).collect();
                return events[..events.len() - 1].to_vec();
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

    /// Another app wrote the file, and the system said so.
    fn write_elsewhere(&self, path: &str, text: &str) {
        fs::write(self.root.join(path), text).unwrap();
        self.changed(path, false);
    }

    fn changed(&self, path: &str, structural: bool) {
        let change = Change {
            path: self.root.join(path),
            structural,
        };
        self.sessions.inject(self.session, Msg::Fs(vec![change]));
    }

    async fn state(&self) -> Value {
        self.ok("state", json!({})).await
    }
}

async fn wait(ms: u64) {
    tokio::time::sleep(Duration::from_millis(ms)).await;
}

// MARK: - Autosave

#[tokio::test(start_paused = true)]
async fn the_autosave_writes_700_ms_after_the_last_edit() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " world");
    wait(600).await;
    doc.edit(11, 0, "!");
    wait(600).await;
    assert_eq!(rig.disk("main.tex"), "Hello");
    // The open's alone: Not Saved is for an error or Cancel, so edits and saves change
    // nothing a `document` event tells.
    assert_eq!(rig.of_type("document").await.len(), 1);
    assert_eq!(rig.state().await["documents"][0]["dirty"], true);
    wait(150).await;
    assert_eq!(rig.disk("main.tex"), "Hello world!");
    let events = rig.events().await;
    assert!(
        events
            .iter()
            .any(|e| e["type"] == "saved" && e["path"] == "main.tex")
    );
    assert!(!events.iter().any(|e| e["type"] == "document"));
    assert_eq!(rig.state().await["documents"][0]["dirty"], false);
    assert_eq!(rig.fake.called("compile"), 0);
}

#[tokio::test(start_paused = true)]
async fn an_autosave_builds_when_auto_compile_is_on() {
    let mut rig = Rig::new(true).await;
    // No PDF yet: the session builds as it opens.
    wait(1).await;
    assert_eq!(rig.fake.called("compile"), 1);
    rig.fake.finish_build(built(true, Vec::new()));
    let doc = rig.open("main.tex").await;
    doc.edit(0, 5, "Bye");
    wait(800).await;
    rig.state().await;
    assert_eq!(rig.disk("main.tex"), "Bye");
    assert_eq!(rig.fake.called("compile"), 2);
    let builds = rig.of_type("build").await;
    assert!(
        builds
            .iter()
            .any(|b| b["compiling"] == true && b["auto"] == true)
    );
}

#[tokio::test(start_paused = true)]
async fn ime_composition_holds_the_autosave_until_it_ends() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.ok(
        "composing",
        json!({ "path": "main.tex", "composing": true }),
    )
    .await;
    doc.edit(5, 0, "ka");
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "Hello");
    doc.edit(5, 2, "か");
    rig.ok(
        "composing",
        json!({ "path": "main.tex", "composing": false }),
    )
    .await;
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "Helloか");
}

// MARK: - Builds

#[tokio::test(start_paused = true)]
async fn requests_during_a_build_queue_one_more_and_stop_drops_it() {
    let mut rig = Rig::new(false).await;
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.fake.called("compile"), 1);
    // An automatic request then a manual one: one manual build follows.
    rig.ok("compile", json!({ "auto": true })).await;
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.ok("state", json!({})).await["build"]["queued"], true);
    rig.fake.finish_build(built(true, Vec::new()));
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
    let finished = rig.of_type("build_finished").await;
    assert_eq!(finished.len(), 1);
    assert_eq!(finished[0]["auto"], false);
    // Stop drops the queued one too.
    rig.ok("compile", json!({})).await;
    rig.ok("stop_compile", json!({})).await;
    rig.state().await;
    assert_eq!(rig.fake.called("stop_compile"), 1);
    assert!(rig.fake.builds.lock().unwrap().is_empty());
    let state = rig.state().await;
    assert_eq!(state["build"]["compiling"], false);
    assert_eq!(state["build"]["queued"], false);
    assert_eq!(rig.fake.called("compile"), 2);
}

#[tokio::test(start_paused = true)]
async fn a_build_saves_first_and_the_preview_is_out_of_date_after_edits_made_during_it() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, "1");
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.disk("main.tex"), "Hello1");
    // Typed while it builds.
    doc.edit(6, 0, "2");
    rig.state().await;
    rig.fake.finish_build(built(true, Vec::new()));
    let finished = rig.of_type("build_finished").await;
    assert_eq!(finished[0]["outdated"], true);
    assert_eq!(rig.state().await["build"]["outdated"], true);
    rig.ok("compile", json!({})).await;
    rig.fake.finish_build(built(true, Vec::new()));
    rig.state().await;
    assert_eq!(rig.state().await["build"]["outdated"], false);
    // With a PDF shown, an edit puts it out of date.
    doc.edit(0, 0, "x");
    let builds = rig.of_type("build").await;
    assert_eq!(builds.last().unwrap()["outdated"], true);
}

#[tokio::test(start_paused = true)]
async fn issues_mark_unedited_documents_and_go_with_an_edit() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    let errors = vec![
        issue("error", 3, "Undefined"),
        issue("error", 3, "Again"),
        issue("error", 9, "Late"),
    ];
    rig.fake.finish_build(built(true, errors));
    let issues = rig.of_type("issues").await;
    assert_eq!(issues.len(), 1);
    let lines = issues[0]["lines"].as_array().unwrap();
    assert_eq!(lines[0]["line"], 3);
    assert_eq!(lines[0]["message"], "Undefined");
    assert_eq!(lines[0]["others"], json!(["Again"]));
    // Round from the last to the first; back from the first to the last.
    let next = rig.ok("issue", json!({ "next": true })).await;
    assert_eq!(next["index"], 0);
    rig.ok("choose_issue", json!({ "index": 2 })).await;
    assert_eq!(rig.ok("issue", json!({ "next": true })).await["index"], 0);
    assert_eq!(rig.ok("issue", json!({ "next": false })).await["index"], 2);
    doc.edit(0, 0, "x");
    let cleared = rig.of_type("issues").await;
    assert_eq!(
        cleared,
        [json!({ "type": "issues", "session": rig.session, "path": "main.tex", "lines": [] })]
    );
}

#[tokio::test(start_paused = true)]
async fn a_document_edited_since_the_build_shows_no_marks_when_it_opens_again() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    rig.fake
        .finish_build(built(true, vec![issue("error", 1, "Undefined")]));
    assert_eq!(rig.of_type("issues").await.len(), 1);
    // The line the issue was on moves down.
    doc.edit(0, 0, "\n");
    rig.ok("close_document", json!({ "path": "main.tex" }))
        .await;
    rig.events().await;
    rig.open("main.tex").await;
    assert_eq!(rig.of_type("issues").await, Vec::<Value>::new());
    // A build since the edit marks it again.
    rig.ok("compile", json!({})).await;
    rig.fake
        .finish_build(built(true, vec![issue("error", 2, "Undefined")]));
    let issues = rig.of_type("issues").await;
    assert_eq!(issues[0]["lines"][0]["line"], 2);
}

#[tokio::test(start_paused = true)]
async fn a_failed_build_announces_and_an_automatic_one_only_when_the_errors_change() {
    let mut rig = Rig::new(false).await;
    rig.ok("compile", json!({ "auto": true })).await;
    rig.fake
        .finish_build(built(true, vec![issue("error", 1, "a")]));
    rig.ok("compile", json!({ "auto": true })).await;
    rig.fake
        .finish_build(built(true, vec![issue("error", 2, "b")]));
    let finished = rig.of_type("build_finished").await;
    let announced: Vec<bool> = finished.iter().map(|f| f["announce"] == true).collect();
    assert_eq!(announced, [true, false]);
}

// MARK: - Changes on disk

#[tokio::test(start_paused = true)]
async fn another_apps_change_to_a_clean_document_reloads_it() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.write_elsewhere("main.tex", "From elsewhere");
    wait(300).await;
    let reloads = rig.of_type("document_reload").await;
    assert_eq!(reloads.len(), 1);
    assert_eq!(reloads[0]["text"], "From elsewhere");
    assert_eq!(reloads[0]["reason"], "disk");
    doc.reload("From elsewhere");
    let state = rig.state().await;
    assert_eq!(state["documents"][0]["dirty"], false);
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "From elsewhere");
}

#[tokio::test(start_paused = true)]
async fn the_sessions_own_save_is_not_another_apps_change() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, "!");
    wait(800).await;
    rig.changed("main.tex", true);
    rig.changed(".texlocal-tmp", true);
    rig.changed("main.tex", false);
    wait(300).await;
    let events = rig.events().await;
    let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
    assert!(
        !kinds
            .iter()
            .any(|k| ["conflict", "document_reload", "tree"].contains(k)),
        "{kinds:?}"
    );
}

#[tokio::test(start_paused = true)]
async fn a_change_under_unsaved_edits_is_asked_about_and_save_anyway_keeps_them() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
    rig.write_elsewhere("main.tex", "theirs");
    wait(300).await;
    let conflicts = rig.of_type("conflict").await;
    assert_eq!(
        conflicts,
        [
            json!({ "type": "conflict", "session": rig.session, "path": "main.tex", "kind": "changed" })
        ]
    );
    // Nothing writes over theirs while it is asked about.
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "theirs");
    rig.ok("resolve", json!({ "path": "main.tex", "answer": "save" }))
        .await;
    assert_eq!(rig.disk("main.tex"), "Hello mine");
}

#[tokio::test(start_paused = true)]
async fn revert_shows_and_writes_back_the_disks_text() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
    rig.write_elsewhere("main.tex", "theirs");
    wait(300).await;
    rig.ok("resolve", json!({ "path": "main.tex", "answer": "revert" }))
        .await;
    let reloads = rig.of_type("document_reload").await;
    assert_eq!(reloads[0]["reason"], "revert");
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
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
    rig.write_elsewhere("main.tex", "theirs");
    wait(300).await;
    rig.ok("resolve", json!({ "path": "main.tex", "answer": "cancel" }))
        .await;
    let state = rig.state().await;
    assert_eq!(state["documents"][0]["held"], true);
    rig.events().await;
    doc.edit(0, 0, "x");
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "theirs");
    assert!(rig.of_type("conflict").await.is_empty());
    // A save someone asks for asks again.
    let saved = rig.ok("save", json!({})).await;
    assert_eq!(saved["saved"], false);
    assert_eq!(rig.of_type("conflict").await.len(), 1);
}

#[tokio::test(start_paused = true)]
async fn a_deleted_file_with_unsaved_edits_is_asked_about_and_not_put_back() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
    fs::remove_file(rig.root.join("main.tex")).unwrap();
    rig.changed("main.tex", true);
    wait(300).await;
    let conflicts = rig.of_type("conflict").await;
    assert_eq!(conflicts[0]["kind"], "gone");
    wait(800).await;
    assert!(!rig.root.join("main.tex").exists());
    rig.ok("resolve", json!({ "path": "main.tex", "answer": "save" }))
        .await;
    assert_eq!(rig.disk("main.tex"), "Hello mine");
}

#[tokio::test(start_paused = true)]
async fn a_deleted_file_without_edits_closes() {
    let mut rig = Rig::new(false).await;
    rig.open("main.tex").await;
    fs::remove_file(rig.root.join("main.tex")).unwrap();
    rig.changed("main.tex", true);
    wait(300).await;
    let events = rig.events().await;
    let closed = events
        .iter()
        .find(|e| e["type"] == "document_closed")
        .unwrap();
    assert_eq!(closed["reason"], "gone");
    // The listing changed too.
    assert!(events.iter().any(|e| e["type"] == "tree"));
    assert!(rig.sessions.document(rig.session, "main.tex").is_none());
}

#[tokio::test(start_paused = true)]
async fn a_new_file_changes_the_tree_and_a_changed_unopened_file_is_told_of() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("refs.bib"), "@book{a,").unwrap();
    rig.changed("refs.bib", true);
    wait(300).await;
    let trees = rig.of_type("tree").await;
    let names: Vec<&str> = trees[0]["tree"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["path"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"refs.bib"));
    rig.write_elsewhere("refs.bib", "@book{b,");
    wait(300).await;
    let changed = rig.of_type("files_changed").await;
    assert_eq!(changed[0]["paths"], json!(["refs.bib"]));
}

// MARK: - Files

#[tokio::test(start_paused = true)]
async fn a_rename_moves_the_open_document_and_its_saves() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    let doc = rig.open("ch.tex").await;
    doc.edit(0, 0, "A ");
    let renamed = rig
        .ok("rename", json!({ "from": "ch.tex", "to": "one.tex" }))
        .await;
    assert_eq!(renamed["to"], "one.tex");
    let moved = rig.of_type("document_renamed").await;
    assert_eq!(moved[0]["to"], "one.tex");
    doc.edit(0, 0, "B");
    wait(800).await;
    assert_eq!(rig.disk("one.tex"), "BA chapter");
    assert!(!rig.root.join("ch.tex").exists());
}

#[tokio::test(start_paused = true)]
async fn the_main_file_cant_go_to_the_trash_and_nothing_puts_a_trashed_file_back() {
    let rig = Rig::new(false).await;
    let refused = rig
        .call("prepare_delete", json!({ "path": "main.tex" }))
        .await;
    assert_eq!(refused.unwrap_err().status, 409);
    fs::write(rig.root.join("old.tex"), "old").unwrap();
    let doc = rig.open("old.tex").await;
    doc.edit(0, 0, "x");
    let ready = rig.ok("prepare_delete", json!({ "path": "old.tex" })).await;
    assert_eq!(ready["ready"], true);
    assert_eq!(rig.disk("old.tex"), "xold");
    doc.edit(0, 0, "y");
    fs::remove_file(rig.root.join("old.tex")).unwrap();
    wait(800).await;
    assert!(!rig.root.join("old.tex").exists());
    rig.ok("deleted", json!({ "path": "old.tex" })).await;
    assert!(rig.sessions.document(rig.session, "old.tex").is_none());
}

// MARK: - Live preview

async fn live(rig: &Rig) -> Value {
    let started = rig.ok("live_start", json!({})).await;
    assert_eq!(started["phase"], "running");
    started
}

#[tokio::test(start_paused = true)]
async fn keys_go_to_texpresso_as_made_and_a_refused_one_sends_the_whole_text() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    assert_eq!(rig.fake.starts.lock().unwrap()[0].0, ["main.tex"]);
    doc.edit(5, 0, "!");
    rig.state().await;
    assert_eq!(rig.fake.edits.lock().unwrap().len(), 1);
    rig.fake
        .edit_answers
        .lock()
        .unwrap()
        .push_back(Err(CoreError::unfit("unfit")));
    doc.edit(6, 0, "?");
    rig.state().await;
    let updates = rig.fake.updates.lock().unwrap().clone();
    assert_eq!(updates, [("main.tex".to_string(), "Hello!?".to_string())]);
    // In step again: the next key is an edit.
    doc.edit(7, 0, ".");
    rig.state().await;
    assert_eq!(rig.fake.edits.lock().unwrap().len(), 2);
}

#[tokio::test(start_paused = true)]
async fn a_stopped_run_is_halted_only_once_it_has_lasted_a_second() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    let stopped = |run: &str| Events {
        done: Some(RunEnd {
            pages: 1,
            run: run.into(),
        }),
        ..news(true)
    };
    rig.fake.send_news(Ok(stopped("stopped")));
    wait(500).await;
    rig.fake.send_news(Ok(stopped("complete")));
    wait(1000).await;
    assert_eq!(rig.state().await["live"]["halted"], false);
    rig.fake.send_news(Ok(stopped("stopped")));
    wait(1100).await;
    let lives = rig.of_type("live").await;
    assert_eq!(lives.last().unwrap()["halted"], true);
}

#[tokio::test(start_paused = true)]
async fn documents_and_pages_go_to_the_host() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    let document = LiveDocument {
        path: "/tmp/live.pdf".into(),
        version: 2,
        serial: 3,
        pages: 4,
        run: Some("complete".into()),
        changed: Some(vec![[1, 1]]),
        edit: 0,
    };
    rig.fake.send_news(Ok(Events {
        pdf: Some(document),
        ..news(true)
    }));
    wait(1).await;
    let shown = rig.of_type("live_document").await;
    // Version 1 never came: any page may differ.
    assert_eq!(shown[0]["changed"], Value::Null);
    assert_eq!(shown[0]["complete"], true);
}

#[tokio::test(start_paused = true)]
async fn a_preview_that_ends_after_ten_seconds_restarts_and_a_new_one_reports() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    wait(11_000).await;
    rig.fake.send_news(Ok(Events {
        error: Some("TeXpresso exited".into()),
        ..news(false)
    }));
    wait(1).await;
    rig.state().await;
    let starts = rig.fake.starts.lock().unwrap().clone();
    assert_eq!(starts.len(), 2);
    assert_eq!(starts[1].1.as_deref(), Some("t1"));
    assert_eq!(rig.of_type("live_restarted").await.len(), 1);
    // At once after its start, the end is reported.
    rig.fake.send_news(Ok(Events {
        error: Some("TeXpresso exited".into()),
        ..news(false)
    }));
    wait(1).await;
    let state = rig.state().await;
    assert_eq!(state["live"]["phase"], "stopped");
    assert_eq!(state["live"]["failure"], "TeXpresso exited");
    assert_eq!(rig.fake.starts.lock().unwrap().len(), 2);
}

#[tokio::test(start_paused = true)]
async fn automatic_builds_wait_while_live_preview_runs() {
    let rig = Rig::new(true).await;
    wait(1).await;
    rig.fake.finish_build(built(true, Vec::new()));
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    doc.edit(0, 0, "x");
    wait(800).await;
    rig.state().await;
    assert_eq!(rig.disk("main.tex"), "xHello");
    assert_eq!(rig.fake.called("compile"), 1);
    // Stopped, the build catches up.
    rig.ok("live_stop", json!({})).await;
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
}

#[tokio::test(start_paused = true)]
async fn another_windows_preview_ends_this_ones() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    rig.fake
        .edit_answers
        .lock()
        .unwrap()
        .push_back(Err(CoreError::conflict("Another window")));
    doc.edit(0, 0, "x");
    let state = rig.state().await;
    assert_eq!(state["live"]["phase"], "stopped");
    assert_eq!(state["live"]["token"], Value::Null);
    assert_eq!(state["live"]["failure"], "Another window");
}

#[tokio::test(start_paused = true)]
async fn a_rename_restarts_the_preview_once_it_settles() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    live(&rig).await;
    rig.ok("rename", json!({ "from": "ch.tex", "to": "one.tex" }))
        .await;
    wait(100).await;
    assert_eq!(rig.fake.starts.lock().unwrap().len(), 1);
    wait(100).await;
    rig.state().await;
    let starts = rig.fake.starts.lock().unwrap().clone();
    assert_eq!(starts.len(), 2);
    assert_eq!(starts[1].1.as_deref(), Some("t1"));
}

#[tokio::test(start_paused = true)]
async fn the_caret_is_told_once_it_settles() {
    let rig = Rig::new(false).await;
    rig.open("main.tex").await;
    live(&rig).await;
    for offset in 0..5 {
        rig.ok(
            "live_caret",
            json!({ "path": "main.tex", "offset": offset }),
        )
        .await;
        wait(50).await;
    }
    assert_eq!(rig.fake.called("live_caret"), 0);
    wait(200).await;
    rig.state().await;
    assert_eq!(rig.fake.called("live_caret"), 1);
}

#[tokio::test(start_paused = true)]
async fn in_texpressos_own_window_the_preview_is_told_no_view_or_caret_and_restarts_there() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    rig.open("main.tex").await;
    rig.ok("live_view", json!({ "first": 0, "last": 1 })).await;
    let started = rig.ok("live_start", json!({ "window": true })).await;
    assert_eq!(started["phase"], "running");
    rig.ok("live_view", json!({ "first": 1, "last": 2 })).await;
    rig.ok("live_caret", json!({ "path": "main.tex", "offset": 2 }))
        .await;
    wait(200).await;
    rig.state().await;
    assert_eq!(rig.fake.called("live_view"), 0);
    assert_eq!(rig.fake.called("live_caret"), 0);
    // A restart of its own keeps to the window; the user's next Start chooses again.
    rig.ok("rename", json!({ "from": "ch.tex", "to": "one.tex" }))
        .await;
    wait(200).await;
    rig.state().await;
    rig.ok("live_stop", json!({})).await;
    live(&rig).await;
    assert_eq!(*rig.fake.panes.lock().unwrap(), [false, false, true]);
}

#[tokio::test(start_paused = true)]
async fn closing_saves_and_stops_the_preview() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    live(&rig).await;
    doc.edit(0, 0, "x");
    let closed = rig.ok("close", json!({})).await;
    assert_eq!(closed["saved"], true);
    assert_eq!(rig.disk("main.tex"), "xHello");
    assert_eq!(rig.fake.called("live_stop"), 1);
    assert_eq!(rig.call("state", json!({})).await.unwrap_err().status, 404);
}

// MARK: - The folder's watcher, for real

/// Waits, on the wall clock, for an event `found` picks out.
fn until_event(seen: &Mutex<Vec<Value>>, found: impl Fn(&Value) -> bool) -> Option<Value> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        if let Some(event) = seen.lock().unwrap().iter().find(|e| found(e)) {
            return Some(event.clone());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_watcher_tells_another_apps_changes_from_the_sessions_own() {
    let data = tempfile::tempdir().unwrap();
    crate::projects::create_project(data.path(), "P", "blank").unwrap();
    let root = dunce::canonicalize(data.path().join("P")).unwrap();
    fs::write(root.join("main.tex"), "Hello").unwrap();
    let service = Arc::new(Service::new(data.path().to_path_buf()));
    let sessions = Sessions::new(service);
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&seen);
    sessions.set_listener(Some(Box::new(move |event| {
        sink.lock().unwrap().push(event.clone())
    })));
    let opened = sessions.call("session_open", &json!({ "id": "P" })).await;
    let session = opened.unwrap()["session"].as_u64().unwrap();
    let args = json!({ "session": session, "path": "main.tex" });
    sessions.call("session_open_document", &args).await.unwrap();
    let doc = sessions.document(session, "main.tex").unwrap();
    doc.edit(5, 0, "!");
    let saved = until_event(&seen, |e| e["type"] == "saved");
    assert!(saved.is_some(), "autosaved");
    // Long enough for the save's own changes to have come and gone.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let mixed =
        |e: &Value| ["conflict", "document_reload", "tree"].contains(&e["type"].as_str().unwrap());
    assert!(
        !seen.lock().unwrap().iter().any(mixed),
        "{:?}",
        seen.lock().unwrap()
    );
    fs::write(root.join("main.tex"), "theirs").unwrap();
    let reload = until_event(&seen, |e| e["type"] == "document_reload");
    assert_eq!(reload.expect("reloaded")["text"], "theirs");
    fs::write(root.join("new.tex"), "").unwrap();
    assert!(until_event(&seen, |e| e["type"] == "tree").is_some());
    sessions.close_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_event_reaches_the_listener_before_the_answer_to_its_sessions_open() {
    let data = tempfile::tempdir().unwrap();
    crate::projects::create_project(data.path(), "P", "blank").unwrap();
    let service = Arc::new(Service::new(data.path().to_path_buf()));
    let fake = Arc::new(Fake::default());
    let engine = Arc::clone(&fake) as Arc<dyn Engine>;
    let timings = Timings {
        watch: false,
        ..Timings::default()
    };
    let sessions = Sessions::with_engine(service, engine, timings);
    // The listener and the answer's delivery write to one list, in the order they happen.
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&seen);
    sessions.set_listener(Some(Box::new(move |event| {
        sink.lock().unwrap().push(event.clone())
    })));
    // No PDF yet, so a build starts at once: its `build` event is made while
    // the open is still being answered.
    let args = json!({ "id": "P", "autoCompile": true });
    let delivered = Arc::clone(&seen);
    let session = sessions
        .call_then("session_open", &args, |answer| {
            // The build has started, so its event is made; and then a good while for it to
            // have gone out, had it not been held back.
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while fake.called("compile") == 0 && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(1));
            }
            assert_eq!(fake.called("compile"), 1, "the build started");
            std::thread::sleep(Duration::from_millis(200));
            let session = answer.unwrap()["session"].as_u64().unwrap();
            delivered
                .lock()
                .unwrap()
                .push(json!({ "type": "answer", "session": session }));
            session
        })
        .await;
    let first = until_event(&seen, |e| e["type"] == "build").expect("the build is told");
    let events = seen.lock().unwrap().clone();
    assert_eq!(events[0], json!({ "type": "answer", "session": session }));
    assert_eq!(first["session"], session);
    assert_eq!(first["compiling"], true);
    // A failed open holds nothing.
    let missing = json!({ "id": "Nope" });
    sessions
        .call_then("session_open", &missing, |answer| assert!(answer.is_err()))
        .await;
    sessions.close_all().await;
}
