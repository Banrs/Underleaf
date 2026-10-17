//! The session's side of live preview. Starts, stops and whole texts go one at
//! a time; a key's edit goes on as the editor makes it; the session waits for
//! TeXpresso's news beside its messages and hands the pages on as events.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};
use tokio::time::Instant;

use super::actor::{Actor, Timer};
use super::engine::{Call, Fut};
use crate::CoreError;
use crate::projects::file_kind;
use crate::texpresso::{Caret, Events, FileBuffer, Pane, Status};

/// A brace or a dollar half typed stops TeX for a moment at every other key,
/// so a stopped run is said so only once it has lasted this long.
const HALTS_AFTER: Duration = Duration::from_secs(1);
/// From a caret's move to telling TeXpresso where it settled.
const CARET: Duration = Duration::from_millis(150);
/// From a rename, a new main file or a changed file to the preview catching up.
pub(super) const FOLLOW: Duration = Duration::from_millis(180);
/// From a whole text TeXpresso couldn't be asked to take to sending it again.
const RETRY: Duration = Duration::from_millis(750);
/// A preview that ends by itself with an error after this long is started again.
const RESTARTABLE_AFTER: Duration = Duration::from_secs(10);

const DIDNT_START: &str =
    "TeXpresso didn’t start. Check its location in Settings and the log below.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Phase {
    #[default]
    Stopped,
    Starting,
    Running,
    Stopping,
}

#[derive(Default)]
pub(crate) struct Live {
    pub phase: Phase,
    /// Whether the project's TeXpresso preview is this session's: kept after it ends, for a
    /// restart; gone with the user's Stop or another session's Start.
    owns: bool,
    /// Paths to send whole: an open document's text, else the file's on disk.
    pending: BTreeSet<String>,
    /// Paths TeXpresso has as the session has them, so a key's edit fits its copy.
    synced: HashSet<String>,
    /// The version of each document last sent whole: edits up to it are in that text.
    sent: HashMap<String, u64>,
    rejected: BTreeMap<String, String>,
    failure: Option<String>,
    reported: BTreeSet<String>,
    /// TeXpresso's own error, as it last said.
    error: Option<String>,
    /// TeXpresso's as last seen: when it rises, the log may have changed.
    revision: u64,
    /// The host shows the Live Preview Log: the `live` event carries it.
    log_shown: bool,
    pub halted: bool,
    started: Option<Instant>,
    view: Option<(u32, u32)>,
    sent_view: Option<(u32, u32)>,
    /// Where the editor's caret is; and where TeXpresso was last told it is.
    wanted: Option<(String, usize)>,
    caret: Option<(String, usize)>,
    pub disk_paths: BTreeSet<String>,
    /// Rises with each Start the user asks for and each Stop: a restart for an older one is dropped.
    pub intent: u64,
    /// TeXpresso's own window shows the document, as the user's Start asked: the host's pane
    /// gets none, and TeXpresso is told no view or caret.
    pub window: bool,
    /// TeXpresso's next news, while the preview runs.
    pub waiting: Option<Fut<Result<Events, CoreError>>>,
    /// The last document's version: the core keeps only the latest.
    version: u64,
    pub document_seen: bool,
    shown: Value,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, Phase::Starting | Phase::Running)
    }

    /// Whether a key's edit or a caret at `path` fits the copy TeXpresso has; a path
    /// pending is never synced.
    fn fits(&self, path: &str) -> bool {
        self.phase == Phase::Running && self.synced.contains(path)
    }

    fn errors(&self) -> impl Iterator<Item = String> {
        let rejected = self
            .rejected
            .iter()
            .map(|(path, error)| format!("{path}: {error}"));
        self.failure.iter().cloned().chain(rejected)
    }
}

impl Actor {
    fn live_call(&self, call: Call) -> Result<Status, CoreError> {
        self.engine.live(self.id, call)
    }

    pub fn live_state(&self) -> Value {
        let live = &self.live;
        let errors: Vec<String> = live.errors().collect();
        let failure = (!errors.is_empty()).then(|| errors.join("\n\n"));
        json!({
            "phase": live.phase,
            "halted": live.halted,
            "log": live.log_shown.then(|| self.live_log(failure.as_deref())),
            "failure": failure,
            "error": live.error,
        })
    }

