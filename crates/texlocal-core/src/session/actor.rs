use std::collections::{BTreeMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use notify::RecommendedWatcher;
use texlocal_latex::diff::DiffLine;
use texlocal_latex::logparse::Fix;
use texlocal_latex::project::Scan;
use texlocal_latex::search::Query;
use texlocal_latex::syntax::SymbolKind;
use texlocal_latex::wordmatch::{PdfHit, PdfPage};
use tokio::sync::{mpsc, oneshot, watch as signal};
use tokio::time::Instant;

use super::build::{Builds, built_pdf};
use super::documents::{Docs, Resolution};
use super::edits::{Fixed, ProjectEdits};
use super::live::Live;
use super::navigate::{QuickHelp, QuickOpenItem};
use super::scans::Usages;
use super::state::{Lifecycle, Stopped};
use super::watch::{self, Change, TreeIndex};
use super::{Compiler, Msg, OnActor, Pending, Preview, Reply, SessionSection, Sessions};
use crate::CoreError;
use crate::events::{Event, Said, Sent, SessionEvent};
use crate::import::{ImportConflict, Imported};
use crate::messages;
use crate::paths::{Project, RelPath};
use crate::projects::{self, Job, Reason, RenameResult, SearchGroup, Snapshot};
use crate::protocol::requests;
use crate::service::{InSession, Service};
use crate::settings::{self, SettingsPatch, UiPatch, UiState};
use crate::synctex::{ForwardLoc, InverseLoc, PageClick};

requests! {
    Session(actor: Actor, pending) {
        OpenProject { id: String, auto_compile: bool } -> UiState
            = Err(CoreError::conflict(messages::session_open())),
        CloseProject {} -> bool => actor.close(pending),
        SetOptions { auto_compile: bool } -> () = Ok(actor.auto_compile = auto_compile),
        Open { path: RelPath } -> Option<String> = actor.open(&path.0),
        Save { reporting: bool } -> bool = actor.save_edits(reporting),
        Resolve { path: RelPath, answer: Resolution } -> () = actor.resolve(&path.0, answer),
        Compile { auto: bool } -> () = actor.compile(auto),
        StopCompile {} -> () = Ok(actor.stop_compile()),
        Clean {} -> () => actor.clean(pending),
        Search { query: String, match_case: bool, whole_word: bool } -> Vec<SearchGroup>
            => actor.search(Query::new(&query, match_case, whole_word), pending),
        FindUsages { path: RelPath, offset: u32 } -> Option<Usages> => actor.usages(&path.0, offset, pending),
        LookUp { path: RelPath, offset: u32 } -> Option<QuickHelp> => actor.quick_help(&path.0, offset, pending),
        QuickOpen { query: String } -> Vec<QuickOpenItem> => actor.quick_open(query, pending),
        Replace { query: String, replacement: String, match_case: bool, whole_word: bool } -> ProjectEdits => {
            let replace = actor.replace(Query::new(&query, match_case, whole_word), replacement);
            actor.before(Reason::ReplaceAll, replace, pending);
        },
        RenameSymbol { kind: SymbolKind, from: String, to: String } -> ProjectEdits => {
            let rename = actor.rename_symbol(kind, from, to);
            actor.before(Reason::Rename, rename, pending);
        },
        ApplyFix { #[schemars(with = "String")] id: Fix } -> Option<Fixed> => actor.fix(id, pending),
        ListVersions {} -> Vec<Snapshot> => actor.history_list(pending),
        SaveVersion { name: String } -> Option<Snapshot> => actor.history_save(name, pending),
        CompareVersion { id: String, path: RelPath } -> Vec<DiffLine> => actor.history_compare(id, path.0, pending),
        RestoreVersion { id: String, paths: Option<Vec<RelPath>> } -> ProjectEdits
            => actor.history_restore(id, paths, pending),
        Rename { from: RelPath, to: String } -> Option<RenameResult> = actor.rename(&from.0, &to),
        CreateEntry { folder: String, name: String, dir: bool } -> String = actor.create_entry(&folder, &name, dir),
        SetSettings { patch: SettingsPatch } -> () = actor.set_settings(&patch, true),
        Trash { path: RelPath } -> Option<PathBuf> = actor.trash(&path.0),
        PutBack { path: RelPath, trashed: PathBuf } -> () = actor.put_back(&path.0, &trashed),
        StartLive {} -> () = Ok(actor.live_start_asked()),
        StopLive {} -> () = Ok(actor.live_stop_asked()),
        LiveView { first: u32, last: u32 } -> () = Ok(actor.live_view(first, last)),
        LiveLog { shown: bool } -> () = Ok(actor.show_live_log(shown)),
        ReloadTree {} -> () = Ok(actor.reload_tree()),
        ImportFiles { dir: String, paths: Vec<PathBuf>, conflict: Option<ImportConflict> } -> Imported
            = actor.import(&dir, &paths, conflict),
        ExportZip { dest: PathBuf, for_arxiv: bool } -> () => actor.export(dest, for_arxiv, pending),
        SetUiState { patch: UiPatch } -> () = actor.write_ui(patch),
        SynctexForward { file: RelPath, line: u32 } -> ForwardLoc => actor.synctex_forward(file.0, line, pending),
        SynctexInverse { page: f64, x: f64, y: f64, click: Option<PageClick> } -> InverseLoc
            => actor.synctex_inverse(page, x, y, click, pending),
        SynctexMatch { file: RelPath, line: u32, column: usize, pages: Vec<PdfPage> } -> Option<PdfHit>
            => actor.synctex_match(file.0, line, column, pages, pending),
    }
}

pub(crate) enum Later {
    Compile(bool),
    Restart,
    Rescan,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Timer {
    Autosave,
    Symbols,
    Fs,
    Caret,
    Follow,
    Halting,
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
            Self::Follow => 120,
            Self::Halting | Self::Issues => 1000,
            Self::Restart | Self::Disk => 180,
            Self::Log => 200,
        })
    }
}

