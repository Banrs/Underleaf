//! The session's rules on tokio's paused clock, with a fake latexmk and
//! TeXpresso (`Fake`) and the folder's changes sent in by hand.

use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::oneshot;

use super::actor::Newline;
use super::engine::Fut;
use super::watch::Change;
use super::{Document, Engine, Msg, Preview, Sessions, Timings};
use crate::compile::CompileResult;
use crate::logparse::LogItem;
use crate::service::Service;
use crate::texpresso::{FileBuffer, LiveEvent, Pane, Sink, Status};
use crate::{CoreError, lock};

// MARK: - A fake engine

#[derive(Default)]
struct Fake {
    calls: Mutex<Vec<String>>,
    builds: Mutex<VecDeque<oneshot::Sender<Result<CompileResult, CoreError>>>>,
    /// Each start's files, and whether it was a restart of the session's own.
    starts: Mutex<Vec<(Vec<String>, bool)>>,
    /// Whether each start gave TeXpresso the host's pane, rather than its own window.
    panes: Mutex<Vec<bool>>,
    updates: Mutex<Vec<(String, String)>>,
    edits: Mutex<Vec<(String, usize, usize, String)>>,
    /// What the next edits answer; Ok once none is left.
    edit_answers: Mutex<VecDeque<Result<(), CoreError>>>,
    /// Where the last start's preview tells what it shows.
    sink: Mutex<Option<Sink>>,
    /// TeX's log, as the Live Preview Log shows it.
    log: Mutex<String>,
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
    }
}

