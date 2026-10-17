//! The session's rules on tokio's paused clock, with a fake latexmk and
//! TeXpresso (`Fake`) and the folder's changes sent in by hand.

use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::actor::Actor;
use super::engine::{Call, Fut};
use super::watch::Change;
use super::{Document, Engine, Msg, Sessions};
use crate::compile::CompileResult;
use crate::logparse::LogItem;
use crate::service::Service;
use crate::texpresso::{Document as LiveDocument, Events, Status};
use crate::{CoreError, lock};

// MARK: - A fake engine

type News = Result<Events, CoreError>;

/// Logs each call as a line (`start main.tex replacing pane`, `update main.tex Hello`, …).
struct Fake {
    calls: Mutex<Vec<String>>,
    builds: Mutex<VecDeque<oneshot::Sender<Result<CompileResult, CoreError>>>>,
    /// What the next edits and whole texts answer; Ok once none is left.
    refusals: Mutex<VecDeque<CoreError>>,
    news: mpsc::UnboundedSender<News>,
    inbox: tokio::sync::Mutex<mpsc::UnboundedReceiver<News>>,
}

impl Fake {
    fn new() -> Self {
        let (news, inbox) = mpsc::unbounded_channel();
        let (calls, builds, refusals) = Default::default();
        let inbox = tokio::sync::Mutex::new(inbox);
        Self {
            calls,
            builds,
            refusals,
            news,
            inbox,
        }
    }

    fn log(&self, call: String) {
        lock(&self.calls).push(call);
    }

    /// The calls of `what` (every call for ""), with their arguments.
    fn calls(&self, what: &str) -> Vec<String> {
        let of = |call: &&String| what.is_empty() || call.split(' ').next() == Some(what);
        lock(&self.calls).iter().filter(of).cloned().collect()
    }

    fn called(&self, what: &str) -> usize {
        self.calls(what).len()
    }

    fn refuse(&self, error: CoreError) {
        lock(&self.refusals).push_back(error);
    }

    fn finish_build(&self, result: CompileResult) {
        let build = lock(&self.builds).pop_front().expect("a build runs");
        let _ = build.send(Ok(result));
    }

    fn send_news(&self, events: Events) {
        self.news.send(Ok(events)).unwrap();
    }
}

fn status(running: bool) -> Status {
    Status {
        running,
        revision: 1,
        ..Status::default()
    }
}

impl Engine for Fake {
    fn compile(self: Arc<Self>, _: PathBuf) -> Fut<Result<CompileResult, CoreError>> {
        self.log("compile".into());
        let (tx, rx) = oneshot::channel();
        lock(&self.builds).push_back(tx);
        Box::pin(async {
            rx.await
                .unwrap_or_else(|_| Err(CoreError::internal("dropped")))
        })
    }

    fn stop_compile(&self, _: &Path) {
        self.log("stop_compile".into());
        if let Some(build) = lock(&self.builds).pop_front() {
            let stopped = CompileResult {
                stopped: true,
                ..built(false, Vec::new())
            };
            let _ = build.send(Ok(stopped));
        }
    }

    fn clean(self: Arc<Self>, _: PathBuf) -> Fut<Result<(), CoreError>> {
        self.log("clean".into());
        Box::pin(async { Ok(()) })
    }

