//! One project session's task: documents, saves, builds and the file watcher's news,
//! handled one message at a time, so no two of them race.

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::fs;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use notify::RecommendedWatcher;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch as signal};
use tokio::time::Instant;

use super::build::Builds;
use super::live::Live;
use super::watch::{self, Change, TreeIndex};
use super::{Document, Engine, Msg, Outline, Preview, Reply, Sessions};
use crate::analyze::{self, Facts, Named, Place};
use crate::events::Emitter;
use crate::paths::{self, within};
use crate::projects::{self, Query, Symbols, file_kind};
use crate::service::{SEARCH_LIMIT, Service, arg, out, string_arg};
use crate::settings;
use crate::stamp::Stamp;
use crate::syntax::{SymbolKind, Text};
use crate::{CoreError, lf, lock};

const MAIN_FILE_TRASH: &str = "Choose a different main file before moving this to the Trash.";
const STOPPED_SAVED: &str = "Saving stopped after an internal error. What was typed so far is saved: close the project and open it again to go on.";
const STOPPED_UNSAVED: &str = "Saving stopped after an internal error, and this file’s edits couldn’t be saved. Copy them out, then close the project and open it again.";
const NOT_UTF8: &str =
    "It isn't UTF-8 text, and saving it here would change it. Convert it to UTF-8 to edit it.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Conflict {
    Changed,
    Gone,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Reload {
    Disk,
    Revert,
}

pub(crate) struct Doc {
    pub doc: Document,
    path: String,
    saved: u64,
    force: bool,
    /// The disk's text as the document would hold it; None while the file isn't UTF-8.
    disk_text: Option<String>,
    newline: Newline,
    /// While a stat still gives it, a change told of is the session's own save, or none.
    disk_stamp: Option<Stamp>,
    /// Asked about once; until answered, no save writes over the other app's change.
    conflict: Option<Conflict>,
    asking: Option<Conflict>,
    held: bool,
    error: Option<String>,
    /// A `document_reload` the host has yet to apply: nothing is saved meanwhile.
    reload: Option<Reload>,
    composing: bool,
    pub issues: Vec<Value>,
    shown: Value,
}

impl Doc {
    pub fn dirty(&self) -> bool {
        self.force || self.doc.version() != self.saved
    }

    fn state(&self) -> Value {
        json!({ "path": self.path, "error": self.error, "held": self.held })
    }
}

pub(crate) enum Later {
    Compile(bool),
    Restart,
    FlushLive,
    Rescan,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Timer {
    Autosave,
    Symbols,
    Fs,
    Caret,
    Halting,
    Retry,
    Restart,
    Disk,
    Log,
}

impl Timer {
    fn wait(self) -> Duration {
        Duration::from_millis(match self {
            Self::Autosave => 700,
            Self::Symbols | Self::Caret => 150,
            // FSEvents' latency: changes this close together are taken together.
            Self::Fs => 250,
            Self::Retry => 750,
            Self::Halting => 1000,
            Self::Restart | Self::Disk => 180,
            // The log's whole text is copied, sent and laid out again each time, beside pages that
            // must land within a frame.
            Self::Log => 200,
        })
    }
}

enum Wake {
    Message(Msg),
    Deadline,
    TexFound,
}

pub(crate) struct Actor {
    pub id: u64,
    project: String,
    pub root: PathBuf,
    pub service: Arc<Service>,
    pub engine: Arc<dyn Engine>,
    pub preview: Arc<dyn Preview>,
    events: Emitter,
    pub tx: mpsc::UnboundedSender<Msg>,
    pub shared: Arc<Mutex<HashMap<String, Document>>>,
    pub docs: BTreeMap<String, Doc>,
    by_id: HashMap<u64, String>,
    next_doc: u64,
    symbols: Arc<RwLock<Arc<Symbols>>>,
    symbols_seq: u64,
    facts: Arc<analyze::Files>,
    pub edits: u64,
    /// Kept for the session's life: a document closed since isn't marked with a build's
    /// issues on lines that may have moved.
    pub last_edits: HashMap<String, u64>,
    pub auto_compile: bool,
    pub builds: Builds,
    tex: signal::Receiver<bool>,
    pub outline: Arc<Mutex<Outline>>,
    analyses: u64,
    pub timers: BTreeMap<Timer, Instant>,
    fs_pending: Vec<Change>,
    pub tree: TreeIndex,
    _watcher: Option<RecommendedWatcher>,
    deleting: BTreeSet<String>,
    pub live: Live,
    pub later: VecDeque<Later>,
    pub closed: bool,
}

impl Actor {
    pub fn new(
        sessions: &Sessions,
        id: u64,
        project: String,
        root: PathBuf,
        tx: mpsc::UnboundedSender<Msg>,
        auto_compile: bool,
    ) -> Result<(Self, Value), CoreError> {
        let tree = projects::file_tree(&root)?;
        let watcher = sessions
            .watch
            .then(|| watch::watch(&root, tx.clone()))
            .flatten();
        let settings = settings::read_settings(&root);
        let pdf = settings
            .output(&root, "pdf")
            .ok()
            .filter(|pdf| pdf.is_file());
        let opened = json!({
            "session": id,
            "root": root.to_string_lossy(),
            "pdf": pdf.as_ref().map(|pdf| pdf.to_string_lossy()),
            "tree": out(&tree)?,
            "settings": settings,
            "ui": settings::read_ui(&root),
        });
        let mut builds = Builds::default();
        builds.pdf = pdf.is_some();
        let mut actor = Self {
            id,
            project,
            root,
            service: Arc::clone(&sessions.service),
            engine: Arc::clone(&sessions.engine),
            preview: Arc::clone(&sessions.preview),
            events: sessions.hub.emitter(),
            tx,
            shared: Arc::default(),
            docs: BTreeMap::new(),
            by_id: HashMap::new(),
            next_doc: 1,
            symbols: Arc::default(),
            symbols_seq: 0,
            facts: Arc::default(),
            edits: 0,
            last_edits: HashMap::new(),
            auto_compile,
            builds,
            tex: sessions.service.tex_found.subscribe(),
            outline: Arc::default(),
            analyses: 0,
            timers: BTreeMap::from([(Timer::Symbols, Instant::now())]),
            fs_pending: Vec::new(),
            tree: TreeIndex::of(&tree),
            _watcher: watcher,
            deleting: BTreeSet::new(),
            live: Live::default(),
            later: VecDeque::new(),
            closed: false,
        };
        if actor.auto_compile && !actor.builds.pdf {
            actor.later.push_back(Later::Compile(true));
        }
        Ok((actor, opened))
    }

