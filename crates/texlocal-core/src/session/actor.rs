//! One project session's task: documents, saves, builds and the file watcher's news,
//! handled one message at a time, so no two of them race.

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::fs;
use std::io::ErrorKind;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use notify::RecommendedWatcher;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch as signal};
use tokio::time::Instant;

use super::build::Builds;
use super::live::Live;
use super::navigate::Trail;
use super::watch::{self, Change, TreeIndex};
use super::{Document, Engine, Msg, Outline, Preview, Reply, Sessions};
use crate::analyze::{self, Facts, Place};
use crate::logparse::{Fix, LogItem};
use crate::paths::{self, Project, within};
use crate::projects::{self, History, Query, Symbols, file_kind};
use crate::service::{Service, arg, out, string_arg};
use crate::settings;
use crate::stamp::Stamp;
use crate::syntax::{self, SymbolKind, Text, TextEdit};
use crate::{CoreError, checks, lf, lock, newline, packages, tex};

const MAIN_FILE_TRASH: &str = "Choose a different main file before moving this to the Trash.";
const STOPPED_SAVED: &str = "Saving stopped after an internal error. What was typed so far is saved: close the project and open it again to go on.";
const STOPPED_UNSAVED: &str = "Saving stopped after an internal error, and this file’s edits couldn’t be saved. Copy them out, then close the project and open it again.";
pub(super) const ONE_DOCUMENT: &str =
    "Only one open document can be edited at once: close the others first.";
const NOT_UTF8: &str =
    "It isn't UTF-8 text, and saving it here would change it. Convert it to UTF-8 to edit it.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Conflict {
    Changed,
    Gone,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
    /// The file's own line ending, which a save writes.
    newline: &'static str,
    /// While a stat still gives it, a change told of is the session's own save, or none.
    disk_stamp: Option<Stamp>,
    /// Asked about once; until answered, no save writes over the other app's change.
    conflict: Option<Conflict>,
    asking: Option<Conflict>,
    held: bool,
    error: Option<String>,
    /// The `document_reload`s the host has yet to apply, in order: nothing is saved meanwhile.
    reloads: VecDeque<Reload>,
    composing: bool,
    pub issues: Vec<Value>,
    pub live_issues: Vec<Value>,
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

/// Work a step leaves for after it, so none of it runs inside another.
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
    Issues,
}