    /// The Live Preview Log as the host shows it: what went wrong, then the preview's own
    /// error, its log and its output.
    fn live_log(&self, failure: Option<&str>) -> String {
        let status = self.live.owns.then(|| self.live_call(Call::Status));
        let mut parts: Vec<&str> = failure.into_iter().collect();
        if let Some(Ok(status)) = &status {
            parts.extend(
                status
                    .error
                    .as_deref()
                    .filter(|&error| Some(error) != failure),
            );
            let texts = [status.log.as_str(), status.output.as_str()];
            parts.extend(texts.into_iter().filter(|text| !text.is_empty()));
        }
        parts.join("\n\n")
    }

    /// `alert`: an error the host hasn't been shown yet.
    pub fn publish_live(&mut self, alert: bool) {
        let mut state = self.live_state();
        if state != self.live.shown || alert {
            self.live.shown = state.clone();
            state["alert"] = alert.into();
            // The host opens the log on an alert: it comes along.
            if alert && !self.live.log_shown {
                state["log"] = self.live_log(state["failure"].as_str()).into();
            }
            self.emit("live", state);
        }
    }

    /// The host shows the Live Preview Log, or no longer does.
    pub fn show_live_log(&mut self, shown: bool) {
        self.live.log_shown = shown;
        if shown {
            self.publish_live(false);
        }
    }

    fn report(&mut self) {
        let mut errors: BTreeSet<String> = self.live.errors().collect();
        errors.extend(self.live.error.clone());
        let alert = !errors.is_subset(&self.live.reported);
        self.live.reported = errors;
        self.publish_live(alert);
    }

    fn live_reset(&mut self) {
        let live = &mut self.live;
        live.waiting = None;
        live.pending.clear();
        live.synced.clear();
        live.sent.clear();
        (live.halted, live.started, live.sent_view) = (false, None, None);
        (live.caret, live.version) = (None, 0);
        for timer in [Timer::Retry, Timer::Halt, Timer::Caret] {
            self.timers.remove(&timer);
        }
    }

    pub fn live_cancel_work(&mut self) {
        self.live.intent += 1;
        self.timers.remove(&Timer::Restart);
        self.timers.remove(&Timer::Disk);
        self.live.disk_paths.clear();
    }

    fn fail(&mut self, error: CoreError) {
        self.live.failure = Some(error.message);
        if error.status == 409 {
            // Another window's preview now: nothing more is sent.
            self.live.owns = false;
            self.live_cancel_work();
            self.ended(false);
        }
        self.report();
    }

    /// A failure that ends the preview, if `fail` hasn't already.
    fn give_up(&mut self, error: CoreError) {
        self.fail(error);
        if self.live.phase != Phase::Stopped {
            self.ended(false);
        }
    }

    fn ended(&mut self, restartable: bool) {
        self.live.phase = Phase::Stopped;
        self.live_reset();
        self.live.rejected.clear();
        self.live.document_seen = false;
        self.publish_live(false);
        if restartable {
            self.live_restart(true);
        } else {
            self.auto_build();
        }
    }

    fn receive(&mut self, status: Status) {
        self.live.revision = self.live.revision.max(status.revision);
        if status.running {
            self.live.phase = Phase::Running;
        } else if status.error.is_none() && self.live.phase == Phase::Starting {
            self.live.failure = Some(DIDNT_START.into());
        }
        self.live.error = status.error;
        self.report();
        if !status.running {
            self.ended(false);
        }
    }