fn exited() -> LiveEvent {
    LiveEvent::Ended(Some("TeXpresso exited".into()))
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

    /// What the preview shows, told as TeXpresso's manager tells it.
    fn tell(&self, event: LiveEvent) {
        if let Some(sink) = self.sink.lock().unwrap().as_ref() {
            sink(event);
        }
    }

    /// The next key's edit is refused with `error`.
    fn refuse_edit(&self, error: CoreError) {
        self.edit_answers.lock().unwrap().push_back(Err(error));
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
}

impl Preview for Fake {
    fn start(
        &self,
        _owner: u64,
        _root: &Path,
        files: &[FileBuffer],
        replacing: bool,
        _path_env: &str,
        pane: Option<&Pane>,
        sink: Sink,
    ) -> Result<Status, CoreError> {
        self.log("live_start");
        self.panes.lock().unwrap().push(pane.is_some());
        let paths = files.iter().map(|f| f.path.clone()).collect();
        self.starts.lock().unwrap().push((paths, replacing));
        *self.sink.lock().unwrap() = Some(sink);
        Ok(status(true))
    }

    fn update(&self, _owner: u64, path: &str, text: &str) -> Result<(), CoreError> {
        let update = (path.to_owned(), text.to_owned());
        self.updates.lock().unwrap().push(update);
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
        let answer = self.edit_answers.lock().unwrap().pop_front();
        if answer.as_ref().is_none_or(Result::is_ok) {
            let edit = (path.to_owned(), start, remove, text.to_owned());
            self.edits.lock().unwrap().push(edit);
        }
        answer.unwrap_or(Ok(()))
    }

    fn view(&self, _owner: u64, _first: u32, _last: u32) -> Result<(), CoreError> {
        self.log("live_view");
        Ok(())
    }

    fn caret(&self, _owner: u64, _path: &str, _offset: usize) -> Result<(), CoreError> {
        self.log("live_caret");
        Ok(())
    }

    fn rescan(&self, _owner: u64) -> Result<(), CoreError> {
        self.log("live_rescan");
        Ok(())
    }

    fn status(&self, _owner: u64) -> Result<Status, CoreError> {
        Ok(Status {
            log: self.log.lock().unwrap().clone(),
            output: "TeX's output".into(),
            ..status(true)
        })
    }

    /// As the manager's, which ends the preview: its end is told.
    fn stop_request(&self, _owner: u64) -> Result<Status, CoreError> {
        self.log("live_stop");
        self.tell(LiveEvent::Ended(None));
        Ok(status(false))
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
    sessions: Sessions,
    fake: Arc<Fake>,
    seen: Arc<Mutex<Vec<Value>>>,
    session: u64,
    marks: u64,
}

impl Rig {
    async fn new(auto_compile: bool) -> Self {
        Self::watching(auto_compile, false).await
    }

    /// Project "P"'s session, its main.tex "Hello"; with `watch`, the folder's watcher runs.
    async fn watching(auto_compile: bool, watch: bool) -> Self {
        let data = tempfile::tempdir().unwrap();
        crate::projects::create_project(data.path(), "P", "blank").unwrap();
        let root = dunce::canonicalize(data.path().join("P")).unwrap();
        fs::write(root.join("main.tex"), "Hello").unwrap();
        let service = Arc::new(Service::new(data.path().to_path_buf()));
        // As if `status` had found TeX, which automatic builds wait for.
        service.tex_found.send_replace(true);
        let fake = Arc::new(Fake {
            log: Mutex::new("TeX's log".into()),
            ..Fake::default()
        });
        let timings = Timings {
            watch,
            ..Timings::default()
        };
        let (engine, preview) = (Arc::clone(&fake), Arc::clone(&fake));
        let sessions = Sessions::with_engine(service, engine, preview, timings);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        sessions.set_listener(Some(Box::new(move |event| {
            sink.lock().unwrap().push(event.clone());
        })));
        let args = json!({ "id": "P", "session": 1, "autoCompile": auto_compile });
        let opened = sessions.call("session_open", &args).await.unwrap();
        let session = opened["session"].as_u64().unwrap();
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
        let marker = json!({ "type": "mark", "n": mark });
        self.sessions.hub().emitter().send(marker);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let mut seen = self.seen.lock().unwrap();
            let at = seen
                .iter()
                .position(|e| e["type"] == "mark" && e["n"] == mark);
            if let Some(at) = at {
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

    /// Answers main.tex's conflict.
    async fn resolve(&self, answer: &str) {
        let args = json!({ "path": "main.tex", "answer": answer });
        self.ok("resolve", args).await;
    }

    /// `outline_current`: the heading `line` of `path` is under.
    async fn heading(&self, path: &str, line: usize) -> Value {
        self.ok("outline_current", json!({ "path": path, "line": line }))
            .await
    }
}

/// An event that takes the session's own save for another app's change.
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
    let saved = json!({ "type": "saved", "session": rig.session, "path": "main.tex" });
    assert!(events.contains(&saved));
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
    let automatic = |build: &Value| build["compiling"] == true && build["auto"] == true;
    assert!(rig.of_type("build").await.iter().any(automatic));
}

#[tokio::test(start_paused = true)]
async fn ime_composition_holds_the_autosave_until_it_ends() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    let composing = |on| rig.ok("composing", json!({ "path": "main.tex", "composing": on }));
    composing(true).await;
    doc.edit(5, 0, "ka");
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "Hello");
    doc.edit(5, 2, "か");
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
    // An automatic request then a manual one: one manual build follows.
    rig.ok("compile", json!({ "auto": true })).await;
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.ok("state", json!({})).await["build"]["queued"], true);
    rig.fake.finish_build(built(true, Vec::new()));
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
    let events = rig.events().await;
    let of = |kind: &'static str| events.iter().filter(move |e| e["type"] == kind);
    let finished: Vec<&Value> = of("build_finished").collect();
    assert_eq!(finished.len(), 1);
    assert_eq!(finished[0]["auto"], false);
    // Compile's word and spinner stay as they are from one build to the next.
    assert!(of("build").all(|b| b["compiling"] == true), "{events:?}");
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
    let errors = vec![issue(3, "Undefined"), issue(3, "Again"), issue(9, "Late")];
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

/// An undefined command's issue says where its line has the command, and names it in fewer words.
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

/// The analysis of the file shown, whose outline the heading a line is under is found in.
#[tokio::test(start_paused = true)]
async fn the_analysis_is_kept_for_the_heading_a_line_is_under() {
    let rig = Rig::new(false).await;
    let text = "\\documentclass{book}\n\\chapter{A}\n\\section{B}\n\\section{}\n";
    fs::write(rig.root.join("main.tex"), text).unwrap();
    let analysis = rig.ok("analyze", json!({ "path": "main.tex" })).await;
    assert_eq!(
        analysis["words"], 2,
        "A and B: the class is a name, not a word"
    );
    assert_eq!(analysis["tree"][0]["children"][0]["command"], "section");
    let untitled = &analysis["tree"][0]["children"][1];
    assert_eq!(untitled["title"], "Untitled Section");
    assert_eq!(untitled["foldKey"], "main.tex\t2:(untitled)#1");
    // The class's levels: a book's, with Normal Text first.
    let levels: Vec<&str> = analysis["headingStyles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["command"].as_str().unwrap())
        .collect();
    assert_eq!(levels[..3], ["", "part", "chapter"]);
    assert_eq!(rig.heading("main.tex", 1).await, Value::Null);
    assert_eq!(rig.heading("main.tex", 3).await, json!(1));
    assert_eq!(rig.heading("main.tex", 9).await, json!(2));
    // The class as the editor has it, before it is saved.
    let doc = rig.open("main.tex").await;
    doc.edit(15, 4, "article");
    let analysis = rig.ok("analyze", json!({ "path": "main.tex" })).await;
    let levels = analysis["headingStyles"].as_array().unwrap();
    assert!(
        !levels.iter().any(|l| l["command"] == "chapter"),
        "{levels:?}"
    );
}

/// An analysis is worked out beside the session: one under way holds up no other command,
/// and one asked for earlier that finishes later leaves the later one's outline.
#[tokio::test]
#[expect(
    clippy::await_holding_lock,
    reason = "the analyses wait for the outline as long ones would"
)]
async fn an_analysis_holds_up_no_other_command_and_the_last_asked_for_is_kept() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("main.tex"), "\\section{A}\n\\section{B}\n").unwrap();
    fs::write(rig.root.join("ch.tex"), "\\section{C}\n").unwrap();
    let outline = rig.sessions.outline(rig.session);
    let held = lock(&outline);
    let analyze = |path| {
        let args = json!({ "session": rig.session, "path": path });
        rig.sessions.send("session_analyze", &args)
    };
    let (earlier, later) = (analyze("main.tex"), analyze("ch.tex"));
    assert_eq!(rig.state().await["build"]["compiling"], false);
    drop(held);
    later.await.unwrap();
    earlier.await.unwrap();
    // ch.tex alone, as the main file doesn't reach it.
    assert_eq!(rig.heading("ch.tex", 5).await, json!(0));
}

