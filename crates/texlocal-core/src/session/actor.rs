use std::collections::{BTreeMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use texlocal_latex::diff::DiffLine;
use texlocal_latex::logparse::Fix;
use texlocal_latex::search::Query;
use texlocal_latex::syntax::SymbolKind;
use texlocal_latex::wordmatch::{PdfHit, PdfPage};
use tokio::sync::{mpsc, oneshot, watch as signal};
use tokio::time::Instant;

use super::build::{Builds, Shown, built_pdf};
use super::documents::{Docs, Resolution};
use super::edits::{AddedCitation, Fixed, ProjectEdits};
use super::live::Live;
use super::navigate::{BadBoxArea, QuickHelp, QuickOpenItem};
use super::scans::Usages;
use super::state::{Lifecycle, Stopped};
use super::watch::Tree;
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
        CloseProject { discard: Option<bool> } -> bool => actor.close(discard == Some(true), pending),
        SetOptions { auto_compile: bool } -> () = Ok(actor.core.auto_compile = auto_compile),
        Open { path: RelPath } -> Option<String> = actor.open(&path.0),
        Save { reporting: bool } -> bool = actor.docs.save_edits(&mut actor.core, reporting),
        Resolve { path: RelPath, answer: Resolution } -> () = actor.resolve(&path.0, answer),
        Compile {} -> () = actor.compile(false),
        StopCompile {} -> () = Ok(actor.builds.stop()),
        Clean {} -> () => actor.builds.clean(&actor.core, pending),
        Search { query: String, match_case: bool, whole_word: bool } -> Vec<SearchGroup>
            => actor.search(Query::new(&query, match_case, whole_word), pending),
        FindUsages { path: RelPath, offset: u32 } -> Option<Usages> => actor.usages(&path.0, offset, pending),
        LookUp { path: RelPath, offset: u32 } -> Option<QuickHelp> => actor.quick_help(&path.0, offset, pending),
        QuickOpen { query: String } -> Vec<QuickOpenItem> => actor.tree.quick_open(query, pending),
        Replace { query: String, replacement: String, match_case: bool, whole_word: bool } -> ProjectEdits => {
            let replace = actor.replace(Query::new(&query, match_case, whole_word), replacement);
            actor.before(Reason::ReplaceAll, replace, pending);
        },
        RenameSymbol { kind: SymbolKind, from: String, to: String } -> ProjectEdits => {
            let rename = actor.rename_symbol(kind, from, to);
            actor.before(Reason::Rename, rename, pending);
        },
        ApplyFix { #[schemars(with = "String")] id: Fix } -> Option<Fixed> => actor.fix(id, pending),
        AddCitation { entry: String } -> AddedCitation => actor.add_citation(entry, pending),
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
        StartLive {} -> () = Ok(actor.live.start_asked(&mut actor.core, &actor.docs)),
        StopLive {} -> () = Ok(actor.live.stop_asked(&mut actor.core, &actor.docs)),
        LiveView { first: u32, last: u32 } -> () = Ok(actor.live.view(first, last)),
        LiveLog { shown: bool } -> () = Ok(actor.live.show_log(&mut actor.core, &actor.docs, shown)),
        ImportFiles { dir: String, paths: Vec<PathBuf>, conflict: Option<ImportConflict> } -> Imported
            = actor.import(&dir, &paths, conflict),
        ExportZip { dest: PathBuf, for_arxiv: bool } -> () => actor.export(dest, for_arxiv, pending),
        SetUiState { patch: UiPatch } -> () = actor.write_ui(patch),
        SynctexForward { file: RelPath, line: u32 } -> ForwardLoc => actor.synctex_forward(file.0, line, pending),
        SynctexInverse { page: f64, x: f64, y: f64, click: Option<PageClick> } -> InverseLoc
            => actor.synctex_inverse(page, x, y, click, pending),
        SynctexMatch { file: RelPath, line: u32, column: usize, pages: Vec<PdfPage> } -> Option<PdfHit>
            => actor.synctex_match(file.0, line, column, pages, pending),
        BadBoxAreas {} -> Vec<BadBoxArea> => actor.bad_box_areas(pending),
    }
}

