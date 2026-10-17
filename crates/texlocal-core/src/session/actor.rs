//! One project session's task: its documents, saves, builds and the file
//! watcher's news, handled one message at a time, so no two of them race.

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
use super::{Document, Engine, Msg, Outline, Preview, Reply, Sessions, Timings};
use crate::analyze;
use crate::events::Emitter;
use crate::paths::{self, within};
use crate::projects::{self, SymbolScan, Symbols, file_kind};
use crate::service::{Service, arg, out, string_arg};
use crate::settings;
use crate::stamp::Stamp;
use crate::syntax::headings;
use crate::{CoreError, lock};

const MAIN_FILE_TRASH: &str = "Choose a different main file before moving this to the Trash.";
/// Not Saved after a panic ended the session (`stopped`), for a document whose text was written,
/// and for one whose edits couldn't be.
const STOPPED_SAVED: &str = "Saving stopped after an internal error. What was typed so far is saved: close the project and open it again to go on.";
const STOPPED_UNSAVED: &str = "Saving stopped after an internal error, and this file’s edits couldn’t be saved. Copy them out, then close the project and open it again.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Conflict {
    /// Another app changed the file while it has unsaved edits here.
    Changed,
    /// The file was moved or deleted while it has unsaved edits here.
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
    /// The version the disk has, as the session last wrote or read it.
    saved: u64,
    /// Save Anyway: written though the text is the disk's.
    force: bool,
    /// The text the disk has, as the session last wrote or read it.
    disk_text: String,
    /// While a stat still gives it, a change told of is the session's own save, or none;
    /// None once the file has gone.
    disk_stamp: Option<Stamp>,
    /// Asked about once; until answered, no save writes over the other app's change
    /// or puts the file back.
    conflict: Option<Conflict>,
    /// The conflict the host is asking about.
    asking: Option<Conflict>,
    /// Cancel in a conflict: not saved, and the autosave stays quiet.
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

    /// A `document` event: what the host's Not Saved follows.
    fn state(&self) -> Value {
        json!({ "path": self.path, "error": self.error, "held": self.held })
    }
}

pub(crate) enum Later {
    Compile(bool),
    /// Start live preview again; true: because it ended by itself.
    Restart(bool),
    FlushLive,
    Rescan,
}

/// What the session waits for, each due at its time; those due together go in this order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Timer {
    /// From the last edit to the autosave.
    Autosave,
    /// From a save, or a change elsewhere, to the scan of labels and citations.
    Symbols,
    /// The folder's changes, taken together once they settle.
    Fs,
    /// A stopped run, shown as halted once it has lasted.
    Halting,
    /// The caret, told to TeXpresso where it settled.
    Caret,
    /// A whole text TeXpresso couldn't be sent, sent again.
    Retry,
    /// The preview, started again after a rename, a new main file or a file gone.
    Restart,
    /// Files changed on disk, sent to TeXpresso.
    Disk,
    /// The Live Preview Log, sent since TeX's changed.
    Log,
}

/// What woke the session's task.
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
    pub t: Timings,
    pub docs: BTreeMap<String, Doc>,
    by_id: HashMap<u64, String>,
    next_doc: u64,
    symbols: Arc<RwLock<Arc<Symbols>>>,
    symbols_seq: u64,
    /// What the last scan read; taken out while a scan runs, so one beside it starts afresh.
    symbol_scan: SymbolScan,
    pub edits: u64,
    /// The edit each path last had, kept for the session's life: a document closed since
    /// isn't marked with a build's issues on lines that may have moved.
    pub last_edits: HashMap<String, u64>,
    pub auto_compile: bool,
    pub builds: Builds,
    /// Whether the last look for TeX found it (`Service::tex_found`).
    tex: signal::Receiver<bool>,
    pub outline: Arc<Mutex<Outline>>,
    /// The analyses asked for.
    analyses: u64,
    pub timers: BTreeMap<Timer, Instant>,
    fs_pending: Vec<Change>,
    /// The listing as last read: the same files and folders make the same tree.
    pub tree: TreeIndex,
    _watcher: Option<RecommendedWatcher>,
    /// The entries on their way to the Trash (`prepare_delete`): nothing saves into them.
    deleting: BTreeSet<String>,
    pub live: Live,
    pub later: VecDeque<Later>,
    pub closed: bool,
}

