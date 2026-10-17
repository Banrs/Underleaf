//! One project session's task: its documents, saves, builds, and the news of
//! the watcher and the preview, handled one at a time, so no two of them race.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use notify::RecommendedWatcher;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::task::{JoinError, JoinHandle};
use tokio::time::Instant;

use super::engine::Fut;
use super::live::{self, Live};
use super::watch::{self, Change, TreeIndex};
use super::{Document, Engine, Msg, Open, Reply, Sessions, Shared};
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

/// From the last edit to the autosave.
const AUTOSAVE: Duration = Duration::from_millis(700);
/// From a save to the scan of labels and citations.
const SYMBOLS: Duration = Duration::from_millis(150);
/// FSEvents' latency: changes this close together are taken together.
const SETTLE: Duration = Duration::from_millis(250);

const MAIN_FILE_TRASH: &str = "Choose a different main file before moving this to the Trash.";

/// What the last event of a kind told the host, so an unchanged state isn't sent again.
#[derive(Default)]
pub(super) struct Shown<T>(Option<T>);

impl<T: PartialEq + Clone> Shown<T> {
    /// Whether `now` differs from what was last shown; from here on, it is what was.
    pub fn changed(&mut self, now: &T) -> bool {
        let changed = self.0.as_ref() != Some(now);
        if changed {
            self.0 = Some(now.clone());
        }
        changed
    }
}

/// The session's waits; several due at once go in this order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Timer {
    Autosave,
    Symbols,
    Fs,
    /// A stopped run is shown as halted.
    Halt,
    /// The caret has settled.
    Caret,
    /// Whole texts TeXpresso couldn't be asked to take go again.
    Retry,
    Restart,
    /// Files changed on disk go to TeXpresso.
    Disk,
}

pub(crate) struct Doc {
    pub doc: Document,
    pub path: String,
    /// The version the disk has, as the session last wrote or read it.
    saved: u64,
    /// Save Anyway: written though the text is the disk's.
    force: bool,
    disk_text: String,
    /// While a stat still gives it, a change told of is the session's own save, or none.
    disk_stamp: Option<Stamp>,
    /// `changed`: another app changed the file while it has unsaved edits here; `gone`: it
    /// was moved or deleted. Asked about once; until answered, no save writes over the
    /// other app's change or puts the file back.
    conflict: Option<&'static str>,
    /// The conflict the host is asking about.
    pub(super) asking: Option<&'static str>,
    /// Cancel in a conflict: not saved, and the autosave stays quiet.
    held: bool,
    error: Option<String>,
    /// The reason of a `document_reload` the host has yet to apply: nothing is saved meanwhile.
    reload: Option<&'static str>,
    composing: bool,
    issues: Vec<Value>,
    /// The last `document` event's `error` and `held`.
    shown: Shown<(Option<String>, bool)>,
}

impl Doc {
    pub fn dirty(&self) -> bool {
        self.force || self.doc.version() != self.saved
    }
}

#[derive(Default)]
pub(super) struct Build {
    pub compiling: bool,
    running: Option<Fut<Result<CompileResult, CoreError>>>,
    /// One more build asked for during this one; `Some(true)` while every request was automatic.
    pub queued: Option<bool>,
    auto: bool,
    /// The edit count when it began, and when the build whose issues show began.
    began: u64,
    shown_began: u64,
    /// Its saves went through: else what it queued would build stale text.
    saved: bool,
    /// A build's PDF is on disk.
    pdf: bool,
    pub outdated: bool,
    errors: usize,
    /// The last `build` event's fields.
    shown: Shown<(bool, bool, bool)>,
}

type Cleaned = (Reply, bool, u64, Result<(), CoreError>);
type Scanned = Result<(SymbolScan, Result<Symbols, CoreError>), JoinError>;

