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
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use serde::Deserialize;
use serde_json::Value;
use texlocal_latex::logparse::{Fix, LogItem};
use texlocal_latex::syntax::{SymbolKind, TextEdit};
use tokio::sync::{mpsc, oneshot};

use crate::compile::CompileResult;
use crate::events::{Hub, Listener};
use crate::paths::RelPath;
use crate::projects::Symbols;
use crate::service::{Service, parse};
use crate::texpresso::{LiveEvent, Preview};
use crate::{CoreError, lock, paths};

pub(crate) use build::Engine;
pub use document::Document;
use documents::Resolution;
use watch::Change;

pub(crate) enum Msg {
    Changed {
        doc: u64,
        version: u64,
        edit: Option<TextEdit>,
    },
    Command(Command, Reply),
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
pub(crate) enum Command {
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
    command: Command,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Opening {
    id: String,
    session: u64,
    #[serde(default)]
    auto_compile: bool,
}

pub(crate) struct Reply(Option<oneshot::Sender<Result<Value, CoreError>>>);

impl Reply {
    pub fn send(mut self, answer: Result<Value, CoreError>) {
        if let Some(reply) = self.0.take() {
            let _ = reply.send(answer);
        }
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        if std::thread::panicking()
            && let Some(reply) = self.0.take()
        {
            let _ = reply.send(Err(stopped()));
        }
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
    docs: Arc<Mutex<HashMap<String, Document>>>,
}

pub type Answer = Pin<Box<dyn Future<Output = Result<Value, CoreError>> + Send>>;

pub struct Sessions {
    service: Arc<Service>,
    hub: Hub,
    engine: Arc<dyn Engine>,
    preview: Arc<dyn Preview>,
    watch: bool,
    open: Arc<Mutex<HashMap<u64, Open>>>,
}

impl Sessions {
    pub fn new(service: Arc<Service>, listener: Listener) -> Self {
        let engine = Arc::new(Arc::clone(&service));
        let preview = Arc::clone(&service.texpresso);
        Self::with_engine(service, engine, preview, true, listener)
    }

    pub(crate) fn with_engine(
        service: Arc<Service>,
        engine: Arc<dyn Engine>,
        preview: Arc<dyn Preview>,
        watch: bool,
        listener: Listener,
    ) -> Self {
        Self {
            service,
            hub: Hub::new(listener),
            engine,
            preview,
            watch,
            open: Arc::default(),
        }
    }

    pub fn document(&self, session: u64, path: &str) -> Option<Document> {
        let path = paths::rel_key(path).ok()?;
        let docs = Arc::clone(&lock(&self.open).get(&session)?.docs);
        lock(&docs).get(&path).cloned()
    }

    pub fn call(self: &Arc<Self>, command: &str, args: Value) -> Answer {
        let (name, sessions) = (command.to_owned(), Arc::clone(self));
        match command.strip_prefix("session_") {
            Some("open") => Box::pin(async move { sessions.open(parse(&name, args)?) }),
            Some(command) => Box::pin(self.send(command, args)),
            None => Box::pin(async move { sessions.service.call(&name, args).await }),
        }
    }

    fn open(&self, opening: Opening) -> Result<Value, CoreError> {
        let Opening {
            id,
            session,
            auto_compile,
        } = opening;
        let taken = || CoreError::conflict("That session is open already");
        if lock(&self.open).contains_key(&session) {
            return Err(taken());
        }
        let project = self.service.project(&id)?;
        let (tx, rx) = mpsc::unbounded_channel();
        let new = actor::Actor::new(self, session, id, project, tx.clone(), auto_compile);
        let (actor, opened) = new?;
        let open = Open {
            tx: tx.clone(),
            docs: Arc::clone(&actor.shared),
        };
        match lock(&self.open).entry(session) {
            Entry::Occupied(_) => return Err(taken()),
            Entry::Vacant(entry) => entry.insert(open),
        };
        let (sessions, runtime) = (Arc::clone(&self.open), tokio::runtime::Handle::current());
        std::thread::Builder::new()
            .name(format!("texlocal-session-{session}"))
            .spawn(move || {
                let _ = catch_unwind(AssertUnwindSafe(|| runtime.block_on(actor.run(rx))));
                let mut open = lock(&sessions);
                if open
                    .get(&session)
                    .is_some_and(|open| open.tx.same_channel(&tx))
                {
                    open.remove(&session);
                }
            })
            .expect("the session's thread starts");
        Ok(opened)
    }

    fn send(
        &self,
        name: &str,
        args: Value,
    ) -> impl Future<Output = Result<Value, CoreError>> + Send + use<> {
        let (reply, answer) = oneshot::channel();
        let queued = parse(name, args).and_then(|Call { session, command }| {
            let closing = matches!(command, Command::Close);
            let message = Msg::Command(command, Reply(Some(reply)));
            let open = lock(&self.open);
            let open = open.get(&session).ok_or_else(gone)?;
            open.tx.send(message).map_err(|_| gone())?;
            Ok((session, closing))
        });
        let open = Arc::clone(&self.open);
        async move {
            let (session, closing) = queued?;
            let answer = answer.await.unwrap_or_else(|_| Err(gone()));
            if closing && answer.as_ref().is_ok_and(|answer| answer["saved"] == true) {
                lock(&open).remove(&session);
            }
            answer
        }
    }
}