    fn live(&self, _: u64, call: Call) -> Result<Status, CoreError> {
        if matches!(call, Call::Edit(..) | Call::Update(..))
            && let Some(refused) = lock(&self.refusals).pop_front()
        {
            return Err(refused);
        }
        self.log(match &call {
            Call::Start {
                files,
                replacing,
                pane,
                ..
            } => {
                let paths: Vec<&str> = files.iter().map(|f| f.path.as_str()).collect();
                let how = [(*replacing, " replacing"), (pane.is_some(), " pane")];
                let how: String = how.iter().filter(|(on, _)| *on).map(|(_, w)| *w).collect();
                format!("start {}{how}", paths.join(","))
            }
            Call::Update(path, text) => format!("update {path} {text}"),
            Call::Edit(path, at, cut, text) => format!("edit {path} {at} {cut} {text}"),
            Call::View(first, last) => format!("view {first} {last}"),
            Call::Caret(path, offset) => format!("caret {path} {offset}"),
            call => format!("{call:?}").to_lowercase(),
        });
        // TeXpresso's log and output, as the Live Preview Log shows them.
        let (log, output) = ("TeX's log".into(), "TeX's output".into());
        Ok(match call {
            Call::Stop => status(false),
            Call::Status => Status {
                log,
                output,
                ..status(true)
            },
            _ => status(true),
        })
    }

    fn live_wait(self: Arc<Self>, _: u64, _: u64) -> Fut<News> {
        Box::pin(async move {
            self.inbox
                .lock()
                .await
                .recv()
                .await
                .expect("the fake sends")
        })
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
        kind: "error",
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
        revision: 1,
        ..Events::default()
    }
}

fn exited() -> Events {
    Events {
        error: Some("TeXpresso exited".into()),
        ..news(false)
    }
}

// MARK: - A session to drive

const SESSION: u64 = 1;

