//! The session's side of live preview: what TeXpressoSession.swift kept.
//! Starts, stops and whole texts go one at a time; a key's edit goes on as
//! the editor makes it; a task of the session's own waits for the pages and
//! hands them on as events.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde_json::{Value, json};
use tokio::task::AbortHandle;
use tokio::time::Instant;

use super::Msg;
use super::actor::{Actor, Later};
use crate::CoreError;
use crate::texpresso::{Caret, Events, FileBuffer, Pane, Status};

const DIDNT_START: &str =
    "TeXpresso didn’t start. Check its location in Settings and the log below.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum Phase {
    #[default]
    Stopped,
    Starting,
    Running,
    Stopping,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Phase::Stopped => "stopped",
            Phase::Starting => "starting",
            Phase::Running => "running",
            Phase::Stopping => "stopping",
        }
    }
}

#[derive(Default)]
pub(crate) struct Live {
    pub phase: Phase,
    /// The token of the TeXpresso session this one owns; kept after it ends, for a restart.
    pub owner: Option<String>,
    /// Paths to send whole: None for the document's own text when sent, else a file's text from disk.
    pub pending: BTreeMap<String, Option<String>>,
    /// Paths TeXpresso has as the session has them, so a key's edit fits its copy.
    pub synced: HashSet<String>,
    /// The version of each document last sent whole: edits up to it are in that text.
    sent: HashMap<String, u64>,
    rejected: BTreeMap<String, String>,
    failure: Option<String>,
    reported: BTreeSet<String>,
    pub status: Option<Status>,
    revision: u64,
    pub halted: bool,
    pub halting_at: Option<Instant>,
    started: Option<Instant>,
    view: Option<(u32, u32)>,
    sent_view: Option<(u32, u32)>,
    /// Where the editor's caret is, for a start; and where TeXpresso was last told it is.
    wanted: Option<(String, usize)>,
    caret: Option<(String, usize)>,
    pub settle: Option<(Instant, (String, usize))>,
    pub retry_at: Option<Instant>,
    pub restart_at: Option<Instant>,
    pub disk_paths: BTreeSet<String>,
    pub disk_at: Option<Instant>,
    /// Rises with each Start the user asks for and each Stop: a restart for an older one is dropped.
    pub intent: u64,
    listen_seq: u64,
    listener: Option<AbortHandle>,
    version: u64,
    pub document_seen: bool,
    shown: Value,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, Phase::Starting | Phase::Running)
    }

    fn errors(&self) -> Vec<String> {
        let rejected = self
            .rejected
            .iter()
            .map(|(path, error)| format!("{path}: {error}"));
        self.failure.iter().cloned().chain(rejected).collect()
    }
}

impl Actor {
    pub fn live_state(&self) -> Value {
        let live = &self.live;
        let errors = live.errors();
        json!({
            "phase": live.phase.name(),
            "halted": live.halted,
            "failure": (!errors.is_empty()).then(|| errors.join("\n\n")),
            "error": live.status.as_ref().and_then(|s| s.error.clone()),
            "token": live.owner,
            "revision": live.revision,
        })
    }

    /// `alert`: an error the host hasn't been shown yet.
    pub fn publish_live(&mut self, alert: bool) {
        let state = self.live_state();
        if state != self.live.shown || alert {
            self.live.shown = state.clone();
            let mut state = state;
            state["alert"] = alert.into();
            self.emit("live", state);
        }
    }

    fn report(&mut self) {
        let mut errors: BTreeSet<String> = self.live.errors().into_iter().collect();
        errors.extend(self.live.status.as_ref().and_then(|s| s.error.clone()));
        let alert = !errors.is_subset(&self.live.reported);
        self.live.reported = errors;
        self.publish_live(alert);
    }

    pub fn live_reset(&mut self) {
        let live = &mut self.live;
        live.listen_seq += 1;
        if let Some(listener) = live.listener.take() {
            listener.abort();
        }
        (live.retry_at, live.halting_at, live.settle) = (None, None, None);
        live.pending.clear();
        live.synced.clear();
        live.sent.clear();
        (live.halted, live.started, live.sent_view, live.caret) = (false, None, None, None);
        live.version = 0;
    }

    pub fn live_cancel_work(&mut self) {
        self.live.intent += 1;
        (self.live.restart_at, self.live.disk_at) = (None, None);
        self.live.disk_paths.clear();
    }

    fn fail(&mut self, error: CoreError) {
        self.live.failure = Some(error.message);
        if error.status == 409 {
            // Another window's preview now: nothing more is sent.
            self.live.owner = None;
            self.live_cancel_work();
            self.ended(false);
        }
        self.report();
    }