impl Timer {
    fn wait(self) -> Duration {
        Duration::from_millis(match self {
            Self::Autosave => 700,
            Self::Symbols | Self::Caret => 150,
            // FSEvents' latency: changes this close together are taken together.
            Self::Fs => 250,
            Self::Retry => 750,
            // A brace or a command half typed is an error for a moment at every other key.
            Self::Halting | Self::Issues => 1000,
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
    pub project_id: String,
    pub project: Project,
    pub service: Arc<Service>,
    pub engine: Arc<dyn Engine>,
    pub preview: Arc<dyn Preview>,
    events: std::sync::mpsc::Sender<Value>,
    pub tx: mpsc::UnboundedSender<Msg>,
    pub shared: Arc<Mutex<HashMap<String, Document>>>,
    pub docs: BTreeMap<String, Doc>,
    next_doc: u64,
    symbols: Arc<RwLock<Arc<Symbols>>>,
    symbols_seq: u64,
    pub facts: Arc<analyze::Files>,
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
    pub history: Arc<Mutex<History>>,
    pub trail: Trail,
    closed: bool,
}

impl Actor {
    pub fn new(
        sessions: &Sessions,
        id: u64,
        project_id: String,
        project: Project,
        tx: mpsc::UnboundedSender<Msg>,
        auto_compile: bool,
    ) -> Result<(Self, Value), CoreError> {
        let tree = projects::file_tree(&project)?;
        let watcher = sessions
            .watch
            .then(|| watch::watch(&project.root, tx.clone()))
            .flatten();
        let settings = settings::read_settings(&project.settings);
        let pdf = settings.output(&project.build, "pdf").ok();
        let pdf = pdf.filter(|pdf| pdf.is_file());
        let opened = json!({
            "name": project.name(),
            "root": project.root.to_string_lossy(),
            "pdf": pdf.as_ref().map(|pdf| pdf.to_string_lossy()),
            "tree": out(&tree)?,
            "settings": settings,
            "ui": settings::read_ui(&project.ui),
        });
        let mut builds = Builds::default();
        builds.pdf = pdf.is_some();
        let mut later = VecDeque::new();
        if auto_compile && !builds.pdf {
            later.push_back(Later::Compile(true));
        }
        let history = sessions.service.history(&project);
        let actor = Self {
            id,
            project_id,
            project,
            service: Arc::clone(&sessions.service),
            engine: Arc::clone(&sessions.engine),
            preview: Arc::clone(&sessions.preview),
            events: sessions.hub.queue.clone(),
            tx,
            shared: Arc::default(),
            docs: BTreeMap::new(),
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
            later,
            history,
            trail: Trail::default(),
            closed: false,
        };
        actor.snapshot_soon();
        Ok((actor, opened))
    }

    pub async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Msg>) {
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
                return self.stopped(&mut rx);
            }
            if self.closed {
                return;
            }
            let deadline = self.timers.values().min().copied();
            let sleep = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now));
            let waiting_for_tex = self.builds.waiting_for_tex;
            woken = tokio::select! {
                message = rx.recv() => match message {
                    Some(message) => Some(Wake::Message(message)),
                    None => return,
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
            let error = if doc.dirty() {
                STOPPED_UNSAVED
            } else {
                STOPPED_SAVED
            };
            let mut state = doc.state();
            state["error"] = error.into();
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
        let _ = self.events.send(fields);
    }

    fn handle(&mut self, message: Msg) {
        match message {
            Msg::Changed { doc, version, edit } => self.changed(doc, version, edit),
            Msg::Command { name, args, reply } => self.command(&name, &args, reply),
            Msg::BuildDone(result) => self.build_done(result),
            Msg::Cleaned(result) => self.cleaned(result),
            Msg::Symbols { seq, edits, result } => self.symbols_done(seq, edits, result),
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
                Timer::Issues => self.live_issues_settled(),
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
                Later::Restart => self.live_start(),
                Later::FlushLive => self.flush_pending(),
                Later::Rescan => self.live_rescan(),
            }
        }
    }

    // MARK: - Commands