    /// Whether a start was tried: `replacing` restarts the preview this session owns.
    pub fn live_start(&mut self, replacing: bool) -> bool {
        let phase = self.live.phase;
        if replacing && (phase == Phase::Stopping || !self.live.owns)
            || !replacing && phase != Phase::Stopped
        {
            return false;
        }
        self.live.phase = Phase::Starting;
        self.live.failure = None;
        self.live.rejected.clear();
        self.live.reported.clear();
        self.live_reset();
        self.publish_live(false);
        let mut versions = HashMap::new();
        let files = self.docs.iter().map(|doc| {
            let (text, version) = doc.doc.snapshot();
            versions.insert(doc.path.clone(), version);
            FileBuffer {
                path: doc.path.clone(),
                text,
            }
        });
        let files: Vec<FileBuffer> = files.collect();
        let caret = self.live.wanted.clone().filter(|_| !self.live.window);
        let pane = (!self.live.window).then(|| Pane {
            view: self.live.view,
            caret: caret.clone().map(|(path, offset)| Caret { path, offset }),
        });
        let root = &self.root;
        let pane = pane.as_ref();
        match self.live_call(Call::Start {
            root,
            files: &files,
            replacing,
            pane,
        }) {
            Ok(status) => {
                self.live.owns = true;
                self.live.synced = versions.keys().cloned().collect();
                self.live.sent = versions;
                (self.live.sent_view, self.live.caret) = (self.live.view, caret);
                self.receive(status);
                if self.live.active() {
                    self.live.started = Some(Instant::now());
                    self.listen(0);
                }
            }
            Err(error) => self.give_up(error),
        }
        true
    }

    /// The session's own start again; `ended`: the preview ended by itself.
    pub fn live_restart(&mut self, ended: bool) {
        let tried = self.live_start(true);
        if ended {
            if self.live.active() {
                self.emit("live_restarted", json!({}));
            } else if !tried {
                self.auto_build();
            }
        }
    }

    pub fn live_stop(&mut self) {
        if self.live.phase == Phase::Stopped {
            self.live.owns = false;
            return;
        }
        self.live.phase = Phase::Stopping;
        self.live_reset();
        self.publish_live(false);
        if self.live.owns {
            match self.live_call(Call::Stop) {
                Ok(status) => (self.live.owns, self.live.error) = (false, status.error),
                Err(error) if !self.closed => self.fail(error),
                Err(_) => {}
            }
        }
        if self.live.phase != Phase::Stopped {
            self.ended(false);
        }
    }

    // MARK: - Edits