pub(crate) struct Actor {
    pub id: u64,
    project: String,
    pub root: PathBuf,
    service: Arc<Service>,
    pub engine: Arc<dyn Engine>,
    events: Emitter,
    tx: mpsc::UnboundedSender<Msg>,
    rx: mpsc::UnboundedReceiver<Msg>,
    shared: Arc<Shared>,
    pub docs: Vec<Doc>,
    next_doc: u64,
    /// The labels and citations the documents complete from.
    symbols: Arc<Mutex<Arc<Symbols>>>,
    /// What the last scan read, for the next; a scan started beside one replaces it.
    scan: SymbolScan,
    pub(super) scanning: Option<JoinHandle<(SymbolScan, Result<Symbols, CoreError>)>>,
    edits: u64,
    /// The edit each path last had, kept for the session's life: a document closed since
    /// isn't marked with a build's issues on lines that may have moved.
    last_edits: HashMap<String, u64>,
    pub auto_compile: bool,
    pub(super) build: Build,
    issues: Vec<LogItem>,
    chosen: Option<usize>,
    /// The analyses asked for.
    analyses: u64,
    pub timers: BTreeMap<Timer, Instant>,
    fs_pending: Vec<Change>,
    /// The listing as last read: the same files and folders make the same tree.
    pub tree: TreeIndex,
    _watcher: Option<RecommendedWatcher>,
    deleting: Option<String>,
    /// A clean waiting for the build to stop, and one under way.
    clean_waiting: Option<Reply>,
    cleaning: Option<Fut<Cleaned>>,
    pub live: Live,
    /// A build to start once the message that asked for it is handled (`true`: automatic,
    /// while every request was).
    build_later: Option<bool>,
    pub closed: bool,
}

impl Actor {
    /// The session numbered `id`, and the answer to its open.
    pub fn new(
        sessions: &Sessions,
        id: u64,
        project: String,
        root: PathBuf,
        auto_compile: bool,
    ) -> Result<(Self, Value), CoreError> {
        let (tx, rx) = mpsc::unbounded_channel();
        let tree = projects::file_tree(&root)?;
        let watcher = sessions.watch.then(|| watch::watch(&root, tx.clone()));
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
        let actor = Self {
            id,
            project,
            root,
            service: Arc::clone(&sessions.service),
            engine: Arc::clone(&sessions.engine),
            events: sessions.hub.emitter(),
            tx,
            rx,
            shared: Arc::default(),
            docs: Vec::new(),
            next_doc: 0,
            symbols: Arc::default(),
            scan: SymbolScan::default(),
            scanning: None,
            edits: 0,
            last_edits: HashMap::new(),
            auto_compile,
            build: Build {
                pdf: pdf.is_some(),
                ..Build::default()
            },
            issues: Vec::new(),
            chosen: None,
            analyses: 0,
            // The labels and citations are scanned as the session opens.
            timers: BTreeMap::from([(Timer::Symbols, Instant::now())]),
            fs_pending: Vec::new(),
            tree: TreeIndex::of(&tree),
            _watcher: watcher.flatten(),
            deleting: None,
            clean_waiting: None,
            cleaning: None,
            live: Live::default(),
            build_later: (auto_compile && pdf.is_none()).then_some(true),
            closed: false,
        };
        Ok((actor, opened))
    }

    pub(super) fn open(&self) -> Open {
        let (tx, shared) = (self.tx.clone(), Arc::clone(&self.shared));
        Open { tx, shared }
    }

    pub async fn run(mut self) {
        loop {
            if self.closed {
                return;
            }
            while let Some(auto) = self.build_later.take() {
                let _ = self.compile(auto);
            }
            let deadline = self.timers.values().min().copied();
            tokio::select! {
                // Work finished goes before messages that may have come after it.
                biased;
                result = next(&mut self.build.running) => self.build_done(result),
                cleaned = next(&mut self.cleaning) => self.cleaned(cleaned),
                news = next(&mut self.live.waiting) => self.live_news(news),
                scanned = next(&mut self.scanning) => self.symbols_done(scanned),
                Some(message) = self.rx.recv() => self.handle(message),
                () = sleep(deadline) => self.fire(),
            }
        }
    }

    pub fn emit(&self, kind: &str, mut fields: Value) {
        fields["type"] = kind.into();
        fields["session"] = self.id.into();
        self.events.send(fields);
    }