#[tokio::test(start_paused = true)]
async fn a_document_edited_since_the_build_shows_no_marks_when_it_opens_again() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    rig.fake
        .finish_build(built(true, vec![issue(1, "Undefined")]));
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
        .finish_build(built(true, vec![issue(2, "Undefined")]));
    let issues = rig.of_type("issues").await;
    assert_eq!(issues[0]["lines"][0]["line"], 2);
}

#[tokio::test(start_paused = true)]
async fn an_edit_heard_of_after_its_build_began_is_in_it() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    // Typed after Compile was asked for, before the session took the request.
    let args = json!({ "session": rig.session, "auto": false });
    let compile = rig.sessions.send("session_compile", &args);
    doc.edit(5, 0, "!");
    compile.await.unwrap();
    assert_eq!(rig.disk("main.tex"), "Hello!");
    rig.state().await;
    rig.fake.finish_build(built(true, vec![issue(1, "a")]));
    wait(1).await;
    let events = rig.events().await;
    let finished = events.iter().find(|e| e["type"] == "build_finished");
    assert_eq!(finished.unwrap()["outdated"], false);
    let issues = events.iter().rfind(|e| e["type"] == "issues");
    assert_eq!(issues.unwrap()["lines"][0]["line"], 1);
}

#[tokio::test(start_paused = true)]
async fn an_automatic_build_announces_only_when_its_errors_change_and_a_stopped_one_never() {
    let mut rig = Rig::new(false).await;
    rig.ok("compile", json!({ "auto": true })).await;
    rig.fake.finish_build(built(true, vec![issue(1, "a")]));
    rig.ok("compile", json!({ "auto": true })).await;
    rig.fake.finish_build(built(true, vec![issue(2, "b")]));
    // Asked for, but stopped: there's nothing to say of it.
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
    assert_eq!(reloads[0]["reason"], "disk");
    doc.reload("From elsewhere");
    let state = rig.state().await;
    assert_eq!(state["documents"][0]["dirty"], false);
    assert_eq!(state["build"]["outdated"], true);
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
    assert!(!events.iter().any(mistaken), "{events:?}");
}