    pub async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Msg>) -> bool {
        let mut woken = None;
        loop {
            // A panic is a bug: the session ends, but the edits it holds mustn't end with it.
            let step = catch_unwind(AssertUnwindSafe(|| {
                match woken.take() {
                    Some(Wake::Message(message)) => self.handle(message),
                    Some(Wake::Deadline) => self.fire(),
                    Some(Wake::TexFound) => self.tex_changed(),
                    None => {}
                }
                self.run_later();
            }));
            if step.is_err() {
                self.stopped(&mut rx);
                return true;
            }
            if self.closed {
                return false;
            }
            let deadline = self.timers.values().min().copied();
            let sleep = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now));
            let waiting_for_tex = self.builds.waiting_for_tex;
            woken = tokio::select! {
                message = rx.recv() => match message {
                    Some(message) => Some(Wake::Message(message)),
                    None => return false,
                },
                () = sleep, if deadline.is_some() => Some(Wake::Deadline),
                Ok(()) = self.tex.changed(), if waiting_for_tex => Some(Wake::TexFound),
            };
        }
    }

    fn tex_changed(&mut self) {
        if *self.tex.borrow_and_update() {
            self.builds.waiting_for_tex = false;
            if self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
    }

    fn stopped(&mut self, rx: &mut mpsc::UnboundedReceiver<Msg>) {
        self.closed = true;
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let _ = self.flush_all(false);
            self.stop_compile();
            self.live_stop();
        }));
        for doc in self.docs.values() {
            let mut state = doc.state();
            state["error"] = (if doc.dirty() {
                STOPPED_UNSAVED
            } else {
                STOPPED_SAVED
            })
            .into();
            self.emit("document", state);
        }
        rx.close();
        while let Ok(message) = rx.try_recv() {
            if let Msg::Command { reply, .. } = message {
                reply.send(Err(super::stopped()));
            }
        }
        for reply in std::mem::take(&mut self.builds.cleaners) {
            reply.send(Err(super::stopped()));
        }
    }

    pub fn emit(&self, kind: &str, mut fields: Value) {
        fields["type"] = kind.into();
        fields["session"] = self.id.into();
        self.events.send(fields);
    }

    fn handle(&mut self, message: Msg) {
        match message {
            Msg::Edited {
                doc,
                version,
                start,
                length,
                text,
            } => self.edited(doc, version, start, length, &text),
            Msg::Reloaded { doc, version } => self.reloaded(doc, version),
            Msg::Command { name, args, reply } => self.command(&name, &args, reply),
            Msg::BuildDone(result) => self.build_done(result),
            Msg::Cleaned(result) => self.cleaned(result),
            Msg::Symbols(seq, result) => self.symbols_done(seq, result),
            Msg::Live(generation, event) => self.live_event(generation, event),
            Msg::Fs(changes) => {
                self.fs_pending.extend(changes);
                self.soon(Timer::Fs);
            }
        }
    }

    fn fire(&mut self) {
        let now = Instant::now();
        while let Some((&timer, _)) = self.timers.iter().find(|(_, at)| **at <= now) {
            self.timers.remove(&timer);
            match timer {
                Timer::Autosave => self.autosave(),
                Timer::Symbols => self.scan_symbols(),
                Timer::Fs => self.files_changed_on_disk(),
                Timer::Caret => self.caret_settled(),
                Timer::Halting => self.live_halted(true),
                Timer::Retry => self.flush_pending(),
                Timer::Restart => self.later.push_back(Later::Restart),
                Timer::Disk => self.refresh_live_disk(),
                Timer::Log => self.publish_live(false),
            }
        }
    }

    pub fn after(&mut self, timer: Timer) {
        self.timers.insert(timer, Instant::now() + timer.wait());
    }

    pub fn soon(&mut self, timer: Timer) {
        self.timers
            .entry(timer)
            .or_insert(Instant::now() + timer.wait());
    }

    fn run_later(&mut self) {
        while let Some(next) = self.later.pop_front() {
            if self.closed {
                self.later.clear();
                return;
            }
            match next {
                Later::Compile(auto) => {
                    let _ = self.compile(auto);
                }
                Later::Restart => self.live_restart(),
                Later::FlushLive => self.flush_pending(),
                Later::Rescan => self.live_rescan(),
            }
        }
    }

    // MARK: - Commands

    fn command(&mut self, name: &str, args: &Value, reply: Reply) {
        match name {
            "clean" => self.clean(reply),
            "analyze" => match string_arg(args, "path").and_then(paths::rel_key) {
                Ok(path) => self.analyze(path, reply),
                Err(err) => reply.send(Err(err)),
            },
            "search" => match query(args) {
                Ok(query) => self.search(query, reply),
                Err(err) => reply.send(Err(err)),
            },
            #[cfg(test)]
            "panic" => panic!("a bug in the session"),
            _ => {
                let answer = self.answer(name, args);
                reply.send(answer);
            }
        }
    }

    fn answer(&mut self, name: &str, args: &Value) -> Result<Value, CoreError> {
        let path = || paths::rel_key(string_arg(args, "path")?);
        match name {
            "close" => return Ok(self.close()),
            #[cfg(test)]
            "state" => return Ok(self.state()),
            "set_options" => {
                if let Some(auto) = arg::<Option<bool>>(args, "autoCompile")? {
                    self.auto_compile = auto;
                }
            }
            "open_document" => self.open_document(&path()?)?,
            "close_document" => return self.close_document(&path()?),
            "composing" => {
                let (path, composing) = (path()?, arg::<bool>(args, "composing")?);
                if let Some(doc) = self.docs.get_mut(&path) {
                    doc.composing = composing;
                    if !composing && doc.dirty() {
                        self.after(Timer::Autosave);
                    }
                }
            }
            "save" => {
                let reporting = arg::<Option<bool>>(args, "reporting")?.unwrap_or(true);
                return Ok(json!({ "saved": self.save_edits(reporting)? }));
            }
            "resolve" => return self.resolve(&path()?, string_arg(args, "answer")?),
            "compile" => self.compile(arg::<Option<bool>>(args, "auto")?.unwrap_or(false))?,
            "stop_compile" => self.stop_compile(),
            "issue" => return Ok(self.next_issue(arg(args, "next")?)),
            "choose_issue" => return Ok(self.choose_issue(arg(args, "index")?)),
            "rename" => {
                let from = paths::rel_key(string_arg(args, "from")?)?;
                return self.rename(&from, string_arg(args, "to")?);
            }
            "replace" => return self.replace(args),
            "rename_symbol" => return self.rename_symbol(args),
            "set_settings" => return self.set_settings(&arg(args, "patch")?),
            "prepare_delete" => return self.prepare_delete(&path()?),
            "deleted" => {
                let path = path()?;
                self.deleting.remove(&path);
                if arg::<Option<bool>>(args, "trashed")?.unwrap_or(true) {
                    for doc in self.docs_within(&path) {
                        self.close_doc(&doc, "deleted");
                    }
                    self.reload_tree();
                }
            }
            "live_start" => {
                let window = arg::<Option<bool>>(args, "window")?.unwrap_or(false);
                return Ok(self.live_start_asked(window));
            }
            "live_stop" => {
                self.live_stop();
                return Ok(self.live_state());
            }
            "live_log" => self.show_live_log(arg(args, "shown")?),
            "live_view" => self.live_view(arg(args, "first")?, arg(args, "last")?),
            "live_caret" => self.live_caret(path()?, arg(args, "offset")?),
            _ => {
                let unknown = format!("Unknown command: session_{name}");
                return Err(CoreError::not_found(unknown));
            }
        }
        Ok(Value::Null)
    }

    #[cfg(test)]
    fn state(&self) -> Value {
        let docs: Vec<Value> = self
            .docs
            .values()
            .map(|doc| {
                let mut state = doc.state();
                state["dirty"] = doc.dirty().into();
                state["conflict"] = json!(doc.asking);
                state
            })
            .collect();
        let mut build = self.build_state();
        build["queued"] = self.builds.queued.is_some().into();
        json!({
            "documents": docs,
            "build": build,
            "live": self.live_state(),
            "autoCompile": self.auto_compile,
        })
    }

    fn close(&mut self) -> Value {
        let saved = self.flush_all(false).unwrap_or(false);
        self.stop_compile();
        self.closed = true;
        self.live_stop();
        lock(&self.shared).clear();
        json!({ "saved": saved })
    }

    // MARK: - Documents

    fn open_document(&mut self, path: &str) -> Result<(), CoreError> {
        let path = &analyze::disk_spelling(&self.root, path).unwrap_or_else(|| path.to_owned());
        if self.docs.contains_key(path) {
            return Ok(());
        }
        let (disk, stamp) = read_disk(&paths::safe_path(&self.root, path)?)?;
        let (text, newline) = disk.ok_or_else(|| CoreError::bad_request(NOT_UTF8))?;
        let id = self.next_doc;
        self.next_doc += 1;
        let symbols = Arc::clone(&self.symbols);
        let document = Document::new(id, path, &text, self.tx.clone(), symbols);
        let doc = Doc {
            doc: document.clone(),
            path: path.to_owned(),
            saved: 0,
            force: false,
            disk_text: Some(text),
            newline,
            disk_stamp: stamp,
            conflict: None,
            asking: None,
            held: false,
            error: None,
            reload: None,
            composing: false,
            issues: Vec::new(),
            shown: Value::Null,
        };
        self.docs.insert(path.to_owned(), doc);
        self.by_id.insert(id, path.to_owned());
        lock(&self.shared).insert(path.to_owned(), document);
        self.publish_doc(path);
        self.mark_issues();
        self.live_whole(path);
        Ok(())
    }

    fn close_document(&mut self, path: &str) -> Result<Value, CoreError> {
        let closed = self.flush(Some(path), true)?;
        if closed {
            self.close_doc(path, "closed");
        }
        Ok(json!({ "closed": closed }))
    }

    fn close_doc(&mut self, path: &str, reason: &str) {
        if let Some(doc) = self.docs.remove(path) {
            self.by_id.remove(&doc.doc.id());
            lock(&self.shared).remove(path);
            self.emit("document_closed", json!({ "path": path, "reason": reason }));
        }
    }

    fn edited(&mut self, doc: u64, version: u64, start: u32, length: u32, text: &str) {
        let Some(path) = self.by_id.get(&doc).cloned() else {
            return;
        };
        self.text_changed(&path);
        self.publish_doc(&path);
        self.after(Timer::Autosave);
        self.live_edited(&path, version, start, length, text);
    }

    fn reloaded(&mut self, doc: u64, version: u64) {
        let Some(path) = self.by_id.get(&doc).cloned() else {
            return;
        };
        self.text_changed(&path);
        self.after(Timer::Symbols);
        let Some(doc) = self.docs.get_mut(&path) else {
            return;
        };
        doc.saved = version;
        let reason = doc.reload.take();
        if reason == Some(Reload::Revert) {
            // A save under way when the change came may have written over it.
            doc.force = true;
        }
        self.publish_doc(&path);
        self.live_whole(&path);
        match reason {
            Some(Reload::Revert) => {
                if self.save_doc(&path, true, false).unwrap_or(false) && self.auto_compile {
                    self.later.push_back(Later::Compile(true));
                }
            }
            Some(Reload::Disk) if self.auto_compile => self.later.push_back(Later::Compile(true)),
            _ => {}
        }
    }

    fn text_changed(&mut self, path: &str) {
        self.edits += 1;
        self.last_edits.insert(path.to_owned(), self.edits);
        self.clear_issues(path);
        self.mark_outdated();
    }

    pub fn publish_doc(&mut self, path: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        let state = doc.state();
        if state != doc.shown {
            doc.shown = state.clone();
            self.emit("document", state);
        }
    }

    // MARK: - Saving

    fn autosave(&mut self) {
        let mut ok = true;
        for path in self.dirty_paths() {
            ok &= self.save_doc(&path, false, true).unwrap_or(false);
        }
        if ok && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
    }

    fn docs_within(&self, dir: &str) -> Vec<String> {
        let docs = self.docs.keys();
        docs.filter(|p| within(p, dir)).cloned().collect()
    }

    fn dirty_paths(&self) -> Vec<String> {
        let docs = self.docs.values();
        docs.filter(|doc| doc.dirty())
            .map(|doc| doc.path.clone())
            .collect()
    }

    /// Ok(false): not written, and not to be (a conflict, or a reload or deletion under way).
    ///
    /// The disk is looked at under the project's lock first: another app's write that the
    /// watcher hasn't told of yet is taken as the watcher would take it, not written over.
    fn save_doc(&mut self, path: &str, reporting: bool, autosave: bool) -> Result<bool, CoreError> {
        for _ in 0..2 {
            let deleting = self.deleting.iter().any(|entry| within(path, entry));
            let Some(doc) = self.docs.get_mut(path) else {
                return Ok(true);
            };
            if !doc.dirty() {
                return Ok(true);
            }
            if doc.reload.is_some() || deleting || doc.asking.is_some() || autosave && doc.composing
            {
                return Ok(false);
            }
            if let Some(kind) = doc.conflict {
                if reporting {
                    self.ask(path, kind);
                }
                return Ok(false);
            }
            let (text, version) = doc.doc.snapshot();
            let file = doc.newline.written(&text);
            let written = self.service.with_project(&self.project, |root| {
                let abs = paths::safe_write_path(root, path)?;
                if !as_left(&abs, doc.disk_stamp, doc.disk_text.as_deref()) {
                    return Ok(None);
                }
                projects::write_creating(&abs, file.as_bytes()).map(Some)
            });
            let result = match written {
                Ok(None) => {
                    self.check_disk(path);
                    continue;
                }
                Ok(Some(stamp)) => {
                    (doc.disk_text, doc.disk_stamp) = (Some(lf(text)), Some(stamp));
                    (doc.saved, doc.force, doc.held, doc.error) = (version, false, false, None);
                    self.after(Timer::Symbols);
                    self.emit("saved", json!({ "path": path }));
                    Ok(true)
                }
                Err(err) => {
                    doc.error = Some(err.message.clone());
                    Err(err)
                }
            };
            self.publish_doc(path);
            return result;
        }
        Ok(false)
    }

    pub fn flush_all(&mut self, reporting: bool) -> Result<bool, CoreError> {
        self.timers.remove(&Timer::Autosave);
        self.flush(None, reporting)
    }

    fn flush(&mut self, only: Option<&str>, reporting: bool) -> Result<bool, CoreError> {
        let mut failure = None;
        for _ in 0..3 {
            let mut dirty = self.dirty_paths();
            dirty.retain(|path| only.is_none_or(|only| only == path));
            if dirty.is_empty() {
                break;
            }
            let mut all = true;
            for path in dirty {
                match self.save_doc(&path, reporting, false) {
                    Ok(saved) => all &= saved,
                    Err(err) => {
                        all = false;
                        failure.get_or_insert(err);
                    }
                }
            }
            if !all {
                return match failure {
                    Some(err) if reporting => Err(err),
                    _ => Ok(false),
                };
            }
        }
        Ok(true)
    }

    fn save_edits(&mut self, reporting: bool) -> Result<bool, CoreError> {
        let edited = !self.dirty_paths().is_empty();
        let saved = self.flush_all(reporting)?;
        if saved && edited && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        Ok(saved)
    }

    // MARK: - Conflicts

    fn ask(&mut self, path: &str, kind: Conflict) {
        if let Some(doc) = self.docs.get_mut(path) {
            doc.asking = Some(kind);
            self.emit("conflict", json!({ "path": path, "kind": kind }));
            self.publish_doc(path);
        }
    }

    fn resolve(&mut self, path: &str, answer: &str) -> Result<Value, CoreError> {
        let doc = self
            .docs
            .get_mut(path)
            .ok_or_else(|| CoreError::not_found("The document isn't open"))?;
        let Some(kind) = doc.asking.or(doc.conflict) else {
            return Ok(Value::Null);
        };
        match (kind, answer) {
            (_, "cancel") => (doc.asking, doc.held) = (None, true),
            (Conflict::Changed, "save") => {
                (doc.asking, doc.conflict, doc.force) = (None, None, true);
            }
            (Conflict::Changed, "revert") | (Conflict::Gone, "save") => {
                (doc.asking, doc.conflict) = (None, None);
            }
            (Conflict::Gone, "close") => {
                self.close_doc(path, "closed");
                return Ok(Value::Null);
            }
            _ => {
                return Err(CoreError::bad_request(format!(
                    "Can't answer “{answer}” here"
                )));
            }
        }
        self.publish_doc(path);
        match answer {
            "save" => Ok(json!({ "saved": self.save_edits(true)? })),
            "revert" => {
                match self.docs[path].disk_text.clone() {
                    Some(text) => self.request_reload(path, &text, Reload::Revert),
                    None => self.close_doc(path, "gone"),
                }
                Ok(Value::Null)
            }
            _ => Ok(Value::Null),
        }
    }

    fn request_reload(&mut self, path: &str, text: &str, reason: Reload) {
        if let Some(doc) = self.docs.get_mut(path) {
            doc.reload = Some(reason);
            self.emit(
                "document_reload",
                json!({ "path": path, "text": text, "reason": reason }),
            );
        }
    }

    // MARK: - Changes on disk

    fn files_changed_on_disk(&mut self) {
        let changes = std::mem::take(&mut self.fs_pending);
        let docs: Vec<String> = self.docs.keys().cloned().collect();
        let meaning = watch::classify(&self.root, &changes, &self.tree, &docs);
        for path in &meaning.docs {
            self.check_disk(path);
        }
        let others: Vec<&String> = meaning
            .listed
            .iter()
            .filter(|p| !self.docs.contains_key(*p))
            .collect();
        let scan = |path: &&String| matches!(file_kind(path), "tex" | "bib");
        if meaning.tree || others.iter().any(scan) {
            self.after(Timer::Symbols);
        }
        if !others.is_empty() {
            self.emit("files_changed", json!({ "paths": others }));
        }
        if self.live.active() {
            self.live.disk_paths.extend(meaning.listed.iter().cloned());
        }
        if meaning.tree || meaning.settings {
            self.reload_tree();
        }
        if self.live.active() && !self.live.disk_paths.is_empty() {
            self.after(Timer::Disk);
        }
    }

    fn check_disk(&mut self, path: &str) {
        let abs = self.root.join(path);
        if !abs.exists() {
            return self.file_gone(path);
        }
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        if doc.conflict == Some(Conflict::Gone) {
            doc.conflict = None;
        }
        if as_left(&abs, doc.disk_stamp, doc.disk_text.as_deref()) {
            return;
        }
        let Ok((disk, stamp)) = read_disk(&abs) else {
            return;
        };
        doc.disk_stamp = stamp;
        let Some((text, newline)) = disk else {
            doc.disk_text = None;
            if !doc.dirty() {
                return self.close_doc(path, "gone");
            }
            if doc.conflict.replace(Conflict::Changed).is_none() {
                self.ask(path, Conflict::Changed);
            }
            return;
        };
        doc.newline = newline;
        if doc.disk_text.as_deref() == Some(text.as_str()) {
            return;
        }
        doc.disk_text = Some(text.clone());
        if doc.dirty() {
            if doc.conflict.replace(Conflict::Changed).is_none() {
                self.ask(path, Conflict::Changed);
            }
            return;
        }
        self.request_reload(path, &text, Reload::Disk);
    }

    fn file_gone(&mut self, path: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        if !doc.dirty() {
            return self.close_doc(path, "gone");
        }
        doc.disk_stamp = None;
        if doc.conflict.replace(Conflict::Gone) != Some(Conflict::Gone) {
            self.ask(path, Conflict::Gone);
        }
    }

    fn reload_tree(&mut self) {
        let Ok(tree) = projects::file_tree(&self.root) else {
            return;
        };
        let index = TreeIndex::of(&tree);
        if index == self.tree {
            return;
        }
        self.tree = index;
        self.after(Timer::Symbols);
        self.emit("tree", json!({ "tree": tree }));
        self.live_files_changed();
    }

    // MARK: - Symbols

    /// Without the project's lock: every write replaces a file in one rename, so a scan reads
    /// each file whole, old or new.
    fn scan_symbols(&mut self) {
        self.symbols_seq += 1;
        let (seq, root, tx) = (self.symbols_seq, self.root.clone(), self.tx.clone());
        let (facts, docs) = (Arc::clone(&self.facts), Arc::clone(&self.shared));
        let mut files: Vec<String> = self.tree.files.iter().cloned().collect();
        files.sort_unstable();
        tokio::task::spawn_blocking(move || {
            let symbols = projects::scan_symbols(&root, &facts, &texts(&docs));
            let symbols = symbols.map(|symbols| Symbols { files, ..symbols });
            let _ = tx.send(Msg::Symbols(seq, symbols));
        });
    }

    fn symbols_done(&mut self, seq: u64, result: Result<Symbols, CoreError>) {
        let Ok(symbols) = result else { return };
        if seq != self.symbols_seq {
            return;
        }
        *self.symbols.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(symbols);
    }

    // MARK: - Analysis

    /// Worked out beside the session, which goes on with its other commands. An analysis
    /// asked for earlier keeps no outline over it.
    fn analyze(&mut self, path: String, reply: Reply) {
        self.analyses += 1;
        let (seq, root) = (self.analyses, self.root.clone());
        let (docs, outline) = (Arc::clone(&self.shared), Arc::clone(&self.outline));
        let facts = Arc::clone(&self.facts);
        tokio::task::spawn_blocking(move || {
            let main = settings::read_settings(&root).main_file;
            let class = paths::rel_key(&main).ok().and_then(|main| {
                let open = lock(&docs).get(&main).cloned();
                match open {
                    Some(doc) => doc.with(|source| source.document_class()),
                    None => facts.at(&root, &main)?.class.clone(),
                }
            });
            let analysis = analyze::analyze_project(&root, &facts, &main, &path, class.as_ref());
            let answer = out(&analysis);
            let mut kept = lock(&outline);
            if seq > kept.seq {
                (kept.seq, kept.headings) = (seq, analysis.outline);
            }
            drop(kept);
            reply.send(answer);
        });
    }

    // MARK: - Search and replace

    /// Worked out beside the session, as an analysis is: it reads every text file.
    fn search(&self, query: Query, reply: Reply) {
        let (root, docs) = (self.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            let hits = projects::search_project(&root, &query, &texts(&docs), SEARCH_LIMIT);
            reply.send(hits.and_then(|hits| out(projects::search_groups(hits))));
        });
    }

    fn replace(&self, args: &Value) -> Result<Value, CoreError> {
        let (query, to) = (query(args)?, string_arg(args, "replacement")?);
        let files = arg::<Option<Vec<String>>>(args, "files")?;
        let open = self.texts_to_edit("replaced")?;
        let chosen = |rel: &str| {
            let listed = files.as_ref();
            projects::is_text(rel) && listed.is_none_or(|files| files.iter().any(|f| f == rel))
        };
        self.edit_project(&open, &chosen, &|_, text| query.places(text), to)
    }

    /// A label's or citation's definitions and every `\ref` or `\cite` kin's key that names it,
    /// one key of a list alone.
    fn rename_symbol(&self, args: &Value) -> Result<Value, CoreError> {
        let (kind, noun) = match string_arg(args, "kind")? {
            "label" => (SymbolKind::Label, "label"),
            "citation" => (SymbolKind::Citation, "citation"),
            _ => {
                return Err(CoreError::bad_request(
                    "Only a label or a citation is renamed",
                ));
            }
        };
        let (from, to) = (string_arg(args, "from")?, string_arg(args, "to")?);
        if to.is_empty() || to.contains(|c: char| "{}%\\,".contains(c) || c.is_whitespace()) {
            return Err(CoreError::bad_request(format!(
                "A {noun} can't be empty or have spaces, commas, braces, % or \\ in it."
            )));
        }
        let open = self.texts_to_edit("renamed")?;
        let symbols = projects::scan_symbols(
            &self.root,
            &self.facts,
            &open
                .iter()
                .map(|(path, text, _)| (path.clone(), text.clone()))
                .collect(),
        )?;
        let defines = |name: &str| {
            let mut files = symbols.by_file.values();
            files.any(|facts| definitions(facts, kind).iter().any(|n| n.name == name))
        };
        if !defines(from) {
            return Err(CoreError::not_found(format!(
                "No {noun} “{from}” is defined."
            )));
        }
        if defines(to) {
            return Err(CoreError::conflict(format!(
                "A {noun} “{to}” exists already."
            )));
        }
        let tex = |rel: &str| matches!(file_kind(rel), "tex" | "bib");
        let found =
            |rel: &str, text: &str| places_of(&Facts::read(text, file_kind(rel)), kind, from);
        self.edit_project(&open, &tex, &found, to)
    }

    /// The open documents' paths, text and versions, unless one has a change on disk still to
    /// settle, when nothing is edited, as nothing is saved.
    fn texts_to_edit(&self, done: &str) -> Result<Vec<(String, String, u64)>, CoreError> {
        let docs = self.docs.values();
        let unsettled =
            |doc: &&Doc| doc.conflict.is_some() || doc.asking.is_some() || doc.reload.is_some();
        if let Some(doc) = docs.clone().find(unsettled) {
            return Err(CoreError::conflict(format!(
                "“{}” changed on disk, so nothing was {done}. Keep your edits or the disk’s first, then try again.",
                doc.path
            )));
        }
        let text = |doc: &Doc| {
            let (text, version) = doc.doc.snapshot();
            (doc.path.clone(), text, version)
        };
        Ok(docs.map(text).collect())
    }

    /// `to` in place of what `found` finds in each file `chosen` takes, given its text with line
    /// feeds alone. An open document isn't written: its edits are answered against its version,
    /// for the host to apply as one edit that the session saves as any other, and the answer
    /// holds one document's. The other files are read again, written and counted under the
    /// project's lock, but for those on their way to the Trash.
    fn edit_project(
        &self,
        open: &[(String, String, u64)],
        chosen: &dyn Fn(&str) -> bool,
        found: &dyn Fn(&str, &str) -> Vec<Place>,
        to: &str,
    ) -> Result<Value, CoreError> {
        let open = open.iter().filter(|(path, ..)| chosen(path));
        let mut edits: Vec<Value> = open
            .filter_map(|(path, text, version)| {
                let edits = projects::edits(&Text::new(text), &found(path, text), to);
                (!edits.is_empty())
                    .then(|| json!({ "path": path, "version": version, "edits": edits }))
            })
            .collect();
        if edits.len() > 1 {
            return Err(CoreError::conflict(
                "Only one open document can be edited at once: close the others first.",
            ));
        }
        let deleting = |rel: &str| self.deleting.iter().any(|entry| within(rel, entry));
        let others = |rel: &str| chosen(rel) && !self.docs.contains_key(rel) && !deleting(rel);
        let written = self.service.with_project(&self.project, |root| {
            projects::replace_in_files(root, &others, found, to)
        })?;
        Ok(json!({ "edits": edits.pop(), "written": written }))
    }

    // MARK: - Files

    fn rename(&mut self, from: &str, to: &str) -> Result<Value, CoreError> {
        if !self.save_edits(true)? {
            return Ok(Value::Null);
        }
        let (renamed, main) = self.service.with_project(&self.project, |root| {
            let main = settings::read_settings(root).main_file;
            let renamed = projects::rename_entry(root, from, to)?;
            self.preview.stop(root)?;
            Ok((renamed, main))
        })?;
        self.live_follow();
        let (from, to) = (renamed.from.as_str(), renamed.to.as_str());
        // Names compare without case, so a rename only in case leaves the entry itself at the
        // new name: that one moves rather than closes.
        for path in self.docs_within(to) {
            if !within(&path, from) {
                self.close_doc(&path, "gone");
            }
        }
        for old in self.docs_within(from) {
            let new = format!("{to}{}", paths::after_entry(&old, from).expect("within"));
            let mut doc = self.docs.remove(&old).expect("listed");
            doc.path.clone_from(&new);
            doc.doc.moved(&new);
            doc.shown = Value::Null;
            self.by_id.insert(doc.doc.id(), new.clone());
            {
                let mut shared = lock(&self.shared);
                shared.remove(&old);
                shared.insert(new.clone(), doc.doc.clone());
            }
            self.docs.insert(new.clone(), doc);
            if let Some(edit) = self.last_edits.remove(&old) {
                self.last_edits.insert(new.clone(), edit);
            }
            self.emit("document_renamed", json!({ "from": old, "to": new }));
            self.publish_doc(&new);
        }
        self.reload_tree();
        if renamed.main_file != main {
            self.main_file_changed();
        }
        let mut answer = out(renamed)?;
        answer["ui"] = out(settings::read_ui(&self.root))?;
        Ok(answer)
    }

    fn set_settings(&mut self, patch: &Value) -> Result<Value, CoreError> {
        let (updated, main_changed) = self.service.with_project(&self.project, |root| {
            let main = settings::read_settings(root).main_file;
            let updated = settings::write_settings(root, patch)?;
            let main_changed = updated.main_file != main;
            if main_changed {
                self.preview.stop(root)?;
            }
            Ok((updated, main_changed))
        })?;
        if main_changed {
            self.main_file_changed();
        } else if self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        out(updated)
    }

    fn main_file_changed(&mut self) {
        self.reload_tree();
        self.live_follow();
        let building = self.builds.compiling;
        self.stop_compile();
        if self.auto_compile || building {
            self.later.push_back(Later::Compile(self.auto_compile));
        }
    }

    /// Saved first, so no autosave can make the file again, and held until `deleted`.
    fn prepare_delete(&mut self, path: &str) -> Result<Value, CoreError> {
        if !self.flush_all(true)? || !self.dirty_paths().is_empty() {
            return Ok(json!({ "ready": false }));
        }
        let main = settings::read_settings(&self.root).main_file;
        if paths::after_entry(&main, path).is_some() {
            return Err(CoreError::conflict(MAIN_FILE_TRASH));
        }
        self.deleting.insert(path.to_owned());
        Ok(json!({ "ready": true }))
    }
}