    pub fn after(&mut self, timer: Timer, wait: Duration) {
        self.timers.insert(timer, Instant::now() + wait);
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
            Msg::Fs(changes) => {
                self.fs_pending.extend(changes);
                let settled = Instant::now() + SETTLE;
                self.timers.entry(Timer::Fs).or_insert(settled);
            }
            #[cfg(test)]
            Msg::Probe(probe) => probe(self),
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
                Timer::Halt => {
                    self.live.halted = true;
                    self.publish_live(false);
                }
                Timer::Caret => self.caret_settled(),
                Timer::Retry => self.flush_pending(),
                Timer::Restart => self.live_restart(false),
                Timer::Disk => self.refresh_live_disk(),
            }
        }
    }

    // MARK: - Commands

    fn command(&mut self, name: &str, args: &Value, reply: Reply) {
        match name {
            "clean" => self.clean(reply),
            "analyze" => match string_arg(args, "path").and_then(paths::rel_key) {
                Ok(path) => self.analyze(path, reply),
                Err(err) => drop(reply.send(Err(err))),
            },
            _ => drop(reply.send(self.answer(name, args))),
        }
    }

    /// Commands that answer something return it; the rest answer null.
    fn answer(&mut self, name: &str, args: &Value) -> Result<Value, CoreError> {
        let path = || paths::rel_key(string_arg(args, "path")?);
        let flag = |key| arg::<Option<bool>>(args, key);
        match name {
            "close" => return Ok(self.close()),
            "set_options" => {
                if let Some(auto) = flag("autoCompile")? {
                    self.auto_compile = auto;
                }
            }
            "open_document" => self.open_document(&path()?)?,
            "close_document" => {
                let path = path()?;
                let closed = self.flush(Some(&path), true)?;
                if closed {
                    self.close_doc(&path, "closed");
                }
                return Ok(json!({ "closed": closed }));
            }
            "composing" => {
                let (path, composing) = (path()?, arg::<bool>(args, "composing")?);
                if let Some(doc) = self.doc_mut(&path) {
                    doc.composing = composing;
                    if !composing && doc.dirty() {
                        self.after(Timer::Autosave, AUTOSAVE);
                    }
                }
            }
            "save" => {
                let saved = self.save_edits(flag("reporting")?.unwrap_or(true))?;
                return Ok(json!({ "saved": saved }));
            }
            "resolve" => return self.resolve(&path()?, string_arg(args, "answer")?),
            "compile" => self.compile(flag("auto")?.unwrap_or(false))?,
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
                if flag("trashed")?.unwrap_or(true) {
                    for doc in self.docs_within(&path) {
                        self.close_doc(&doc, "deleted");
                    }
                    self.reload_tree();
                }
            }
            "live_start" => {
                self.live.intent += 1;
                self.live.window = flag("window")?.unwrap_or(false);
                self.live_start(false);
                return Ok(self.live_state());
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

    fn close(&mut self) -> Value {
        let saved = self.flush(None, false).unwrap_or(false);
        self.stop_compile();
        self.closed = true;
        self.live_cancel_work();
        self.live_stop();
        lock(&self.shared.docs).clear();
        json!({ "saved": saved })
    }

    // MARK: - Documents

    pub fn doc(&self, path: &str) -> Option<&Doc> {
        self.docs.iter().find(|doc| doc.path == path)
    }

    fn doc_mut(&mut self, path: &str) -> Option<&mut Doc> {
        self.docs.iter_mut().find(|doc| doc.path == path)
    }

    fn paths(&self, keep: impl Fn(&Doc) -> bool) -> Vec<String> {
        let docs = self.docs.iter().filter(|doc| keep(doc));
        docs.map(|doc| doc.path.clone()).collect()
    }

    /// The open documents at `dir` or inside it.
    fn docs_within(&self, dir: &str) -> Vec<String> {
        self.paths(|doc| within(&doc.path, dir))
    }

    /// The editor reads the text from the document's source (`tl_source_text`), as
    /// it is once the switch to it is made.
    fn open_document(&mut self, path: &str) -> Result<(), CoreError> {
        if self.doc(path).is_some() {
            return Ok(());
        }
        let (text, stamp) = read_disk(&paths::safe_path(&self.root, path)?)?;
        self.next_doc += 1;
        let symbols = Arc::clone(&self.symbols);
        let doc = Document::new(self.next_doc, &text, Some(self.tx.clone()), symbols);
        lock(&self.shared.docs).insert(path.to_owned(), doc.clone());
        self.docs.push(Doc {
            doc,
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
            shown: Shown::default(),
        });
        self.publish_doc(path);
        self.mark_issues();
        self.live_whole(path);
        Ok(())
    }

    fn close_doc(&mut self, path: &str, reason: &str) {
        if let Some(at) = self.docs.iter().position(|doc| doc.path == path) {
            self.docs.remove(at);
            lock(&self.shared.docs).remove(path);
            self.emit("document_closed", json!({ "path": path, "reason": reason }));
        }
    }

    /// The path of the document `id`, which an edit or reload changed: its issues go.
    fn touched(&mut self, id: u64) -> Option<String> {
        let path = self
            .docs
            .iter()
            .find(|doc| doc.doc.id() == id)?
            .path
            .clone();
        self.edits += 1;
        self.last_edits.insert(path.clone(), self.edits);
        self.clear_issues(&path);
        Some(path)
    }

    fn edited(&mut self, id: u64, version: u64, start: u32, length: u32, text: &str) {
        let Some(path) = self.touched(id) else {
            return;
        };
        let has_pdf = self.build.pdf || self.live.document_seen;
        if has_pdf && !self.build.outdated {
            self.build.outdated = true;
            self.publish_build();
        }
        self.after(Timer::Autosave, AUTOSAVE);
        self.live_edited(&path, version, start, length, text);
    }

    fn reloaded(&mut self, id: u64, version: u64) {
        let Some(path) = self.touched(id) else {
            return;
        };
        let doc = self.doc_mut(&path).expect("the document is open");
        doc.saved = version;
        let reason = doc.reload.take();
        // Written back: a save under way when the change came may have written over it.
        doc.force |= reason == Some("revert");
        self.live_whole(&path);
        let build = match reason {
            Some("revert") => self.save_doc(&path, true, false).unwrap_or(false),
            reason => reason.is_some(),
        };
        if build {
            self.auto_build();
        }
    }

    /// A `document` event, if Not Saved's grounds changed or the host has none for `path`.
    fn publish_doc(&mut self, path: &str) {
        let Some(doc) = self.doc_mut(path) else {
            return;
        };
        if doc.shown.changed(&(doc.error.clone(), doc.held)) {
            let event = json!({ "path": path, "error": doc.error, "held": doc.held });
            self.emit("document", event);
        }
    }

    // MARK: - Saving

    fn autosave(&mut self) {
        let mut ok = true;
        for path in self.paths(Doc::dirty) {
            ok &= self.save_doc(&path, false, true).unwrap_or(false);
        }
        if ok {
            self.auto_build();
        }
    }

    /// Writes one document. Ok(false): not written, and not to be (a conflict,
    /// asked about when `reporting`, or a reload or deletion under way).
    fn save_doc(&mut self, path: &str, reporting: bool, autosave: bool) -> Result<bool, CoreError> {
        let deleting = self
            .deleting
            .as_deref()
            .is_some_and(|dir| within(path, dir));
        let Some(doc) = self.doc_mut(path).filter(|doc| doc.dirty()) else {
            return Ok(true);
        };
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
        let doc = self.doc_mut(path).expect("the document is open");
        let result = match written {
            Ok(stamp) => {
                (doc.disk_text, doc.disk_stamp) = (text, Some(stamp));
                (doc.saved, doc.force, doc.held, doc.error) = (version, false, false, None);
                self.after(Timer::Symbols, SYMBOLS);
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

    /// Writes every document with unsaved edits, or `only` that one; typing during a
    /// write is written too, so a build or a trash that follows has it.
    fn flush(&mut self, only: Option<&str>, reporting: bool) -> Result<bool, CoreError> {
        if only.is_none() {
            self.timers.remove(&Timer::Autosave);
        }
        let flushed = |doc: &Doc| doc.dirty() && only.is_none_or(|only| doc.path == only);
        for _ in 0..3 {
            let (mut all, mut failure) = (true, None);
            for path in self.paths(flushed) {
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
        let edited = self.docs.iter().any(Doc::dirty);
        let saved = self.flush(None, reporting)?;
        if saved && edited {
            self.auto_build();
        }
        Ok(saved)
    }

    // MARK: - Conflicts

    fn ask(&mut self, path: &str, kind: &'static str) {
        if let Some(doc) = self.doc_mut(path) {
            doc.asking = Some(kind);
            self.emit("conflict", json!({ "path": path, "kind": kind }));
            self.publish_doc(path);
        }
    }

    fn resolve(&mut self, path: &str, answer: &str) -> Result<Value, CoreError> {
        let doc = self.doc_mut(path);
        let doc = doc.ok_or_else(|| CoreError::not_found("The document isn't open"))?;
        let Some(kind) = doc.asking.or(doc.conflict) else {
            return Ok(Value::Null);
        };
        match (kind, answer) {
            (_, "cancel") => (doc.asking, doc.held) = (None, true),
            // The autosave was held while asking, or the edits were saved before the other app's change.
            ("changed", "save") => (doc.asking, doc.conflict, doc.force) = (None, None, true),
            ("changed", "revert") | ("gone", "save") => (doc.asking, doc.conflict) = (None, None),
            ("gone", "close") => {
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
                self.request_reload(path, "revert");
                Ok(Value::Null)
            }
            _ => Ok(Value::Null),
        }
    }

    /// Has the host show the disk's text.
    fn request_reload(&mut self, path: &str, reason: &'static str) {
        if let Some(doc) = self.doc_mut(path) {
            doc.reload = Some(reason);
            let event = json!({ "path": path, "text": doc.disk_text, "reason": reason });
            self.emit("document_reload", event);
        }
    }

    // MARK: - Changes on disk

    fn files_changed_on_disk(&mut self) {
        let changes = std::mem::take(&mut self.fs_pending);
        let docs: Vec<&str> = self.docs.iter().map(|doc| doc.path.as_str()).collect();
        let meaning = watch::classify(&self.root, &changes, &self.tree, &docs);
        for path in &meaning.docs {
            self.check_disk(path);
        }
        let others: Vec<&String> = meaning
            .listed
            .iter()
            .filter(|p| self.doc(p).is_none())
            .collect();
        if !others.is_empty() {
            self.emit("files_changed", json!({ "paths": others }));
        }
        if meaning.tree {
            self.reload_tree();
        }
        if self.live.active() {
            self.live.disk_paths.extend(meaning.listed);
            if !self.live.disk_paths.is_empty() {
                self.after(Timer::Disk, live::FOLLOW);
            }
        }
    }

    fn check_disk(&mut self, path: &str) {
        let abs = self.root.join(path);
        if !abs.exists() {
            return self.file_gone(path);
        }
        let Some(doc) = self.doc_mut(path) else {
            return;
        };
        // It is there, so not gone.
        if doc.conflict == Some("gone") {
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
        if doc.disk_text == text {
            return;
        }
        doc.disk_text = text;
        if !doc.dirty() {
            self.request_reload(path, "disk");
        } else if doc.conflict.replace("changed").is_none() {
            self.ask(path, "changed");
        }
    }

    fn file_gone(&mut self, path: &str) {
        let Some(doc) = self.doc_mut(path) else {
            return;
        };
        if !doc.dirty() {
            self.close_doc(path, "gone");
        } else if doc.conflict.replace("gone") != Some("gone") {
            self.ask(path, "gone");
        }
    }

    fn reload_tree(&mut self) {
        let Ok(tree) = projects::file_tree(&self.root) else {
            return;
        };
        let index = TreeIndex::of(&tree);
        if index != self.tree {
            self.tree = index;
            self.emit("tree", json!({ "tree": tree }));
            self.live_files_changed();
        }
    }

    // MARK: - Symbols

    /// Without the project's lock: every write replaces a file in one rename,
    /// so a scan reads each file whole, old or new, and a save need not wait for it.
    fn scan_symbols(&mut self) {
        let (root, mut scan) = (self.root.clone(), std::mem::take(&mut self.scan));
        self.scanning = Some(tokio::task::spawn_blocking(move || {
            let found = scan.scan(&root);
            (scan, found)
        }));
    }

    fn symbols_done(&mut self, scanned: Scanned) {
        let Ok((scan, found)) = scanned else { return };
        self.scan = scan;
        let mut symbols = lock(&self.symbols);
        // Unchanged, the documents keep the completions they made from it.
        if let Ok(found) = found
            && **symbols != found
        {
            *symbols = Arc::new(found);
        }
    }

    // MARK: - Builds

    /// A request during a build queues one more. An automatic build waits
    /// while live preview runs, and needs TeX found (`status`). Err: a save
    /// someone asked for failed.
    pub fn compile(&mut self, auto: bool) -> Result<(), CoreError> {
        let previewing = self.live.active() || self.timers.contains_key(&Timer::Restart);
        if auto && (previewing || !self.service.tex_found()) {
            return Ok(());
        }
        let build = &mut self.build;
        if build.compiling {
            build.queued = Some(build.queued.unwrap_or(true) && auto);
            return Ok(());
        }
        (build.compiling, build.auto) = (true, auto);
        self.publish_build();
        let saved = self.flush(None, !auto);
        self.build.saved = matches!(saved, Ok(true));
        self.build.began = self.edits;
        if self.build.saved {
            let build = Arc::clone(&self.engine).compile(self.root.clone());
            self.build.running = Some(build);
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
        let build = &mut self.build;
        if result.pdf.is_some() {
            build.pdf = true;
            build.outdated = self.edits != build.began;
        }
        let announce = !build.auto || result.errors.len() != build.errors;
        (build.errors, build.shown_began) = (result.errors.len(), build.began);
        let (auto, outdated) = (build.auto, build.outdated);
        self.issues = result
            .errors
            .iter()
            .chain(&result.warnings)
            .cloned()
            .collect();
        self.chosen = None;
        self.mark_issues();
        let fields =
            json!({ "auto": auto, "announce": announce, "outdated": outdated, "result": result });
        self.emit("build_finished", fields);
        self.finish_build();
    }

    fn finish_build(&mut self) {
        self.build.compiling = false;
        // After a failed save the queued build would only build stale text.
        let again = self.build.queued.take().filter(|_| self.build.saved);
        self.publish_build();
        if let Some(reply) = self.clean_waiting.take() {
            self.start_clean(reply);
        }
        if let Some(auto) = again {
            self.build_soon(auto);
        }
    }

    fn build_soon(&mut self, auto: bool) {
        self.build_later = Some(self.build_later.unwrap_or(true) && auto);
    }

    /// An automatic build, if they are on.
    pub fn auto_build(&mut self) {
        if self.auto_compile {
            self.build_soon(true);
        }
    }

    pub fn publish_build(&mut self) {
        let Build {
            compiling,
            auto,
            outdated,
            ..
        } = self.build;
        let auto = compiling && auto;
        if self.build.shown.changed(&(compiling, auto, outdated)) {
            let event = json!({ "compiling": compiling, "auto": auto, "outdated": outdated });
            self.emit("build", event);
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
        let (live, intent) = (self.live.active(), self.live.intent);
        let clean = Arc::clone(&self.engine).clean(self.root.clone());
        self.cleaning = Some(Box::pin(async move { (reply, live, intent, clean.await) }));
    }

    fn cleaned(&mut self, (reply, live, intent, result): Cleaned) {
        self.keep_live(live, intent, result.is_ok());
        if result.is_ok() {
            (self.build.pdf, self.build.outdated, self.build.errors) = (false, false, 0);
            (self.issues, self.chosen) = (Vec::new(), None);
            self.mark_issues();
            self.publish_build();
            self.emit("build_cleaned", json!({}));
            self.auto_build();
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
        let (seq, root, shared) = (self.analyses, self.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            // Read each time: another app, or another host's `set_settings`, may have changed it.
            let main = settings::read_settings(&root).main_file;
            let analysis = analyze::analyze_project(&root, &main, &path);
            let open = paths::rel_key(&main)
                .ok()
                .and_then(|main| lock(&shared.docs).get(&main).cloned());
            let main_text = match open {
                Some(doc) => Some(doc.snapshot().0),
                None => paths::safe_path(&root, &main)
                    .ok()
                    .and_then(|path| fs::read(path).ok())
                    .map(crate::lossy_string),
            };
            let class = main_text.as_deref().and_then(headings::document_class);
            let answer = out(ProjectAnalysis::new(&analysis, class.as_ref()));
            let mut kept = lock(&shared.outline);
            if seq > kept.0 {
                *kept = (seq, analysis.outline);
            }
            drop(kept);
            let _ = reply.send(answer);
        });
    }

    // MARK: - Issues

    fn clear_issues(&mut self, path: &str) {
        if let Some(doc) = self.doc_mut(path)
            && !doc.issues.is_empty()
        {
            doc.issues.clear();
            self.emit("issues", json!({ "path": path, "lines": [] }));
        }
    }

    /// The build's issues on the lines of each document not edited since it started.
    fn mark_issues(&mut self) {
        let mut changed = Vec::new();
        for doc in &mut self.docs {
            let edited = self.last_edits.get(&doc.path).copied().unwrap_or(0);
            let lines = if edited <= self.build.shown_began {
                let tokens = |line, command: &str| {
                    doc.doc.with(|source| source.command_ranges(line, command))
                };
                issue_lines(&self.issues, &doc.path, tokens)
            } else {
                Vec::new()
            };
            if lines != doc.issues {
                changed.push(json!({ "path": doc.path, "lines": lines }));
                doc.issues = lines;
            }
        }
        for issues in changed {
            self.emit("issues", issues);
        }
    }

    fn chosen_issue(&self) -> Value {
        match self
            .chosen
            .and_then(|index| Some((index, self.issues.get(index)?)))
        {
            Some((index, issue)) => json!({ "index": index, "issue": issue }),
            None => Value::Null,
        }
    }

    /// The next (or previous) issue with a place in a file, round the ends.
    fn next_issue(&mut self, next: bool) -> Value {
        let places = (0..self.issues.len()).filter(|&i| self.issues[i].file.is_some());
        let mut places: Vec<usize> = places.collect();
        if !next {
            places.reverse();
        }
        let beyond = |place: usize| {
            self.chosen
                .is_none_or(|c| if next { place > c } else { place < c })
        };
        let Some(&place) = places.iter().find(|&&p| beyond(p)).or(places.first()) else {
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
            let doc = self.doc_mut(&old).expect("the document is open");
            (doc.path, doc.shown) = (new.clone(), Shown::default());
            let doc = doc.doc.clone();
            let mut shared = lock(&self.shared.docs);
            shared.remove(&old);
            shared.insert(new.clone(), doc);
            drop(shared);
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
        } else {
            self.auto_build();
        }
        out(updated)
    }

    fn main_file_changed(&mut self) {
        let building = self.build.compiling;
        self.stop_compile();
        if self.live.active() {
            self.after(Timer::Restart, live::FOLLOW);
        }
        if self.auto_compile || building {
            self.build_soon(self.auto_compile);
        }
    }

    /// The core ends a live preview when a rename, a new main file or a clean changes what
    /// it shows; one live before starts again after, unless stopped or started meanwhile.
    fn keep_live(&mut self, live: bool, intent: u64, changed: bool) {
        if live && changed && intent == self.live.intent {
            self.after(Timer::Restart, live::FOLLOW);
        }
    }

    /// Saved first, so no autosave can make the file again; the main file stays.
    fn prepare_delete(&mut self, path: &str) -> Result<Value, CoreError> {
        if !self.flush(None, true)? || self.docs.iter().any(Doc::dirty) {
            return Ok(json!({ "ready": false }));
        }
        if within(&settings::read_settings(&self.root).main_file, path) {
            return Err(CoreError::conflict(MAIN_FILE_TRASH));
        }
        self.deleting = Some(path.to_owned());
        Ok(json!({ "ready": true }))
    }
}

/// What `slot`'s work comes to, once it does; never, with no work there.
async fn next<F: Future + Unpin>(slot: &mut Option<F>) -> F::Output {
    let Some(work) = slot else {
        return std::future::pending().await;
    };
    let output = work.await;
    *slot = None;
    output
}

async fn sleep(until: Option<Instant>) {
    match until {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
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
    let mut lines: BTreeMap<u32, (&LogItem, Vec<&str>)> = BTreeMap::new();
    for item in issues {
        if let (Some(file), Some(line)) = (&item.file, item.line)
            && file == path
        {
            let (first, others) = lines.entry(line).or_insert((item, Vec::new()));
            if !std::ptr::eq(*first, item) {
                others.push(&item.message);
            }
        }
    }
    let lines = lines.into_iter().map(|(line, (item, others))| {
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
    });
    lines.collect()
}

/// A file's text, and its stamp from before the read: a write meanwhile gives
/// another stamp at the next look, which reads it again.
fn read_disk(path: &Path) -> Result<(String, Option<Stamp>), CoreError> {
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    Ok((crate::lossy_string(fs::read(path)?), stamp))
}
