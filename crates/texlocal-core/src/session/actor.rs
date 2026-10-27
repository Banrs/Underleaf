use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use notify::RecommendedWatcher;
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch as signal};
use tokio::time::Instant;

use super::build::Builds;
use super::documents::Doc;
use super::live::Live;
use super::watch::{self, Change, TreeIndex};
use super::{Command, Document, Engine, Msg, Preview, Reply, Sessions};
use crate::events::Queued;
use crate::paths::Project;
use crate::projects::{self, History, Query, Symbols};
use crate::service::{Service, out, unknown};
use crate::settings;
use crate::{CoreError, lock};

const STOPPED_SAVED: &str = "Saving stopped after an internal error. What was typed so far is saved: close the project and open it again to go on.";
const STOPPED_UNSAVED: &str = "Saving stopped after an internal error, and this file’s edits couldn’t be saved. Copy them out, then close the project and open it again.";

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
    pub next_doc: u64,
    pub shown: u64,
    pub symbols: Arc<RwLock<Arc<Symbols>>>,
    pub symbols_seq: u64,
    pub outline: Value,
    pub facts: Arc<projects::Files>,
    pub edits: u64,
    pub last_edits: HashMap<String, u64>,
    pub auto_compile: bool,
    pub builds: Builds,
    tex: signal::Receiver<bool>,
    pub timers: BTreeMap<Timer, Instant>,
    pub fs_pending: Vec<Change>,
    pub tree: TreeIndex,
    _watcher: Option<RecommendedWatcher>,
    pub deleting: BTreeSet<String>,
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
}