struct Rig {
    _data: tempfile::TempDir,
    root: PathBuf,
    sessions: Sessions,
    fake: Arc<Fake>,
    seen: Arc<Mutex<Vec<Value>>>,
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
        service.tex_found.store(true, Ordering::Relaxed);
        let fake = Arc::new(Fake::new());
        let sessions = Sessions::with_engine(service, Arc::clone(&fake) as Arc<dyn Engine>, watch);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        sessions.set_listener(Some(Box::new(move |event| lock(&sink).push(event.clone()))));
        let args = json!({ "id": "P", "session": SESSION, "autoCompile": auto_compile });
        let opened = sessions.call("session_open", &args).await.unwrap();
        assert_eq!(opened["session"], SESSION);
        Self {
            _data: data,
            root,
            sessions,
            fake,
            seen,
            marks: 0,
        }
    }

    async fn call(&self, name: &str, mut args: Value) -> Result<Value, CoreError> {
        args["session"] = SESSION.into();
        self.sessions.call(&format!("session_{name}"), &args).await
    }

    async fn ok(&self, name: &str, args: Value) -> Value {
        self.call(name, args).await.unwrap()
    }

    async fn open(&self, path: &str) -> Document {
        self.ok("open_document", json!({ "path": path })).await;
        self.sessions.document(SESSION, path).unwrap()
    }

    fn inject(&self, message: Msg) {
        let _ = lock(&self.sessions.open)[&SESSION].tx.send(message);
    }

    /// What `look` reads of the session once every message sent before it has been handled.
    async fn probe<T: Send + 'static>(
        &self,
        look: impl FnOnce(&mut Actor) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = oneshot::channel();
        self.inject(Msg::Probe(Box::new(move |actor| {
            drop(tx.send(look(actor)));
        })));
        rx.await.unwrap()
    }

    async fn settle(&self) {
        self.probe(|_| ()).await;
    }

    /// Waits for the scan of labels and citations under way, if any.
    async fn scanned(&self) {
        while self.probe(|actor| actor.scanning.is_some()).await {
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    async fn dirty(&self) -> bool {
        self.probe(|actor| actor.docs[0].dirty()).await
    }

    async fn live_state(&self) -> Value {
        self.probe(|actor| actor.live_state()).await
    }

    /// The events since the last look.
    async fn events(&mut self) -> Vec<Value> {
        self.settle().await;
        self.marks += 1;
        let mark = json!({ "type": "mark", "n": self.marks });
        self.sessions.hub.emitter().send(mark.clone());
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

    /// Another app wrote the file, and the system said so.
    fn write_elsewhere(&self, path: &str, text: &str) {
        fs::write(self.root.join(path), text).unwrap();
        self.changed(path, false);
    }

    fn changed(&self, path: &str, structural: bool) {
        let path = self.root.join(path);
        self.inject(Msg::Fs(vec![Change { path, structural }]));
    }

    async fn resolve(&self, answer: &str) {
        self.ok("resolve", json!({ "path": "main.tex", "answer": answer }))
            .await;
    }

    async fn heading(&self, path: &str, line: usize) -> Value {
        self.ok("outline_current", json!({ "path": path, "line": line }))
            .await
    }

    async fn live(&self) {
        assert_eq!(self.ok("live_start", json!({})).await["phase"], "running");
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
    assert!(rig.dirty().await);
    wait(150).await;
    assert_eq!(rig.disk("main.tex"), "Hello world!");
    let events = rig.events().await;
    assert!(events.contains(&json!({ "type": "saved", "session": SESSION, "path": "main.tex" })));
    assert!(!events.iter().any(|e| e["type"] == "document"));
    assert!(!rig.dirty().await);
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
    rig.settle().await;
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

#[tokio::test(start_paused = true)]
async fn labels_are_scanned_150_ms_after_a_save_and_completed_from() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    // The scan as the session opens, which found none.
    rig.scanned().await;
    doc.edit(5, 0, "\\label{fresh}");
    rig.ok("save", json!({})).await;
    wait(140).await;
    assert!(!rig.probe(|a| a.scanning.is_some()).await);
    wait(20).await;
    rig.scanned().await;
    assert_eq!(doc.symbols().labels, ["fresh"]);
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
    assert_eq!(rig.probe(|a| a.build.queued).await, Some(false));
    rig.fake.finish_build(built(true, Vec::new()));
    rig.settle().await;
    assert_eq!(rig.fake.called("compile"), 2);
    let finished = rig.of_type("build_finished").await;
    assert_eq!(finished.len(), 1);
    assert_eq!(finished[0]["auto"], false);
    // Stop drops the queued one too.
    rig.ok("compile", json!({})).await;
    rig.ok("stop_compile", json!({})).await;
    rig.settle().await;
    assert_eq!(rig.fake.called("stop_compile"), 1);
    let build = rig.probe(|a| (a.build.compiling, a.build.queued)).await;
    assert_eq!(build, (false, None));
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
    rig.settle().await;
    rig.fake.finish_build(built(true, Vec::new()));
    assert_eq!(rig.of_type("build_finished").await[0]["outdated"], true);
    assert!(rig.probe(|a| a.build.outdated).await);
    rig.ok("compile", json!({})).await;
    rig.fake.finish_build(built(true, Vec::new()));
    assert!(!rig.probe(|a| a.build.outdated).await);
    // With a PDF shown, an edit puts it out of date.
    doc.edit(0, 0, "x");
    assert_eq!(rig.of_type("build").await.last().unwrap()["outdated"], true);
}

#[tokio::test(start_paused = true)]
async fn a_clean_stops_the_build_waits_for_it_and_removes_the_pdf() {
    let mut rig = Rig::new(false).await;
    rig.ok("compile", json!({})).await;
    rig.ok("clean", json!({})).await;
    assert_eq!(rig.fake.calls(""), ["compile", "stop_compile", "clean"]);
    let events = rig.events().await;
    let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
    assert_eq!(kinds.iter().filter(|k| **k == "build_cleaned").count(), 1);
    assert_eq!(events.last().unwrap()["type"], "build_cleaned");
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
    let line = &issues[0]["lines"][0];
    assert_eq!(
        (&line["line"], &line["message"]),
        (&json!(3), &json!("Undefined"))
    );
    assert_eq!(line["others"], json!(["Again"]));
    // Round from the last to the first; back from the first to the last.
    assert_eq!(rig.ok("issue", json!({ "next": true })).await["index"], 0);
    rig.ok("choose_issue", json!({ "index": 2 })).await;
    assert_eq!(rig.ok("issue", json!({ "next": true })).await["index"], 0);
    assert_eq!(rig.ok("issue", json!({ "next": false })).await["index"], 2);
    doc.edit(0, 0, "x");
    let cleared = json!({ "type": "issues", "session": SESSION, "path": "main.tex", "lines": [] });
    assert_eq!(rig.of_type("issues").await, [cleared]);
}

/// An undefined command's issue says where its line has the command, and names it in fewer words.
#[tokio::test(start_paused = true)]
async fn an_undefined_commands_issue_says_where_its_line_has_it() {
    let mut rig = Rig::new(false).await;
    fs::write(
        rig.root.join("main.tex"),
        "Hello\n\\foo and \\foobar % \\foo\n",
    )
    .unwrap();
    rig.open("main.tex").await;
    rig.ok("compile", json!({})).await;
    let mut undefined = issue(2, "Undefined control sequence: \\foo");
    undefined.command = Some("\\foo".into());
    rig.fake
        .finish_build(built(true, vec![undefined, issue(1, "Other")]));
    let issues = rig.of_type("issues").await;
    let lines = &issues[0]["lines"];
    assert_eq!(
        (&lines[0]["compact"], &lines[0]["tokens"]),
        (&Value::Null, &json!([]))
    );
    assert_eq!(lines[1]["compact"], "Undefined: \\foo");
    assert_eq!(lines[1]["tokens"], json!([{ "start": 0, "length": 4 }]));
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
    assert_eq!(rig.of_type("issues").await[0]["lines"][0]["line"], 2);
}

#[tokio::test(start_paused = true)]
async fn a_failed_build_announces_and_an_automatic_one_only_when_the_errors_change() {
    let mut rig = Rig::new(false).await;
    for line in [1, 2] {
        rig.ok("compile", json!({ "auto": true })).await;
        rig.fake.finish_build(built(true, vec![issue(line, "a")]));
    }
    let finished = rig.of_type("build_finished").await;
    let announced: Vec<&Value> = finished.iter().map(|f| &f["announce"]).collect();
    assert_eq!(announced, [true, false]);
}

#[tokio::test]
async fn automatic_builds_wait_for_tex_to_be_found() {
    let rig = Rig::new(false).await;
    rig.sessions
        .service
        .tex_found
        .store(false, Ordering::Relaxed);
    rig.ok("set_options", json!({ "autoCompile": true })).await;
    rig.ok("compile", json!({ "auto": true })).await;
    assert_eq!(rig.fake.called("compile"), 0, "no TeX: no automatic build");
    rig.ok("compile", json!({})).await;
    assert_eq!(rig.fake.called("compile"), 1, "one asked for still runs");
}

// MARK: - Analysis

/// The analysis of the file shown, whose outline the heading a line is under is found in.
#[tokio::test(start_paused = true)]
async fn the_analysis_is_kept_for_the_heading_a_line_is_under() {
    let rig = Rig::new(false).await;
    let text = "\\documentclass{book}\n\\chapter{A}\n\\section{B}\n\\section{}\n";
    fs::write(rig.root.join("main.tex"), text).unwrap();
    let analyze = || rig.ok("analyze", json!({ "path": "main.tex" }));
    let analysis = analyze().await;
    assert_eq!(analysis["words"], 3, "book, A and B");
    assert_eq!(analysis["tree"][0]["children"][0]["command"], "section");
    let untitled = &analysis["tree"][0]["children"][1];
    assert_eq!(untitled["title"], "Untitled Section");
    assert_eq!(untitled["foldKey"], "main.tex\t2:(untitled)#1");
    let levels = |analysis: &Value| -> Vec<String> {
        let levels = analysis["headingStyles"].as_array().unwrap().iter();
        levels
            .map(|l| l["command"].as_str().unwrap().to_owned())
            .collect()
    };
    // The class's levels: a book's, with Normal Text first.
    assert_eq!(levels(&analysis)[..3], ["", "part", "chapter"]);
    assert_eq!(rig.heading("main.tex", 1).await, Value::Null);
    assert_eq!(rig.heading("main.tex", 3).await, json!(1));
    assert_eq!(rig.heading("main.tex", 9).await, json!(2));
    // The class as the editor has it, before it is saved.
    let doc = rig.open("main.tex").await;
    doc.edit(15, 4, "article");
    assert!(!levels(&analyze().await).contains(&"chapter".into()));
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
    let shared = Arc::clone(&lock(&rig.sessions.open)[&SESSION].shared);
    let held = lock(&shared.outline);
    let analyze = |path| {
        let args = json!({ "session": SESSION, "path": path });
        rig.sessions.send("session_analyze", &args)
    };
    let (earlier, later) = (analyze("main.tex"), analyze("ch.tex"));
    assert!(!rig.probe(|a| a.build.compiling).await);
    drop(held);
    later.await.unwrap();
    earlier.await.unwrap();
    // ch.tex alone, as the main file doesn't reach it.
    assert_eq!(rig.heading("ch.tex", 5).await, json!(0));
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
    assert_eq!(
        (&reloads[0]["text"], &reloads[0]["reason"]),
        (&json!("From elsewhere"), &json!("disk"))
    );
    doc.reload("From elsewhere");
    assert!(!rig.dirty().await);
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
    let asked =
        json!({ "type": "conflict", "session": SESSION, "path": "main.tex", "kind": "changed" });
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
    assert_eq!(
        (&reloads[0]["reason"], &reloads[0]["text"]),
        (&json!("revert"), &json!("theirs"))
    );
    doc.reload("theirs");
    let doc = rig.probe(|a| (a.docs[0].dirty(), a.docs[0].asking)).await;
    assert_eq!(doc, (false, None));
    assert_eq!(rig.disk("main.tex"), "theirs");
}

#[tokio::test(start_paused = true)]
async fn cancel_leaves_the_edits_unsaved_until_a_save_is_asked_for() {
    let mut rig = Rig::new(false).await;
    let doc = in_conflict(&rig).await;
    rig.resolve("cancel").await;
    assert_eq!(rig.of_type("document").await.last().unwrap()["held"], true);
    doc.edit(0, 0, "x");
    wait(800).await;
    assert_eq!(rig.disk("main.tex"), "theirs");
    assert!(rig.of_type("conflict").await.is_empty());
    // A save someone asks for asks again.
    assert_eq!(rig.ok("save", json!({})).await["saved"], false);
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
    assert_eq!(rig.of_type("conflict").await[0]["kind"], "gone");
    wait(800).await;
    assert!(!rig.root.join("main.tex").exists());
    rig.resolve("save").await;
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
    let closed = events.iter().find(|e| e["type"] == "document_closed");
    assert_eq!(closed.unwrap()["reason"], "gone");
    // The listing changed too.
    assert!(events.iter().any(|e| e["type"] == "tree"));
    assert!(rig.sessions.document(SESSION, "main.tex").is_none());
}

#[tokio::test(start_paused = true)]
async fn a_new_file_changes_the_tree_and_a_changed_unopened_file_is_told_of() {
    let mut rig = Rig::new(false).await;
    fs::write(rig.root.join("refs.bib"), "@book{a,").unwrap();
    rig.changed("refs.bib", true);
    wait(300).await;
    let trees = rig.of_type("tree").await;
    assert!(
        trees[0]["tree"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["path"] == "refs.bib")
    );
    rig.write_elsewhere("refs.bib", "@book{b,");
    wait(300).await;
    assert_eq!(
        rig.of_type("files_changed").await[0]["paths"],
        json!(["refs.bib"])
    );
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
    assert_eq!(rig.of_type("document_renamed").await[0]["to"], "one.tex");
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
    assert!(rig.sessions.document(SESSION, "old.tex").is_none());
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
    let args = json!({ "session": SESSION, "path": "old.tex" });
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

#[tokio::test(start_paused = true)]
async fn keys_go_to_texpresso_as_made_and_a_refused_one_sends_the_whole_text() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.live().await;
    assert_eq!(rig.fake.calls("start"), ["start main.tex pane"]);
    doc.edit(5, 0, "!");
    rig.settle().await;
    rig.fake.refuse(CoreError::unfit("unfit"));
    doc.edit(6, 0, "?");
    rig.settle().await;
    assert_eq!(rig.fake.calls("update"), ["update main.tex Hello!?"]);
    // In step again: the next key is an edit.
    doc.edit(7, 0, ".");
    rig.settle().await;
    assert_eq!(
        rig.fake.calls("edit"),
        ["edit main.tex 5 0 !", "edit main.tex 7 0 ."]
    );
}

#[tokio::test(start_paused = true)]
async fn a_whole_text_texpresso_couldnt_be_asked_to_take_goes_again_750_ms_later() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.live().await;
    rig.fake.refuse(CoreError::unfit("unfit"));
    rig.fake.refuse(CoreError::internal("busy"));
    doc.edit(5, 0, "!");
    wait(700).await;
    assert_eq!(rig.live_state().await["failure"], "busy");
    assert!(rig.fake.calls("update").is_empty());
    wait(100).await;
    assert_eq!(rig.fake.calls("update"), ["update main.tex Hello!"]);
    assert_eq!(rig.live_state().await["failure"], Value::Null);
}

#[tokio::test(start_paused = true)]
async fn a_stopped_run_is_halted_only_once_it_has_lasted_a_second() {
    let mut rig = Rig::new(false).await;
    rig.live().await;
    let ended = |run: &str| Events {
        done: Some(run.into()),
        ..news(true)
    };
    rig.fake.send_news(ended("stopped"));
    wait(500).await;
    rig.fake.send_news(ended("complete"));
    wait(1000).await;
    assert!(!rig.probe(|a| a.live.halted).await);
    rig.fake.send_news(ended("stopped"));
    wait(1100).await;
    assert_eq!(rig.of_type("live").await.last().unwrap()["halted"], true);
}

#[tokio::test(start_paused = true)]
async fn documents_and_pages_go_to_the_host() {
    let mut rig = Rig::new(false).await;
    rig.live().await;
    let document = LiveDocument {
        path: "/tmp/live.pdf".into(),
        version: 2,
        serial: 3,
        pages: 4,
        run: Some("complete".into()),
        changed: Some(vec![[1, 1]]),
    };
    rig.fake.send_news(Events {
        pdf: Some(document),
        ..news(true)
    });
    wait(1).await;
    let shown = rig.of_type("live_document").await;
    // Version 1 never came: any page may differ.
    assert_eq!(
        (&shown[0]["changed"], &shown[0]["complete"]),
        (&Value::Null, &json!(true))
    );
}

#[tokio::test(start_paused = true)]
async fn a_preview_that_ends_after_ten_seconds_restarts_and_a_new_one_reports() {
    let mut rig = Rig::new(false).await;
    rig.live().await;
    wait(11_000).await;
    rig.fake.send_news(exited());
    wait(1).await;
    assert_eq!(
        rig.fake.calls("start"),
        ["start  pane", "start  replacing pane"]
    );
    assert_eq!(rig.of_type("live_restarted").await.len(), 1);
    // At once after its start, the end is reported.
    rig.fake.send_news(exited());
    wait(1).await;
    let state = rig.live_state().await;
    assert_eq!(
        (&state["phase"], &state["failure"]),
        (&json!("stopped"), &json!("TeXpresso exited"))
    );
    assert_eq!(rig.fake.called("start"), 2);
}

#[tokio::test(start_paused = true)]
async fn automatic_builds_wait_while_live_preview_runs() {
    let rig = Rig::new(true).await;
    wait(1).await;
    rig.fake.finish_build(built(true, Vec::new()));
    let doc = rig.open("main.tex").await;
    rig.live().await;
    doc.edit(0, 0, "x");
    wait(800).await;
    rig.settle().await;
    assert_eq!(rig.disk("main.tex"), "xHello");
    assert_eq!(rig.fake.called("compile"), 1);
    // Stopped, the build catches up.
    rig.ok("live_stop", json!({})).await;
    rig.settle().await;
    assert_eq!(rig.fake.called("compile"), 2);
}

#[tokio::test(start_paused = true)]
async fn another_windows_preview_ends_this_ones() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.live().await;
    rig.fake.refuse(CoreError::conflict("Another window"));
    doc.edit(0, 0, "x");
    let state = rig.live_state().await;
    assert_eq!(
        (&state["phase"], &state["failure"]),
        (&json!("stopped"), &json!("Another window"))
    );
    // The preview is another's: its log isn't this session's.
    rig.ok("live_log", json!({ "shown": true })).await;
    assert_eq!(rig.live_state().await["log"], "Another window");
}

#[tokio::test(start_paused = true)]
async fn the_live_event_carries_the_log_while_the_host_shows_it() {
    let mut rig = Rig::new(false).await;
    rig.live().await;
    fn logs(events: Vec<Value>) -> Vec<Value> {
        events.iter().map(|event| event["log"].clone()).collect()
    }
    let log = "TeX's log\n\nTeX's output";
    let failed = "TeXpresso exited\n\nTeX's log\n\nTeX's output";
    assert!(logs(rig.of_type("live").await).iter().all(Value::is_null));
    rig.ok("live_log", json!({ "shown": true })).await;
    assert_eq!(logs(rig.of_type("live").await), [log]);
    // What went wrong comes first.
    rig.fake.send_news(exited());
    wait(1).await;
    assert_eq!(logs(rig.of_type("live").await).last().unwrap(), failed);
    // Hidden, the log is no longer sent, but with an alert, which opens it.
    rig.ok("live_log", json!({ "shown": false })).await;
    rig.live().await;
    assert!(logs(rig.of_type("live").await).iter().all(Value::is_null));
    rig.fake.send_news(exited());
    wait(1).await;
    let lives = rig.of_type("live").await;
    let (alerts, others): (Vec<Value>, Vec<Value>) =
        lives.into_iter().partition(|e| e["alert"] == true);
    assert_eq!(logs(alerts), [failed]);
    assert!(logs(others).iter().all(Value::is_null));
}

#[tokio::test(start_paused = true)]
async fn a_rename_restarts_the_preview_180_ms_later() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    rig.live().await;
    rig.ok("rename", json!({ "from": "ch.tex", "to": "one.tex" }))
        .await;
    wait(170).await;
    assert_eq!(rig.fake.called("start"), 1);
    wait(20).await;
    rig.settle().await;
    assert_eq!(rig.fake.calls("start")[1], "start  replacing pane");
}

