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
use std::collections::hash_map::Entry;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};

use serde::Deserialize;
use serde_json::Value;
use texlocal_latex::logparse::{Fix, LogItem};
use texlocal_latex::syntax::{SymbolKind, TextEdit};
use tokio::sync::mpsc;

use crate::compile::CompileResult;
use crate::events::{Hub, Listener, Queued};
use crate::paths::RelPath;
use crate::projects::Symbols;
use crate::service::{Service, parse};
use crate::texpresso::{LiveEvent, Preview};
use crate::{CoreError, lock, paths};

pub(crate) use build::Compiler;
pub use document::Document;
use documents::{Docs, Resolution, Shared};
use watch::Change;

pub(crate) enum Msg {
    Changed {
        doc: u64,
        version: u64,
        edit: Option<TextEdit>,
    },
    Command(SessionCommand, Reply),
    BuildDone(Result<CompileResult, CoreError>),
    Cleaned(Result<(), CoreError>),
    Symbols {
        seq: u64,
        edits: u64,
        result: Result<Box<(Symbols, Vec<LogItem>, Value)>, CoreError>,
    },
    Live(u64, LiveEvent),
    Fs(Vec<Change>),
}

#[derive(Deserialize)]
#[serde(tag = "call", rename_all = "snake_case", rename_all_fields = "camelCase")]
#[rustfmt::skip]
pub(crate) enum SessionCommand {
    Close,
    SetOptions { auto_compile: Option<bool> },
    OpenDocument { path: RelPath },
    CloseDocument { path: RelPath },
    Composing { path: RelPath, composing: bool },
    Save { reporting: Option<bool> },
    Resolve { path: RelPath, answer: Resolution },
    Compile { #[serde(default)] auto: bool },
    StopCompile,
    Clean,
    Search { query: String, #[serde(default)] match_case: bool, #[serde(default)] whole_word: bool },
    Usages { path: RelPath, offset: u32 },
    QuickHelp { path: RelPath, offset: u32 },
    QuickOpen { query: String },
    Replace { query: String, replacement: String, #[serde(default)] match_case: bool,
        #[serde(default)] whole_word: bool },
    RenameSymbol { kind: SymbolKind, from: String, to: String },
    Fix { id: Fix },
    HistoryList,
    HistorySave { name: String },
    HistoryCompare { id: String, path: RelPath },
    HistoryRestore { id: String, paths: Option<Vec<RelPath>> },
    Rename { from: RelPath, to: String },
    CreateEntry { #[serde(default)] folder: String, name: String, #[serde(default)] dir: bool },
    SetSettings { patch: Value },
    PrepareDelete { path: RelPath },
    Deleted { path: RelPath, trashed: Option<bool> },
    LiveStart,
    LiveStop,
    LiveView { first: u32, last: u32 },
    LiveCaret { path: RelPath, offset: usize },
    LiveLog { shown: bool },
    #[serde(other)]
    Unknown,
}

#[derive(Deserialize)]
struct Call {
    session: u64,
    #[serde(flatten)]
    command: SessionCommand,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Opening {
    id: String,
    session: u64,
    #[serde(default)]
    auto_compile: bool,
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

    pub fn send(self: &Arc<Self>, id: u64, command: &str, args: Value) {
        let reply = self.reply(id);
        match command.strip_prefix("session_") {
            Some("open") => match parse(command, args) {
                Ok(opening) => self.open(opening, reply),
                Err(err) => reply.send(Err(err)),
            },
            Some(name) => match parse(name, args) {
                Ok(Call { session, command }) => match lock(&self.open).get(&session) {
                    Some(open) => {
                        let _ = open.tx.send(Msg::Command(command, reply));
                    }
                    None => reply.send(Err(gone())),
                },
                Err(err) => reply.send(Err(err)),
            },
            None => {
                let (service, name) = (Arc::clone(&self.service), command.to_owned());
                let runtime = tokio::runtime::Handle::current();
                tokio::task::spawn_blocking(move || {
                    reply.send(runtime.block_on(service.call(&name, args)));
                });
            }
        }
    }

    pub fn refuse(&self, id: u64, error: CoreError) {
        self.reply(id).send(Err(error));
    }

    fn reply(&self, id: u64) -> Reply {
        Reply(Some((id, self.hub.queue.clone())))
    }

    fn open(self: &Arc<Self>, opening: Opening, reply: Reply) {
        let Opening {
            id,
            session,
            auto_compile,
        } = opening;
        let (tx, rx) = mpsc::unbounded_channel();
        let docs = Docs::default();
        let open = Open {
            tx: tx.clone(),
            docs: docs.shared(),
        };
        match lock(&self.open).entry(session) {
            Entry::Occupied(_) => {
                return reply.send(Err(CoreError::conflict("That session is open already")));
            }
            Entry::Vacant(entry) => entry.insert(open),
        };
        let (sessions, runtime) = (Arc::clone(self), tokio::runtime::Handle::current());
        std::thread::Builder::new()
            .name(format!("texlocal-session-{session}"))
            .spawn(move || {
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    let _entered = runtime.enter();
                    match actor::Actor::new(&sessions, session, id, docs, tx.clone(), auto_compile)
                    {
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
        sessions.send(0, "session_open", json!({ "id": "P", "session": 1 }));
        let pending = [
            "session_compile",
            "session_save",
            "session_search",
            "session_clean",
        ];
        for (id, command) in (1..).zip(pending) {
            sessions.send(id, command, json!({ "session": 1, "query": "x" }));
        }
        let mut replies = BTreeMap::new();
        while replies.len() <= pending.len() {
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
