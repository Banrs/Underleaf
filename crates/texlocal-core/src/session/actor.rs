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
use super::watch::{self, Change, TreeIndex};
use super::{Command, Document, Engine, Msg, Preview, Reply, Sessions};
use crate::analyze::{self, Facts, Place};
use crate::events::Queued;
use crate::logparse::{Fix, LogItem};
use crate::paths::{self, Project, within};
use crate::projects::{self, History, Query, Symbols, file_kind};
use crate::service::{Service, out, unknown};
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
pub(super) const MAX_EDITED: u64 = 64 << 20;

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
    disk_text: Option<String>,
    newline: &'static str,
    disk_stamp: Option<Stamp>,
    conflict: Option<Conflict>,
    asking: Option<Conflict>,
    held: bool,
    error: Option<String>,
    reloads: VecDeque<Reload>,
    composing: bool,
    pub issues: Vec<Value>,
    pub live_issues: Vec<Value>,
    shown: Value,
}

impl Doc {
    fn dirty(&self) -> bool {
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
    Issues,
}

impl Timer {
    fn wait(self) -> Duration {
        Duration::from_millis(match self {
            Self::Autosave => 700,
            Self::Symbols | Self::Caret => 150,
            Self::Fs => 250,
            Self::Retry => 750,
            Self::Halting | Self::Issues => 1000,
            Self::Restart | Self::Disk => 180,
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
    events: std::sync::mpsc::Sender<Queued>,
    pub tx: mpsc::UnboundedSender<Msg>,
    pub shared: Arc<Mutex<HashMap<String, Document>>>,
    pub docs: BTreeMap<String, Doc>,
    next_doc: u64,
    shown: u64,
    pub symbols: Arc<RwLock<Arc<Symbols>>>,
    symbols_seq: u64,
    outline: Value,
    pub facts: Arc<analyze::Files>,
    pub edits: u64,
    pub last_edits: HashMap<String, u64>,
    pub auto_compile: bool,
    pub builds: Builds,
    tex: signal::Receiver<bool>,
    pub timers: BTreeMap<Timer, Instant>,
    fs_pending: Vec<Change>,
    pub tree: TreeIndex,
    _watcher: Option<RecommendedWatcher>,
    deleting: BTreeSet<String>,
    pub live: Live,
    pub later: VecDeque<Later>,
    pub history: Arc<Mutex<History>>,
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
        let opened = json!({
            "name": project.name(),
            "root": project.root.to_string_lossy(),
            "tree": out(&tree)?,
            "settings": settings::shown(&project),
            "ui": settings::read_ui(&project.ui),
        });
        let mut builds = Builds::default();
        builds.pdf = settings::read_settings(&project.settings)
            .output(&project.build, "pdf")
            .is_ok_and(|pdf| pdf.is_file());
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
            shown: 0,
            symbols: Arc::default(),
            symbols_seq: 0,
            outline: Value::Null,
            facts: Arc::default(),
            edits: 0,
            last_edits: HashMap::new(),
            auto_compile,
            builds,
            tex: sessions.service.tex_found.subscribe(),
            timers: BTreeMap::from([(Timer::Symbols, Instant::now())]),
            fs_pending: Vec::new(),
            tree: TreeIndex::of(&tree),
            _watcher: watcher,
            deleting: BTreeSet::new(),
            live: Live::default(),
            later,
            history,
            closed: false,
        };
        actor.snapshot_soon();
        Ok((actor, opened))
    }

    pub async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Msg>) {
        let mut woken = None;
        loop {
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
            if let Msg::Command(_, reply) = message {
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
        let _ = self.events.send(Queued::Event(fields));
    }

    fn handle(&mut self, message: Msg) {
        match message {
            Msg::Changed { doc, version, edit } => self.changed(doc, version, edit),
            Msg::Command(command, reply) => self.command(command, reply),
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

    #[expect(clippy::unit_arg)]
    fn command(&mut self, command: Command, reply: Reply) {
        let answer = match command {
            Command::Clean => return self.clean(reply),
            Command::Fix { id } => return self.fix(&id, reply),
            Command::Search {
                query,
                match_case,
                whole_word,
            } => return self.search(Query::new(&query, match_case, whole_word), reply),
            Command::Usages { path, offset } => return self.usages(&path.0, offset, reply),
            Command::QuickHelp { path, offset } => return self.quick_help(&path.0, offset, reply),
            Command::QuickOpen { query } => return self.quick_open(query, reply),
            Command::HistoryList => return self.history_list(reply),
            Command::HistorySave { name } => return self.history_save(name, reply),
            Command::HistoryCompare { id, path } => return self.history_compare(id, path.0, reply),
            Command::Rename { from, to } => {
                let answer = self.rename(&from.0, &to);
                return self.after_events(answer, reply);
            }
            Command::CreateEntry { folder, name, dir } => {
                let answer = self.create_entry(&folder, &name, dir);
                return self.after_events(answer, reply);
            }
            Command::Close => self.close(),
            Command::SetOptions { auto_compile } => {
                out(auto_compile.map(|auto| self.auto_compile = auto))
            }
            Command::OpenDocument { path } => self.open_document(&path.0).and_then(out),
            Command::CloseDocument { path } => self.close_document(&path.0),
            Command::Composing { path, composing } => out(self.composing(&path.0, composing)),
            Command::Save { reporting } => self
                .save_edits(reporting.unwrap_or(true))
                .map(|saved| json!({ "saved": saved })),
            Command::Resolve { path, answer } => self.resolve(&path.0, &answer),
            Command::Compile { auto } => self.compile(auto).and_then(out),
            Command::StopCompile => out(self.stop_compile()),
            Command::Replace {
                query,
                replacement,
                match_case,
                whole_word,
            } => self.replace(&Query::new(&query, match_case, whole_word), &replacement),
            Command::RenameSymbol { kind, from, to } => self.rename_symbol(&kind, &from, &to),
            Command::HistoryRestore { id, paths } => self.history_restore(&id, paths),
            Command::SetSettings { patch } => self.set_settings(&patch, true),
            Command::PrepareDelete { path } => self.prepare_delete(&path.0),
            Command::Deleted { path, trashed } => out(self.deleted(&path.0, trashed)),
            Command::LiveStart => Ok(self.live_start_asked()),
            Command::LiveStop => Ok(self.live_stop_asked()),
            Command::LiveLog { shown } => out(self.show_live_log(shown)),
            Command::LiveView { first, last } => out(self.live_view(first, last)),
            Command::LiveCaret { path, offset } => out(self.live_caret(path.0, offset)),
            Command::Unknown => Err(unknown()),
        };
        reply.send(answer);
    }

    fn after_events(&self, answer: Result<Value, CoreError>, reply: Reply) {
        let then = Queued::Then(Box::new(move || reply.send(answer)));
        let _ = self.events.send(then);
    }

    fn composing(&mut self, path: &str, composing: bool) {
        if let Some(doc) = self.docs.get_mut(path) {
            doc.composing = composing;
            if !composing && doc.dirty() {
                self.after(Timer::Autosave);
            }
        }
    }

    fn deleted(&mut self, path: &str, trashed: Option<bool>) {
        self.deleting.remove(path);
        if trashed.unwrap_or(true) {
            for doc in self.docs_within(path) {
                self.close_doc(&doc, "deleted");
            }
            self.reload_tree();
        }
    }

    fn create_entry(&mut self, folder: &str, name: &str, dir: bool) -> Result<Value, CoreError> {
        let path = paths::in_folder(folder, name);
        let made = self.service.with_project(&self.project_id, |project| {
            projects::create_free(&project.root, &path, dir)
        })?;
        self.reload_tree();
        Ok(json!({ "path": made }))
    }

    fn close(&mut self) -> Result<Value, CoreError> {
        if !self.flush_all(true)? {
            return Ok(json!({ "saved": false }));
        }
        self.stop_compile();
        self.closed = true;
        self.live_stop();
        lock(&self.shared).clear();
        Ok(json!({ "saved": true }))
    }

    fn open_document(&mut self, path: &str) -> Result<(), CoreError> {
        let path =
            &analyze::disk_spelling(&self.project.root, path).unwrap_or_else(|| path.to_owned());
        if let Some(doc) = self.docs.get(path) {
            let id = doc.doc.id();
            if id != self.shown {
                self.shown = id;
                self.after(Timer::Symbols);
            }
            return Ok(());
        }
        let abs = paths::safe_path(&self.project.root, path)?;
        let size = fs::metadata(&abs).map_err(CoreError::at(&abs))?.len();
        if size > MAX_EDITED {
            return Err(CoreError::bad_request(format!(
                "It's {} MB, too large to edit here. Open it in another app.",
                size >> 20
            )));
        }
        let (disk, stamp) = read_disk(&abs)?;
        let (text, newline) = disk.ok_or_else(|| CoreError::bad_request(NOT_UTF8))?;
        let id = self.next_doc;
        self.next_doc += 1;
        self.shown = id;
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
        self.after(Timer::Symbols);
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

    fn publish_doc(&mut self, path: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        let state = doc.state();
        if state != doc.shown {
            doc.shown = state.clone();
            self.emit("document", state);
        }
    }

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

    pub fn deleting(&self, path: &str) -> bool {
        self.deleting.iter().any(|entry| within(path, entry))
    }

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
        Ok(self
            .docs
            .iter()
            .all(|(path, doc)| only.is_some_and(|only| only != path) || !doc.dirty()))
    }

    fn save_edits(&mut self, reporting: bool) -> Result<bool, CoreError> {
        let edited = !self.dirty_paths().is_empty();
        let saved = self.flush_all(reporting)?;
        if saved && edited && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        Ok(saved)
    }

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
            let seen = match reason {
                Reload::Disk => doc.saved,
                Reload::Revert => doc.doc.version(),
            };
            doc.doc.expect_reload(seen);
            doc.reloads.push_back(reason);
            self.emit("document_reload", json!({ "path": path, "text": text }));
        }
    }

    fn files_changed_on_disk(&mut self) {
        let changes = std::mem::take(&mut self.fs_pending);
        let docs: Vec<String> = self.docs.keys().cloned().collect();
        let meaning = watch::classify(&self.project.root, &changes, &self.tree, &docs);
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
        if meaning.tree || !others.is_empty() {
            self.edits += 1;
            self.mark_outdated();
            if self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
        if self.live.active() {
            self.live.disk_paths.extend(meaning.listed.iter().cloned());
        }
        let main = self.tree.main.clone();
        if meaning.tree {
            self.reload_tree();
        }
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
        let shown = self.docs.values().find(|doc| doc.doc.id() == self.shown);
        let shown = shown.map(|doc| doc.path.clone());
        tokio::task::spawn_blocking(move || {
            let symbols = projects::scan_symbols(&root, &facts, &texts(&docs));
            let installed = tex::installed(&service.tool_paths().0);
            let result = symbols.and_then(|symbols| {
                let symbols = Symbols {
                    files,
                    installed,
                    ..symbols
                };
                let checks = main
                    .as_deref()
                    .map_or_else(Vec::new, |main| checks::check(&symbols, main));
                let analysis =
                    analyze::analyze_project(&symbols, main.as_deref(), shown.as_deref());
                let outline = out(&analysis)?;
                Ok(Box::new((symbols, checks, outline)))
            });
            let _ = tx.send(Msg::Symbols { seq, edits, result });
        });
    }

    fn symbols_done(
        &mut self,
        seq: u64,
        edits: u64,
        result: Result<Box<(Symbols, Vec<LogItem>, Value)>, CoreError>,
    ) {
        if let Ok(scanned) = result
            && seq == self.symbols_seq
        {
            let (symbols, checks, outline) = *scanned;
            *self.symbols.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(symbols);
            self.checks_done(checks, edits);
            if outline != self.outline {
                self.emit("outline", outline.clone());
                self.outline = outline;
            }
        }
    }

    fn search(&self, query: Query, reply: Reply) {
        let (root, docs) = (self.project.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            let found = |_: &str, text: &str| query.places(text);
            let open = texts(&docs);
            let hits = projects::search_project(&root, &open, &projects::is_text, &found, 100);
            reply.send(hits.and_then(|hits| out(projects::search_groups(hits))));
        });
    }

    fn replace(&self, query: &Query, to: &str) -> Result<Value, CoreError> {
        let open = self.texts_to_edit("replaced")?;
        let found = |_: &str, text: &str| query.places(text);
        self.edit_project("Before Replace All", &open, &projects::is_text, &found, to)
    }

    fn usages(&self, path: &str, offset: u32, reply: Reply) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(Value::Null));
        };
        let (root, docs) = (self.project.root.clone(), Arc::clone(&self.shared));
        tokio::task::spawn_blocking(move || {
            let own = doc.facts();
            let symbol = doc.with(|source| source.symbol_at(&own, offset));
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

    fn rename_symbol(&self, noun: &str, from: &str, to: &str) -> Result<Value, CoreError> {
        let kind = match noun {
            "label" => SymbolKind::Label,
            "citation" => SymbolKind::Citation,
            _ => {
                return Err(CoreError::bad_request(
                    "Only a label or a citation is renamed",
                ));
            }
        };
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

    fn fix(&mut self, id: &str, reply: Reply) {
        let edits = match Fix::parse(id) {
            Some(Fix::Install(file)) => {
                let (service, project) = (Arc::clone(&self.service), self.project.clone());
                tokio::spawn(async move {
                    let installed = packages::install_package(&file, &service.tool_paths().0).await;
                    reply.send(match installed {
                        Err(err) if err.kind == crate::ErrorKind::Denied => Ok(Value::Null),
                        installed => installed.map(|_| fixed(Value::Null, &project)),
                    });
                });
                return;
            }
            Some(Fix::AddPackage(name)) => self
                .add_package(&name)
                .map(|mut added| added["edits"].take()),
            Some(Fix::Xelatex) => self
                .set_settings(&json!({ "engine": "xelatex" }), false)
                .map(|_| Value::Null),
            Some(Fix::ShellEscape) => self
                .set_settings(&json!({ "shellEscape": true }), false)
                .map(|_| Value::Null),
            None => Err(CoreError::bad_request("There's no such fix.")),
        };
        reply.send(edits.map(|edits| fixed(edits, &self.project)));
    }

    fn add_package(&self, name: &str) -> Result<Value, CoreError> {
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

    fn set_settings(&mut self, patch: &Value, build: bool) -> Result<Value, CoreError> {
        let (updated, main_changed) = self.service.with_project(&self.project_id, |project| {
            let main = settings::read_settings(&project.settings).main_file;
            let grant = patch.get("shellEscape").map(|on| {
                on.as_bool()
                    .ok_or_else(|| CoreError::bad_request("Invalid settings: shellEscape"))
            });
            let grant = grant.transpose()?;
            let updated = settings::write_settings(&project.settings, patch)?;
            if let Some(on) = grant {
                settings::grant(project, on)?;
            }
            let main_changed = updated.main_file != main;
            if main_changed {
                self.preview.stop(&project.root)?;
            }
            Ok((settings::shown(project), main_changed))
        })?;
        if main_changed {
            self.main_file_changed();
        } else if build && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        Ok(updated)
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

fn fixed(edits: Value, project: &Project) -> Value {
    json!({ "edits": edits, "settings": settings::shown(project) })
}

fn tex(rel: &str) -> bool {
    matches!(file_kind(rel), "tex" | "bib")
}

fn texts(docs: &Mutex<HashMap<String, Document>>) -> HashMap<String, String> {
    let docs = lock(docs).clone();
    docs.into_iter()
        .map(|(path, doc)| (path, doc.snapshot().0))
        .collect()
}

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

fn read_disk(path: &Path) -> Result<(Option<DiskText>, Option<Stamp>), CoreError> {
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    let disk = String::from_utf8(fs::read(path)?).ok().map(|text| {
        let newline = newline(&text);
        (lf(text), newline)
    });
    Ok((disk, stamp))
}

type DiskText = (String, &'static str);