#[tokio::test(start_paused = true)]
async fn files_changed_on_disk_reach_the_preview_and_one_gone_restarts_it() {
    let rig = Rig::new(false).await;
    fs::write(rig.root.join("refs.bib"), "@book{a,").unwrap();
    fs::write(rig.root.join("ch.tex"), "chapter").unwrap();
    rig.changed("refs.bib", true);
    wait(300).await;
    rig.open("ch.tex").await;
    rig.live().await;
    rig.write_elsewhere("refs.bib", "@book{b,");
    wait(250 + 170).await;
    assert!(rig.fake.calls("update").is_empty());
    wait(20).await;
    assert_eq!(rig.fake.calls("update"), ["update refs.bib @book{b,"]);
    assert_eq!(rig.fake.called("rescan"), 1);
    // A file the preview has leaves the tree: a new preview drops it.
    fs::remove_file(rig.root.join("ch.tex")).unwrap();
    rig.changed("ch.tex", true);
    wait(250 + 200).await;
    rig.settle().await;
    assert_eq!(
        rig.fake.calls("start"),
        ["start ch.tex pane", "start  replacing pane"]
    );
}

#[tokio::test(start_paused = true)]
async fn the_caret_is_told_once_it_settles() {
    let rig = Rig::new(false).await;
    rig.open("main.tex").await;
    rig.live().await;
    for offset in 0..5 {
        rig.ok(
            "live_caret",
            json!({ "path": "main.tex", "offset": offset }),
        )
        .await;
        wait(50).await;
    }
    assert_eq!(rig.fake.called("caret"), 0);
    wait(200).await;
    rig.settle().await;
    assert_eq!(rig.fake.calls("caret"), ["caret main.tex 4"]);
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
    rig.settle().await;
    assert_eq!(rig.fake.called("view") + rig.fake.called("caret"), 0);
    // A restart of its own keeps to the window; the user's next Start chooses again.
    rig.ok("rename", json!({ "from": "ch.tex", "to": "one.tex" }))
        .await;
    wait(200).await;
    rig.ok("live_stop", json!({})).await;
    rig.live().await;
    let starts = [
        "start main.tex",
        "start main.tex replacing",
        "start main.tex pane",
    ];
    assert_eq!(rig.fake.calls("start"), starts);
}