enum Stage {
    Open(InSession),
    Closing(InSession, Vec<Pending<bool>>),
    Closed,
}

enum Wake {
    Message(Msg),
    Deadline,
    TexFound,
}

pub(crate) struct Actor {
    pub id: u64,
    pub children: u64,
    pub project: Project,
    pub service: Arc<Service>,
    pub compiler: Arc<dyn Compiler>,
    pub preview: Arc<dyn Preview>,
    events: std::sync::mpsc::Sender<Said>,
    pub tx: mpsc::UnboundedSender<Msg>,
    pub docs: Docs,
    pub next_doc: u64,
    pub open: Option<String>,
    pub opens: Arc<AtomicU64>,
    pub scan: Arc<RwLock<Arc<Scan>>>,
    pub symbols_seq: u64,
    pub facts: Arc<projects::Files>,
    pub auto_compile: bool,
    pub builds: Builds,
    tex: signal::Receiver<bool>,
    pub timers: BTreeMap<Timer, Instant>,
    pub fs_pending: Vec<Change>,
    pub tree: TreeIndex,
    _watcher: Option<RecommendedWatcher>,
    pub live: Live,
    pub later: VecDeque<Later>,
    pub history: Arc<std::sync::mpsc::Sender<Job>>,
    pub writes_history: Arc<AtomicBool>,
    pub snapshots: usize,
    pub queued: VecDeque<OnActor>,
    pub sent: Sent<SessionSection>,
    stage: Stage,
}

impl Actor {
    pub fn new(
        sessions: &Sessions,
        id: u64,
        opening: OpenProject,
        docs: Docs,
        opens: Arc<AtomicU64>,
        tx: mpsc::UnboundedSender<Msg>,
    ) -> Result<(Self, UiState), CoreError> {
        let OpenProject {
            id: project_id,
            auto_compile,
        } = opening;
        let (project, in_session) = sessions.service.in_session(&project_id)?;
        let tree = projects::file_tree(&project)?;
        let watcher = sessions
            .watch
            .then(|| watch::watch(&project.root, tx.clone()))
            .flatten();
        let mut builds = Builds::default();
        builds.pdf = built_pdf(&project);
        settings::migrate(&project);
        let ui = settings::read_ui(&project.ui);
        let mut later = VecDeque::new();
        if ui.live_preview && sessions.preview.available(&sessions.service.tool_paths().1) {
            later.push_back(Later::Restart);
        }
        if auto_compile && builds.pdf.is_none() {
            later.push_back(Later::Compile(true));
        }
        let history = sessions.service.history(&project);
        let mut actor = Self {
            id,
            children: sessions.service.processes.owner(),
            project,
            service: Arc::clone(&sessions.service),
            compiler: Arc::clone(&sessions.compiler),
            preview: Arc::clone(&sessions.preview),
            events: sessions.hub.queue.clone(),
            tx,
            docs,
            next_doc: 1,
            open: None,
            opens,
            scan: Arc::default(),
            symbols_seq: 0,
            facts: Arc::default(),
            auto_compile,
            builds,
            tex: sessions.service.tex_found.subscribe(),
            timers: BTreeMap::from([(Timer::Symbols, Instant::now())]),
            fs_pending: Vec::new(),
            tree: TreeIndex::of(&tree),
            _watcher: watcher,
            live: Live::default(),
            later,
            history,
            writes_history: Arc::new(AtomicBool::new(true)),
            snapshots: 0,
            queued: VecDeque::new(),
            sent: Sent::default(),
            stage: Stage::Open(in_session),
        };
        actor.reopen(ui.file.clone());
        actor.publish_all(tree);
        actor.snapshot_soon();
        Ok((actor, ui))
    }

