//! One project session's task: its documents, saves, builds and the file
//! watcher's news, handled one message at a time, so no two of them race.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, RwLock};

use notify::RecommendedWatcher;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

use super::live::Live;
use super::watch::{self, Change, TreeIndex};
use super::{Document, Engine, Msg, Outline, Sessions, Timings};
use crate::analyze::{self, ProjectAnalysis};
use crate::atomic::Stamp;
use crate::compile::CompileResult;
use crate::events::Emitter;
use crate::logparse::LogItem;
use crate::paths::{self, within};
use crate::projects::{self, SymbolScan, Symbols};
use crate::service::{Service, arg, out, string_arg};
use crate::settings;
use crate::syntax::{TextRange, headings};
use crate::{CoreError, lock};

const MAIN_FILE_TRASH: &str = "Choose a different main file before moving this to the Trash.";

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
    disk_text: Option<String>,
    /// While a stat still gives it, a change told of is the session's own save, or none.
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
    issues: Vec<Value>,
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

#[derive(Default)]
struct Build {
    compiling: bool,
    /// One more build asked for during this one; `Some(true)` while every request was automatic.
    queued: Option<bool>,
    auto: bool,
    /// The edit count when it began.
    built: u64,
    /// Its saves went through: else what it queued would build stale text.
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
    pub shared: Arc<Mutex<HashMap<String, Document>>>,
    pub t: Timings,
    pub docs: BTreeMap<String, Doc>,
    by_id: HashMap<u64, String>,
    next_doc: u64,
    symbols: Arc<RwLock<Arc<Symbols>>>,
    symbols_seq: u64,
    symbols_at: Option<Instant>,
    /// What the last scan read; taken out while a scan runs, so one beside it starts afresh.
    symbol_scan: SymbolScan,
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
    pub outline: Arc<Mutex<Outline>>,
    /// The analyses asked for.
    analyses: u64,
    error_count: usize,
    chosen: Option<usize>,
    autosave_at: Option<Instant>,
    fs_pending: Vec<Change>,
    fs_at: Option<Instant>,
    /// The listing as last read: the same files and folders make the same tree.
    pub tree: TreeIndex,
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
        let pdf = settings.pdf_path(&root).ok().filter(|pdf| pdf.is_file());
        // All a host shows as the project opens, so it need ask for nothing first.
        let opened = json!({
            "session": id,
            "root": root.to_string_lossy(),
            "pdf": pdf.as_ref().map(|pdf| pdf.to_string_lossy()),
            "tree": out(&tree)?,
            "settings": settings,
            "ui": settings::read_ui(&root),
        });
        let build_pdf = pdf.is_some();
        let mut actor = Self {
            id,
            project,
            root,
            service: Arc::clone(&sessions.service),
            engine: Arc::clone(&sessions.engine),
            events: sessions.hub.emitter(),
            tx,
            shared: Arc::default(),
            t: sessions.timings.clone(),
            docs: BTreeMap::new(),
            by_id: HashMap::new(),
            next_doc: 1,
            symbols: Arc::default(),
            symbols_seq: 0,
            symbols_at: Some(Instant::now()),
            symbol_scan: SymbolScan::default(),
            edits: 0,
            last_edits: HashMap::new(),
            result_edits: 0,
            build_pdf,
            outdated: false,
            auto_compile,
            build: Build::default(),
            issues: Vec::new(),
            outline: Arc::default(),
            analyses: 0,
            error_count: 0,
            chosen: None,
            autosave_at: None,
            fs_pending: Vec::new(),
            fs_at: None,
            tree: TreeIndex::of(&tree),
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
        Ok((actor, opened))
    }