/// What `facts` defines as a label, or as a citation (a `\bibitem` or a .bib entry's key).
fn definitions(facts: &Facts, kind: SymbolKind) -> &[Named] {
    if kind == SymbolKind::Label {
        &facts.labels
    } else {
        &facts.citations
    }
}

/// Where `facts` defines `name` as a `kind`, and where a `\ref` or `\cite` kin names it, in order.
fn places_of(facts: &Facts, kind: SymbolKind, name: &str) -> Vec<Place> {
    let defined = definitions(facts, kind).iter().filter(|n| n.name == name);
    let used = facts
        .uses
        .iter()
        .filter(|u| u.kind == kind && u.name == name);
    let mut places: Vec<Place> = defined
        .map(|n| n.place)
        .chain(used.map(|u| u.place))
        .collect();
    places.sort_by_key(|place| (place.line, place.column));
    places
}

fn query(args: &Value) -> Result<Query, CoreError> {
    let option = |key| arg::<Option<bool>>(args, key).map(Option::unwrap_or_default);
    let text = string_arg(args, "query")?;
    Ok(Query::new(text, option("matchCase")?, option("wholeWord")?))
}

/// The open documents' text as the editor has it, each taken without holding the others.
fn texts(docs: &Mutex<HashMap<String, Document>>) -> HashMap<String, String> {
    let docs = lock(docs).clone();
    docs.into_iter()
        .map(|(path, doc)| (path, doc.snapshot().0))
        .collect()
}

