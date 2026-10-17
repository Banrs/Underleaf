//! Project sessions: what a host had to keep per open project (open files'
//! text, autosave, conflicts with other apps, builds and their issues, live
//! preview, the folder's watcher), kept here once for every host.
//!
//! Each session is one task (`actor.rs`) that takes commands, edits and file
//! changes as messages, and the work it waits on (a build, TeXpresso's news),
//! one at a time, and tells the host what changed through the event hub. A
//! document's text is the session's (`Document`): the host's editor sends each
//! edit to it once, and the session saves, previews and highlights from that
//! same text. docs/core-api.md is the contract.

mod actor;
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
use crate::events::{Hub, Listener};
use crate::service::{Service, arg, out, string_arg};
use crate::{CoreError, lock, paths};

pub use document::Document;
pub(crate) use engine::Engine;

type Reply = oneshot::Sender<Result<Value, CoreError>>;

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
    Fs(Vec<watch::Change>),
    #[cfg(test)]
    Probe(Box<dyn FnOnce(&mut actor::Actor) + Send>),
}

/// What other threads read without waiting for the session's task.
#[derive(Default)]
pub(crate) struct Shared {
    /// The documents by path, for the host's editor to edit.
    docs: Mutex<HashMap<String, Document>>,
    /// The outline of the last `analyze` asked for of those finished, by its place in
    /// the order asked, for `outline_current`.
    outline: Mutex<(u64, Vec<Heading>)>,
}

struct Open {
    tx: mpsc::UnboundedSender<Msg>,
    shared: Arc<Shared>,
}

/// Every open session, by the number its host gave it, and the hub their events go out through.
pub struct Sessions {
    service: Arc<Service>,
    hub: Hub,
    engine: Arc<dyn Engine>,
    /// Whether folders are watched; tests send the changes themselves.
    watch: bool,
    open: Arc<Mutex<HashMap<u64, Open>>>,
}

impl Sessions {
    pub fn new(service: Arc<Service>) -> Self {
        let engine = Arc::clone(&service) as Arc<dyn Engine>;
        Self::with_engine(service, engine, true)
    }

    pub(crate) fn with_engine(service: Arc<Service>, engine: Arc<dyn Engine>, watch: bool) -> Self {
        let (hub, open) = (Hub::default(), Arc::default());
        Self {
            service,
            hub,
            engine,
            watch,
            open,
        }
    }

    /// Sets the function the sessions' events go to; see `Hub::set_listener`.
    pub fn set_listener(&self, listener: Option<Listener>) {
        self.hub.set_listener(listener);
    }

    /// The document the session `session` has open at `path`, for the host's
    /// editor: its edits go to it, and its highlighting reads from it.
    pub fn document(&self, session: u64, path: &str) -> Option<Document> {
        let shared = Arc::clone(&lock(&self.open).get(&session)?.shared);
        lock(&shared.docs).get(path).cloned()
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
        let project = string_arg(args, "id")?.to_owned();
        let root = dunce::canonicalize(self.service.project_root(&project)?)?;
        let auto_compile = arg::<Option<bool>>(args, "autoCompile")?.unwrap_or(false);
        let (actor, opened) = actor::Actor::new(self, id, project, root, auto_compile)?;
        match lock(&self.open).entry(id) {
            Entry::Occupied(_) => return Err(CoreError::conflict("That session is open already")),
            Entry::Vacant(entry) => entry.insert(actor.open()),
        };
        tokio::spawn(actor.run());
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
            let open = open.get(&id).ok_or_else(gone)?;
            if name == "outline_current" {
                let _ = reply.send(outline_current(&open.shared, args));
                return Ok(id);
            }
            let args = args.clone();
            let message = Msg::Command { name, args, reply };
            open.tx.send(message).map_err(|_| gone())?;
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

    /// Closes every session, saving what can be saved, as a host does when it quits.
    pub async fn close_all(&self) {
        let ids: Vec<u64> = lock(&self.open).keys().copied().collect();
        for id in ids {
            let _ = self.send("session_close", &json!({ "session": id })).await;
        }
    }
}

/// The heading a line of `path` is under, as its place in the outline kept.
fn outline_current(shared: &Shared, args: &Value) -> Result<Value, CoreError> {
    let path = paths::rel_key(string_arg(args, "path")?)?;
    let line = arg(args, "line")?;
    out(analyze::current_heading(
        &lock(&shared.outline).1,
        &path,
        line,
    ))
}
