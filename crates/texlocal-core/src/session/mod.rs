mod actor;
mod build;
mod document;
mod documents;
mod edits;
mod files;
mod history;
mod live;
mod navigate;
mod scans;
mod state;
mod watch;

use std::cell::Cell;
use std::collections::HashMap;
use std::collections::hash_map::{Entry, VacantEntry};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use texlocal_latex::logparse::LogItem;
use texlocal_latex::project::{Analysis, Scan};
use texlocal_latex::syntax::TextEdit;
use tokio::sync::{mpsc, oneshot};

use crate::compile::CompileResult;
use crate::events::{Hub, Listener, Replied, Said};
use crate::protocol::Answer;
use crate::service::Service;
use crate::settings::UiState;
use crate::{CoreError, lock, messages, paths};

use actor::OpenProject;
pub(crate) use actor::Session;
pub use build::Compiler;
pub use document::Document;
pub(crate) use documents::DiskConflict;
use documents::{Docs, Shared};
pub(crate) use state::SessionSection;
#[cfg(test)]
pub(crate) use state::{Lifecycle, Stopped};
use watch::Change;

pub use crate::paths::Project;
pub use crate::texpresso::{FileBuffer, LiveEvent, LiveRun, Pane, Preview, Sink};

pub(crate) enum Msg {
    Changed {
        doc: u64,
        version: u64,
        edit: TextEdit,
    },
    Command(Session, Reply),
    BuildDone(Result<CompileResult, CoreError>),
    Cleaned(Result<(), CoreError>),
    Symbols {
        seq: u64,
        edits: u64,
        result: Result<Box<(Scan, Vec<LogItem>, Analysis)>, CoreError>,
    },
    Live(u64, LiveEvent),
    Fs(Vec<Change>),
    Snapshotted(OnActor),
}

pub(crate) type OnActor = Box<dyn FnOnce(&mut actor::Actor) + Send>;

pub(crate) struct Reply(Option<(u64, std::sync::mpsc::Sender<Said>)>);

impl Reply {
    pub fn send(mut self, answer: Result<Value, CoreError>) {
        self.answer(answer);
    }

    fn answer(&mut self, answer: Result<Value, CoreError>) {
        if let Some((id, queue)) = self.0.take() {
            let answer = answer.into();
            let _ = queue.send(Said::Reply(Replied { id, answer }));
        }
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        self.answer(Err(match std::thread::panicking() {
            true if ACTOR.get() => stopped(),
            true => failed(),
            false => gone(),
        }));
    }
}

thread_local! {
    static ACTOR: Cell<bool> = const { Cell::new(false) };
}

pub(crate) struct Pending<T> {
    reply: Reply,
    answer: Answer<T>,
}

impl<T> Pending<T> {
    pub fn send(self, result: Result<T, CoreError>) {
        self.reply.send((self.answer)(result));
    }
}

pub(crate) fn stopped() -> CoreError {
    CoreError::internal(messages::session_stopped())
}

fn failed() -> CoreError {
    CoreError::internal(messages::went_wrong())
}

fn gone() -> CoreError {
    CoreError::not_found(messages::no_such_session())
}

struct Open {
    tx: mpsc::UnboundedSender<Msg>,
    docs: Shared,
    opens: Arc<AtomicU64>,
}

pub struct Sessions {
    service: Arc<Service>,
    hub: Hub,
    compiler: Arc<dyn Compiler>,
    preview: Arc<dyn Preview>,
    watch: bool,
    open: Mutex<HashMap<u64, Open>>,
}

impl Sessions {
    pub fn new(service: Arc<Service>, listener: Listener) -> Self {
        let compiler = Arc::new(Arc::clone(&service));
        let preview = Arc::clone(&service.texpresso);
        Self::with_compiler(service, compiler, preview, true, listener)
    }