    fn ended(&mut self, restartable: bool) {
        self.live.phase = Phase::Stopped;
        self.live_reset();
        self.live.rejected.clear();
        self.live.document_seen = false;
        self.publish_live(false);
        if !self.closed {
            if restartable {
                self.later.push_back(Later::Restart { ended: true });
            } else if self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
    }

    fn receive(&mut self, status: Status) {
        self.live.revision = self.live.revision.max(status.revision);
        let running = status.running;
        let failed = status.error.is_none() && self.live.phase == Phase::Starting;
        self.live.status = Some(status);
        if running {
            self.live.phase = Phase::Running;
            self.report();
        } else {
            if failed {
                self.live.failure = Some(DIDNT_START.into());
            }
            self.report();
            self.ended(false);
        }
    }

    /// Whether a start was tried: `replacing` restarts the session this one owned.
    pub async fn live_start(&mut self, replacing: bool) -> bool {
        let phase = self.live.phase;
        if self.closed
            || !replacing && phase != Phase::Stopped
            || replacing
                && (phase == Phase::Stopping
                    || self.live.owner.is_none() && phase != Phase::Starting)
        {
            return false;
        }
        self.live.phase = Phase::Starting;
        self.live.failure = None;
        self.live.rejected.clear();
        self.live.reported.clear();
        self.live_reset();
        self.publish_live(false);
        let expected = self.live.owner.clone().filter(|_| replacing);
        if replacing && expected.is_none() {
            self.ended(false);
            return true;
        }
        let mut files = Vec::new();
        let mut versions = HashMap::new();
        for (path, doc) in &self.docs {
            let (text, version) = doc.doc.snapshot();
            versions.insert(path.clone(), version);
            files.push(FileBuffer {
                path: path.clone(),
                text,
            });
        }
        let caret = self.live.wanted.clone();
        let pane = Pane {
            view: self.live.view,
            caret: caret.clone().map(|(path, offset)| Caret { path, offset }),
        };
        let start = self
            .engine
            .live_start(self.root.clone(), files, expected, pane);
        match start.await {
            Ok(status) => {
                self.live.owner.clone_from(&status.session);
                self.live.synced = versions.keys().cloned().collect();
                self.live.sent = versions;
                (self.live.sent_view, self.live.caret) = (self.live.view, caret);
                self.receive(status);
                if self.live.active() {
                    self.live.started = Some(Instant::now());
                    self.listen();
                    self.flush_pending().await;
                }
            }
            Err(error) => {
                self.fail(error);
                if self.live.phase != Phase::Stopped {
                    self.ended(false);
                }
            }
        }
        true
    }

    pub async fn live_restart(&mut self, ended: bool) {
        let tried = self.live_start(true).await;
        if ended {
            if self.live.active() {
                self.emit("live_restarted", json!({}));
            } else if !tried && self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
    }

    pub async fn live_stop(&mut self) {
        if self.live.phase == Phase::Stopped {
            self.live.owner = None;
            return;
        }
        self.live.phase = Phase::Stopping;
        self.live_reset();
        self.publish_live(false);
        if let Some(owner) = self.live.owner.clone() {
            match self
                .engine
                .live_stop(self.root.clone(), owner.clone())
                .await
            {
                Ok(status) => {
                    if self.live.owner.as_ref() == Some(&owner) {
                        self.live.owner = None;
                    }
                    self.live.status = Some(status);
                }
                Err(error) => {
                    if !self.closed {
                        self.fail(error);
                    }
                }
            }
        }
        if self.live.phase != Phase::Stopped {
            self.ended(false);
        }
    }

    pub fn live_status(&self) -> Result<Value, CoreError> {
        let status = self
            .engine
            .live_status(&self.root, self.live.owner.as_deref());
        serde_json::to_value(status?).map_err(|err| CoreError::internal(err.to_string()))
    }

    // MARK: - Edits

    /// A key's edit, as the document took it: sent on at once where TeXpresso's copy fits it.
    pub async fn live_edited(
        &mut self,
        path: &str,
        version: u64,
        start: u32,
        length: u32,
        text: &str,
    ) {
        if !self.live.active() || self.closed {
            return;
        }
        // Typing takes the engine's snapshot along: the caret there is no news.
        let end = start as usize + text.encode_utf16().count();
        self.live.caret = Some((path.to_owned(), end));
        if self
            .live
            .sent
            .get(path)
            .is_some_and(|sent| version <= *sent)
        {
            return;
        }
        let live = &self.live;
        if live.phase == Phase::Running
            && live.synced.contains(path)
            && !live.pending.contains_key(path)
            && let Some(owner) = live.owner.clone()
        {
            let sent = self
                .engine
                .live_edit(&owner, path, start as usize, length as usize, text);
            match sent {
                Ok(_) => return,
                Err(error) if error.status == 409 => return self.fail(error),
                // Refused, so the copy is a step behind: the whole text puts it right, or says why not.
                Err(_) => {
                    self.live.synced.remove(path);
                }
            }
        }
        self.live.pending.insert(path.to_owned(), None);
        self.flush_pending().await;
    }

    /// A document's whole text is to go: it opened, or the disk's replaced it.
    pub fn live_whole(&mut self, path: &str) {
        if self.live.active() && !self.closed {
            self.live.synced.remove(path);
            self.live.pending.insert(path.to_owned(), None);
            self.later.push_back(Later::FlushLive);
        }
    }

    pub async fn flush_pending(&mut self) {
        if self.live.phase != Phase::Running || self.closed || self.live.pending.is_empty() {
            return;
        }
        self.live.retry_at = None;
        while self.live.phase == Phase::Running && !self.closed {
            let Some((path, text)) = self.live.pending.pop_first() else {
                break;
            };
            let Some(owner) = self.live.owner.clone() else {
                return;
            };
            let (text, version) = match text {
                Some(text) => (text, None),
                None => match self.docs.get(&path) {
                    Some(doc) => {
                        let (text, version) = doc.doc.snapshot();
                        (text, Some(version))
                    }
                    None => continue,
                },
            };
            let update =
                self.engine
                    .live_update(self.root.clone(), path.clone(), text.clone(), owner);
            match update.await {
                Ok(_) => {
                    self.live.rejected.remove(&path);
                    if self.live.pending.is_empty() {
                        self.live.failure = None;
                    }
                    if let Some(version) = version {
                        self.live.sent.insert(path.clone(), version);
                    }
                    if !self.live.pending.contains_key(&path) {
                        self.live.synced.insert(path);
                    }
                    self.publish_live(false);
                }
                // This text can't be taken, whenever it is sent: its error stays until the file is edited.
                Err(error) if error.status == 400 => {
                    self.live.rejected.insert(path, error.message);
                    self.live.failure = None;
                    self.report();
                }
                Err(error) => {
                    self.fail(error);
                    if self.live.phase != Phase::Running {
                        return;
                    }
                    self.live.pending.entry(path).or_insert(Some(text));
                    self.live.retry_at = Some(Instant::now() + self.t.retry);
                    return;
                }
            }
        }
    }

    pub async fn live_rescan(&mut self) {
        let Some(owner) = self.live.owner.clone() else {
            return;
        };
        if self.live.phase != Phase::Running || self.closed {
            return;
        }
        match self.engine.live_rescan(self.root.clone(), owner).await {
            Ok(status) => self.receive(status),
            Err(error) => self.fail(error),
        }
    }

    // MARK: - The view and the caret

    pub fn live_view(&mut self, first: u32, last: u32) {
        let pages = (first, last.max(first));
        self.live.view = Some(pages);
        if self.live.phase == Phase::Running
            && self.live.sent_view != Some(pages)
            && let Some(owner) = &self.live.owner
        {
            self.engine.live_view(owner, pages.0, pages.1);
            self.live.sent_view = Some(pages);
        }
    }

    pub fn live_caret(&mut self, path: String, offset: usize) {
        let moved = (path, offset);
        self.live.wanted = Some(moved.clone());
        if self.live.phase == Phase::Running && self.live.caret.as_ref() != Some(&moved) {
            self.live.settle = Some((Instant::now() + self.t.caret, moved));
        }
    }

    pub fn caret_settled(&mut self) {
        let Some((_, (path, offset))) = self.live.settle.take() else {
            return;
        };
        let live = &self.live;
        let moved = Some((path.clone(), offset));
        if live.phase == Phase::Running
            && live.synced.contains(&path)
            && !live.pending.contains_key(&path)
            && live.caret != moved
            && let Some(owner) = live.owner.clone()
        {
            self.live.caret = moved;
            self.engine.live_caret(&owner, &path, offset);
        }
    }

    // MARK: - Files on disk

    /// The tree changed: TeXpresso keeps the texts it has through a rescan,
    /// so only a new session drops one whose file went.
    pub fn live_files_changed(&mut self) {
        if !self.live.active() {
            return;
        }
        let live = &self.live;
        let mut files = live.synced.iter().chain(live.pending.keys());
        if files.all(|path| self.tree.contains(path)) {
            self.later.push_back(Later::Rescan);
        } else {
            self.live.restart_at = Some(Instant::now() + self.t.live_follow);
        }
    }

    /// Files changed on disk reach TeXpresso. A save of an open document isn't news to it:
    /// a rescan as it typesets the edit stalled it (TeXpresso e8df770).
    pub async fn refresh_live_disk(&mut self) {
        let mut others = false;
        for path in std::mem::take(&mut self.live.disk_paths) {
            if !self.live.active() || self.closed {
                return;
            }
            if self.docs.contains_key(&path) {
                continue;
            }
            others = true;
            if is_text_file(&path)
                && let Ok(bytes) = std::fs::read(self.root.join(&path))
            {
                self.live.synced.remove(&path);
                let text = crate::lossy_string(bytes);
                self.live.pending.insert(path, Some(text));
            }
        }
        if others {
            self.flush_pending().await;
            self.live_rescan().await;
        }
    }

    // MARK: - What the preview sends back

    fn listen(&mut self) {
        let Some(owner) = self.live.owner.clone() else {
            return;
        };
        self.live.listen_seq += 1;
        let (seq, engine, root, tx) = (
            self.live.listen_seq,
            std::sync::Arc::clone(&self.engine),
            self.root.clone(),
            self.tx.clone(),
        );
        let task = tokio::spawn(async move {
            let mut after = 0;
            loop {
                let news = engine.live_wait(root.clone(), owner.clone(), after).await;
                let running = news.as_ref().is_ok_and(|events| events.running);
                if let Ok(events) = &news {
                    after = events.seq;
                }
                if tx.send(Msg::LiveNews(seq, news)).is_err() || !running {
                    break;
                }
            }
        });
        self.live.listener = Some(task.abort_handle());
    }

    pub fn live_news(&mut self, seq: u64, news: Result<Events, CoreError>) {
        if seq != self.live.listen_seq {
            return;
        }
        let events = match news {
            Ok(events) => events,
            Err(error) => {
                // Another window's preview now, or a core that can't be asked.
                self.fail(error);
                if self.live.phase != Phase::Stopped {
                    self.ended(false);
                }
                return;
            }
        };
        if events.revision > self.live.revision {
            self.live.revision = events.revision;
            self.publish_live(false);
        }
        let run = events.done.as_ref().map(|done| done.run.as_str());
        let run = run.or(events.pdf.as_ref().and_then(|pdf| pdf.run.as_deref()));
        if let Some(pdf) = &events.pdf {
            // The core keeps the latest document only: one replaced unread took its changed pages with it.
            let skipped = pdf.version != self.live.version + 1;
            self.live.version = pdf.version;
            if pdf.pages > 0 {
                self.live.document_seen = true;
                let complete = !matches!(pdf.run.as_deref(), Some("stopped" | "partial"));
                self.emit(
                    "live_document",
                    json!({
                        "path": pdf.path,
                        "version": pdf.version,
                        "serial": pdf.serial,
                        "pages": pdf.pages,
                        "changed": if skipped { None } else { pdf.changed.clone() },
                        "complete": complete,
                    }),
                );
            }
        }
        for page in &events.pages {
            self.emit(
                "live_page",
                json!({ "page": page.page, "path": page.path, "serial": page.serial }),
            );
        }
        match run {
            Some("partial") | None => {}
            Some(run) => self.run_ended(run == "stopped"),
        }
        if !events.running {
            let restartable = events.error.is_some()
                && self.live.owner.is_some()
                && self
                    .live
                    .started
                    .is_some_and(|at| at.elapsed() > self.t.restartable_after);
            if !restartable && let Some(error) = &events.error {
                self.live.failure = Some(error.clone());
                self.report();
            }
            self.ended(restartable);
        }
    }

    /// A brace or a dollar half typed stops TeX for a moment at every other key,
    /// so a stopped run is said so only once it has lasted a while.
    fn run_ended(&mut self, stopped: bool) {
        if !stopped {
            self.live.halting_at = None;
            if self.live.halted {
                self.live.halted = false;
                self.publish_live(false);
            }
        } else if !self.live.halted && self.live.halting_at.is_none() {
            self.live.halting_at = Some(Instant::now() + self.t.halts_after);
        }
    }
}

/// The files the editor opens as text, as the Mac app's `isTextFile` has them.
pub(crate) fn is_text_file(path: &str) -> bool {
    let ext = path
        .rsplit_once('.')
        .map_or("", |(_, ext)| ext)
        .to_ascii_lowercase();
    const TEXT: &[&str] = &[
        "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
        "py", "r", "dat", "def", "clo", "tikz",
    ];
    !path.rsplit('/').next().unwrap_or(path).starts_with('.') && TEXT.contains(&ext.as_str())
}
