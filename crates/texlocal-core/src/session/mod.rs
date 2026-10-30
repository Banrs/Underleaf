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

use std::collections::HashMap;
use std::collections::hash_map::{Entry, VacantEntry};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::Value;
use texlocal_latex::analyze::Analysis;
use texlocal_latex::logparse::LogItem;
use texlocal_latex::syntax::TextEdit;
use tokio::sync::{mpsc, oneshot};

use crate::compile::CompileResult;
use crate::events::{Hub, Listener, Queued};
use crate::projects::Symbols;
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
use watch::Change;

pub use crate::paths::Project;
pub use crate::texpresso::{FileBuffer, LiveEvent, Pane, Preview, Sink, Status};

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
        result: Result<Box<(Symbols, Vec<LogItem>, Analysis)>, CoreError>,
    },
    Live(u64, LiveEvent),
    Fs(Vec<Change>),
}

pub(crate) struct Reply(Option<(u64, std::sync::mpsc::Sender<Queued>)>);

impl Reply {
    pub fn send(mut self, answer: Result<Value, CoreError>) {
        self.answer(answer);
    }

    fn answer(&mut self, answer: Result<Value, CoreError>) {
        if let Some((id, queue)) = self.0.take() {
            let _ = queue.send(Queued::Reply { id, answer });
        }
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        self.answer(Err(if std::thread::panicking() {
            stopped()
        } else {
            gone()
        }));
    }
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
        Self {
            service,
            hub,
            compiler,
            preview,
            watch,
            open: Mutex::default(),
        }
    }

    pub fn document(&self, session: u64, path: &str) -> Option<Document> {
        let path = paths::rel_key(path).ok()?;
        let docs = Arc::clone(&lock(&self.open).get(&session)?.docs);
        let document = lock(&docs).get(&path).cloned()?;
        document.shown();
        Some(document)
    }

    pub fn send(&self, id: u64, command: &str, args: Value) {
        let (service, name, reply) = (
            Arc::clone(&self.service),
            command.to_owned(),
            self.reply(id),
        );
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            reply.send(runtime.block_on(service.call(&name, args)));
        });
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
    use std::sync::mpsc::channel;
    use std::time::Duration;

    use serde_json::json;

    use super::build::Fut;
    use super::*;

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

    type Heard = std::sync::mpsc::Receiver<Value>;

    async fn panicking() -> (Arc<Sessions>, Heard, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let service = Arc::new(Service::new(dir.path().into()));
        let made = json!({ "name": "P", "template": "blank" });
        service.call("CreateProject", made).await.unwrap();
        let (tx, heard) = channel();
        let tx = Mutex::new(tx);
        let listener = Box::new(move |said: String| {
            let _ = lock(&tx).send(serde_json::from_str(&said).unwrap());
        });
        let preview = Arc::clone(&service.texpresso);
        let sessions = Sessions::with_compiler(service, Arc::new(Panics), preview, false, listener);
        (Arc::new(sessions), heard, dir)
    }

    fn replied_within(heard: &Heard, id: u64, wait: Duration) -> Option<Value> {
        let deadline = std::time::Instant::now() + wait;
        loop {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            let said = heard.recv_timeout(left).ok()?;
            if said["reply"] == id {
                return Some(said);
            }
        }
    }

    fn replied(heard: &Heard, id: u64) -> Value {
        replied_within(heard, id, Duration::from_secs(10)).expect("a reply")
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
        assert!(replied(&heard, 0)["ok"].is_object());
        for id in 1..=4 {
            let said = replied(&heard, id);
            assert_eq!(said["error"]["kind"], "internal", "{said}");
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_close_or_a_failed_open_is_answered_only_once_its_project_is_free() {
        let (sessions, heard, dir) = panicking().await;
        let open = |id: &str| json!({ "id": id, "autoCompile": false });
        for (session, stops) in [(1, false), (2, true)] {
            let asked = session * 10;
            sessions.send_to(asked, session, "OpenProject", open("P"));
            assert!(replied(&heard, asked)["ok"].is_object());
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
            replied(&heard, asked + 2);
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
            assert!(refused["error"].is_object(), "{refused}");
        }
        assert!(lock(&sessions.service.library).is_empty());
        sessions.send_to(50, 5, "OpenProject", open("P"));
        assert!(replied(&heard, 50)["ok"].is_object());
    }
}