    pub async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Msg>) {
        loop {
            self.run_later();
            if self.closed {
                break;
            }
            let message = match self.next_deadline() {
                Some(at) => tokio::select! {
                    message = rx.recv() => message,
                    () = tokio::time::sleep_until(at) => {
                        self.fire();
                        continue;
                    }
                },
                None => rx.recv().await,
            };
            match message {
                Some(message) => self.handle(message),
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
            live.log_at,
        ]
        .into_iter()
        .flatten()
        .min()
    }

    fn fire(&mut self) {
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
            self.flush_pending();
        }
        if due(self.live.restart_at) {
            self.live.restart_at = None;
            self.later.push_back(Later::Restart { ended: false });
        }
        if due(self.live.disk_at) {
            self.live.disk_at = None;
            self.refresh_live_disk();
        }
        if due(self.live.log_at) {
            self.log_due();
        }
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
                Later::Restart { ended } => self.live_restart(ended),
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
                Err(err) => {
                    let _ = reply.send(Err(err));
                }
            },
            _ => {
                let answer = self.answer(name, args);
                let _ = reply.send(answer);
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
                        self.autosave_at = Some(Instant::now() + self.t.autosave);
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
            "choose_issue" => {
                self.chosen = arg(args, "index")?;
                return Ok(self.chosen_issue());
            }
            "rename" => {
                let from = paths::rel_key(string_arg(args, "from")?)?;
                return self.rename(&from, string_arg(args, "to")?);
            }
            "set_settings" => return self.set_settings(&arg(args, "patch")?),
            "prepare_delete" => return self.prepare_delete(&path()?),
            "deleted" => {
                let path = path()?;
                self.deleting = None;
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
                self.live_cancel_work();
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
        build["queued"] = self.build.queued.is_some().into();
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
        self.live_cancel_work();
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
            disk_text: Some(text),
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
        for _ in 0..3 {
            if !self.save_doc(path, true, false)? {
                return Ok(json!({ "closed": false }));
            }
            if !self.docs.get(path).is_some_and(Doc::dirty) {
                break;
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

    fn edited(&mut self, doc: u64, version: u64, start: u32, length: u32, text: &str) {
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
        self.live_edited(&path, version, start, length, text);
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
        if let Some(kind) = doc.conflict {
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

    /// Writes every document with unsaved edits; typing during a write is
    /// written too, so a build or a trash that follows has it.
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
        let disk_text = doc.disk_text.clone();
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
                if let Some(text) = disk_text {
                    self.request_reload(path, &text, Reload::Revert);
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
        // It is there, so not gone.
        if doc.conflict == Some(Conflict::Gone) {
            doc.conflict = None;
        }
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

    // MARK: - Builds

    fn has_pdf(&self) -> bool {
        self.build_pdf || self.live.document_seen
    }

    pub fn live_previewing(&self) -> bool {
        self.live.active() || self.live.restart_at.is_some()
    }

    /// A request during a build queues one more. An automatic build waits
    /// while live preview runs, and needs TeX found (`status`). Err: a save
    /// someone asked for failed.
    pub fn compile(&mut self, auto: bool) -> Result<(), CoreError> {
        if self.closed || auto && (self.live_previewing() || !self.service.tex_found()) {
            return Ok(());
        }
        if self.build.compiling {
            self.build.queued = Some(self.build.queued.unwrap_or(true) && auto);
            return Ok(());
        }
        // Before the save, so a second request queues instead of racing this one.
        (self.build.compiling, self.build.auto) = (true, auto);
        self.publish_build();
        let saved = self.flush_all(!auto);
        self.build.saved = saved.as_ref().is_ok_and(|saved| *saved);
        self.build.built = self.edits;
        if self.build.saved && !(auto && self.live_previewing()) {
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
            self.build.queued = None;
            self.engine.stop_compile(&self.root);
        }
    }

    fn build_done(&mut self, result: Result<CompileResult, CoreError>) {
        let result = result.unwrap_or_else(|err| CompileResult {
            errors: vec![LogItem::error(err.message)],
            ..CompileResult::default()
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
        let saved = self.build.saved && !self.closed;
        let again = self.build.queued.take().filter(|_| saved);
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
            let analysis = analyze::analyze_project(&root, &main, &path);
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
            let answer = out(ProjectAnalysis::new(&analysis, class.as_ref()));
            let mut kept = lock(&outline);
            if seq > kept.seq {
                (kept.seq, kept.headings) = (seq, analysis.outline);
            }
            drop(kept);
            let _ = reply.send(answer);
        });
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
                let tokens = |line, command: &str| {
                    doc.doc.with(|source| source.command_ranges(line, command))
                };
                issue_lines(&self.issues, path, tokens)
            } else {
                Vec::new()
            };
            if lines != doc.issues {
                doc.issues.clone_from(&lines);
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
        let chosen = self.chosen;
        let place = if next {
            let after = places.iter().find(|&&p| chosen.is_none_or(|c| p > c));
            after.or(places.first())
        } else {
            let before = places.iter().rev().find(|&&p| chosen.is_none_or(|c| p < c));
            before.or(places.last())
        };
        let Some(&place) = place else {
            return Value::Null;
        };
        self.chosen = Some(place);
        self.chosen_issue()
    }

    // MARK: - Files

    fn rename(&mut self, from: &str, to: &str) -> Result<Value, CoreError> {
        if !self.save_edits(true)? {
            return Ok(Value::Null);
        }
        let (live, intent) = (self.live.active(), self.live.intent);
        let renamed = self.service.with_project(&self.project, |root| {
            let main = settings::read_settings(root).main_file;
            let renamed = projects::rename_entry(root, from, to)?;
            // What the preview shows may have moved: it starts again after (`keep_live`).
            self.service.texpresso.stop(root)?;
            Ok((renamed, main))
        });
        self.keep_live(live, intent, renamed.is_ok());
        let (renamed, main) = renamed?;
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
        let (live, intent) = (self.live.active(), self.live.intent);
        let (updated, main_changed) = self.service.with_project(&self.project, |root| {
            let main = settings::read_settings(root).main_file;
            let updated = settings::write_settings(root, patch)?;
            let main_changed = updated.main_file != main;
            if main_changed {
                // The preview shows the old main file: it starts again after (`keep_live`).
                self.service.texpresso.stop(root)?;
            }
            Ok((updated, main_changed))
        })?;
        if main_changed {
            self.keep_live(live, intent, true);
            self.main_file_changed();
        } else if self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        out(updated)
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
        if within(&settings::read_settings(&self.root).main_file, path) {
            return Err(CoreError::conflict(MAIN_FILE_TRASH));
        }
        self.deleting = Some(path.to_owned());
        Ok(json!({ "ready": true }))
    }
}

/// The build's issues on `path`'s lines, as the editor marks them: the
/// first issue of a line with the rest after it. An undefined command's
/// issue has where the line has the command (as `tokens` finds it, from the
/// line's start), and a `compact` message that names it in fewer words.
fn issue_lines(
    issues: &[LogItem],
    path: &str,
    tokens: impl Fn(u32, &str) -> Vec<TextRange>,
) -> Vec<Value> {
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
            let command = item.command.as_deref();
            json!({
                "line": line,
                "error": item.kind == "error",
                "message": item.message,
                "short": item.short,
                "compact": command.map(|command| format!("Undefined: {command}")),
                "tokens": command.map_or_else(Vec::new, |command| tokens(line, command)),
                "others": others,
            })
        })
        .collect()
}

/// A file's text, and its stamp from before the read: a write meanwhile gives
/// another stamp at the next look, which reads it again.
fn read_disk(path: &Path) -> Result<(String, Option<Stamp>), CoreError> {
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    Ok((crate::lossy_string(fs::read(path)?), stamp))
}
