//! One project session's task: its documents, saves, builds and the file
//! watcher's news, handled one message at a time, so no two of them race.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, RwLock};

use notify::RecommendedWatcher;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

use super::live::Live;
use super::watch::{self, Change, TreeIndex};
use super::{Document, Engine, Msg, Timings};
use crate::atomic::Stamp;
use crate::compile::CompileResult;
use crate::events::Emitter;
use crate::logparse::LogItem;
use crate::projects::{self, Symbols};
use crate::service::{Service, arg, string_arg};
use crate::{CoreError, lock, paths, settings};

const MAIN_FILE_TRASH: &str = "Choose a different main file before moving this to the Trash.";

pub(crate) struct Setup {
    pub id: u64,
    pub project: String,
    pub root: PathBuf,
    pub service: Arc<Service>,
    pub engine: Arc<dyn Engine>,
    pub events: Emitter,
    pub tx: mpsc::UnboundedSender<Msg>,
    pub docs: Arc<Mutex<HashMap<String, Document>>>,
    pub timings: Timings,
    pub auto_compile: bool,
}

pub(crate) struct Opened {
    pub pdf: Option<String>,
    pub tree: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Conflict {
    /// Another app changed the file while it has unsaved edits here.
    Changed,
    /// The file was moved or deleted while it has unsaved edits here.
    Gone,
}

impl Conflict {
    fn name(self) -> &'static str {
        match self {
            Conflict::Changed => "changed",
            Conflict::Gone => "gone",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
    disk_text: Option<String>,
    /// While a stat still gives it, a change told of is the session's own save, or none.
    disk_stamp: Option<Stamp>,
    /// Asked about once; until answered, no save writes over the other app's change.
    changed: bool,
    /// Asked about once; until answered, no save puts the file back.
    gone: bool,
    asking: Option<Conflict>,
    /// Cancel in a conflict: not saved, and the autosave stays quiet.
    held: bool,
    error: Option<String>,
    /// A `document_reload` the host has yet to apply: nothing is saved meanwhile.
    reload: Option<Reload>,
    composing: bool,
    issues: Vec<Value>,
    shown: Value,
}

impl Doc {
    pub fn dirty(&self) -> bool {
        self.force || self.doc.version() != self.saved
    }