    pub fn with_compiler(
        service: Arc<Service>,
        compiler: Arc<dyn Compiler>,
        preview: Arc<dyn Preview>,
        watch: bool,
        listener: Listener,
    ) -> Self {
        let hub = Hub::new(listener);
        let _ = service.hub.set(hub.queue.clone());
        tokio::spawn(service.call("CheckTex", json!({})));
        Self {
            service,
            hub,
            compiler,
            preview,
            watch,
            open: Mutex::default(),
        }
    }

    pub fn log_panics(&self) {
        self.hub.log_panics();
    }

    pub fn document(&self, session: u64, path: &str) -> Option<Document> {
        let path = paths::rel_key(path).ok()?;
        let docs = Arc::clone(&lock(&self.open).get(&session)?.docs);
        let document = lock(&docs).get(&path).cloned()?;
        document.shown();
        Some(document)
    }

    pub fn send(&self, id: u64, command: &str, args: Value) {
        let (call, reply) = (self.service.call(command, args), self.reply(id));
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || reply.send(runtime.block_on(call)));
    }

    pub fn send_to(self: &Arc<Self>, id: u64, session: u64, command: &str, args: Value) {
        let reply = self.reply(id);
        let request = match Session::parse(command, args) {
            Ok(request) => request,
            Err(err) => return reply.send(Err(err)),
        };
        match lock(&self.open).entry(session) {
            Entry::Occupied(open) => {
                if matches!(request, Session::Open(..)) {
                    open.get().opens.fetch_add(1, Ordering::Relaxed);
                }
                drop(open.get().tx.send(Msg::Command(request, reply)));
            }
            Entry::Vacant(entry) => match request {
                Session::OpenProject(opening, answer) => {
                    self.open(entry, opening, Pending { reply, answer });
                }
                Session::CloseProject(_, answer) => reply.send(answer(Ok(true))),
                _ => reply.send(Err(gone())),
            },
        }
    }

    pub fn refuse(&self, id: u64, error: CoreError) {
        self.reply(id).send(Err(error));
    }

    fn reply(&self, id: u64) -> Reply {
        Reply(Some((id, self.hub.queue.clone())))
    }

    fn open(
        self: &Arc<Self>,
        entry: VacantEntry<'_, u64, Open>,
        opening: OpenProject,
        reply: Pending<UiState>,
    ) {
        let session = *entry.key();
        let (tx, rx) = mpsc::unbounded_channel();
        let (docs, opens) = (Docs::default(), Arc::default());
        entry.insert(Open {
            tx: tx.clone(),
            docs: docs.shared(),
            opens: Arc::clone(&opens),
        });
        let (sessions, runtime) = (Arc::clone(self), tokio::runtime::Handle::current());
        let (mut alive, runtime_gone) = oneshot::channel::<()>();
        runtime.spawn(async move { alive.closed().await });
        std::thread::Builder::new()
            .name(format!("texlocal-session-{session}"))
            .spawn(move || {
                ACTOR.set(true);
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    let _entered = runtime.enter();
                    match actor::Actor::new(&sessions, session, opening, docs, opens, tx.clone()) {
                        Ok((actor, ui)) => {
                            reply.send(Ok(ui));
                            runtime.block_on(actor.run(rx, runtime_gone));
                        }
                        Err(err) => reply.send(Err(err)),
                    }
                }));
                let mut open = lock(&sessions.open);
                if open
                    .get(&session)
                    .is_some_and(|open| open.tx.same_channel(&tx))
                {
                    open.remove(&session);
                }
            })
            .expect("the session's thread starts");
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc::{Sender, channel};
    use std::time::Duration;

    use tokio::sync::Notify;

    use super::build::Fut;
    use super::*;
    use crate::projects::History;

    struct Panics;

    impl Compiler for Panics {
        fn compile(&self, _: Project, _: bool) -> Fut<Result<CompileResult, CoreError>> {
            panic!("the test compiler panics")
        }

        fn stop_compile(&self, _: &Path) {}

        fn clean(&self, _: PathBuf) -> Fut<Result<(), CoreError>> {
            panic!("the test compiler panics")
        }
    }

    #[derive(Default)]
    struct Holds {
        builds: AtomicUsize,
        done: Arc<Notify>,
    }

    impl Compiler for Holds {
        fn compile(&self, _: Project, _: bool) -> Fut<Result<CompileResult, CoreError>> {
            self.builds.fetch_add(1, Ordering::Relaxed);
            let done = Arc::clone(&self.done);
            Box::pin(async move {
                done.notified().await;
                Ok(CompileResult::default())
            })
        }

        fn stop_compile(&self, _: &Path) {}

        fn clean(&self, _: PathBuf) -> Fut<Result<(), CoreError>> {
            Box::pin(async { Ok(()) })
        }
    }

    type Heard = std::sync::mpsc::Receiver<Value>;

    async fn panicking() -> (Arc<Sessions>, Heard, tempfile::TempDir) {
        compiling_with(Arc::new(Panics)).await
    }

    async fn compiling_with(
        compiler: Arc<dyn Compiler>,
    ) -> (Arc<Sessions>, Heard, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let service = Arc::new(Service::new(dir.path().into(), dir.path().into(), None));
        let made = json!({ "name": "P", "template": "blank" });
        service.call("CreateProject", made).await.unwrap();
        let (tx, heard) = channel();
        let tx = Mutex::new(tx);
        let listener = Box::new(move |said: String| {
            let _ = lock(&tx).send(serde_json::from_str(&said).unwrap());
        });
        let preview = Arc::clone(&service.texpresso);
        let sessions = Sessions::with_compiler(service, compiler, preview, false, listener);
        (Arc::new(sessions), heard, dir)
    }

    fn heard_within(
        heard: &Heard,
        wait: Duration,
        matching: impl Fn(&Value) -> bool,
    ) -> Option<Value> {
        let deadline = std::time::Instant::now() + wait;
        loop {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            let said = heard.recv_timeout(left).ok()?;
            if matching(&said) {
                return Some(said);
            }
        }
    }

    fn replied_within(heard: &Heard, id: u64, wait: Duration) -> Option<Result<Value, Value>> {
        let replied = |said: &Value| said["type"] == "reply" && said["value"]["id"] == id;
        let mut answer = heard_within(heard, wait, replied)?["value"]["answer"].take();
        let value = answer["value"].take();
        Some(if answer["type"] == "ok" {
            Ok(value)
        } else {
            Err(value)
        })
    }

    fn replied(heard: &Heard, id: u64) -> Result<Value, Value> {
        replied_within(heard, id, Duration::from_secs(10)).expect("a reply")
    }

    fn hold_history(sessions: &Sessions) -> Sender<()> {
        let (release, held) = channel::<()>();
        let project = sessions.service.project("P").unwrap();
        let hold = Box::new(move |_: &History| {
            let _ = held.recv();
        });
        sessions.service.history(&project).send(hold).unwrap();
        release
    }

    type Held = (Arc<Sessions>, Heard, tempfile::TempDir, Sender<()>);

    async fn replacing_while_the_history_is_held() -> Held {
        let (sessions, heard, dir) = panicking().await;
        fs::write(dir.path().join("P/ch.tex"), "cat\n").unwrap();
        let open = json!({ "id": "P", "autoCompile": false });
        sessions.send_to(0, 1, "OpenProject", open);
        replied(&heard, 0).unwrap();
        let release = hold_history(&sessions);
        let replace =
            json!({ "query": "cat", "replacement": "dog", "matchCase": false, "wholeWord": false });
        sessions.send_to(1, 1, "Replace", replace);
        (sessions, heard, dir, release)
    }

    fn chapter(dir: &tempfile::TempDir) -> String {
        fs::read_to_string(dir.path().join("P/ch.tex")).unwrap()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_panicking_compiler_fails_every_pending_command() {
        let (sessions, heard, _dir) = panicking().await;
        let open = json!({ "id": "P", "autoCompile": false });
        sessions.send_to(0, 1, "OpenProject", open);
        let pending = [
            ("Compile", json!({ "auto": false })),
            ("Save", json!({ "reporting": true })),
            (
                "Search",
                json!({ "query": "x", "matchCase": false, "wholeWord": false }),
            ),
            ("Clean", json!({})),
        ];
        for (id, (command, args)) in (1..).zip(pending) {
            sessions.send_to(id, 1, command, args);
        }
        assert!(replied(&heard, 0).unwrap().is_object());
        for id in 1..=4 {
            let refused = replied(&heard, id).unwrap_err();
            assert_eq!(refused["message"]["id"], "session_stopped", "{refused}");
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_panic_beside_a_session_fails_only_what_it_was_doing() {
        let (sessions, heard, _dir) = panicking().await;
        let open = json!({ "id": "P", "autoCompile": false });
        sessions.send_to(0, 1, "OpenProject", open);
        replied(&heard, 0).unwrap();
        let (project, reply) = (sessions.service.project("P").unwrap(), sessions.reply(1));
        let job = Box::new(move |_: &History| {
            let _reply = reply;
            panic!("a history job panics");
        });
        sessions.service.history(&project).send(job).unwrap();
        let refused = replied(&heard, 1).unwrap_err();
        assert_eq!(refused["message"]["id"], "went_wrong", "{refused}");
        sessions.send_to(2, 1, "ListVersions", json!({}));
        assert!(replied(&heard, 2).is_ok());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_panic_in_a_session_reaches_the_stream_as_a_log_before_the_replies_it_fails() {
        let (sessions, heard, _dir) = panicking().await;
        sessions.log_panics();
        let open = json!({ "id": "P", "autoCompile": false });
        sessions.send_to(0, 9, "OpenProject", open);
        replied(&heard, 0).unwrap();
        sessions.send_to(1, 9, "Compile", json!({ "auto": false }));
        let at = format!("thread 'texlocal-session-9' panicked at {}:", file!());
        let ours = |said: &Value| {
            said["value"]["text"]
                .as_str()
                .is_some_and(|t| t.starts_with(&at))
        };
        let wait = Duration::from_secs(10);
        let first = heard_within(&heard, wait, |said| ours(said) || said["type"] == "reply");
        let log = first.expect("the session panics");
        assert!(ours(&log), "a reply came before the log: {log}");
        assert_eq!(log["value"]["level"], "fault");
        let text = log["value"]["text"].as_str().unwrap();
        assert!(text.ends_with(":\nthe test compiler panics"), "{text}");
        assert_eq!(replied(&heard, 1).unwrap_err()["kind"], "internal");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_stopped_session_saves_what_it_can_and_says_so_of_each_document() {
        let (sessions, heard, dir) = panicking().await;
        let root = dir.path().join("P");
        fs::write(root.join("ch.tex"), "chapter\n").unwrap();
        let open = json!({ "id": "P", "autoCompile": false });
        sessions.send_to(0, 1, "OpenProject", open);
        replied(&heard, 0).unwrap();
        let typed = |path| {
            sessions
                .document(1, path)
                .unwrap()
                .edit(0, 0, "% typed\n", None, false)
        };
        typed("main.tex");
        fs::set_permissions(root.join("main.tex"), fs::Permissions::from_mode(0o444)).unwrap();
        sessions.send_to(1, 1, "Open", json!({ "path": "ch.tex" }));
        assert_eq!(replied(&heard, 1).unwrap(), "ch.tex");
        typed("ch.tex");
        sessions.send_to(2, 1, "Clean", json!({}));
        let marked = |said: &Value| {
            let section = &said["value"]["event"]["value"];
            let ids = section["value"].as_array().into_iter().flatten();
            let ids: Vec<_> = ids.map(|doc| &doc["error"]["id"]).collect();
            section["type"] == "documents" && ids == ["stopped_saved", "stopped_unsaved"]
        };
        let wait = Duration::from_secs(10);
        heard_within(&heard, wait, marked).expect("each document marked");
        let lifecycle = |said: &Value| said["value"]["event"]["value"]["type"] == "lifecycle";
        let stopped = heard_within(&heard, wait, lifecycle).expect("the session stops");
        let unsaved = json!({ "type": "stopped", "value": { "unsaved": ["main.tex"] } });
        assert_eq!(stopped["value"]["event"]["value"]["value"], unsaved);
        let disk = |path| fs::read_to_string(root.join(path)).unwrap();
        assert_eq!(disk("ch.tex"), "% typed\nchapter\n");
        assert!(!disk("main.tex").starts_with("% typed"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn commands_after_a_close_are_refused_every_close_waits_and_closing_none_is_done() {
        let holds = Arc::new(Holds::default());
        let (sessions, heard, _dir) = compiling_with(Arc::clone(&holds) as _).await;
        let asked = [
            ("OpenProject", json!({ "id": "P", "autoCompile": false })),
            ("Compile", json!({ "auto": false })),
            ("CloseProject", json!({})),
            ("Compile", json!({ "auto": false })),
            ("Open", json!({ "path": "main.tex" })),
            ("CloseProject", json!({})),
        ];
        for (id, (command, args)) in (0..).zip(asked) {
            sessions.send_to(id, 1, command, args);
        }
        for id in [0, 1] {
            assert!(replied(&heard, id).is_ok());
        }
        for id in [3, 4] {
            assert_eq!(replied(&heard, id).unwrap_err()["kind"], "notFound");
        }
        assert!(sessions.document(1, "main.tex").is_none());
        holds.done.notify_one();
        for id in [2, 5] {
            assert_eq!(replied(&heard, id), Ok(json!(true)));
        }
        assert_eq!(holds.builds.load(Ordering::Relaxed), 1);
        sessions.send_to(6, 2, "CloseProject", json!({}));
        assert_eq!(replied(&heard, 6), Ok(json!(true)));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_snapshot_before_an_edit_waits_on_the_history_and_not_the_session() {
        let (sessions, heard, _dir) = panicking().await;
        let open = json!({ "id": "P", "autoCompile": false });
        sessions.send_to(0, 1, "OpenProject", open);
        replied(&heard, 0).unwrap();
        sessions.send_to(1, 1, "SaveVersion", json!({ "name": "Draft" }));
        let draft = replied(&heard, 1).unwrap()["id"].take();
        let release = hold_history(&sessions);
        let replace =
            json!({ "query": "x", "replacement": "y", "matchCase": false, "wholeWord": false });
        sessions.send_to(2, 1, "Replace", replace);
        let restore = json!({ "id": draft, "paths": ["main.tex"] });
        sessions.send_to(3, 1, "RestoreVersion", restore);
        sessions.send_to(4, 1, "Save", json!({ "reporting": true }));
        assert_eq!(replied(&heard, 4), Ok(json!(true)));
        let early = heard_within(&heard, Duration::from_millis(300), |said| {
            said["type"] == "reply" && (said["value"]["id"] == 2 || said["value"]["id"] == 3)
        });
        assert_eq!(
            early, None,
            "a snapshot was taken while the history was held"
        );
        drop(release);
        for id in [2, 3] {
            assert!(replied(&heard, id).is_ok());
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_close_applies_the_edits_sent_before_it_and_refuses_those_after() {
        let (sessions, heard, dir, release) = replacing_while_the_history_is_held().await;
        sessions.send_to(2, 1, "CloseProject", json!({}));
        sessions.send_to(3, 1, "Open", json!({ "path": "ch.tex" }));
        assert_eq!(replied(&heard, 3).unwrap_err()["kind"], "notFound");
        drop(release);
        assert!(replied(&heard, 1).unwrap()["snapshot"].is_string());
        assert_eq!(replied(&heard, 2), Ok(json!(true)));
        assert_eq!(chapter(&dir), "dog\n");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_version_asked_before_a_close_is_saved_before_the_close_answers() {
        let (sessions, heard, _dir) = panicking().await;
        let open = json!({ "id": "P", "autoCompile": false });
        sessions.send_to(0, 1, "OpenProject", open);
        replied(&heard, 0).unwrap();
        let release = hold_history(&sessions);
        sessions.send_to(1, 1, "SaveVersion", json!({ "name": "Draft" }));
        sessions.send_to(2, 1, "CloseProject", json!({}));
        sessions.send_to(3, 1, "ListVersions", json!({}));
        assert_eq!(replied(&heard, 3).unwrap_err()["kind"], "notFound");
        drop(release);
        assert_eq!(replied(&heard, 1).unwrap()["name"], "Draft");
        assert_eq!(replied(&heard, 2), Ok(json!(true)));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_version_asked_while_a_replace_waits_on_the_history_holds_its_writes() {
        let (sessions, heard, _dir, release) = replacing_while_the_history_is_held().await;
        sessions.send_to(2, 1, "SaveVersion", json!({ "name": "Draft" }));
        drop(release);
        assert!(replied(&heard, 1).is_ok());
        let changed = replied(&heard, 2).unwrap()["changed"].take();
        assert_eq!(changed, json!([{ "path": "ch.tex", "change": "changed" }]));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn what_waits_on_the_history_when_its_session_stops_is_answered_as_stopped() {
        let (sessions, heard, dir, release) = replacing_while_the_history_is_held().await;
        sessions.send_to(2, 1, "SaveVersion", json!({ "name": "Draft" }));
        sessions.send_to(3, 1, "SaveVersion", json!({ "name": "Final" }));
        sessions.send_to(4, 1, "Compile", json!({ "auto": false }));
        assert_eq!(replied(&heard, 4).unwrap_err()["kind"], "internal");
        drop(release);
        for id in [1, 2, 3] {
            let refused = replied(&heard, id).unwrap_err();
            assert_eq!(refused["message"]["id"], "session_stopped", "{refused}");
        }
        assert_eq!(chapter(&dir), "cat\n");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_close_or_a_failed_open_is_answered_only_once_its_project_is_free() {
        let (sessions, heard, dir) = panicking().await;
        let open = |id: &str| json!({ "id": id, "autoCompile": false });
        for (session, stops) in [(1, false), (2, true)] {
            let asked = session * 10;
            sessions.send_to(asked, session, "OpenProject", open("P"));
            assert!(replied(&heard, asked).unwrap().is_object());
            let registry = lock(&sessions.service.library);
            if stops {
                sessions.send_to(asked + 1, session, "Compile", json!({ "auto": false }));
            }
            sessions.send_to(asked + 2, session, "CloseProject", json!({}));
            let early = replied_within(&heard, asked + 2, Duration::from_millis(300));
            assert_eq!(
                early, None,
                "the close was answered before the project was free"
            );
            drop(registry);
            assert_eq!(replied(&heard, asked + 2).is_ok(), !stops);
        }
        let root = dir.path().join("P");
        let mode = |mode| fs::set_permissions(&root, fs::Permissions::from_mode(mode)).unwrap();
        mode(0);
        sessions.send_to(30, 3, "OpenProject", open("P"));
        let unreadable = replied(&heard, 30);
        mode(0o755);
        sessions.send_to(40, 4, "OpenProject", open("Q"));
        let unknown = replied(&heard, 40);
        for refused in [unreadable, unknown] {
            assert!(refused.is_err(), "{refused:?}");
        }
        assert!(lock(&sessions.service.library).is_empty());
        sessions.send_to(50, 5, "OpenProject", open("P"));
        assert!(replied(&heard, 50).unwrap().is_object());
    }
}