    fn command(&mut self, name: &str, args: &Value, reply: Reply) {
        match name {
            "clean" => self.clean(reply),
            "fix" => self.fix(args, reply),
            "analyze" => match string_arg(args, "path").and_then(paths::rel_key) {
                Ok(path) => self.analyze(path, reply),
                Err(err) => reply.send(Err(err)),
            },
            "search" => match query(args) {
                Ok(query) => self.search(query, reply),
                Err(err) => reply.send(Err(err)),
            },
            "history_list" | "history_save" | "history_compare" => {
                self.history_command(name, args, reply);
            }
            "usages" | "quick_help" => {
                let path = string_arg(args, "path").and_then(paths::rel_key);
                match path.and_then(|path| Ok((path, arg::<u32>(args, "offset")?))) {
                    Ok((path, offset)) if name == "usages" => self.usages(&path, offset, reply),
                    Ok((path, offset)) => self.quick_help(&path, offset, reply),
                    Err(err) => reply.send(Err(err)),
                }
            }
            "quick_open" => match string_arg(args, "query") {
                Ok(query) => self.quick_open(query.to_owned(), reply),
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
            "rescan" => self.handle(Msg::Fs(vec![Change {
                path: self.project.root.clone(),
                structural: true,
            }])),
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
            "navigate" => return self.navigate(args),
            "back" => return self.step(args, true),
            "forward" => return self.step(args, false),
            "replace" => return self.replace(args),
            "rename_symbol" => return self.rename_symbol(args),
            "history_restore" => return self.history_restore(args),
            "set_settings" => return self.set_settings(&arg(args, "patch")?, true),
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
            "live_start" => return Ok(self.live_start_asked()),
            "live_stop" => return Ok(self.live_stop_asked()),
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
        let doc = |doc: &Doc| {
            let mut state = doc.state();
            state["dirty"] = doc.dirty().into();
            state["conflict"] = json!(doc.asking);
            state
        };
        let mut build = self.build_state();
        build["queued"] = self.builds.queued.is_some().into();
        json!({
            "documents": self.docs.values().map(doc).collect::<Vec<_>>(),
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
        let path =
            &analyze::disk_spelling(&self.project.root, path).unwrap_or_else(|| path.to_owned());
        if self.docs.contains_key(path) {
            return Ok(());
        }
        let (disk, stamp) = read_disk(&paths::safe_path(&self.project.root, path)?)?;
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
            reloads: VecDeque::new(),
            composing: false,
            issues: Vec::new(),
            live_issues: Vec::new(),
            shown: Value::Null,
        };
        self.docs.insert(path.to_owned(), doc);
        lock(&self.shared).insert(path.to_owned(), document);
        self.publish_doc(path);
        self.mark_issues();
        self.live_issues_opened(path);
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
        if self.docs.remove(path).is_some() {
            lock(&self.shared).remove(path);
            self.emit("document_closed", json!({ "path": path, "reason": reason }));
        }
    }

    /// A document's text changed: by an edit, or to a reload's text.
    fn changed(&mut self, id: u64, version: u64, edit: Option<TextEdit>) {
        let Some(doc) = self.docs.values().find(|doc| doc.doc.id() == id) else {
            return;
        };
        let path = doc.path.clone();
        self.edits += 1;
        self.last_edits.insert(path.clone(), self.edits);
        self.clear_issues(&path);
        self.live_issues_edited(&path, edit.as_ref());
        self.mark_outdated();
        match edit {
            Some(edit) => {
                self.after(Timer::Autosave);
                self.live_edited(&path, version, &edit);
                // Typed before the reload reached the editor, which refuses it now.
                let doc = self.docs.get_mut(&path).expect("found by its id");
                if !doc.reloads.is_empty() {
                    doc.reloads.clear();
                    doc.conflict = Some(Conflict::Changed);
                    self.ask(&path, Conflict::Changed);
                }
            }
            None => self.reloaded(&path, version),
        }
    }

    fn reloaded(&mut self, path: &str, version: u64) {
        self.after(Timer::Symbols);
        let doc = self.docs.get_mut(path).expect("found by its id");
        doc.saved = version;
        let reason = doc.reloads.pop_front();
        // A save under way when the change came may have written over it.
        doc.force |= reason == Some(Reload::Revert);
        self.live_whole(path);
        match reason {
            Some(Reload::Revert) => {
                if self.save_doc(path, true, false).unwrap_or(false) && self.auto_compile {
                    self.later.push_back(Later::Compile(true));
                }
            }
            Some(Reload::Disk) if self.auto_compile => self.later.push_back(Later::Compile(true)),
            _ => {}
        }
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
        let docs = self.docs.values().filter(|doc| doc.dirty());
        docs.map(|doc| doc.path.clone()).collect()
    }

    /// On its way to the Trash, alone or in a folder.
    pub fn deleting(&self, path: &str) -> bool {
        self.deleting.iter().any(|entry| within(path, entry))
    }

    /// Ok(false): not written, and not to be (a conflict, or a reload or deletion under way).
    ///
    /// The disk is looked at under the project's lock first: another app's write that the
    /// watcher hasn't told of yet is taken as the watcher would take it, not written over.
    fn save_doc(&mut self, path: &str, reporting: bool, autosave: bool) -> Result<bool, CoreError> {
        for _ in 0..2 {
            let deleting = self.deleting(path);
            let Some(doc) = self.docs.get_mut(path) else {
                return Ok(true);
            };
            if !doc.dirty() {
                return Ok(true);
            }
            if !doc.reloads.is_empty()
                || deleting
                || doc.asking.is_some()
                || autosave && doc.composing
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
            let text = lf(text);
            let file = match doc.newline {
                "\n" => Cow::Borrowed(text.as_str()),
                ending => Cow::Owned(text.replace('\n', ending)),
            };
            let written = self.service.with_project(&self.project_id, |project| {
                let abs = paths::safe_write_path(&project.root, path)?;
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
                    (doc.disk_text, doc.disk_stamp) = (Some(text), Some(stamp));
                    (doc.saved, doc.force, doc.held, doc.error) = (version, false, false, None);
                    self.after(Timer::Symbols);
                    self.snapshot_soon();
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

    /// Text typed while a save waits for the project's lock is saved by the next round.
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

    /// In place of the text as saved, or, for a Revert, as the user chose to drop it: keys typed
    /// since then refuse it.
    fn request_reload(&mut self, path: &str, text: &str, reason: Reload) {
        if let Some(doc) = self.docs.get_mut(path) {
            let seen = match reason {
                Reload::Disk => doc.saved,
                Reload::Revert => doc.doc.version(),
            };
            doc.doc.expect_reload(seen);
            doc.reloads.push_back(reason);
            self.emit("document_reload", json!({ "path": path, "text": text }));
        }
    }

    // MARK: - Changes on disk

    fn files_changed_on_disk(&mut self) {
        let changes = std::mem::take(&mut self.fs_pending);
        let docs: Vec<String> = self.docs.keys().cloned().collect();
        let meaning = watch::classify(&self.project.root, &changes, &self.tree, &docs);
        for path in &meaning.docs {
            self.check_disk(path);
        }
        let others = meaning.listed.iter();
        let others: Vec<&String> = others.filter(|p| !self.docs.contains_key(*p)).collect();
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
        let main = self.tree.main.clone();
        if meaning.tree {
            self.reload_tree();
        }
        // Another app chose another main file: builds and Live Preview follow it as they follow
        // the app's own choice. Each fold and folder opened writes the settings too, so the
        // folder is walked again only for another mark.
        if meaning.settings {
            let chosen = settings::read_settings(&self.project.settings).main_file;
            let chosen = paths::fold_case(&chosen);
            let mut files = self.tree.files.iter();
            if files.find(|f| paths::fold_case(f) == chosen) != main.as_ref() {
                self.main_file_changed();
            }
        }
        if self.live.active() && !self.live.disk_paths.is_empty() {
            self.after(Timer::Disk);
        }
    }

    fn check_disk(&mut self, path: &str) {
        let abs = self.project.root.join(path);
        if fs::metadata(&abs).is_err_and(|err| err.kind() == ErrorKind::NotFound) {
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
        let (disk, stamp) = match read_disk(&abs) {
            Ok(read) => read,
            // An error that may pass, as a permission or another app's lock does, while saves wait.
            Err(err) => {
                if doc.dirty() {
                    doc.error = Some(err.message);
                    self.publish_doc(path);
                }
                return;
            }
        };
        doc.disk_stamp = stamp;
        if let Some((text, newline)) = &disk {
            doc.newline = *newline;
            if doc.disk_text.as_ref() == Some(text) {
                return;
            }
        }
        doc.disk_text = disk.map(|(text, _)| text);
        match (doc.disk_text.clone(), doc.dirty()) {
            (_, true) => {
                if doc.conflict.replace(Conflict::Changed).is_none() {
                    self.ask(path, Conflict::Changed);
                }
            }
            (Some(text), false) => self.request_reload(path, &text, Reload::Disk),
            (None, false) => self.close_doc(path, "gone"),
        }
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

    pub fn reload_tree(&mut self) {
        let Ok(tree) = projects::file_tree(&self.project) else {
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
        let (seq, root, tx) = (self.symbols_seq, self.project.root.clone(), self.tx.clone());
        let (facts, docs) = (Arc::clone(&self.facts), Arc::clone(&self.shared));
        let mut files: Vec<String> = self.tree.files.iter().cloned().collect();
        files.sort_unstable();
        let (service, main, edits) = (
            Arc::clone(&self.service),
            self.tree.main.clone(),
            self.edits,
        );
        tokio::task::spawn_blocking(move || {
            let symbols = projects::scan_symbols(&root, &facts, &texts(&docs));
            let installed = tex::installed(|| service.tool_paths().0);
            let result = symbols.map(|symbols| {
                let symbols = Symbols {
                    files,
                    installed,
                    ..symbols
                };
                let checks = main.map_or_else(Vec::new, |main| checks::check(&symbols, &main));
                (symbols, checks)
            });
            let _ = tx.send(Msg::Symbols { seq, edits, result });
        });
    }

    fn symbols_done(
        &mut self,
        seq: u64,
        edits: u64,
        result: Result<(Symbols, Vec<LogItem>), CoreError>,
    ) {
        if let Ok((symbols, checks)) = result
            && seq == self.symbols_seq
        {
            *self.symbols.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(symbols);
            self.checks_done(checks, edits);
        }
    }

    // MARK: - Analysis

    /// Worked out beside the session, which goes on with its other commands. An analysis
    /// asked for earlier keeps no outline over it.
    fn analyze(&mut self, path: String, reply: Reply) {
        self.analyses += 1;
        let (seq, project) = (self.analyses, self.project.clone());
        let (docs, outline) = (Arc::clone(&self.shared), Arc::clone(&self.outline));
        let facts = Arc::clone(&self.facts);
        tokio::task::spawn_blocking(move || {
            let root = &project.root;
            let main = settings::read_settings(&project.settings).main_file;
            let class = paths::rel_key(&main).ok().and_then(|main| {
                let open = lock(&docs).get(&main).cloned();
                match open {
                    Some(doc) => doc.with(|source| source.document_class()),
                    None => facts.at(root, &main)?.class.clone(),
                }
            });
            let analysis = analyze::analyze_project(root, &facts, &main, &path, class.as_ref());
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
        let (root, docs) = (self.project.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            let found = |_: &str, text: &str| query.places(text);
            let open = texts(&docs);
            let hits = projects::search_project(&root, &open, &projects::is_text, &found, 100);
            reply.send(hits.and_then(|hits| out(projects::search_groups(hits))));
        });
    }

    fn replace(&self, args: &Value) -> Result<Value, CoreError> {
        let (query, to) = (query(args)?, string_arg(args, "replacement")?);
        let open = self.texts_to_edit("replaced")?;
        let found = |_: &str, text: &str| query.places(text);
        self.edit_project("Before Replace All", &open, &projects::is_text, &found, to)
    }

    /// Where the project defines or uses the name at `offset` in the open document `path`, as
    /// a search's hits: worked out beside the session, as a search is.
    fn usages(&self, path: &str, offset: u32, reply: Reply) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(Value::Null));
        };
        let (root, docs) = (self.project.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            let own = doc.facts();
            let symbol = doc.with(|source| source.symbol_at(&own, offset));
            // A file by the project's name for it, which every input of it elsewhere resolves to.
            let named = symbol.and_then(|(kind, name, file)| match kind {
                SymbolKind::File => Some((kind, file?)),
                kind => Some((kind, name)),
            });
            let Some((kind, name)) = named else {
                return reply.send(Ok(Value::Null));
            };
            let symbols = doc.symbols();
            let found = |rel: &str, text: &str| {
                let facts = Facts::read(text, file_kind(rel));
                syntax::usages(&facts, rel, kind, &name, |file| symbols.spelt(file))
            };
            let hits = projects::search_project(&root, &texts(&docs), &tex, &found, usize::MAX);
            // As the source writes it, for a host's heading: a command has its backslash already.
            let name = match kind {
                SymbolKind::Label => format!("\\label{{{name}}}"),
                SymbolKind::Citation => format!("\\cite{{{name}}}"),
                SymbolKind::Environment => format!("\\begin{{{name}}}"),
                _ => name,
            };
            let groups = hits.map(projects::search_groups);
            reply.send(groups.map(|groups| json!({ "name": name, "groups": groups })));
        });
    }

    /// A label's or citation's definitions and every `\ref` or `\cite` kin's key that names it,
    /// one key of a list alone.
    fn rename_symbol(&self, args: &Value) -> Result<Value, CoreError> {
        let noun = string_arg(args, "kind")?;
        let kind = match noun {
            "label" => SymbolKind::Label,
            "citation" => SymbolKind::Citation,
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
        let texts = open
            .iter()
            .map(|(path, text, _)| (path.clone(), text.clone()));
        let symbols = projects::scan_symbols(&self.project.root, &self.facts, &texts.collect())?;
        let defines = |name: &str| {
            let mut files = symbols.by_file.values();
            files.any(|facts| !syntax::definitions(facts, kind, name).is_empty())
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
        let found = |rel: &str, text: &str| {
            let facts = Facts::read(text, file_kind(rel));
            syntax::usages(&facts, rel, kind, from, |_| None)
        };
        self.edit_project("Before Rename", &open, &tex, &found, to)
    }

    /// An issue's fix by its id. An install takes minutes, so it runs beside the session, as an
    /// analysis does; its password or UAC dialog cancelled answers null, nothing to do.
    fn fix(&mut self, args: &Value, reply: Reply) {
        let unknown = || CoreError::bad_request("There's no such fix.");
        let fix = string_arg(args, "id").and_then(|id| Fix::parse(id).ok_or_else(unknown));
        let edits = match fix {
            Ok(Fix::Install(file)) => {
                let (service, settings) =
                    (Arc::clone(&self.service), self.project.settings.clone());
                tokio::spawn(async move {
                    let installed = packages::install_package(&file, &service.tool_paths().0).await;
                    reply.send(match installed {
                        Err(err) if err.status == 403 => Ok(Value::Null),
                        installed => installed.map(|_| fixed(Value::Null, &settings)),
                    });
                });
                return;
            }
            Ok(Fix::AddPackage(name)) => self
                .add_package(&name)
                .map(|mut added| added["edits"].take()),
            Ok(Fix::Xelatex) => self
                .set_settings(&json!({ "engine": "xelatex" }), false)
                .map(|_| Value::Null),
            Ok(Fix::ShellEscape) => self
                .set_settings(&json!({ "shellEscape": true }), false)
                .map(|_| Value::Null),
            Err(err) => Err(err),
        };
        reply.send(edits.map(|edits| fixed(edits, &self.project.settings)));
    }

    /// `\usepackage{name}` on a line of its own where `Facts::new_package` says, unless the main
    /// file loads the package already.
    fn add_package(&self, name: &str) -> Result<Value, CoreError> {
        // As the disk spells it, which the walk compares, however the settings do.
        let main = self.tree.main.as_deref();
        let open = self.texts_to_edit("added")?;
        let found = |_: &str, text: &str| {
            let facts = Facts::read(text, "tex");
            let loaded = facts.packages.iter().any(|package| package == name);
            facts.new_package.filter(|_| !loaded).into_iter().collect()
        };
        let line = format!("\n\\usepackage{{{name}}}");
        let main = |rel: &str| Some(rel) == main;
        self.edit_project("Before Adding a Package", &open, &main, &found, &line)
    }

    /// The open documents' paths, text and versions, unless one has a change on disk still to
    /// settle, when nothing is edited, as nothing is saved.
    pub fn texts_to_edit(&self, done: &str) -> Result<Vec<(String, String, u64)>, CoreError> {
        let docs = self.docs.values();
        let unsettled =
            |doc: &&Doc| doc.conflict.is_some() || doc.asking.is_some() || !doc.reloads.is_empty();
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
    /// feeds alone, after a snapshot taken for `reason`. An open document isn't written: its edits
    /// are answered against its version, for the host to apply as one edit that the session saves
    /// as any other, and the answer holds one document's. The other files are read again, written
    /// and counted under the project's lock, but for those on their way to the Trash. The
    /// snapshot's id is answered, for a host that can't apply the edits to put the others back.
    fn edit_project(
        &self,
        reason: &'static str,
        open: &[(String, String, u64)],
        chosen: &dyn Fn(&str) -> bool,
        found: &dyn Fn(&str, &str) -> Vec<Place>,
        to: &str,
    ) -> Result<Value, CoreError> {
        let open = open.iter().filter(|(path, ..)| chosen(path));
        let mut edits: Vec<Value> = open
            .filter_map(|(path, text, version)| {
                let lines = Text::new(text).lines;
                let edit = |place: Place| TextEdit {
                    start: lines[place.line as usize - 1] + place.column,
                    length: place.length,
                    text: to.to_owned(),
                };
                let edits: Vec<TextEdit> = found(path, text).into_iter().map(edit).collect();
                (!edits.is_empty())
                    .then(|| json!({ "path": path, "version": version, "edits": edits }))
            })
            .collect();
        if edits.len() > 1 {
            return Err(CoreError::conflict(ONE_DOCUMENT));
        }
        let snapshot = self.snapshot_before(reason)?;
        let others = |rel: &str| chosen(rel) && !self.docs.contains_key(rel) && !self.deleting(rel);
        let written = self.service.with_project(&self.project_id, |project| {
            projects::replace_in_files(&project.root, &others, found, to)
        })?;
        Ok(json!({ "edits": edits.pop(), "written": written, "snapshot": snapshot }))
    }

    // MARK: - Files

    fn rename(&mut self, from: &str, to: &str) -> Result<Value, CoreError> {
        if !self.save_edits(true)? {
            return Ok(Value::Null);
        }
        let (renamed, main) = self.service.with_project(&self.project_id, |project| {
            let main = settings::read_settings(&project.settings).main_file;
            let renamed = projects::rename_entry(project, from, to)?;
            self.preview.stop(&project.root)?;
            Ok((renamed, main))
        })?;
        self.live_follow();
        let (from, to) = (renamed.from.as_str(), renamed.to.as_str());
        self.trail.moved(from, to);
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
            let mut shared = lock(&self.shared);
            shared.remove(&old);
            shared.insert(new.clone(), doc.doc.clone());
            drop(shared);
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
        answer["ui"] = out(settings::read_ui(&self.project.ui))?;
        Ok(answer)
    }

    /// With `build`, an automatic build follows; after a fix the host builds, once it has applied
    /// the fix's edits.
    fn set_settings(&mut self, patch: &Value, build: bool) -> Result<Value, CoreError> {
        let (updated, main_changed) = self.service.with_project(&self.project_id, |project| {
            let main = settings::read_settings(&project.settings).main_file;
            let updated = settings::write_settings(&project.settings, patch)?;
            let main_changed = updated.main_file != main;
            if main_changed {
                self.preview.stop(&project.root)?;
            }
            Ok((updated, main_changed))
        })?;
        if main_changed {
            self.main_file_changed();
        } else if build && self.auto_compile {
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
        let main = settings::read_settings(&self.project.settings).main_file;
        if paths::after_entry(&main, path).is_some() {
            return Err(CoreError::conflict(MAIN_FILE_TRASH));
        }
        self.deleting.insert(path.to_owned());
        Ok(json!({ "ready": true }))
    }
}

/// The settings always, so a host shows the engine and toggles as a fix leaves them.
fn fixed(edits: Value, settings: &Path) -> Value {
    json!({ "edits": edits, "settings": settings::read_settings(settings) })
}

/// The files a symbol is defined and used in.
fn tex(rel: &str) -> bool {
    matches!(file_kind(rel), "tex" | "bib")
}

fn query(args: &Value) -> Result<Query, CoreError> {
    string_arg(args, "query").map(Query::new)
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

/// The text with line feeds alone, as a document holds it, and the file's own line ending;
/// None for a file that isn't UTF-8, whose bytes a save would change. The stamp is from before
/// the read, so a write meanwhile reads again at the next look.
fn read_disk(path: &Path) -> Result<(Option<DiskText>, Option<Stamp>), CoreError> {
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    let disk = String::from_utf8(fs::read(path)?).ok().map(|text| {
        let newline = newline(&text);
        (lf(text), newline)
    });
    Ok((disk, stamp))
}

type DiskText = (String, &'static str);
