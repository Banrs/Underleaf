//! Project sessions: what a host had to keep per open project (open files'
//! text, autosave, conflicts with other apps, builds and their issues, live
//! preview, the folder's watcher), kept here once for every host.
//!
//! Each session is one task (`actor.rs`) that takes commands, edits, file
//! changes and build and preview results as messages, one at a time, and
//! tells the host what changed through the event hub. A document's text is
//! the session's (`Document`): the host's editor sends each edit to it once,
//! and the session saves, previews and highlights from that same text. A
//! host numbers its sessions, so it listens for one before opening it.
//! docs/core-api.md is the contract.

mod actor;
mod build;
mod document;
mod engine;
mod live;
#[cfg(test)]
mod tests;
mod watch;

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::analyze::{self, Heading};
use crate::compile::CompileResult;
use crate::events::{Hub, Listener};
use crate::projects::Symbols;
use crate::service::{Service, arg, out, string_arg};
use crate::texpresso::{LiveEvent, Preview};
use crate::{CoreError, lock, paths};

pub use document::Document;
pub(crate) use engine::Engine;
use watch::Change;

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
        reply: Reply,
    },
    BuildDone(Result<CompileResult, CoreError>),
    Cleaned(Result<(), CoreError>),
    /// A scan's sequence number, what it read for the next, and what it found.
    Symbols(u64, Result<Symbols, CoreError>),
    /// What the preview of a start, by its number, tells (`Live::generation`).
    Live(u64, LiveEvent),
    Fs(Vec<Change>),
}

/// A command's answer, sent once. One a panic drops says the session stopped, where
/// the host would otherwise be told there is no such session.
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

/// The answer of a session that a panic ended (`Actor::stopped`).
pub(crate) fn stopped() -> CoreError {
    CoreError::internal("The project stopped after an internal error. Close it and open it again.")
}

struct Open {
    tx: mpsc::UnboundedSender<Msg>,
    /// The session's documents by path, for the host's editor to edit.
    docs: Arc<Mutex<HashMap<String, Document>>>,
    outline: Arc<Mutex<Outline>>,
}

/// The outline of the last `analyze` asked for of those finished, which
/// `outline_current` reads without waiting for the session's task.
#[derive(Default)]
pub(crate) struct Outline {
    /// The analysis's place in the order they were asked for.
    seq: u64,
    headings: Vec<Heading>,
}

/// Every open session, by the number its host gave it, and the hub their events go out through.
pub struct Sessions {
    service: Arc<Service>,
    hub: Hub,
    engine: Arc<dyn Engine>,
    preview: Arc<dyn Preview>,
    /// Whether each session watches its folder; tests send the changes themselves.
    watch: bool,
    open: Arc<Mutex<HashMap<u64, Open>>>,
}

impl Sessions {
    pub fn new(service: Arc<Service>) -> Self {
        let engine = Arc::new(Arc::clone(&service));
        let preview = Arc::clone(&service.texpresso);
        Self::with_engine(service, engine, preview, true)
    }

    pub(crate) fn with_engine(
        service: Arc<Service>,
        engine: Arc<dyn Engine>,
        preview: Arc<dyn Preview>,
        watch: bool,
    ) -> Self {
        Self {
            service,
            hub: Hub::default(),
            engine,
            preview,
            watch,
            open: Arc::default(),
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
        let path = paths::rel_key(path).ok()?;
        let docs = Arc::clone(&lock(&self.open).get(&session)?.docs);
        lock(&docs).get(&path).cloned()
    }

    /// Answers a `session_*` command; the host sends every other command to `Service::call`.
    /// Must run inside a tokio runtime that goes on running its tasks between calls.
    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        match command {
            "session_open" => self.open(args),
            _ => self.send(command, args).await,
        }
    }

    /// Opens the session numbered `session`, a number its host chose and listens for
    /// already: the session's first events may come before this answers. A number open
    /// already is refused (409).
    fn open(&self, args: &Value) -> Result<Value, CoreError> {
        let id: u64 = arg(args, "session")?;
        let taken = || CoreError::conflict("That session is open already");
        // Before the tree is read and the folder watched for a session that won't be.
        if lock(&self.open).contains_key(&id) {
            return Err(taken());
        }
        let project = string_arg(args, "id")?.to_owned();
        let root = self.service.project_root(&project)?;
        let auto_compile = arg::<Option<bool>>(args, "autoCompile")?.unwrap_or(false);
        let (tx, rx) = mpsc::unbounded_channel();
        let (actor, opened) = actor::Actor::new(self, id, project, root, tx.clone(), auto_compile)?;
        let open = Open {
            tx: tx.clone(),
            docs: Arc::clone(&actor.shared),
            outline: Arc::clone(&actor.outline),
        };
        match lock(&self.open).entry(id) {
            Entry::Occupied(_) => return Err(taken()),
            Entry::Vacant(entry) => entry.insert(open),
        };
        let sessions = Arc::clone(&self.open);
        tokio::spawn(async move {
            // A session a panic ended is gone, and the host's next command is told so.
            if actor.run(rx).await {
                let mut open = lock(&sessions);
                if open.get(&id).is_some_and(|open| open.tx.same_channel(&tx)) {
                    open.remove(&id);
                }
            }
        });
        Ok(opened)
    }

    /// A command for an open session (any but `session_open`), queued for its task as this
    /// is called, so a session takes its commands in the order they were sent however
    /// their answers are awaited. `outline_current` alone is answered here, as it is called.
    pub fn send(
        &self,
        command: &str,
        args: &Value,
    ) -> impl Future<Output = Result<Value, CoreError>> + Send + use<> {
        let gone = || CoreError::not_found("No such session");
        let name = command.trim_start_matches("session_").to_owned();
        let closing = name == "close";
        let (reply, answer) = oneshot::channel();
        let queued = arg::<u64>(args, "session").and_then(|id| {
            let open = lock(&self.open);
            let session = open.get(&id).ok_or_else(gone)?;
            if name == "outline_current" {
                // From the outline kept, so it waits for none of the session's work.
                let outline = Arc::clone(&session.outline);
                drop(open);
                let _ = reply.send(outline_current(&outline, args));
                return Ok(id);
            }
            let message = Msg::Command {
                name,
                args: args.clone(),
                reply: Reply(Some(reply)),
            };
            session.tx.send(message).map_err(|_| gone())?;
            Ok(id)
        });
        let open = Arc::clone(&self.open);
        async move {
            let id = queued?;
            let answer = answer.await.unwrap_or_else(|_| Err(gone()));
            if closing {
                lock(&open).remove(&id);
            }
            answer
        }
    }

    #[cfg(test)]
    pub(crate) fn outline(&self, session: u64) -> Arc<Mutex<Outline>> {
        Arc::clone(&lock(&self.open)[&session].outline)
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

/// The heading a line of `path` is under, as its place in the outline kept.
fn outline_current(outline: &Mutex<Outline>, args: &Value) -> Result<Value, CoreError> {
    let path = paths::rel_key(string_arg(args, "path")?)?;
    let line = arg(args, "line")?;
    let current = analyze::current_heading(&lock(outline).headings, &path, line);
    out(current)
}
