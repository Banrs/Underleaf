use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use notify::RecommendedWatcher;
use texlocal_latex::diff::DiffLine;
use texlocal_latex::logparse::Fix;
use texlocal_latex::search::Query;
use texlocal_latex::syntax::SymbolKind;
use texlocal_latex::wordmatch::{PdfHit, PdfPage};
use tokio::sync::{mpsc, oneshot, watch as signal};
use tokio::time::Instant;

use super::build::{Builds, built_pdf};
use super::documents::{Docs, Resolution};
use super::edits::{DocumentEdits, Fixed, ProjectEdits};
use super::live::Live;
use super::navigate::{QuickHelp, QuickOpenItem};
use super::scans::Usages;
use super::state::Sent;
use super::watch::{self, Change, TreeIndex};
use super::{Compiler, Msg, Pending, Preview, Reply, Sessions};
use crate::CoreError;
use crate::events::{Event, Queued, SessionEvent};
use crate::import::{ImportConflict, Imported};
use crate::messages;
use crate::paths::{Project, RelPath};
use crate::projects::{self, History, RenameResult, SearchGroup, Snapshot, Symbols};
use crate::protocol::requests;
use crate::service::{InSession, Service};
use crate::settings::{self, SettingsPatch, UiPatch, UiState};
use crate::synctex::{ForwardLoc, InverseLoc, PageClick};