pub(crate) enum Later {
    Compile(bool),
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

pub(crate) struct Core {
    id: u64,
    pub children: u64,
    pub project: Project,
    pub service: Arc<Service>,
    pub compiler: Arc<dyn Compiler>,
    pub preview: Arc<dyn Preview>,
    events: std::sync::mpsc::Sender<Said>,
    pub tx: mpsc::UnboundedSender<Msg>,
    sent: Sent<SessionSection>,
    pub later: VecDeque<Later>,
    pub timers: BTreeMap<Timer, Instant>,
    pub auto_compile: bool,
    pub pdf: Shown,
    pub history: Arc<std::sync::mpsc::Sender<Job>>,
    pub writes_history: Arc<AtomicBool>,
}

impl Core {
    pub fn emit(&self, event: Event) {
        let session = self.id;
        let _ = self
            .events
            .send(Said::Event(SessionEvent { session, event }));
    }

    pub fn publish(&mut self, section: SessionSection) -> bool {
        let Some(said) = self.sent.changed(&section) else {
            return false;
        };
        self.emit(Event::Section(said));
        true
    }

    pub fn after(&mut self, timer: Timer) {
        self.timers.insert(timer, Instant::now() + timer.wait());
    }

    pub fn soon(&mut self, timer: Timer) {
        self.timers
            .entry(timer)
            .or_insert(Instant::now() + timer.wait());
    }
}

pub(crate) struct Actor {
    pub core: Core,
    pub docs: Docs,
    pub builds: Builds,
    tex: signal::Receiver<bool>,
    pub tree: Tree,
    pub live: Live,
    pub snapshots: usize,
    pub queued: VecDeque<OnActor>,
    stage: Stage,
}

impl Actor {
    pub fn new(
        sessions: &Sessions,
        id: u64,
        opening: OpenProject,
        docs: Docs,
        tx: mpsc::UnboundedSender<Msg>,
    ) -> Result<(Self, UiState), CoreError> {
        let OpenProject {
            id: project_id,
            auto_compile,
        } = opening;
        let (project, in_session) = sessions.service.in_session(&project_id)?;
        let nodes = projects::file_tree(&project)?;
        let tree = Tree::new(&project, &nodes, sessions.watch.then(|| tx.clone()));
        let pdf = Shown {
            built: built_pdf(&project),
            ..Shown::default()
        };
        let ui = settings::read_ui(&project.ui);
        let mut timers = BTreeMap::from([(Timer::Symbols, Instant::now())]);
        if ui.live_preview && sessions.preview.available(&sessions.service.tool_paths().1) {
            timers.insert(Timer::Restart, Instant::now());
        }
        let mut later = VecDeque::new();
        if auto_compile && pdf.built.is_none() {
            later.push_back(Later::Compile(true));
        }
        let history = sessions.service.history(&project);
        let core = Core {
            id,
            children: sessions.service.processes.owner(),
            project,
            service: Arc::clone(&sessions.service),
            compiler: Arc::clone(&sessions.compiler),
            preview: Arc::clone(&sessions.preview),
            events: sessions.hub.queue.clone(),
            tx,
            sent: Sent::default(),
            later,
            timers,
            auto_compile,
            pdf,
            history,
            writes_history: Arc::new(AtomicBool::new(true)),
        };
        let mut actor = Self {
            core,
            docs,
            builds: Builds::default(),
            tex: sessions.service.tex_found.subscribe(),
            tree,
            live: Live::default(),
            snapshots: 0,
            queued: VecDeque::new(),
            stage: Stage::Open(in_session),
        };
        actor.reopen(ui.file.clone());
        actor.publish_all(nodes);
        actor.core.snapshot_soon();
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
                self.close_hidden();
            }));
            if step.is_err() {
                return self.stopped(&mut rx);
            }
            if matches!(self.stage, Stage::Closed) {
                return;
            }
            let deadline = self.core.timers.values().min().copied();
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
            self.builds.tex_found(&mut self.core);
        }
    }

    fn stopped(&mut self, rx: &mut mpsc::UnboundedReceiver<Msg>) {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let _ = self.docs.flush_all(&mut self.core, false);
            self.builds.stop();
            self.live.stop(&mut self.core, &self.docs);
        }));
        self.core.stop_history();
        let stopped = Stopped {
            unsaved: self.docs.dirty_paths(),
        };
        self.docs.stopped(&mut self.core);
        self.core
            .publish(SessionSection::Lifecycle(Lifecycle::Stopped(stopped)));
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
        self.builds.stopped();
    }

    fn handle(&mut self, message: Msg) {
        if let Stage::Closing(_, closes) = &mut self.stage {
            return match message {
                Msg::Command(Session::CloseProject(_), reply) => closes.push(Pending::new(reply)),
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
        let (cx, docs) = (&mut self.core, &self.docs);
        match message {
            Msg::Edited { doc, version, edit } => self.edited(doc, version, &edit),
            Msg::Selected { doc, caret } => {
                if let Some(path) = docs.path_of(doc) {
                    self.live.caret(cx, path, caret);
                }
            }
            Msg::Command(command, reply) => command.run(self, reply),
            Msg::BuildDone(result) => self.build_done(result),
            Msg::Cleaned(result) => self.cleaned(result),
            Msg::Symbols { seq, edits, result } => {
                if let Some((checks, outline)) = self.tree.scanned(seq, result) {
                    self.builds.checks_done(cx, docs, checks, edits);
                    cx.publish(SessionSection::Outline(Some(outline)));
                }
            }
            Msg::Live(generation, event) => self.live.event(cx, docs, generation, event),
            Msg::Snapshotted(finish) => finish(self),
            Msg::Fs(changes) => self.tree.changed(cx, changes),
        }
    }

    fn fire(&mut self) {
        let now = Instant::now();
        while let Some((&timer, _)) = self.core.timers.iter().find(|(_, at)| **at <= now) {
            self.core.timers.remove(&timer);
            let (cx, docs) = (&mut self.core, &self.docs);
            match timer {
                Timer::Autosave => self.docs.autosave(cx),
                Timer::Symbols => self.tree.scan(cx, docs, self.builds.clock),
                Timer::Fs => self.files_changed_on_disk(),
                Timer::Caret => self.live.caret_settled(),
                Timer::Follow => self.live.follow(cx, docs),
                Timer::Halting => self.live.halted(cx, docs, true),
                Timer::Restart => self.live.start(cx, docs),
                Timer::Disk => self.live.refresh_disk(cx, docs),
                Timer::Log => self.live.publish_log(cx),
                Timer::Issues => self.live.issues_settled(cx, docs, &self.tree),
            }
        }
    }

    fn run_later(&mut self) {
        while let Some(next) = self.core.later.pop_front() {
            if !matches!(self.stage, Stage::Open(_)) {
                self.core.later.clear();
                return;
            }
            match next {
                Later::Compile(auto) => {
                    let _ = self.compile(auto);
                }
                Later::Rescan => self.live.rescan(),
            }
        }
    }

    /// Saves first; discarding, it saves what it can and closes anyway.
    fn close(&mut self, discard: bool, reply: Pending<bool>) {
        match self.docs.flush_all(&mut self.core, !discard) {
            Ok(true) => {}
            _ if discard => {}
            flushed => return reply.send(flushed),
        }
        let Stage::Open(held) = std::mem::replace(&mut self.stage, Stage::Closed) else {
            unreachable!("a closing session queues its closes")
        };
        self.stage = Stage::Closing(held, vec![reply]);
        self.core
            .publish(SessionSection::Lifecycle(Lifecycle::Closing));
        self.builds.stop();
        self.live.stop(&mut self.core, &self.docs);
        self.docs.clear();
        self.core.timers.clear();
        self.close_when_idle();
    }

    pub fn close_when_idle(&mut self) {
        if self.builds.busy() || self.snapshots > 0 || !matches!(self.stage, Stage::Closing(..)) {
            return;
        }
        self.core.stop_history();
        let closes = self.end();
        self.core
            .publish(SessionSection::Lifecycle(Lifecycle::Closed));
        self.core.service.relist();
        for close in closes {
            close.send(Ok(true));
        }
    }

    fn end(&mut self) -> Vec<Pending<bool>> {
        self.core.service.processes.end(self.core.children);
        match std::mem::replace(&mut self.stage, Stage::Closed) {
            Stage::Closing(held, closes) => {
                drop(held);
                closes
            }
            _ => Vec::new(),
        }
    }
}