/// main.tex, open with unsaved edits, as another app writes over it.
async fn in_conflict(rig: &Rig) -> Document {
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
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
    let doc = in_conflict(&rig).await;
    rig.resolve("cancel").await;
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

/// Files deleted elsewhere: one without edits closes; one with unsaved edits is asked about,
/// and nothing puts it back until Save does.
#[tokio::test(start_paused = true)]
async fn a_deleted_file_closes_and_one_with_unsaved_edits_is_asked_about_not_put_back() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    rig.open("ch.tex").await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
    for path in ["ch.tex", "main.tex"] {
        fs::remove_file(rig.root.join(path)).unwrap();
        rig.changed(path, true);
    }
    wait(300).await;
    let events = rig.events().await;
    let of = |kind: &'static str| events.iter().filter(move |e| e["type"] == kind);
    let closed: Vec<&Value> = of("document_closed").collect();
    assert_eq!(
        (closed[0]["path"].as_str(), closed.len()),
        (Some("ch.tex"), 1)
    );
    assert_eq!(closed[0]["reason"], "gone");
    assert!(rig.sessions.document(rig.session, "ch.tex").is_none());
    // The listing changed too.
    assert_eq!(of("tree").count(), 1);
    assert_eq!(of("conflict").next().unwrap()["kind"], "gone");
    wait(800).await;
    assert!(!rig.root.join("main.tex").exists());
    rig.resolve("save").await;
    assert_eq!(rig.disk("main.tex"), "Hello mine");
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

#[test]
fn a_file_ends_its_lines_as_its_first_line_break_does() {
    assert_eq!(Newline::of("a\r\nb\nc"), Newline::CrLf);
    assert_eq!(Newline::of("a\rb"), Newline::Cr);
    assert_eq!(Newline::of("a\nb\r\n"), Newline::Lf);
    assert_eq!(Newline::of("a"), Newline::Lf);
    assert_eq!(Newline::CrLf.written("a\nb\r\nc\rd"), "a\r\nb\r\nc\r\nd");
    assert_eq!(Newline::Cr.written("a\nb"), "a\rb");
    assert_eq!(Newline::Lf.written("a\r\nb"), "a\nb");
    assert!(matches!(
        Newline::Lf.written("a\nb"),
        std::borrow::Cow::Borrowed(_)
    ));
}

#[tokio::test(start_paused = true)]
async fn a_document_holds_line_feeds_and_saves_the_files_own_line_ends() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("main.tex"), "a\r\nb\r\n").unwrap();
    let doc = rig.open("main.tex").await;
    assert_eq!(doc.snapshot().0, "a\nb\n");
    // A paste with its own line end.
    doc.edit(4, 0, "c\r\nd");
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "a\r\nb\r\nc\r\nd");
    // Another app changing only the line ends changes no text, and the next save keeps its.
    rig.write_elsewhere("main.tex", "a\nb\nc\nd");
    wait(300).await;
    assert!(rig.of_type("document_reload").await.is_empty());
    doc.edit(8, 0, "!");
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "a\nb\nc\nd!");
}