    fn state(&self) -> Value {
        json!({
            "path": self.path,
            "dirty": self.dirty(),
            "error": self.error,
            "conflict": self.asking.map(Conflict::name),
            "held": self.held,
        })
    }
}

#[derive(Default)]
struct Build {
    compiling: bool,
    queued: Option<bool>,
    stop: bool,
    auto: bool,
    built: u64,
    saved: bool,
}

pub(crate) enum Later {
    Compile(bool),
    /// Start live preview again; `ended`: because it ended by itself.
    Restart {
        ended: bool,
    },
    FlushLive,
    Rescan,
}

type Reply = oneshot::Sender<Result<Value, CoreError>>;

pub(crate) struct Actor {
    pub id: u64,
    project: String,
    pub root: PathBuf,
    service: Arc<Service>,
    pub engine: Arc<dyn Engine>,
    events: Emitter,
    pub tx: mpsc::UnboundedSender<Msg>,
    shared: Arc<Mutex<HashMap<String, Document>>>,
    pub t: Timings,
    pub docs: BTreeMap<String, Doc>,
    by_id: HashMap<u64, String>,
    next_doc: u64,
    symbols: Arc<RwLock<Arc<Symbols>>>,
    symbols_seq: u64,
    symbols_at: Option<Instant>,
    symbols_sent: Option<Value>,
    edits: u64,
    /// The edit each path last had, kept for the session's life: a document closed since
    /// isn't marked with a build's issues on lines that may have moved.
    last_edits: HashMap<String, u64>,
    result_edits: u64,
    build_pdf: bool,
    outdated: bool,
    pub auto_compile: bool,
    build: Build,
    issues: Vec<LogItem>,
    error_count: usize,
    chosen: Option<usize>,
    autosave_at: Option<Instant>,
    fs_pending: Vec<Change>,
    fs_at: Option<Instant>,
    pub tree: TreeIndex,
    tree_json: Value,
    _watcher: Option<RecommendedWatcher>,
    deleting: Option<String>,
    clean_waiting: Option<Reply>,
    cleaning: Option<(Reply, bool, u64)>,
    shown_build: Value,
    pub live: Live,
    pub later: VecDeque<Later>,
    pub closed: bool,
}

impl Actor {
    pub fn new(setup: Setup) -> Result<Self, CoreError> {
        let tree = projects::file_tree(&setup.root)?;
        let watcher = setup
            .timings
            .watch
            .then(|| watch::watch(&setup.root, setup.tx.clone()))
            .flatten();
        let build_pdf = settings::compiled_pdf_path(&setup.root).is_ok_and(|pdf| pdf.is_file());
        let empty = Symbols {
            citations: Vec::new(),
            labels: Vec::new(),
        };
        let mut actor = Actor {
            id: setup.id,
            project: setup.project,
            root: setup.root,
            service: setup.service,
            engine: setup.engine,
            events: setup.events,
            tx: setup.tx,
            shared: setup.docs,
            t: setup.timings,
            docs: BTreeMap::new(),
            by_id: HashMap::new(),
            next_doc: 1,
            symbols: Arc::new(RwLock::new(Arc::new(empty))),
            symbols_seq: 0,
            symbols_at: Some(Instant::now()),
            symbols_sent: None,
            edits: 0,
            last_edits: HashMap::new(),
            result_edits: 0,
            build_pdf,
            outdated: false,
            auto_compile: setup.auto_compile,
            build: Build::default(),
            issues: Vec::new(),
            error_count: 0,
            chosen: None,
            autosave_at: None,
            fs_pending: Vec::new(),
            fs_at: None,
            tree: TreeIndex::of(&tree),
            tree_json: serde_json::to_value(&tree).unwrap_or_default(),
            _watcher: watcher,
            deleting: None,
            clean_waiting: None,
            cleaning: None,
            shown_build: Value::Null,
            live: Live::default(),
            later: VecDeque::new(),
            closed: false,
        };
        if actor.auto_compile && !build_pdf {
            actor.later.push_back(Later::Compile(true));
        }
        Ok(actor)
    }

    pub fn opened(&self) -> Opened {
        let pdf = settings::compiled_pdf_path(&self.root)
            .ok()
            .filter(|pdf| self.build_pdf && pdf.is_file());
        Opened {
            pdf: pdf.map(|pdf| pdf.to_string_lossy().into_owned()),
            tree: self.tree_json.clone(),
        }
    }

    pub async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Msg>) {
        loop {
            self.run_later().await;
            if self.closed {
                break;
            }
            let message = match self.next_deadline() {
                Some(at) => tokio::select! {
                    message = rx.recv() => message,
                    () = tokio::time::sleep_until(at) => {
                        self.fire().await;
                        continue;
                    }
                },
                None => rx.recv().await,
            };
            match message {
                Some(message) => self.handle(message).await,
                None => break,
            }
        }
        self.live_reset();
    }

    pub fn emit(&self, kind: &str, mut fields: Value) {
        if let Value::Object(map) = &mut fields {
            map.insert("type".into(), kind.into());
            map.insert("session".into(), self.id.into());
        }
        self.events.send(fields);
    }