impl Actor {
    /// The session numbered `id`, and the answer to its open.
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
            .timings
            .watch
            .then(|| watch::watch(&root, tx.clone()))
            .flatten();
        let settings = settings::read_settings(&root);
        let pdf = settings
            .output(&root, "pdf")
            .ok()
            .filter(|pdf| pdf.is_file());
        // All a host shows as the project opens, so it need ask for nothing first.
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
            t: sessions.timings.clone(),
            docs: BTreeMap::new(),
            by_id: HashMap::new(),
            next_doc: 1,
            symbols: Arc::default(),
            symbols_seq: 0,
            symbol_scan: SymbolScan::default(),
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

    /// Whether the session ended by a panic, which `stopped` makes good as far as it can.
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

    /// An automatic build skipped for want of TeX runs once `status` finds it.
    fn tex_changed(&mut self) {
        if *self.tex.borrow_and_update() {
            self.builds.waiting_for_tex = false;
            if self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
    }

    /// After a panic, a bug: each document's edits are written as a save would write
    /// them, the host is told that nothing more is saved, and every command waiting is
    /// answered so.
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
        if let Value::Object(map) = &mut fields {
            map.insert("type".into(), kind.into());
            map.insert("session".into(), self.id.into());
        }
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
            Msg::Symbols(seq, scan, result) => self.symbols_done(seq, scan, result),
            Msg::Live(generation, event) => self.live_event(generation, event),
            Msg::Fs(changes) => {
                self.fs_pending.extend(changes);
                let at = Instant::now() + self.t.settle;
                self.timers.entry(Timer::Fs).or_insert(at);
            }
        }
    }

    /// Each timer due, in its order: one that a timer before it changed is looked at again.
    fn fire(&mut self) {
        let now = Instant::now();
        while let Some((&timer, _)) = self.timers.iter().find(|(_, at)| **at <= now) {
            self.timers.remove(&timer);
            match timer {
                Timer::Autosave => self.autosave(),
                Timer::Symbols => self.scan_symbols(),
                Timer::Fs => self.files_changed_on_disk(),
                Timer::Halting => self.live_halted(),
                Timer::Caret => self.caret_settled(),
                Timer::Retry => self.flush_pending(),
                Timer::Restart => self.later.push_back(Later::Restart(false)),
                Timer::Disk => self.refresh_live_disk(),
                Timer::Log => self.publish_live(false),
            }
        }
    }

    /// `timer` is due `wait` from now, in place of when it was.
    pub fn after(&mut self, timer: Timer, wait: Duration) {
        self.timers.insert(timer, Instant::now() + wait);
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
                Later::Restart(ended) => self.live_restart(ended),
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
            #[cfg(test)]
            "panic" => panic!("a bug in the session"),
            _ => {
                let answer = self.answer(name, args);
                reply.send(answer);
            }
        }
    }

    /// Commands that answer something return it; the rest answer null.
    fn answer(&mut self, name: &str, args: &Value) -> Result<Value, CoreError> {
        let path = || paths::rel_key(string_arg(args, "path")?);
        match name {
            "close" => return Ok(self.close()),
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
                        self.after(Timer::Autosave, self.t.autosave);
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

    /// A snapshot, with what the events leave out.
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

    /// The editor reads the text from the document's source (`tl_source_text`), as
    /// it is once the switch to it is made.
    fn open_document(&mut self, path: &str) -> Result<(), CoreError> {
        if self.docs.contains_key(path) {
            return Ok(());
        }
        let (text, stamp) = read_disk(&paths::safe_path(&self.root, path)?)?;
        let id = self.next_doc;
        self.next_doc += 1;
        let symbols = Arc::clone(&self.symbols);
        let document = Document::new(id, &text, self.tx.clone(), symbols);
        let doc = Doc {
            doc: document.clone(),
            path: path.to_owned(),
            saved: 0,
            force: false,
            disk_text: text,
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
        if !self.docs.contains_key(path) {
            return Ok(json!({ "closed": true }));
        }
        if !self.flush(Some(path), true)? {
            return Ok(json!({ "closed": false }));
        }
        self.close_doc(path, "closed");
        Ok(json!({ "closed": true }))
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
        self.after(Timer::Autosave, self.t.autosave);
        self.live_edited(&path, version, start, length, text);
    }

    fn reloaded(&mut self, doc: u64, version: u64) {
        let Some(path) = self.by_id.get(&doc).cloned() else {
            return;
        };
        self.text_changed(&path);
        // Its labels and citations may have changed with it.
        self.after(Timer::Symbols, self.t.symbols);
        let Some(doc) = self.docs.get_mut(&path) else {
            return;
        };
        doc.saved = version;
        let reason = doc.reload.take();
        if reason == Some(Reload::Revert) {
            // Written back: a save under way when the change came may have written over it.
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

    /// `path`'s text changed, by an edit or from the disk: the build's marks on it
    /// go, and the PDF it showed is out of date.
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

    /// The open documents at `dir` or inside it.
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

    /// Writes one document. Ok(false): not written, and not to be (a conflict,
    /// asked about when `reporting`, or a reload or deletion under way).
    ///
    /// The disk is looked at under the project's lock first: another app's write
    /// that the watcher hasn't told of yet (its changes settle for 250 ms) is taken
    /// as the watcher would take it, not written over. A touch that left the text
    /// as it was leaves nothing to ask, and the write goes on at the second look.
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
            let written = self.service.with_project(&self.project, |root| {
                let abs = paths::safe_write_path(root, path)?;
                if !as_left(&abs, doc.disk_stamp, &doc.disk_text) {
                    return Ok(None);
                }
                projects::write_creating(&abs, text.as_bytes()).map(Some)
            });
            let result = match written {
                Ok(None) => {
                    self.check_disk(path);
                    continue;
                }
                Ok(Some(stamp)) => {
                    (doc.disk_text, doc.disk_stamp) = (text, Some(stamp));
                    (doc.saved, doc.force, doc.held, doc.error) = (version, false, false, None);
                    self.after(Timer::Symbols, self.t.symbols);
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

    /// Writes every document with unsaved edits; typing during a write is
    /// written too, so a build or a trash that follows has it.
    pub fn flush_all(&mut self, reporting: bool) -> Result<bool, CoreError> {
        self.timers.remove(&Timer::Autosave);
        self.flush(None, reporting)
    }

    /// Writes the documents with unsaved edits, or `only` that one, again while
    /// typing during a write leaves them unsaved.
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

    /// A save someone asked for: a build follows when it wrote anything.
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
            // The autosave was held while asking, or the edits were saved before the other app's change.
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
                let text = self.docs[path].disk_text.clone();
                self.request_reload(path, &text, Reload::Revert);
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
        // Labels and citations another app wrote reach completion too; an open
        // document's are scanned as it reloads.
        let scan = |path: &&String| matches!(file_kind(path), "tex" | "bib");
        if meaning.tree || others.iter().any(scan) {
            self.after(Timer::Symbols, self.t.symbols);
        }
        if !others.is_empty() {
            self.emit("files_changed", json!({ "paths": others }));
        }
        if self.live.active() {
            self.live.disk_paths.extend(meaning.listed.iter().cloned());
        }
        if meaning.tree {
            self.reload_tree();
        }
        if self.live.active() && !self.live.disk_paths.is_empty() {
            self.after(Timer::Disk, self.t.live_follow);
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
        // It is there, so not gone.
        if doc.conflict == Some(Conflict::Gone) {
            doc.conflict = None;
        }
        if as_left(&abs, doc.disk_stamp, &doc.disk_text) {
            return;
        }
        let Ok((text, stamp)) = read_disk(&abs) else {
            return;
        };
        doc.disk_stamp = stamp;
        if doc.disk_text == text {
            return;
        }
        doc.disk_text.clone_from(&text);
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
        // Gone as the session last saw it: Save puts it back.
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
        self.emit("tree", json!({ "tree": tree }));
        self.live_files_changed();
    }

    // MARK: - Symbols

    /// Without the project's lock: every write replaces a file in one rename,
    /// so a scan reads each file whole, old or new, and a save need not wait for it.
    fn scan_symbols(&mut self) {
        self.symbols_seq += 1;
        let (seq, root, tx) = (self.symbols_seq, self.root.clone(), self.tx.clone());
        let mut scan = std::mem::take(&mut self.symbol_scan);
        tokio::task::spawn_blocking(move || {
            let result = scan.scan(&root);
            let _ = tx.send(Msg::Symbols(seq, scan, result));
        });
    }

    fn symbols_done(&mut self, seq: u64, scan: SymbolScan, result: Result<Symbols, CoreError>) {
        self.symbol_scan = scan;
        let Ok(symbols) = result else { return };
        if seq != self.symbols_seq {
            return;
        }
        // Unchanged, the documents keep the completions they made from it.
        if **self.symbols.read().unwrap_or_else(PoisonError::into_inner) == symbols {
            return;
        }
        *self.symbols.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(symbols);
    }

    // MARK: - Analysis

    /// The document the main file reads, as `analyze::analyze_project` finds it for
    /// the file at `path`, and the levels the main file's class has, the class read
    /// from its text as the editor has it; its outline is kept for `outline_current`.
    /// Worked out beside the session, which goes on with its other commands, and
    /// answered from there; an analysis asked for earlier keeps no outline over it.
    fn analyze(&mut self, path: String, reply: Reply) {
        self.analyses += 1;
        let (seq, root) = (self.analyses, self.root.clone());
        let (docs, outline) = (Arc::clone(&self.shared), Arc::clone(&self.outline));
        tokio::task::spawn_blocking(move || {
            // Read each time: another app, or another host's `set_settings`, may have changed it.
            let main = settings::read_settings(&root).main_file;
            let open = paths::rel_key(&main)
                .ok()
                .and_then(|main| lock(&docs).get(&main).cloned());
            let main_text = match open {
                Some(doc) => Some(doc.snapshot().0),
                None => paths::safe_path(&root, &main)
                    .ok()
                    .and_then(|path| read_disk(&path).ok())
                    .map(|(text, _)| text),
            };
            let class = main_text.as_deref().and_then(headings::document_class);
            let analysis = analyze::analyze_project(&root, &main, &path, class.as_ref());
            let answer = out(&analysis);
            let mut kept = lock(&outline);
            if seq > kept.seq {
                (kept.seq, kept.headings) = (seq, analysis.outline);
            }
            drop(kept);
            reply.send(answer);
        });
    }

    // MARK: - Files

    fn rename(&mut self, from: &str, to: &str) -> Result<Value, CoreError> {
        if !self.save_edits(true)? {
            return Ok(Value::Null);
        }
        let (renamed, main) = self.service.with_project(&self.project, |root| {
            let main = settings::read_settings(root).main_file;
            let renamed = projects::rename_entry(root, from, to)?;
            // What the preview shows may have moved: it starts again after.
            self.preview.stop(root)?;
            Ok((renamed, main))
        })?;
        self.live_follow();
        let (from, to) = (renamed.from.as_str(), renamed.to.as_str());
        // Whatever was open at the new name is stale: the name was free.
        for path in self.docs_within(to) {
            self.close_doc(&path, "gone");
        }
        for old in self.docs_within(from) {
            let new = format!("{to}{}", &old[from.len()..]);
            let mut doc = self.docs.remove(&old).expect("listed");
            doc.path.clone_from(&new);
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
        // The sidebar's state, moved with the entry, so the host need not ask for it.
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
                // The preview shows the old main file: it starts again after.
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

    /// The build and the preview follow a new main file.
    fn main_file_changed(&mut self) {
        self.live_follow();
        let building = self.builds.compiling;
        self.stop_compile();
        if self.auto_compile || building {
            self.later.push_back(Later::Compile(self.auto_compile));
        }
    }

    /// Saved first, so no autosave can make the file again, and held until `deleted`;
    /// the main file stays, however the settings spell it.
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

/// Whether the file at `abs` is as the session last wrote or read it (`stamp`,
/// `text`), or gone as it was. A volume that keeps whole seconds could give a
/// same-length write in the same second that stamp: there the text tells.
fn as_left(abs: &Path, stamp: Option<Stamp>, text: &str) -> bool {
    let now = fs::metadata(abs).ok().map(|meta| Stamp::of(&meta));
    match (stamp, now) {
        (Some(stamp), Some(now)) if stamp == now => {
            stamp.nanoseconds != 0
                || fs::read(abs).is_ok_and(|bytes| crate::lossy_string(bytes) == text)
        }
        (stamp, now) => stamp.is_none() && now.is_none(),
    }
}

/// A file's text, and its stamp from before the read: a write meanwhile gives
/// another stamp at the next look, which reads it again.
fn read_disk(path: &Path) -> Result<(String, Option<Stamp>), CoreError> {
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    Ok((crate::lossy_string(fs::read(path)?), stamp))
}