    pub async fn run(
        mut self,
        mut rx: mpsc::UnboundedReceiver<Msg>,
        mut runtime_gone: oneshot::Receiver<()>,
    ) {
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
            if matches!(self.stage, Stage::Closed) {
                return;
            }
            let deadline = self.timers.values().min().copied();
            let sleep = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now));
            let waiting_for_tex = self.builds.waiting_for_tex;
            woken = tokio::select! {
                biased;
                _ = &mut runtime_gone => return,
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
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let _ = self.flush_all(false);
            self.stop_compile();
            self.live_stop();
        }));
        self.stop_history();
        let stopped = Stopped {
            unsaved: self.dirty_paths(),
        };
        for (_, doc) in self.docs.iter_mut() {
            doc.doc.close();
            doc.error = Some(if doc.dirty() {
                messages::stopped_unsaved()
            } else {
                messages::stopped_saved()
            });
        }
        self.publish_documents();
        self.publish(SessionSection::Lifecycle(Lifecycle::Stopped(stopped)));
        for close in self.end() {
            close.send(Err(super::stopped()));
        }
        rx.close();
        while let Ok(message) = rx.try_recv() {
            match message {
                Msg::Command(_, reply) => reply.send(Err(super::stopped())),
                Msg::Snapshotted(finish) => finish(self),
                _ => {}
            }
        }
        while let Some(queued) = self.queued.pop_front() {
            queued(self);
        }
        for reply in std::mem::take(&mut self.builds.cleaners) {
            reply.send(Err(super::stopped()));
        }
    }

    pub fn emit(&self, event: Event) {
        let session = self.id;
        let _ = self
            .events
            .send(Said::Event(SessionEvent { session, event }));
    }

    fn handle(&mut self, message: Msg) {
        if let Stage::Closing(_, closes) = &mut self.stage {
            return match message {
                Msg::Command(Session::CloseProject(_, answer), reply) => {
                    closes.push(Pending { reply, answer });
                }
                Msg::Command(_, reply) => reply.send(Err(super::gone())),
                Msg::BuildDone(result) => self.build_done(result),
                Msg::Cleaned(result) => self.cleaned(result),
                Msg::Snapshotted(finish) => {
                    finish(self);
                    self.close_when_idle();
                }
                _ => {}
            };
        }
        match message {
            Msg::Edited { doc, version, edit } => self.edited(doc, version, &edit),
            Msg::Selected { doc, caret } => self.selected(doc, caret),
            Msg::Command(command, reply) => command.run(self, reply),
            Msg::BuildDone(result) => self.build_done(result),
            Msg::Cleaned(result) => self.cleaned(result),
            Msg::Symbols { seq, edits, result } => self.symbols_done(seq, edits, result),
            Msg::Live(generation, event) => self.live_event(generation, event),
            Msg::Snapshotted(finish) => finish(self),
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
                Timer::Follow => self.follow(),
                Timer::Halting => self.live_halted(true),
                Timer::Restart => self.later.push_back(Later::Restart),
                Timer::Disk => self.refresh_live_disk(),
                Timer::Log => self.publish_live_log(),
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
            if !matches!(self.stage, Stage::Open(_)) {
                self.later.clear();
                return;
            }
            match next {
                Later::Compile(auto) => {
                    let _ = self.compile(auto);
                }
                Later::Restart => self.live_start(),
                Later::Rescan => self.live_rescan(),
            }
        }
    }

    fn close(&mut self, reply: Pending<bool>) {
        match self.flush_all(true) {
            Ok(true) => {}
            flushed => return reply.send(flushed),
        }
        let Stage::Open(held) = std::mem::replace(&mut self.stage, Stage::Closed) else {
            unreachable!("a closing session queues its closes")
        };
        self.stage = Stage::Closing(held, vec![reply]);
        self.publish(SessionSection::Lifecycle(Lifecycle::Closing));
        self.stop_compile();
        self.live_stop();
        self.docs.clear();
        self.timers.clear();
        self.close_when_idle();
    }

    pub fn close_when_idle(&mut self) {
        if self.builds.busy() || self.snapshots > 0 || !matches!(self.stage, Stage::Closing(..)) {
            return;
        }
        self.stop_history();
        let closes = self.end();
        self.publish(SessionSection::Lifecycle(Lifecycle::Closed));
        self.service.relist();
        for close in closes {
            close.send(Ok(true));
        }
    }

    fn end(&mut self) -> Vec<Pending<bool>> {
        self.service.processes.end(self.children);
        match std::mem::replace(&mut self.stage, Stage::Closed) {
            Stage::Closing(held, closes) => {
                drop(held);
                closes
            }
            _ => Vec::new(),
        }
    }
}