/// A volume that keeps whole seconds could give a same-length write in the same second
/// that stamp: there the text tells.
fn as_left(abs: &Path, stamp: Option<Stamp>, text: Option<&str>) -> bool {
    let now = fs::metadata(abs).ok().map(|meta| Stamp::of(&meta));
    match (stamp, now) {
        (Some(stamp), Some(now)) if stamp == now => {
            stamp.modified % 1_000_000_000 != 0
                || fs::read(abs)
                    .is_ok_and(|bytes| String::from_utf8(bytes).ok().map(lf).as_deref() == text)
        }
        (stamp, now) => stamp.is_none() && now.is_none(),
    }
}

/// None for a file that isn't UTF-8, whose bytes a save would change; the stamp is from
/// before the read, so a write meanwhile reads again at the next look.
fn read_disk(path: &Path) -> Result<(Option<DiskText>, Option<Stamp>), CoreError> {
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    let disk = String::from_utf8(fs::read(path)?).ok().map(|text| {
        let newline = Newline::of(&text);
        (lf(text), newline)
    });
    Ok((disk, stamp))
}

type DiskText = (String, Newline);

/// A document holds `\n` alone, as an editor needs; a save writes the file's own ending.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Newline {
    Lf,
    CrLf,
    Cr,
}

impl Newline {
    pub fn of(text: &str) -> Self {
        let Some(at) = text.find(['\r', '\n']) else {
            return Self::Lf;
        };
        match &text.as_bytes()[at..] {
            [b'\r', b'\n', ..] => Self::CrLf,
            [b'\r', ..] => Self::Cr,
            _ => Self::Lf,
        }
    }

    pub fn written(self, text: &str) -> Cow<'_, str> {
        let ending = match self {
            Self::Lf if !text.contains('\r') => return Cow::Borrowed(text),
            Self::Lf => return Cow::Owned(lf(text.to_owned())),
            Self::CrLf => "\r\n",
            Self::Cr => "\r",
        };
        Cow::Owned(lf(text.to_owned()).replace('\n', ending))
    }
}
