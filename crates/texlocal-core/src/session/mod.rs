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
mod watch;

use std::collections::HashMap;
use std::collections::hash_map::{Entry, VacantEntry};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};

use serde_json::Value;
use texlocal_latex::analyze::Analysis;
use texlocal_latex::logparse::LogItem;
use texlocal_latex::syntax::TextEdit;
use tokio::sync::mpsc;

use crate::compile::CompileResult;
use crate::events::{Hub, Listener, Queued};
use crate::projects::Symbols;
use crate::protocol::Answer;
use crate::service::Service;
use crate::texpresso::{LiveEvent, Preview};
use crate::{CoreError, lock, paths};

pub(crate) use actor::Session;
use actor::{OpenProject, SessionOpened};
pub(crate) use build::Compiler;
pub use document::Document;
pub(crate) use documents::{CloseReason, DiskConflict};
use documents::{Docs, Shared};
pub(crate) use live::LiveState;
use watch::Change;

pub(crate) enum Msg {
    Changed {
        doc: u64,
        version: u64,
        edit: Option<TextEdit>,
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
    CoreError::internal("The project stopped after an internal error. Close it and open it again.")
}

fn gone() -> CoreError {
    CoreError::not_found("No such session")
}

struct Open {
    tx: mpsc::UnboundedSender<Msg>,
    docs: Shared,
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

    pub(crate) fn with_compiler(
        service: Arc<Service>,
        compiler: Arc<dyn Compiler>,
        preview: Arc<dyn Preview>,
        watch: bool,
        listener: Listener,
    ) -> Self {
        Self {
            service,
            hub: Hub::new(listener),
            compiler,
            preview,
            watch,
            open: Mutex::default(),
        }
    }

    pub fn document(&self, session: u64, path: &str) -> Option<Document> {
        let path = paths::rel_key(path).ok()?;
        let docs = Arc::clone(&lock(&self.open).get(&session)?.docs);
        lock(&docs).get(&path).cloned()
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
            Entry::Occupied(open) => drop(open.get().tx.send(Msg::Command(request, reply))),
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
        reply: Pending<SessionOpened>,
    ) {
        let session = *entry.key();
        let (tx, rx) = mpsc::unbounded_channel();
        let docs = Docs::default();
        entry.insert(Open {
            tx: tx.clone(),
            docs: docs.shared(),
        });
        let (sessions, runtime) = (Arc::clone(self), tokio::runtime::Handle::current());
        std::thread::Builder::new()
            .name(format!("texlocal-session-{session}"))
            .spawn(move || {
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    let _entered = runtime.enter();
                    match actor::Actor::new(&sessions, session, opening, docs, tx.clone()) {
                        Ok((actor, opened)) => {
                            reply.send(Ok(opened));
                            runtime.block_on(actor.run(rx));
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
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    use serde_json::json;

    use super::build::Fut;
    use super::*;
    use crate::paths::Project;

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

    #[tokio::test(flavor = "multi_thread")]
    async fn a_panicking_compiler_fails_every_pending_command() {
        let dir = tempfile::tempdir().unwrap();
        let service = Arc::new(Service::new(dir.path().into()));
        let made = json!({ "name": "P", "template": "blank" });
        service.call("CreateProject", made).await.unwrap();
        let (tx, heard) = channel();
        let tx = Mutex::new(tx);
        let listener = Box::new(move |said: &Value| drop(lock(&tx).send(said.clone())));
        let preview = Arc::clone(&service.texpresso);
        let sessions = Arc::new(Sessions::with_compiler(
            service,
            Arc::new(Panics),
            preview,
            false,
            listener,
        ));
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
        let mut replies = BTreeMap::new();
        while replies.len() <= 4 {
            let said = heard.recv_timeout(Duration::from_secs(10)).unwrap();
            if let Some(id) = said["reply"].as_u64() {
                replies.insert(id, said);
            }
        }
        assert!(replies[&0]["ok"].is_object());
        for id in 1..=4 {
            assert_eq!(
                replies[&id]["error"]["kind"], "internal",
                "{}",
                replies[&id]
            );
        }
    }
}