    /// A key's edit, as the document took it: sent on at once where TeXpresso's copy fits it.
    pub fn live_edited(&mut self, path: &str, version: u64, start: u32, length: u32, text: &str) {
        if !self.live.active() {
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
        if self.live.fits(path) {
            match self.live_call(Call::Edit(path, start as usize, length as usize, text)) {
                Ok(_) => return,
                Err(error) if error.status == 409 => return self.fail(error),
                // Refused, so the copy is a step behind: the whole text puts it right, or says why not.
                Err(_) => {}
            }
        }
        self.live_whole(path);
    }

    /// A file's whole text is to go: a document opened, the disk's replaced it, or TeXpresso's
    /// copy is behind.
    pub fn live_whole(&mut self, path: &str) {
        if self.live.active() {
            self.live.synced.remove(path);
            self.live.pending.insert(path.to_owned());
            self.flush_pending();
        }
    }

    pub fn flush_pending(&mut self) {
        if self.live.phase != Phase::Running || self.live.pending.is_empty() {
            return;
        }
        self.timers.remove(&Timer::Retry);
        while self.live.phase == Phase::Running
            && let Some(path) = self.live.pending.pop_first()
        {
            let (text, version) = match self.doc(&path) {
                Some(doc) => {
                    let (text, version) = doc.doc.snapshot();
                    (text, Some(version))
                }
                None => match std::fs::read(self.root.join(&path)) {
                    Ok(bytes) if is_text_file(&path) => (crate::lossy_string(bytes), None),
                    _ => continue,
                },
            };
            match self.live_call(Call::Update(&path, &text)) {
                Ok(_) => {
                    self.live.rejected.remove(&path);
                    if self.live.pending.is_empty() {
                        self.live.failure = None;
                    }
                    if let Some(version) = version {
                        self.live.sent.insert(path.clone(), version);
                    }
                    self.live.synced.insert(path);
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
                    if self.live.phase == Phase::Running {
                        self.live.pending.insert(path);
                        self.after(Timer::Retry, RETRY);
                    }
                    return;
                }
            }
        }
    }

    pub fn live_rescan(&mut self) {
        if self.live.phase == Phase::Running {
            match self.live_call(Call::Rescan) {
                Ok(status) => self.receive(status),
                Err(error) => self.fail(error),
            }
        }
    }

    // MARK: - The view and the caret

    pub fn live_view(&mut self, first: u32, last: u32) {
        let pages = (first, last.max(first));
        self.live.view = Some(pages);
        if self.live.phase == Phase::Running
            && !self.live.window
            && self.live.sent_view != Some(pages)
        {
            let _ = self.live_call(Call::View(pages.0, pages.1));
            self.live.sent_view = Some(pages);
        }
    }

    pub fn live_caret(&mut self, path: String, offset: usize) {
        let moved = Some((path, offset));
        if self.live.phase == Phase::Running && !self.live.window && self.live.caret != moved {
            self.after(Timer::Caret, CARET);
        }
        self.live.wanted = moved;
    }

    pub fn caret_settled(&mut self) {
        if let Some((path, offset)) = &self.live.wanted
            && self.live.fits(path)
            && self.live.caret != self.live.wanted
        {
            let _ = self.live_call(Call::Caret(path, *offset));
            self.live.caret.clone_from(&self.live.wanted);
        }
    }

    // MARK: - Files on disk

    /// The tree changed: TeXpresso keeps the texts it has through a rescan,
    /// so only a new session drops one whose file went.
    pub fn live_files_changed(&mut self) {
        if !self.live.active() {
            return;
        }
        let mut files = self.live.synced.iter().chain(&self.live.pending);
        if files.all(|path| self.tree.contains(path)) {
            self.live_rescan();
        } else {
            self.after(Timer::Restart, FOLLOW);
        }
    }

    /// Files changed on disk reach TeXpresso. A save of an open document isn't news to it:
    /// a rescan as it typesets the edit stalled it (TeXpresso e8df770).
    pub fn refresh_live_disk(&mut self) {
        let paths = std::mem::take(&mut self.live.disk_paths);
        let others: Vec<String> = paths
            .into_iter()
            .filter(|path| self.doc(path).is_none())
            .collect();
        if !self.live.active() || others.is_empty() {
            return;
        }
        for path in others.into_iter().filter(|path| is_text_file(path)) {
            self.live.synced.remove(&path);
            self.live.pending.insert(path);
        }
        self.flush_pending();
        self.live_rescan();
    }

    // MARK: - What the preview sends back

    /// Waits for the news after the `after`th.
    fn listen(&mut self, after: u64) {
        self.live.waiting = Some(Arc::clone(&self.engine).live_wait(self.id, after));
    }

    pub fn live_news(&mut self, news: Result<Events, CoreError>) {
        let events = match news {
            Ok(events) => events,
            // Another window's preview now, or a core that can't be asked.
            Err(error) => return self.give_up(error),
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
                let document = json!({
                    "path": pdf.path,
                    "version": pdf.version,
                    "serial": pdf.serial,
                    "pages": pdf.pages,
                    "changed": if skipped { None } else { pdf.changed.as_ref() },
                    "complete": complete,
                });
                self.emit("live_document", document);
            }
        }
        for page in &events.pages {
            let page = json!({ "page": page.page, "path": page.path, "serial": page.serial });
            self.emit("live_page", page);
        }
        match run {
            None | Some("partial") => {}
            Some("stopped") if !self.live.halted => {
                let halts = Instant::now() + HALTS_AFTER;
                self.timers.entry(Timer::Halt).or_insert(halts);
            }
            Some("stopped") => {}
            Some(_) => {
                self.timers.remove(&Timer::Halt);
                if self.live.halted {
                    self.live.halted = false;
                    self.publish_live(false);
                }
            }
        }
        if events.running {
            return self.listen(events.seq);
        }
        let lasted = self
            .live
            .started
            .is_some_and(|at| at.elapsed() > RESTARTABLE_AFTER);
        let restartable = events.error.is_some() && self.live.owns && lasted;
        if !restartable && let Some(error) = events.error {
            self.live.failure = Some(error);
            self.report();
        }
        self.ended(restartable);
    }
}

/// The files the editor opens as text, as the Mac app's `isTextFile` has them: those
/// `file_kind` gives as text, but for hidden ones.
fn is_text_file(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    !name.starts_with('.') && matches!(file_kind(name), "tex" | "bib" | "text")
}