    async fn handle(&mut self, message: Msg) {
        match message {
            Msg::Edited {
                doc,
                version,
                start,
                length,
                text,
            } => self.edited(doc, version, start, length, text).await,
            Msg::Reloaded { doc, version } => self.reloaded(doc, version),
            Msg::Command { name, args, reply } => self.command(&name, &args, reply).await,
            Msg::BuildDone(result) => self.build_done(result),
            Msg::Cleaned(result) => self.cleaned(result),
            Msg::Symbols(seq, result) => self.symbols_done(seq, result),
            Msg::LiveNews(seq, news) => self.live_news(seq, news),
            Msg::Fs(changes) => {
                self.fs_pending.extend(changes);
                self.fs_at.get_or_insert(Instant::now() + self.t.settle);
            }
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        let live = &self.live;
        [
            self.autosave_at,
            self.symbols_at,
            self.fs_at,
            live.halting_at,
            live.settle.as_ref().map(|(at, _)| *at),
            live.retry_at,
            live.restart_at,
            live.disk_at,
        ]
        .into_iter()
        .flatten()
        .min()
    }

    async fn fire(&mut self) {
        let now = Instant::now();
        let due = |at: Option<Instant>| at.is_some_and(|at| at <= now);
        if due(self.autosave_at) {
            self.autosave_at = None;
            self.autosave();
        }
        if due(self.symbols_at) {
            self.symbols_at = None;
            self.scan_symbols();
        }
        if due(self.fs_at) {
            self.fs_at = None;
            self.files_changed_on_disk();
        }
        if due(self.live.halting_at) {
            self.live.halting_at = None;
            self.live.halted = true;
            self.publish_live(false);
        }
        if due(self.live.settle.as_ref().map(|(at, _)| *at)) {
            self.caret_settled();
        }
        if due(self.live.retry_at) {
            self.live.retry_at = None;
            self.flush_pending().await;
        }
        if due(self.live.restart_at) {
            self.live.restart_at = None;
            self.later.push_back(Later::Restart { ended: false });
        }
        if due(self.live.disk_at) {
            self.live.disk_at = None;
            self.refresh_live_disk().await;
        }
    }

    async fn run_later(&mut self) {
        while let Some(next) = self.later.pop_front() {
            if self.closed {
                self.later.clear();
                return;
            }
            match next {
                Later::Compile(auto) => {
                    let _ = self.compile(auto);
                }
                Later::Restart { ended } => self.live_restart(ended).await,
                Later::FlushLive => self.flush_pending().await,
                Later::Rescan => self.live_rescan().await,
            }
        }
    }

    // MARK: - Commands

    async fn command(&mut self, name: &str, args: &Value, reply: Reply) {
        if name == "clean" {
            return self.clean(reply);
        }
        let answer = self.answer(name, args).await;
        let _ = reply.send(answer);
    }

    async fn answer(&mut self, name: &str, args: &Value) -> Result<Value, CoreError> {
        let path = || paths::rel_key(string_arg(args, "path")?);
        match name {
            "close" => Ok(self.close().await),
            "state" => Ok(self.state()),
            "set_options" => {
                if let Some(auto) = arg::<Option<bool>>(args, "autoCompile")? {
                    self.auto_compile = auto;
                }
                Ok(Value::Null)
            }
            "open_document" => self.open_document(&path()?),
            "close_document" => {
                let discard = arg::<Option<bool>>(args, "discard")?.unwrap_or(false);
                self.close_document(&path()?, discard)
            }
            "composing" => {
                let (path, composing) = (path()?, arg::<bool>(args, "composing")?);
                if let Some(doc) = self.docs.get_mut(&path) {
                    doc.composing = composing;
                    if !composing && doc.dirty() {
                        self.autosave_at = Some(Instant::now() + self.t.autosave);
                    }
                }
                Ok(Value::Null)
            }
            "save" => {
                let reporting = arg::<Option<bool>>(args, "reporting")?.unwrap_or(true);
                Ok(json!({ "saved": self.save_edits(reporting)? }))
            }
            "resolve" => self.resolve(&path()?, string_arg(args, "answer")?),
            "compile" => {
                let auto = arg::<Option<bool>>(args, "auto")?.unwrap_or(false);
                self.compile(auto).map(|_| Value::Null)
            }
            "stop_compile" => {
                self.stop_compile();
                Ok(Value::Null)
            }
            "issue" => Ok(self.next_issue(arg(args, "next")?)),
            "choose_issue" => {
                self.chosen = arg(args, "index")?;
                Ok(self.chosen_issue())
            }
            "rename" => {
                let (from, to) = (
                    paths::rel_key(string_arg(args, "from")?)?,
                    string_arg(args, "to")?,
                );
                self.rename(&from, to).await
            }
            "set_settings" => self.set_settings(&arg(args, "patch")?).await,
            "prepare_delete" => self.prepare_delete(&path()?),
            "deleted" => {
                let path = path()?;
                self.deleting = None;
                if arg::<Option<bool>>(args, "trashed")?.unwrap_or(true) {
                    let inside: Vec<String> = self
                        .docs
                        .keys()
                        .filter(|p| within(p, &path))
                        .cloned()
                        .collect();
                    for doc in inside {
                        self.close_doc(&doc, "deleted");
                    }
                    self.reload_tree();
                }
                Ok(Value::Null)
            }
            "live_start" => {
                self.live.intent += 1;
                self.live.window = arg::<Option<bool>>(args, "window")?.unwrap_or(false);
                self.live_start(false).await;
                Ok(self.live_state())
            }
            "live_stop" => {
                self.live_cancel_work();
                self.live_stop().await;
                Ok(self.live_state())
            }
            "live_view" => {
                self.live_view(arg(args, "first")?, arg(args, "last")?);
                Ok(Value::Null)
            }
            "live_caret" => {
                self.live_caret(path()?, arg(args, "offset")?);
                Ok(Value::Null)
            }
            "live_status" => self.live_status(),
            _ => Err(CoreError::not_found(format!(
                "Unknown command: session_{name}"
            ))),
        }
    }

    fn state(&self) -> Value {
        let docs: Vec<Value> = self.docs.values().map(Doc::state).collect();
        json!({
            "documents": docs,
            "build": self.build_state(),
            "live": self.live_state(),
            "autoCompile": self.auto_compile,
        })
    }

    async fn close(&mut self) -> Value {
        let saved = self.flush_all(false).unwrap_or(false);
        self.stop_compile();
        self.closed = true;
        self.live_cancel_work();
        self.live_stop().await;
        lock(&self.shared).clear();
        json!({ "saved": saved })
    }

    // MARK: - Documents

    fn open_document(&mut self, path: &str) -> Result<Value, CoreError> {
        if let Some(doc) = self.docs.get(path) {
            return Ok(json!({ "text": doc.doc.snapshot().0 }));
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
            disk_text: Some(text.clone()),
            disk_stamp: stamp,
            changed: false,
            gone: false,
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
        Ok(json!({ "text": text }))
    }

    fn close_document(&mut self, path: &str, discard: bool) -> Result<Value, CoreError> {
        if !self.docs.contains_key(path) {
            return Ok(json!({ "closed": true }));
        }
        if !discard {
            for _ in 0..3 {
                if !self.save_doc(path, true, false)? {
                    return Ok(json!({ "closed": false }));
                }
                if !self.docs.get(path).is_some_and(Doc::dirty) {
                    break;
                }
            }
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

    async fn edited(&mut self, doc: u64, version: u64, start: u32, length: u32, text: String) {
        let Some(path) = self.by_id.get(&doc).cloned() else {
            return;
        };
        self.edits += 1;
        self.last_edits.insert(path.clone(), self.edits);
        self.clear_issues(&path);
        if self.has_pdf() && !self.outdated {
            self.outdated = true;
            self.publish_build();
        }
        self.publish_doc(&path);
        self.autosave_at = Some(Instant::now() + self.t.autosave);
        self.live_edited(&path, version, start, length, &text).await;
    }

    fn reloaded(&mut self, doc: u64, version: u64) {
        let Some(path) = self.by_id.get(&doc).cloned() else {
            return;
        };
        self.edits += 1;
        self.last_edits.insert(path.clone(), self.edits);
        let Some(doc) = self.docs.get_mut(&path) else {
            return;
        };
        doc.saved = version;
        let reason = doc.reload.take();
        if reason == Some(Reload::Revert) {
            // Written back: a save under way when the change came may have written over it.
            doc.force = true;
        }
        self.clear_issues(&path);
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
        let dirty: Vec<String> = self.dirty_paths();
        let mut ok = true;
        for path in dirty {
            ok &= self.save_doc(&path, false, true).unwrap_or(false);
        }
        if ok && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
    }

    fn dirty_paths(&self) -> Vec<String> {
        let docs = self.docs.values();
        docs.filter(|doc| doc.dirty())
            .map(|doc| doc.path.clone())
            .collect()
    }

    /// Writes one document. Ok(false): not written, and not to be (a conflict,
    /// asked about when `reporting`, or a reload or deletion under way).
    fn save_doc(&mut self, path: &str, reporting: bool, autosave: bool) -> Result<bool, CoreError> {
        let deleting = self
            .deleting
            .as_deref()
            .is_some_and(|dir| within(path, dir));
        let Some(doc) = self.docs.get_mut(path) else {
            return Ok(true);
        };
        if !doc.dirty() {
            return Ok(true);
        }
        if doc.reload.is_some() || deleting || doc.asking.is_some() || autosave && doc.composing {
            return Ok(false);
        }
        let conflict = if doc.gone {
            Some(Conflict::Gone)
        } else if doc.changed {
            Some(Conflict::Changed)
        } else {
            None
        };
        if let Some(kind) = conflict {
            if reporting {
                self.ask(path, kind);
            }
            return Ok(false);
        }
        let (text, version) = doc.doc.snapshot();
        let written = self.service.write_text(&self.project, path, &text);
        let doc = self.docs.get_mut(path).expect("the document is open");
        let result = match written {
            Ok(stamp) => {
                (doc.disk_text, doc.disk_stamp) = (Some(text), Some(stamp));
                (doc.saved, doc.force, doc.held, doc.error) = (version, false, false, None);
                self.symbols_at = Some(Instant::now() + self.t.symbols);
                self.emit("saved", json!({ "path": path }));
                Ok(true)
            }
            Err(err) => {
                doc.error = Some(err.message.clone());
                Err(err)
            }
        };
        self.publish_doc(path);
        result
    }

    /// Writes every document with unsaved edits; typing during a write is written too.
    fn flush_all(&mut self, reporting: bool) -> Result<bool, CoreError> {
        self.autosave_at = None;
        let mut failure = None;
        for _ in 0..3 {
            let dirty = self.dirty_paths();
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
                return failure.map_or(
                    Ok(false),
                    |err| if reporting { Err(err) } else { Ok(false) },
                );
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
            self.emit("conflict", json!({ "path": path, "kind": kind.name() }));
            self.publish_doc(path);
        }
    }

    fn resolve(&mut self, path: &str, answer: &str) -> Result<Value, CoreError> {
        let doc = self
            .docs
            .get_mut(path)
            .ok_or_else(|| CoreError::not_found("The document isn't open"))?;
        let kind = doc.asking.or(if doc.gone {
            Some(Conflict::Gone)
        } else if doc.changed {
            Some(Conflict::Changed)
        } else {
            None
        });
        let Some(kind) = kind else {
            return Ok(Value::Null);
        };
        let disk_text = doc.disk_text.clone();
        match (kind, answer) {
            (_, "cancel") => (doc.asking, doc.held) = (None, true),
            // The autosave was held while asking, or the edits were saved before the other app's change.
            (Conflict::Changed, "save") => {
                (doc.asking, doc.changed, doc.force) = (None, false, true)
            }
            (Conflict::Changed, "revert") => (doc.asking, doc.changed) = (None, false),
            (Conflict::Gone, "save") => (doc.asking, doc.gone) = (None, false),
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
                if let Some(text) = disk_text {
                    self.request_reload(path, text, Reload::Revert);
                }
                Ok(Value::Null)
            }
            _ => Ok(Value::Null),
        }
    }

    fn request_reload(&mut self, path: &str, text: String, reason: Reload) {
        if let Some(doc) = self.docs.get_mut(path) {
            doc.reload = Some(reason);
            let reason = if reason == Reload::Revert {
                "revert"
            } else {
                "disk"
            };
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
            self.live.disk_at = Some(Instant::now() + self.t.live_follow);
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
        doc.gone = false;
        // A volume that keeps whole seconds could give a same-length write in the same second this stamp.
        let exact = doc.disk_stamp.filter(|stamp| stamp.nanoseconds != 0);
        if exact.is_some() && fs::metadata(&abs).ok().map(|meta| Stamp::of(&meta)) == exact {
            return;
        }
        let Ok((text, stamp)) = read_disk(&abs) else {
            return;
        };
        doc.disk_stamp = stamp;
        if doc.disk_text.as_deref() == Some(text.as_str()) {
            return;
        }
        doc.disk_text = Some(text.clone());
        if doc.dirty() {
            let asked = doc.changed;
            doc.changed = true;
            if !asked {
                self.ask(path, Conflict::Changed);
            }
            return;
        }
        self.request_reload(path, text, Reload::Disk);
    }

    fn file_gone(&mut self, path: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        doc.changed = false;
        if !doc.dirty() {
            return self.close_doc(path, "gone");
        }
        let asked = doc.gone;
        doc.gone = true;
        if !asked {
            self.ask(path, Conflict::Gone);
        }
    }

    fn reload_tree(&mut self) {
        let Ok(tree) = projects::file_tree(&self.root) else {
            return;
        };
        let json = serde_json::to_value(&tree).unwrap_or_default();
        if json == self.tree_json {
            return;
        }
        self.tree = TreeIndex::of(&tree);
        self.tree_json = json.clone();
        self.emit("tree", json!({ "tree": json }));
        self.live_files_changed();
    }

    // MARK: - Symbols

    fn scan_symbols(&mut self) {
        self.symbols_seq += 1;
        let (seq, service, root, tx) = (
            self.symbols_seq,
            Arc::clone(&self.service),
            self.root.clone(),
            self.tx.clone(),
        );
        tokio::task::spawn_blocking(move || {
            let _ = tx.send(Msg::Symbols(seq, service.scan_symbols(&root)));
        });
    }

    fn symbols_done(&mut self, seq: u64, result: Result<Symbols, CoreError>) {
        let Ok(symbols) = result else { return };
        if seq != self.symbols_seq {
            return;
        }
        let json = serde_json::to_value(&symbols).unwrap_or_default();
        if self.symbols_sent.as_ref() == Some(&json) {
            return;
        }
        *self.symbols.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(symbols);
        self.emit("symbols", json.clone());
        self.symbols_sent = Some(json);
    }

    // MARK: - Builds

    fn has_pdf(&self) -> bool {
        self.build_pdf || self.live.document_seen
    }

    pub fn live_previewing(&self) -> bool {
        self.live.active() || self.live.restart_at.is_some()
    }

    /// A request during a build queues one more. An automatic build waits
    /// while live preview runs. Err: a save someone asked for failed.
    pub fn compile(&mut self, auto: bool) -> Result<(), CoreError> {
        if self.closed || auto && self.live_previewing() {
            return Ok(());
        }
        if self.build.compiling {
            self.build.queued = Some(self.build.queued.unwrap_or(true) && auto);
            self.publish_build();
            return Ok(());
        }
        // Before the save, so a second request queues instead of racing this one.
        (self.build.compiling, self.build.stop, self.build.auto) = (true, false, auto);
        self.publish_build();
        let saved = self.flush_all(!auto);
        self.build.saved = saved.as_ref().is_ok_and(|saved| *saved);
        self.build.built = self.edits;
        if self.build.saved && !self.build.stop && !(auto && self.live_previewing()) {
            let (build, tx) = (self.engine.compile(self.root.clone()), self.tx.clone());
            tokio::spawn(async move {
                let _ = tx.send(Msg::BuildDone(build.await));
            });
        } else {
            self.finish_build();
        }
        saved.map(|_| ())
    }

    pub fn stop_compile(&mut self) {
        if self.build.compiling {
            (self.build.queued, self.build.stop) = (None, true);
            self.engine.stop_compile(&self.root);
            self.publish_build();
        }
    }

    fn build_done(&mut self, result: Result<CompileResult, CoreError>) {
        let result = result.unwrap_or_else(|err| CompileResult {
            ok: false,
            stopped: false,
            duration_ms: 0,
            pdf: None,
            pdf_changed: false,
            errors: vec![LogItem::error(err.message)],
            warnings: Vec::new(),
            log: String::new(),
        });
        if !self.closed {
            if result.pdf.is_some() {
                self.build_pdf = true;
                self.outdated = self.edits != self.build.built;
            }
            let before = self.error_count;
            self.issues = result
                .errors
                .iter()
                .chain(&result.warnings)
                .cloned()
                .collect();
            self.error_count = result.errors.len();
            self.result_edits = self.build.built;
            self.chosen = None;
            self.mark_issues();
            let auto = self.build.auto;
            let announce = !auto || self.error_count != before;
            let fields = json!({ "auto": auto, "announce": announce, "outdated": self.outdated, "result": result });
            self.emit("build_finished", fields);
        }
        self.finish_build();
    }

    fn finish_build(&mut self) {
        self.build.compiling = false;
        // After a failed save the queued build would only build stale text.
        let again = if self.build.saved && !self.closed {
            self.build.queued
        } else {
            None
        };
        self.build.queued = None;
        self.publish_build();
        if let Some(reply) = self.clean_waiting.take() {
            self.start_clean(reply);
        }
        if let Some(auto) = again {
            self.later.push_back(Later::Compile(auto));
        }
    }

    fn build_state(&self) -> Value {
        json!({
            "compiling": self.build.compiling,
            "auto": self.build.compiling && self.build.auto,
            "queued": self.build.queued.is_some(),
            "outdated": self.outdated,
        })
    }

    pub fn publish_build(&mut self) {
        let state = self.build_state();
        if state != self.shown_build {
            self.shown_build = state.clone();
            self.emit("build", state);
        }
    }

    fn clean(&mut self, reply: Reply) {
        self.stop_compile();
        if self.build.compiling {
            self.clean_waiting = Some(reply);
        } else {
            self.start_clean(reply);
        }
    }

    fn start_clean(&mut self, reply: Reply) {
        self.cleaning = Some((reply, self.live.active(), self.live.intent));
        let (clean, tx) = (self.engine.clean(self.root.clone()), self.tx.clone());
        tokio::spawn(async move {
            let _ = tx.send(Msg::Cleaned(clean.await));
        });
    }

    fn cleaned(&mut self, result: Result<(), CoreError>) {
        let Some((reply, live, intent)) = self.cleaning.take() else {
            return;
        };
        self.keep_live(live, intent, result.is_ok());
        if result.is_ok() && !self.closed {
            (self.build_pdf, self.outdated) = (false, false);
            (self.issues, self.error_count, self.chosen) = (Vec::new(), 0, None);
            self.mark_issues();
            self.publish_build();
            self.emit("build_cleaned", json!({}));
            if self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
        let _ = reply.send(result.map(|()| Value::Null));
    }

    // MARK: - Issues

    fn clear_issues(&mut self, path: &str) {
        if let Some(doc) = self.docs.get_mut(path)
            && !doc.issues.is_empty()
        {
            doc.issues.clear();
            self.emit("issues", json!({ "path": path, "lines": [] }));
        }
    }

    /// The build's issues on the lines of each document not edited since it started.
    fn mark_issues(&mut self) {
        let mut changed = Vec::new();
        for (path, doc) in &mut self.docs {
            let last_edit = self.last_edits.get(path).copied().unwrap_or(0);
            let lines = if last_edit <= self.result_edits {
                issue_lines(&self.issues, path)
            } else {
                Vec::new()
            };
            if lines != doc.issues {
                doc.issues = lines.clone();
                changed.push(json!({ "path": path, "lines": lines }));
            }
        }
        for issues in changed {
            self.emit("issues", issues);
        }
    }

    fn chosen_issue(&self) -> Value {
        let Some(index) = self.chosen.filter(|i| *i < self.issues.len()) else {
            return Value::Null;
        };
        json!({ "index": index, "issue": self.issues[index] })
    }

    /// The next (or previous) issue with a place in a file, round to the first.
    fn next_issue(&mut self, next: bool) -> Value {
        let places: Vec<usize> = (0..self.issues.len())
            .filter(|&i| self.issues[i].file.is_some())
            .collect();
        let (Some(&first), Some(&last)) = (places.first(), places.last()) else {
            return Value::Null;
        };
        let place = match self.chosen {
            Some(chosen) if next => places
                .iter()
                .copied()
                .find(|&p| p > chosen)
                .unwrap_or(first),
            Some(chosen) => places
                .iter()
                .copied()
                .rev()
                .find(|&p| p < chosen)
                .unwrap_or(last),
            None if next => first,
            None => last,
        };
        self.chosen = Some(place);
        self.chosen_issue()
    }

    // MARK: - Files

    async fn rename(&mut self, from: &str, to: &str) -> Result<Value, CoreError> {
        if !self.save_edits(true)? {
            return Ok(Value::Null);
        }
        let main = settings::read_settings(&self.root).main_file;
        let (live, intent) = (self.live.active(), self.live.intent);
        let args = json!({ "id": self.project, "from": from, "to": to });
        let renamed = self.service.call("rename_entry", &args).await;
        self.keep_live(live, intent, renamed.is_ok());
        let renamed = renamed?;
        let (from, to) = (
            renamed["from"].as_str().unwrap_or(from).to_owned(),
            renamed["to"].as_str().unwrap_or(to).to_owned(),
        );
        // Whatever was open at the new name is stale: the name was free.
        let stale: Vec<String> = self
            .docs
            .keys()
            .filter(|p| within(p, &to))
            .cloned()
            .collect();
        for path in stale {
            self.close_doc(&path, "gone");
        }
        let moved: Vec<String> = self
            .docs
            .keys()
            .filter(|p| within(p, &from))
            .cloned()
            .collect();
        for old in moved {
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
        if renamed["mainFile"].as_str() != Some(main.as_str()) {
            self.main_file_changed();
        }
        Ok(renamed)
    }

    async fn set_settings(&mut self, patch: &Value) -> Result<Value, CoreError> {
        let main = settings::read_settings(&self.root).main_file;
        let (live, intent) = (self.live.active(), self.live.intent);
        let args = json!({ "id": self.project, "patch": patch });
        let updated = self.service.call("set_settings", &args).await;
        let main_changed = updated
            .as_ref()
            .is_ok_and(|s| s["mainFile"].as_str() != Some(main.as_str()));
        if main_changed {
            self.keep_live(live, intent, true);
            self.main_file_changed();
        } else if updated.is_ok() && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        updated
    }

    fn main_file_changed(&mut self) {
        let building = self.build.compiling;
        self.stop_compile();
        if self.live.active() {
            self.live.restart_at = Some(Instant::now() + self.t.live_follow);
        }
        if self.auto_compile || building {
            self.later.push_back(Later::Compile(self.auto_compile));
        }
    }

    /// The core ends a live preview when a rename or a new main file changes what it shows;
    /// one live before starts again after, unless stopped or started meanwhile.
    fn keep_live(&mut self, live: bool, intent: u64, changed: bool) {
        if live && changed && intent == self.live.intent && !self.closed {
            self.live.restart_at = Some(Instant::now() + self.t.live_follow);
        }
    }

    /// Saved first, so no autosave can make the file again; the main file stays.
    fn prepare_delete(&mut self, path: &str) -> Result<Value, CoreError> {
        if !self.flush_all(true)? || !self.dirty_paths().is_empty() {
            return Ok(json!({ "ready": false }));
        }
        let main = settings::read_settings(&self.root).main_file;
        if within(&main, path) {
            return Err(CoreError::conflict(MAIN_FILE_TRASH));
        }
        self.deleting = Some(path.to_owned());
        Ok(json!({ "ready": true }))
    }
}

/// The build's issues on `path`'s lines, as the editor marks them: the
/// first issue of a line with the rest after it.
fn issue_lines(issues: &[LogItem], path: &str) -> Vec<Value> {
    let mut lines: BTreeMap<u32, (&LogItem, Vec<String>)> = BTreeMap::new();
    for item in issues.iter().rev() {
        let (Some(file), Some(line)) = (&item.file, item.line) else {
            continue;
        };
        if file != path {
            continue;
        }
        let others = lines.remove(&line).map(|(later, mut others)| {
            others.insert(0, later.message.clone());
            others
        });
        lines.insert(line, (item, others.unwrap_or_default()));
    }
    let lines = lines.into_iter();
    lines
        .map(|(line, (item, others))| {
            json!({
                "line": line,
                "error": item.kind == "error",
                "message": item.message,
                "short": item.short,
                "command": item.command,
                "others": others,
            })
        })
        .collect()
}

fn within(path: &str, dir: &str) -> bool {
    path.strip_prefix(dir)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

/// A file's text, and its stamp from before the read: a write meanwhile gives
/// another stamp at the next look, which reads it again.
fn read_disk(path: &Path) -> Result<(String, Option<Stamp>), CoreError> {
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    Ok((crate::lossy_string(fs::read(path)?), stamp))
}