requests! {
    Session {
        OpenProject { id: String, auto_compile: bool } -> UiState,
        CloseProject {} -> bool,
        SetOptions { auto_compile: bool } -> (),
        Open { path: RelPath } -> Option<String>,
        Composing { path: RelPath, composing: bool } -> (),
        Save { reporting: bool } -> bool,
        Resolve { path: RelPath, answer: Resolution } -> (),
        Compile { auto: bool } -> (),
        StopCompile {} -> (),
        Clean {} -> (),
        Search { query: String, match_case: bool, whole_word: bool } -> Vec<SearchGroup>,
        FindUsages { path: RelPath, offset: u32 } -> Option<Usages>,
        LookUp { path: RelPath, offset: u32 } -> Option<QuickHelp>,
        QuickOpen { query: String } -> Vec<QuickOpenItem>,
        Replace { query: String, replacement: String, match_case: bool, whole_word: bool } -> ProjectEdits,
        RenameSymbol { kind: SymbolKind, from: String, to: String } -> ProjectEdits,
        ApplyFix { #[schemars(with = "String")] id: Fix } -> Option<Fixed>,
        ListVersions {} -> Vec<Snapshot>,
        SaveVersion { name: String } -> Option<Snapshot>,
        CompareVersion { id: String, path: RelPath } -> Vec<DiffLine>,
        RestoreVersion { id: String, paths: Option<Vec<RelPath>> } -> Option<DocumentEdits>,
        Rename { from: RelPath, to: String } -> Option<RenameResult>,
        CreateEntry { folder: String, name: String, dir: bool } -> String,
        SetSettings { patch: SettingsPatch } -> (),
        PrepareDelete { path: RelPath } -> bool,
        Deleted { path: RelPath, trashed: bool } -> (),
        StartLive {} -> (),
        StopLive {} -> (),
        LiveView { first: u32, last: u32 } -> (),
        LiveCaret { path: RelPath, offset: usize } -> (),
        LiveLog { shown: bool } -> (),
        ReloadTree {} -> (),
        ImportFiles { dir: String, paths: Vec<PathBuf>, conflict: Option<ImportConflict> } -> Imported,
        ExportZip { dest: PathBuf, for_arxiv: bool } -> (),
        SetUiState { patch: UiPatch } -> (),
        SynctexForward { file: RelPath, line: u32 } -> ForwardLoc,
        SynctexInverse { page: f64, x: f64, y: f64, click: Option<PageClick> } -> InverseLoc,
        SynctexMatch { file: RelPath, line: u32, column: usize, pages: Vec<PdfPage> } -> Option<PdfHit>,
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
    pub compiler: Arc<dyn Compiler>,
    pub preview: Arc<dyn Preview>,
    events: std::sync::mpsc::Sender<Queued>,
    pub tx: mpsc::UnboundedSender<Msg>,
    pub docs: Docs,
    pub next_doc: u64,
    pub open: Option<String>,
    pub opens: Arc<AtomicU64>,
    pub symbols: Arc<RwLock<Arc<Symbols>>>,
    pub symbols_seq: u64,
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
    pub writes_history: Arc<AtomicBool>,
    pub sent: Sent,
    in_session: Option<InSession>,
    closing: Option<Pending<bool>>,
    closed: bool,
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
        let in_session = sessions.service.in_session(&project_id);
        let project = sessions.service.project(&project_id)?;
        let tree = projects::file_tree(&project)?;
        let watcher = sessions
            .watch
            .then(|| watch::watch(&project.root, tx.clone()))
            .flatten();
        let mut builds = Builds::default();
        builds.pdf = built_pdf(&project);
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
            project_id,
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
            symbols: Arc::default(),
            symbols_seq: 0,
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
            writes_history: Arc::new(AtomicBool::new(true)),
            sent: Sent::default(),
            in_session: Some(in_session),
            closing: None,
            closed: false,
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
            if self.closed {
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
        self.closed = true;
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let _ = self.flush_all(false);
            self.stop_compile();
            self.live_stop();
        }));
        self.stop_history();
        for (_, doc) in self.docs.iter_mut() {
            doc.doc.close();
            doc.error = Some(if doc.dirty() {
                messages::stopped_unsaved()
            } else {
                messages::stopped_saved()
            });
        }
        self.publish_documents();
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

    pub fn emit(&self, event: Event) {
        let session = self.id;
        let _ = self
            .events
            .send(Queued::Event(SessionEvent { session, event }));
    }

    fn handle(&mut self, message: Msg) {
        match message {
            Msg::Changed { doc, version, edit } => self.changed(doc, version, &edit),
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
            if self.closed || self.closing.is_some() {
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
    fn command(&mut self, command: Session, reply: Reply) {
        let answer = match command {
            Session::OpenProject(_, answer) => {
                answer(Err(CoreError::conflict(messages::session_open())))
            }
            Session::CloseProject(CloseProject {}, answer) => {
                return self.close(Pending { reply, answer });
            }
            Session::SetOptions(SetOptions { auto_compile }, answer) => {
                answer(Ok(self.auto_compile = auto_compile))
            }
            Session::Open(Open { path }, answer) => answer(self.open(&path.0)),
            Session::Composing(Composing { path, composing }, answer) => {
                answer(Ok(self.composing(&path.0, composing)))
            }
            Session::Save(Save { reporting }, answer) => answer(self.save_edits(reporting)),
            Session::Resolve(Resolve { path, answer: to }, answer) => {
                answer(self.resolve(&path.0, to))
            }
            Session::Compile(Compile { auto }, answer) => answer(self.compile(auto)),
            Session::StopCompile(StopCompile {}, answer) => answer(Ok(self.stop_compile())),
            Session::Clean(Clean {}, answer) => return self.clean(Pending { reply, answer }),
            Session::Search(
                Search {
                    query,
                    match_case,
                    whole_word,
                },
                answer,
            ) => {
                let query = Query::new(&query, match_case, whole_word);
                return self.search(query, Pending { reply, answer });
            }
            Session::FindUsages(FindUsages { path, offset }, answer) => {
                return self.usages(&path.0, offset, Pending { reply, answer });
            }
            Session::LookUp(LookUp { path, offset }, answer) => {
                return self.quick_help(&path.0, offset, Pending { reply, answer });
            }
            Session::QuickOpen(QuickOpen { query }, answer) => {
                return self.quick_open(query, Pending { reply, answer });
            }
            Session::Replace(
                Replace {
                    query,
                    replacement,
                    match_case,
                    whole_word,
                },
                answer,
            ) => answer(self.replace(&Query::new(&query, match_case, whole_word), &replacement)),
            Session::RenameSymbol(RenameSymbol { kind, from, to }, answer) => {
                answer(self.rename_symbol(kind, &from, &to))
            }
            Session::ApplyFix(ApplyFix { id }, answer) => {
                return self.fix(id, Pending { reply, answer });
            }
            Session::ListVersions(ListVersions {}, answer) => {
                return self.history_list(Pending { reply, answer });
            }
            Session::SaveVersion(SaveVersion { name }, answer) => {
                return self.history_save(name, Pending { reply, answer });
            }
            Session::CompareVersion(CompareVersion { id, path }, answer) => {
                return self.history_compare(id, path.0, Pending { reply, answer });
            }
            Session::RestoreVersion(RestoreVersion { id, paths }, answer) => {
                answer(self.history_restore(&id, paths))
            }
            Session::Rename(Rename { from, to }, answer) => answer(self.rename(&from.0, &to)),
            Session::CreateEntry(CreateEntry { folder, name, dir }, answer) => {
                answer(self.create_entry(&folder, &name, dir))
            }
            Session::SetSettings(SetSettings { patch }, answer) => {
                answer(self.set_settings(&patch, true))
            }
            Session::PrepareDelete(PrepareDelete { path }, answer) => {
                answer(self.prepare_delete(&path.0))
            }
            Session::Deleted(Deleted { path, trashed }, answer) => {
                answer(Ok(self.deleted(&path.0, trashed)))
            }
            Session::StartLive(StartLive {}, answer) => answer(Ok(self.live_start_asked())),
            Session::StopLive(StopLive {}, answer) => answer(Ok(self.live_stop_asked())),
            Session::LiveView(LiveView { first, last }, answer) => {
                answer(Ok(self.live_view(first, last)))
            }
            Session::LiveCaret(LiveCaret { path, offset }, answer) => {
                answer(Ok(self.live_caret(path.0, offset)))
            }
            Session::LiveLog(LiveLog { shown }, answer) => answer(Ok(self.show_live_log(shown))),
            Session::ReloadTree(ReloadTree {}, answer) => answer(Ok(self.reload_tree())),
            Session::ImportFiles(
                ImportFiles {
                    dir,
                    paths,
                    conflict,
                },
                answer,
            ) => answer(self.import(&dir, &paths, conflict)),
            Session::ExportZip(ExportZip { dest, for_arxiv }, answer) => {
                return self.export(dest, for_arxiv, Pending { reply, answer });
            }
            Session::SetUiState(SetUiState { patch }, answer) => answer(self.write_ui(patch)),
            Session::SynctexForward(SynctexForward { file, line }, answer) => {
                return self.synctex_forward(file.0, line, Pending { reply, answer });
            }
            Session::SynctexInverse(SynctexInverse { page, x, y, click }, answer) => {
                return self.synctex_inverse(page, x, y, click, Pending { reply, answer });
            }
            Session::SynctexMatch(
                SynctexMatch {
                    file,
                    line,
                    column,
                    pages,
                },
                answer,
            ) => answer(self.synctex_match(&file.0, line, column, &pages)),
        };
        reply.send(answer);
    }

    fn close(&mut self, reply: Pending<bool>) {
        match self.flush_all(true) {
            Ok(true) => self.closing = Some(reply),
            flushed => return reply.send(flushed),
        }
        self.stop_compile();
        self.live_stop();
        self.docs.clear();
        self.close_when_idle();
    }

    pub fn close_when_idle(&mut self) {
        if self.builds.busy() {
            return;
        }
        let Some(reply) = self.closing.take() else {
            return;
        };
        self.stop_history();
        self.closed = true;
        self.in_session = None;
        let _ = self.service.publish_projects();
        reply.send(Ok(true));
    }
}