#[tokio::test(start_paused = true)]
async fn a_file_that_isnt_utf8_neither_opens_nor_is_written_over() {
    let mut rig = Rig::new(false).await;
    let latin = b"caf\xe9";
    fs::write(rig.root.join("latin.tex"), latin).unwrap();
    let refused = rig
        .call("open_document", json!({ "path": "latin.tex" }))
        .await;
    assert_eq!(refused.unwrap_err().status, 400);
    // Open, it closes once another app makes it so.
    rig.open("main.tex").await;
    fs::write(rig.root.join("main.tex"), latin).unwrap();
    rig.changed("main.tex", false);
    wait(300).await;
    let closed = rig.of_type("document_closed").await;
    assert_eq!(closed[0]["reason"], "gone");
    // With unsaved edits it is asked about, and Revert closes it.
    fs::write(rig.root.join("main.tex"), "Hello").unwrap();
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
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
    if cfg!(any(target_os = "macos", windows)) {
        // Spelt as a volume that ignores case finds it.
        let other_case = rig.call("prepare_delete", json!({ "path": "MAIN.tex" }));
        assert_eq!(other_case.await.unwrap_err().status, 409);
    }
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

/// `command`'s answer, with `typed` put at the start of `doc` while the save before
/// it waits for the project's lock, as a long write would, with the text it took.
async fn typed_during_a_save(rig: &Rig, doc: &Document, typed: &str, command: &str) -> Value {
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
    let answer = rig.sessions.send(&format!("session_{command}"), &args);
    std::thread::sleep(Duration::from_millis(100));
    doc.edit(0, 0, typed);
    release.send(()).unwrap();
    holder.join().unwrap().unwrap();
    answer.await.unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn text_typed_during_a_save_is_saved_before_a_build_or_a_trash_goes_on() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("old.tex"), "old").unwrap();
    let doc = rig.open("old.tex").await;
    doc.edit(0, 0, "a");
    typed_during_a_save(&rig, &doc, "b", "compile").await;
    assert_eq!(rig.fake.called("compile"), 1);
    assert_eq!(rig.disk("old.tex"), "baold");
    rig.fake.finish_build(built(true, Vec::new()));
    doc.edit(0, 0, "c");
    let ready = typed_during_a_save(&rig, &doc, "d", "prepare_delete").await;
    assert_eq!(ready["ready"], true);
    assert_eq!(rig.disk("old.tex"), "dcbaold");
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
    rig.fake.refuse_edit(CoreError::unfit("unfit"));
    doc.edit(6, 0, "?");
    rig.state().await;
    let updates = rig.fake.updates.lock().unwrap().clone();
    assert_eq!(updates, [("main.tex".to_string(), "Hello!?".to_string())]);
    // In step again: the next key is an edit.
    doc.edit(7, 0, ".");
    rig.state().await;
    assert_eq!(rig.fake.edits.lock().unwrap().len(), 2);
}

/// The phases the `live` events among `events` say, in order.
fn phases(events: &[Value]) -> Vec<&str> {
    let lives = events.iter().filter(|e| e["type"] == "live");
    lives.map(|e| e["phase"].as_str().unwrap()).collect()
}

#[tokio::test(start_paused = true)]
async fn a_file_changed_on_disk_goes_to_texpresso_and_a_rescan_follows() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "x").unwrap();
    rig.changed("ch.tex", true);
    wait(300).await;
    live(&rig).await;
    rig.write_elsewhere("ch.tex", "chapter");
    wait(1000).await;
    rig.state().await;
    let updates = rig.fake.updates.lock().unwrap().clone();
    assert_eq!(updates, [("ch.tex".to_string(), "chapter".to_string())]);
    assert!(rig.fake.called("live_rescan") > 0);
}

#[tokio::test(start_paused = true)]
async fn a_stopped_run_is_halted_only_once_it_has_lasted_a_second() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    let stopped = |run: &str| LiveEvent::Done(run.into());
    rig.fake.tell(stopped("stopped"));
    wait(500).await;
    rig.fake.tell(stopped("complete"));
    wait(1000).await;
    assert_eq!(rig.state().await["live"]["halted"], false);
    rig.fake.tell(stopped("stopped"));
    wait(1100).await;
    let lives = rig.of_type("live").await;
    assert_eq!(lives.last().unwrap()["halted"], true);
}

