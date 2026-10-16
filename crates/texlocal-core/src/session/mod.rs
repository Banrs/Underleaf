//! Project sessions: what a host had to keep per open project (open files'
//! text, autosave, conflicts with other apps, builds and their issues, live
//! preview, the folder's watcher), kept here once for every host.
//!
//! Each session is one task (`actor.rs`) that takes commands, edits, file
//! changes and build and preview results as messages, one at a time, and
//! tells the host what changed through the event hub. A document's text is
//! the session's (`Document`): the host's editor sends each edit to it once,
//! and the session saves, previews and highlights from that same text.
//! docs/core-api.md is the contract.

mod actor;
mod document;
mod engine;
mod live;
#[cfg(test)]
mod tests;
mod watch;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::compile::CompileResult;
use crate::events::{Hub, Listener};
use crate::projects::Symbols;
use crate::service::{Service, arg, string_arg};
use crate::texpresso::Events;
use crate::{CoreError, lock};

pub use document::Document;
pub(crate) use engine::{Engine, ServiceEngine};
use watch::Change;

/// The session's waits.
#[derive(Debug, Clone)]
pub(crate) struct Timings {
    /// From the last edit to the autosave.
    pub autosave: Duration,
    /// From a save to the scan of labels and citations.
    pub symbols: Duration,
    /// FSEvents' latency: changes this close together are taken together.
    pub settle: Duration,
    /// A stopped run is shown as halted only once it has lasted this long.
    pub halts_after: Duration,
    /// From a caret's move to telling TeXpresso where it settled.
    pub caret: Duration,
    /// From a rename, a new main file or a changed file to the preview catching up.
    pub live_follow: Duration,
    /// From a failed whole text to sending it again.
    pub retry: Duration,
    /// A preview that ends by itself after this long is started again.
    pub restartable_after: Duration,
    /// Whether the folder is watched; tests send the changes themselves.
    pub watch: bool,
}

impl Default for Timings {
    fn default() -> Self {
        Timings {
            autosave: Duration::from_millis(700),
            symbols: Duration::from_millis(150),
            settle: Duration::from_millis(250),
            halts_after: Duration::from_secs(1),
            caret: Duration::from_millis(150),
            live_follow: Duration::from_millis(180),
            retry: Duration::from_millis(750),
            restartable_after: Duration::from_secs(10),
            watch: true,
        }
    }
}

/// What reaches a session's task.
pub(crate) enum Msg {
    Edited {
        doc: u64,
        version: u64,
        start: u32,
        length: u32,
        text: String,
    },
    Reloaded {
        doc: u64,
        version: u64,
    },
    Command {
        name: String,
        args: Value,
        reply: oneshot::Sender<Result<Value, CoreError>>,
    },
    BuildDone(Result<CompileResult, CoreError>),
    Cleaned(Result<(), CoreError>),
    Symbols(u64, Result<Symbols, CoreError>),
    LiveNews(u64, Result<Events, CoreError>),
    Fs(Vec<Change>),
}

/// Lets a new session's events go out when dropped.
struct Release<'a>(&'a Hub, u64);

impl Drop for Release<'_> {
    fn drop(&mut self) {
        self.0.release(self.1);
    }
}

struct Open {
    tx: mpsc::UnboundedSender<Msg>,
    /// The session's documents by path, for the host's editor to edit.
    docs: Arc<Mutex<HashMap<String, Document>>>,
}

/// Every open session, and the hub their events go out through.
pub struct Sessions {
    service: Arc<Service>,
    hub: Hub,
    engine: Arc<dyn Engine>,
    timings: Timings,
    open: Mutex<HashMap<u64, Open>>,
    next: AtomicU64,
}

impl Sessions {
    pub fn new(service: Arc<Service>) -> Self {
        let engine = Arc::new(ServiceEngine(Arc::clone(&service)));
        Self::with_engine(service, engine, Timings::default())
    }

    pub(crate) fn with_engine(
        service: Arc<Service>,
        engine: Arc<dyn Engine>,
        timings: Timings,
    ) -> Self {
        Sessions {
            service,
            hub: Hub::default(),
            engine,
            timings,
            open: Mutex::default(),
            next: AtomicU64::new(1),
        }
    }

