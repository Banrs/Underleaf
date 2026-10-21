//! Project sessions: what a host would keep per open project (open files' text, autosave,
//! conflicts, builds and issues, live preview, the folder's watcher), kept once here.
//! Each session is one task (`actor.rs`) taking messages one at a time; a host numbers its
//! sessions, so it listens for one before opening it. docs/core-api.md is the contract.

mod actor;
mod build;
mod document;
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
use crate::syntax::TextEdit;
use crate::texpresso::{LiveEvent, Preview};
use crate::{CoreError, lock, paths};

pub(crate) use build::Engine;
pub use document::Document;
use watch::Change;

pub(crate) enum Msg {
    /// A document's text changed to `version`: by `edit`, or replaced whole by a reload.
    Changed {
        doc: u64,
        version: u64,
        edit: Option<TextEdit>,
    },
    Command {
        name: String,
        args: Value,
        reply: Reply,
    },
    BuildDone(Result<CompileResult, CoreError>),
    Cleaned(Result<(), CoreError>),
    Symbols(u64, Result<Symbols, CoreError>),
    Live(u64, LiveEvent),
    Fs(Vec<Change>),
}

/// One a panic drops says the session stopped, where the host would otherwise be told
/// there is no such session.
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

struct Open {
    tx: mpsc::UnboundedSender<Msg>,
    docs: Arc<Mutex<HashMap<String, Document>>>,
    outline: Arc<Mutex<Outline>>,
}

/// `outline_current` reads it without waiting for the session's task.
#[derive(Default)]
pub(crate) struct Outline {
    seq: u64,
    headings: Vec<Heading>,
}

pub struct Sessions {
    service: Arc<Service>,
    hub: Hub,
    engine: Arc<dyn Engine>,
    preview: Arc<dyn Preview>,
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

    pub fn set_listener(&self, listener: Option<Listener>) {
        self.hub.set_listener(listener);
    }

    pub fn document(&self, session: u64, path: &str) -> Option<Document> {
        let path = paths::rel_key(path).ok()?;
        let docs = Arc::clone(&lock(&self.open).get(&session)?.docs);
        lock(&docs).get(&path).cloned()
    }

    /// Must run inside a tokio runtime that goes on running its tasks between calls.
    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        match command {
            "session_open" => self.open(args),
            _ => self.send(command, args).await,
        }
    }

    /// The session's first events may come before this answers. A number open already is
    /// refused (409).
    fn open(&self, args: &Value) -> Result<Value, CoreError> {
        let id: u64 = arg(args, "session")?;
        let taken = || CoreError::conflict("That session is open already");
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
            actor.run(rx).await;
            // A close took it off already, and the host may have opened the number again.
            let mut open = lock(&sessions);
            if open.get(&id).is_some_and(|open| open.tx.same_channel(&tx)) {
                open.remove(&id);
            }
        });
        Ok(opened)
    }

    /// Queued for the session's task as this is called, so commands are taken in the order
    /// sent however their answers are awaited.
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
            // Taken off here, not as the task ends, so the number is free once this answers.
            if closing {
                lock(&open).remove(&id);
            }
            answer
        }
    }

    pub async fn close_all(&self) {
        let ids: Vec<u64> = lock(&self.open).keys().copied().collect();
        for id in ids {
            let _ = self.send("session_close", &json!({ "session": id })).await;
        }
    }
}

fn outline_current(outline: &Mutex<Outline>, args: &Value) -> Result<Value, CoreError> {
    let path = paths::rel_key(string_arg(args, "path")?)?;
    let line = arg(args, "line")?;
    let current = analyze::current_heading(&lock(outline).headings, &path, line);
    out(current)
}