#[tokio::test(start_paused = true)]
async fn documents_and_pages_go_to_the_host_as_they_come_and_none_of_a_start_before() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    let earlier = rig.fake.sink.lock().unwrap().take();
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
        run: Some("partial".into()),
        changed: Some(vec![[1, 1]]),
    });
    rig.fake.tell(page("/tmp/page.pdf"));
    let events = rig.events().await;
    let shown: Vec<&Value> = events.iter().filter(|e| e["type"] != "live").collect();
    let session = rig.session;
    assert_eq!(
        shown,
        [
            &json!({ "type": "live_document", "session": session, "path": "/tmp/live.pdf",
                "version": 1, "serial": 1, "pages": 4, "changed": [[1, 1]], "complete": false }),
            &json!({ "type": "live_page", "session": session, "page": 1, "path": "/tmp/page.pdf",
                "serial": 2 }),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn a_preview_that_ends_after_ten_seconds_restarts_and_a_new_one_reports() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    wait(11_000).await;
    rig.events().await;
    rig.fake.tell(exited());
    wait(1).await;
    let starts = rig.fake.starts.lock().unwrap().clone();
    assert_eq!(starts.len(), 2);
    assert!(starts[1].1, "a restart of its own");
    let events = rig.events().await;
    assert_eq!(phases(&events), ["starting", "running"]);
    assert!(events.iter().any(|e| e["type"] == "live_restarted"));
    // At once after its start, the end is reported.
    rig.fake.tell(exited());
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
    rig.fake.refuse_edit(CoreError::conflict("Another window"));
    doc.edit(0, 0, "x");
    let state = rig.state().await;
    assert_eq!(state["live"]["phase"], "stopped");
    assert_eq!(state["live"]["failure"], "Another window");
    // The preview is another's: its log isn't this session's.
    rig.ok("live_log", json!({ "shown": true })).await;
    assert_eq!(rig.state().await["live"]["log"], "Another window");
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
    // What went wrong comes first.
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
/// `starting` meanwhile, as a host told it stopped would show the build's PDF; a Start then
/// leaves the restart to finish, and a Stop then a Start start once.
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
    assert_eq!(rig.fake.starts.lock().unwrap().len(), 1);
    wait(100).await;
    assert_eq!(phases(&rig.events().await), ["starting", "running"]);
    // The user's Start after their Stop is the one start: the restart due would stop it.
    rig.ok("rename", json!({ "from": "one.tex", "to": "ch.tex" }))
        .await;
    rig.ok("live_stop", json!({})).await;
    live(&rig).await;
    wait(200).await;
    let starts = rig.fake.starts.lock().unwrap().clone();
    let restarts: Vec<bool> = starts.into_iter().map(|(_, restart)| restart).collect();
    assert_eq!(restarts, [false, true, false]);
}

/// While the host shows the log it follows TeX's, at most every 200 ms.
#[tokio::test(start_paused = true)]
async fn the_log_follows_tex_at_most_five_times_a_second() {
    let mut rig = Rig::new(false).await;
    live(&rig).await;
    rig.ok("live_log", json!({ "shown": true })).await;
    rig.events().await;
    for line in 0..20 {
        *rig.fake.log.lock().unwrap() = format!("line {line}");
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
    for offset in 0..5 {
        let caret = json!({ "path": "main.tex", "offset": offset });
        rig.ok("live_caret", caret).await;
        wait(50).await;
    }
    assert_eq!(rig.fake.called("live_caret"), 0);
    wait(200).await;
    rig.state().await;
    assert_eq!(rig.fake.called("live_caret"), 1);
}

#[tokio::test(start_paused = true)]
async fn texpressos_own_window_is_kept_through_the_sessions_restarts() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    let started = rig.ok("live_start", json!({ "window": true })).await;
    assert_eq!(started["phase"], "running");
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
    let rig = Rig::watching(false, true).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, "!");
    let saved = until_event(&rig.seen, |e| e["type"] == "saved");
    assert!(saved.is_some(), "autosaved");
    // Long enough for the save's own changes to have come and gone.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let seen = rig.seen.lock().unwrap().clone();
    assert!(!seen.iter().any(mistaken), "{seen:?}");
    fs::write(rig.root.join("main.tex"), "theirs").unwrap();
    let reload = until_event(&rig.seen, |e| e["type"] == "document_reload");
    assert_eq!(reload.expect("reloaded")["text"], "theirs");
    fs::write(rig.root.join("new.tex"), "").unwrap();
    assert!(until_event(&rig.seen, |e| e["type"] == "tree").is_some());
    rig.sessions.close_all().await;
}