    /// Sets the function the sessions' events go to; see `Hub::set_listener`.
    pub fn set_listener(&self, listener: Option<Listener>) {
        self.hub.set_listener(listener);
    }

    #[cfg(test)]
    pub(crate) fn hub(&self) -> &Hub {
        &self.hub
    }

    /// The document the session `session` has open at `path`, for the host's
    /// editor: its edits go to it, and its highlighting reads from it.
    pub fn document(&self, session: u64, path: &str) -> Option<Document> {
        let docs = Arc::clone(&lock(&self.open).get(&session)?.docs);
        lock(&docs).get(path).cloned()
    }

    /// `call_then`, answering what it is given.
    #[cfg(test)]
    pub(crate) async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        self.call_then(command, args, |answer| answer).await
    }

    /// Answers a `session_*` command, handing the answer to `deliver` and returning what
    /// it does; the host sends every other command to `Service::call`. Must run inside a
    /// tokio runtime that goes on running its tasks between calls.
    ///
    /// No event of a session reaches the listener before `deliver` has returned for the
    /// answer to its `session_open`: `deliver` is where a host's callback gets the answer,
    /// so none of the events can come first.
    pub async fn call_then<T, F>(&self, command: &str, args: &Value, deliver: F) -> T
    where
        F: FnOnce(Result<Value, CoreError>) -> T,
    {
        let answer = match command {
            "session_open" => self.open(args),
            _ => self.send(command, args).await,
        };
        // Released however `deliver` ends.
        let _release = (command == "session_open")
            .then(|| answer.as_ref().ok()?["session"].as_u64())
            .flatten()
            .map(|session| Release(&self.hub, session));
        deliver(answer)
    }

    fn open(&self, args: &Value) -> Result<Value, CoreError> {
        let project = string_arg(args, "id")?.to_owned();
        let root = dunce::canonicalize(self.service.project_root(&project)?)?;
        let auto_compile = arg::<Option<bool>>(args, "autoCompile")?.unwrap_or(false);
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::unbounded_channel();
        let docs = Arc::default();
        let actor = actor::Actor::new(actor::Setup {
            id,
            project,
            root: root.clone(),
            service: Arc::clone(&self.service),
            engine: Arc::clone(&self.engine),
            events: self.hub.emitter(),
            tx: tx.clone(),
            docs: Arc::clone(&docs),
            timings: self.timings.clone(),
            auto_compile,
        })?;
        let opened = actor.opened();
        // Before the task can make an event (a build, say, for `autoCompile`), and let go
        // once the host has the answer that names the session (`call_then`).
        self.hub.hold(id);
        tokio::spawn(actor.run(rx));
        lock(&self.open).insert(id, Open { tx, docs });
        Ok(
            json!({ "session": id, "root": root.to_string_lossy(), "pdf": opened.pdf, "tree": opened.tree }),
        )
    }

    async fn send(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let id: u64 = arg(args, "session")?;
        let tx = lock(&self.open)
            .get(&id)
            .map(|open| open.tx.clone())
            .ok_or_else(|| CoreError::not_found("No such session"))?;
        let (reply, answer) = oneshot::channel();
        let name = command.trim_start_matches("session_").to_owned();
        let closing = name == "close";
        let message = Msg::Command {
            name,
            args: args.clone(),
            reply,
        };
        tx.send(message)
            .map_err(|_| CoreError::not_found("No such session"))?;
        let answer = answer
            .await
            .unwrap_or_else(|_| Err(CoreError::not_found("No such session")));
        if closing {
            lock(&self.open).remove(&id);
            // A session closed before its open was released lets go of its events.
            self.hub.release(id);
        }
        answer
    }

    #[cfg(test)]
    pub(crate) fn inject(&self, session: u64, message: Msg) {
        if let Some(open) = lock(&self.open).get(&session) {
            let _ = open.tx.send(message);
        }
    }

    /// Closes every session, saving what can be saved, as a host does when it quits.
    pub async fn close_all(&self) {
        let ids: Vec<u64> = lock(&self.open).keys().copied().collect();
        for id in ids {
            let _ = self.send("session_close", &json!({ "session": id })).await;
        }
    }
}