#[tokio::test(start_paused = true)]
async fn closing_saves_and_stops_the_preview() {
    let rig = Rig::new(false).await;
    let doc = rig.open("main.tex").await;
    rig.live().await;
    doc.edit(0, 0, "x");
    assert_eq!(rig.ok("close", json!({})).await["saved"], true);
    assert_eq!(rig.disk("main.tex"), "xHello");
    assert_eq!(rig.fake.called("stop"), 1);
    assert_eq!(rig.call("save", json!({})).await.unwrap_err().status, 404);
}

// MARK: - The folder's watcher, for real

/// Waits, on the wall clock, for an event `found` picks out.
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
async fn the_watcher_tells_another_apps_changes_from_the_sessions_own() {
    let rig = Rig::watching(false, true).await;
    let doc = rig.open("main.tex").await;
    doc.edit(5, 0, "!");
    assert!(
        until_event(&rig.seen, |e| e["type"] == "saved").is_some(),
        "autosaved"
    );
    // Long enough for the save's own changes to have come and gone.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let seen = lock(&rig.seen).clone();
    assert!(!seen.iter().any(mistaken), "{seen:?}");
    fs::write(rig.root.join("main.tex"), "theirs").unwrap();
    let reload = until_event(&rig.seen, |e| e["type"] == "document_reload");
    assert_eq!(reload.expect("reloaded")["text"], "theirs");
    fs::write(rig.root.join("new.tex"), "").unwrap();
    assert!(until_event(&rig.seen, |e| e["type"] == "tree").is_some());
    rig.sessions.close_all().await;
}

// MARK: - Sessions

#[tokio::test]
async fn a_host_numbers_its_sessions_and_a_number_open_already_is_refused() {
    let mut rig = Rig::new(true).await;
    // The first build's event names the number the host gave: it listened for it before
    // the open answered.
    let events = rig.events().await;
    let build = events.iter().find(|e| e["type"] == "build");
    assert_eq!(build.expect("the build is told")["session"], SESSION);
    let again = json!({ "id": "P", "session": SESSION });
    let taken = rig.sessions.call("session_open", &again).await.unwrap_err();
    assert_eq!(taken.status, 409);
    // The session open already goes on as before.
    assert!(rig.probe(|a| a.build.compiling).await);
}

#[tokio::test]
async fn a_sessions_commands_are_taken_in_the_order_sent_however_they_are_awaited() {
    let rig = Rig::new(false).await;
    let send = |auto: bool| {
        let args = json!({ "session": SESSION, "autoCompile": auto });
        rig.sessions.send("session_set_options", &args)
    };
    let (first, second) = (send(false), send(true));
    assert!(rig.probe(|a| a.auto_compile).await);
    second.await.unwrap();
    first.await.unwrap();
}