#[tokio::test]
async fn a_host_numbers_its_sessions_and_a_number_open_already_is_refused() {
    let mut rig = Rig::new(true).await;
    // The first build's event names the number the host gave: it listened for it before
    // the open answered.
    let events = rig.events().await;
    let build = events.iter().find(|e| e["type"] == "build");
    assert_eq!(build.expect("the build is told")["session"], rig.session);
    let again = json!({ "id": "P", "session": rig.session });
    let taken = rig.sessions.call("session_open", &again).await.unwrap_err();
    assert_eq!(taken.status, 409);
    // The session open already goes on as before.
    assert!(rig.ok("state", json!({})).await["build"]["compiling"] == true);
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
    // Found, as Settings' look for it finds it: the build waiting runs.
    service.tex_found.send_replace(true);
    wait(1).await;
    rig.state().await;
    assert_eq!(rig.fake.called("compile"), 2);
}

// MARK: - The edges

/// Another app's write that the watcher hasn't told of yet (its changes settle for
/// 250 ms) is asked about, not written over by the autosave.
#[tokio::test(start_paused = true)]
async fn a_write_elsewhere_just_before_the_autosave_is_asked_about_not_written_over() {
    let mut rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
    wait(550).await;
    rig.write_elsewhere("main.tex", "theirs");
    wait(200).await;
    assert_eq!(rig.disk("main.tex"), "theirs");
    let conflicts = rig.of_type("conflict").await;
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0]["kind"], "changed");
    // The watcher's news, when it comes, asks nothing more.
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
        rig.sessions.send("session_clean", &args)
    };
    let (first, second) = (clean(), clean());
    first.await.unwrap();
    second.await.unwrap();
    assert_eq!(rig.fake.called("clean"), 1);
}

/// Waits for the session's citations to have `key`, as a scan beside it finds them.
async fn until_cited(doc: &Document, key: &str) -> bool {
    for _ in 0..500 {
        if doc.symbols().citations.iter().any(|cited| cited == key) {
            return true;
        }
        wait(10).await;
        std::thread::sleep(Duration::from_millis(1));
    }
    false
}

#[tokio::test(start_paused = true)]
async fn citations_another_app_writes_reach_completion() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    fs::write(rig.root.join("refs.bib"), "@book{first,").unwrap();
    rig.changed("refs.bib", true);
    assert!(until_cited(&doc, "first").await, "a new file's");
    rig.write_elsewhere("refs.bib", "@book{second,");
    assert!(until_cited(&doc, "second").await, "a listed file's");
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
    b.edit(0, 0, "x");
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

/// A bug that panics ends the session, but loudly: the edits it held are written, each
/// document says nothing more is saved, and commands waiting are told the session stopped.
#[tokio::test(start_paused = true)]
async fn a_panic_ends_the_session_with_its_edits_written_and_the_host_told() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, " mine");
    let args = json!({ "session": rig.session });
    let panicked = rig.sessions.send("session_panic", &args);
    let behind = rig.sessions.send("session_state", &args);
    assert_eq!(panicked.await.unwrap_err().status, 500);
    assert_eq!(behind.await.unwrap_err().status, 500);
    assert_eq!(rig.disk("main.tex"), "Hello mine");
    let told = until_event(&rig.seen, |e| {
        e["type"] == "document" && e["error"].as_str().is_some_and(|e| e.contains("saved"))
    });
    assert!(told.is_some());
    assert_eq!(rig.call("state", json!({})).await.unwrap_err().status, 404);
}

#[tokio::test]
async fn a_sessions_commands_are_taken_in_the_order_sent_however_they_are_awaited() {
    let rig = Rig::new(false).await;
    let send = |auto: bool| {
        let args = json!({ "session": rig.session, "autoCompile": auto });
        rig.sessions.send("session_set_options", &args)
    };
    let (first, second) = (send(false), send(true));
    let state = rig
        .sessions
        .send("session_state", &json!({ "session": rig.session }));
    assert_eq!(state.await.unwrap()["autoCompile"], true);
    second.await.unwrap();
    first.await.unwrap();
}
