//! The session's side of live preview. Starts, stops and whole texts go one at a time; a
//! key's edit goes on as the editor makes it; what the preview tells comes back as messages
//! of the session's own (`Msg::Live`) and goes on to the host as events.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};
use tokio::time::Instant;

use super::Msg;
use super::actor::{Actor, Later, Timer};
use crate::CoreError;
use crate::projects::file_kind;
use crate::texpresso::{FileBuffer, LiveEvent, Pane, Status};

const DIDNT_START: &str =
    "TeXpresso didn’t start. Check its location in Settings and the log below.";
/// The Live Preview Log follows TeX's at most this often: its whole text is copied, sent and
/// laid out again each time, beside pages that must land within a frame.
const LOG_EVERY: Duration = Duration::from_millis(200);

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
    phase: Phase,
    /// Whether the project's TeXpresso preview is this session's: kept after it ends, for a
    /// restart; gone with the user's Stop or another session's Start.
    owns: bool,
    /// Paths to send whole: None for the document's own text when sent, else a file's text from disk.
    pending: BTreeMap<String, Option<String>>,
    /// Paths TeXpresso has a text of. It keeps them through a rescan: only a new start drops
    /// one whose file went.
    synced: HashSet<String>,
    /// The version of each document last sent whole: edits up to it are in that text.
    sent: HashMap<String, u64>,
    rejected: BTreeMap<String, String>,
    failure: Option<String>,
    reported: BTreeSet<String>,
    status: Option<Status>,
    /// The host shows the Live Preview Log: the `live` event carries it.
    log_shown: bool,
    halted: bool,
    started: Option<Instant>,
    view: Option<(u32, u32)>,
    sent_view: Option<(u32, u32)>,
    /// Where the editor's caret is, for a start; where TeXpresso was last told it is; and
    /// where it has moved to, told once it settles (`Timer::Caret`).
    wanted: Option<(String, usize)>,
    caret: Option<(String, usize)>,
    settling: Option<(String, usize)>,
    pub disk_paths: BTreeSet<String>,
    /// Rises with each Start the user asks for and each Stop: a restart for an older one is dropped.
    pub intent: u64,
    /// TeXpresso's own window shows the document, as the user's Start asked: the host's pane
    /// gets none.
    window: bool,
    /// Rises with each start and each end: what an earlier start's preview tells is dropped.
    generation: u64,
    /// The documents this start's preview has written, and its documents and pages.
    version: u64,
    serial: u64,
    pub document_seen: bool,
    shown: Value,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, Phase::Starting | Phase::Running)
    }

    /// Whether a key's edit or a caret at `path` may go to TeXpresso as it is: no whole text
    /// is waiting to go before it. One its copy can't take is refused (412).
    fn fits(&self, path: &str) -> bool {
        self.phase == Phase::Running && !self.pending.contains_key(path)
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
        let failure = (!errors.is_empty()).then(|| errors.join("\n\n"));
        json!({
            "phase": live.phase,
            "halted": live.halted,
            "log": live.log_shown.then(|| self.live_log(failure.as_deref())),
            "failure": failure,
            "error": live.status.as_ref().and_then(|s| s.error.clone()),
        })
    }

    /// The Live Preview Log as the host shows it: what went wrong, then the preview's own
    /// error, its log and its output.
    fn live_log(&self, failure: Option<&str>) -> String {
        let status = self.live.owns.then(|| self.preview.status(self.id));
        let mut parts: Vec<&str> = failure.into_iter().collect();
        if let Some(Ok(status)) = &status {
            let error = status.error.as_deref();
            parts.extend(error.filter(|&error| Some(error) != failure));
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
        let mut errors: BTreeSet<String> = self.live.errors().into_iter().collect();
        errors.extend(self.live.status.as_ref().and_then(|s| s.error.clone()));
        let alert = !errors.is_subset(&self.live.reported);
        self.live.reported = errors;
        self.publish_live(alert);
    }

    pub fn live_reset(&mut self) {
        for timer in [Timer::Halting, Timer::Caret, Timer::Retry] {
            self.timers.remove(&timer);
        }
        let live = &mut self.live;
        live.generation += 1;
        live.pending.clear();
        live.synced.clear();
        live.sent.clear();
        (live.halted, live.started, live.sent_view) = (false, None, None);
        (live.caret, live.settling) = (None, None);
        (live.version, live.serial) = (0, 0);
    }

    pub fn live_cancel_work(&mut self) {
        self.live.intent += 1;
        self.timers.remove(&Timer::Restart);
        self.timers.remove(&Timer::Disk);
        self.live.disk_paths.clear();
    }

    /// Whether the preview runs, or is about to start again: automatic builds wait for it.
    pub fn live_previewing(&self) -> bool {
        self.live.active() || self.timers.contains_key(&Timer::Restart)
    }

    fn fail(&mut self, error: CoreError) {
        self.live.failure = Some(error.message);
        if error.status == 409 {
            // Another window's preview now: nothing more is sent.
            self.live.owns = false;
            self.live_cancel_work();
            self.ended();
        }
        self.report();
    }

    fn ended(&mut self) {
        self.live.phase = Phase::Stopped;
        self.live_reset();
        self.live.rejected.clear();
        self.live.document_seen = false;
        self.publish_live(false);
        if !self.closed && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
    }

    /// A preview that ended for the session to start again, at once (`now`) or when its
    /// `Timer::Restart` comes. It stays `starting` meanwhile: a host that saw it stop would
    /// show the build's PDF in place of the live document until the new run's first one came.
    fn restarting(&mut self, now: bool) {
        if self.closed {
            return self.ended();
        }
        self.live.phase = Phase::Starting;
        self.live_reset();
        self.publish_live(false);
        if now {
            self.later.push_back(Later::Restart(true));
        }
    }

    /// The user's Start, `window` choosing TeXpresso's own window. A restart still pending
    /// gives way to it: it would stop the preview this starts.
    pub fn live_start_asked(&mut self, window: bool) -> Value {
        if self.live.phase == Phase::Stopped {
            self.live_cancel_work();
            self.live.window = window;
            self.live_start(false);
        }
        self.live_state()
    }

    /// Whether a start was tried: `replacing` restarts the preview this session owns.
    pub fn live_start(&mut self, replacing: bool) -> bool {
        if self.closed
            || !replacing && self.live.phase != Phase::Stopped
            || replacing && !self.live.owns
        {
            return false;
        }
        self.live.phase = Phase::Starting;
        self.live.failure = None;
        self.live.rejected.clear();
        self.live.reported.clear();
        self.live_reset();
        self.publish_live(false);
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
        let caret = self.live.wanted.clone().filter(|_| !self.live.window);
        let pane = (!self.live.window).then(|| Pane {
            view: self.live.view,
            caret: caret.clone(),
        });
        let (tx, generation) = (self.tx.clone(), self.live.generation);
        let sink = Box::new(move |event| {
            let _ = tx.send(Msg::Live(generation, event));
        });
        let path_env = self.service.tool_paths().1;
        let (root, pane) = (&self.root, pane.as_ref());
        let start = self
            .preview
            .start(self.id, root, &files, replacing, &path_env, pane, sink);
        match start {
            Ok(status) => {
                self.live.owns = true;
                self.live.synced = versions.keys().cloned().collect();
                self.live.sent = versions;
                (self.live.sent_view, self.live.caret) = (self.live.view, caret);
                let running = status.running;
                if running {
                    self.live.phase = Phase::Running;
                    self.live.started = Some(Instant::now());
                } else if status.error.is_none() {
                    self.live.failure = Some(DIDNT_START.into());
                }
                self.live.status = Some(status);
                self.report();
                if running {
                    self.flush_pending();
                } else {
                    self.ended();
                }
            }
            Err(error) => {
                self.fail(error);
                if self.live.phase != Phase::Stopped {
                    self.ended();
                }
            }
        }
        true
    }

    pub fn live_restart(&mut self, ended: bool) {
        if self.live_start(true) {
            if ended && self.live.active() {
                self.emit("live_restarted", json!({}));
            }
        } else if self.live.phase != Phase::Stopped {
            // A restart that can't be tried leaves no preview to wait for.
            self.ended();
        }
    }

    /// A Stop: the user's, or the session's as it closes. Pending live work goes with it.
    pub fn live_stop(&mut self) {
        self.live_cancel_work();
        if self.live.phase == Phase::Stopped {
            self.live.owns = false;
            return;
        }
        self.live.phase = Phase::Stopping;
        self.live_reset();
        self.publish_live(false);
        if self.live.owns {
            match self.preview.stop_request(self.id) {
                Ok(status) => {
                    self.live.owns = false;
                    self.live.status = Some(status);
                }
                Err(error) if !self.closed => self.fail(error),
                Err(_) => {}
            }
        }
        if self.live.phase != Phase::Stopped {
            self.ended();
        }
    }

    /// A rename or a new main file changed what the preview shows, and stopped it: it starts
    /// again once the change has settled.
    pub fn live_follow(&mut self) {
        if self.live.active() && !self.closed {
            self.after(Timer::Restart, self.t.live_follow);
        }
    }

    // MARK: - Edits

    /// A key's edit, as the document took it: sent on at once where TeXpresso's copy fits it.
    pub fn live_edited(&mut self, path: &str, version: u64, start: u32, length: u32, text: &str) {
        if !self.live.active() || self.closed {
            return;
        }
        // Typing takes the engine's snapshot along: the caret there is no news.
        let end = start as usize + text.encode_utf16().count();
        self.live.caret = Some((path.to_owned(), end));
        let live = &self.live;
        if live.sent.get(path).is_some_and(|sent| version <= *sent) {
            return;
        }
        if live.fits(path) {
            let sent = self
                .preview
                .edit(self.id, path, start as usize, length as usize, text);
            match sent {
                Ok(()) => return,
                Err(error) if error.status == 409 => return self.fail(error),
                // Refused, so the copy is a step behind: the whole text puts it right, or says why not.
                Err(_) => {}
            }
        }
        self.live.pending.insert(path.to_owned(), None);
        self.flush_pending();
    }

    /// A document's whole text is to go: it opened, or the disk's replaced it.
    pub fn live_whole(&mut self, path: &str) {
        if self.live.active() && !self.closed {
            self.live.pending.insert(path.to_owned(), None);
            self.later.push_back(Later::FlushLive);
        }
    }

    pub fn flush_pending(&mut self) {
        if self.live.phase != Phase::Running || self.closed || self.live.pending.is_empty() {
            return;
        }
        self.timers.remove(&Timer::Retry);
        while self.live.phase == Phase::Running && !self.closed {
            let Some((path, text)) = self.live.pending.pop_first() else {
                break;
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
            match self.preview.update(self.id, &path, &text) {
                Ok(()) => {
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
                        self.live.pending.entry(path).or_insert(Some(text));
                        self.after(Timer::Retry, self.t.retry);
                    }
                    return;
                }
            }
        }
    }

    pub fn live_rescan(&mut self) {
        if self.live.phase == Phase::Running
            && !self.closed
            && let Err(error) = self.preview.rescan(self.id)
        {
            self.fail(error);
        }
    }

    // MARK: - The view and the caret

    pub fn live_view(&mut self, first: u32, last: u32) {
        let pages = (first, last.max(first));
        self.live.view = Some(pages);
        if self.live.phase == Phase::Running && self.live.sent_view != Some(pages) {
            let _ = self.preview.view(self.id, pages.0, pages.1);
            self.live.sent_view = Some(pages);
        }
    }

    pub fn live_caret(&mut self, path: String, offset: usize) {
        let moved = (path, offset);
        self.live.wanted = Some(moved.clone());
        if self.live.phase == Phase::Running && self.live.caret.as_ref() != Some(&moved) {
            self.live.settling = Some(moved);
            self.after(Timer::Caret, self.t.caret);
        }
    }

    pub fn caret_settled(&mut self) {
        let Some((path, offset)) = self.live.settling.take() else {
            return;
        };
        let moved = Some((path.clone(), offset));
        if self.live.fits(&path) && self.live.caret != moved {
            self.live.caret = moved;
            let _ = self.preview.caret(self.id, &path, offset);
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
            self.live_follow();
        }
    }

    /// Files changed on disk reach TeXpresso. A save of an open document isn't news to it:
    /// a rescan as it typesets the edit stalled it (TeXpresso e8df770).
    pub fn refresh_live_disk(&mut self) {
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
                let text = crate::lossy_string(bytes);
                self.live.pending.insert(path, Some(text));
            }
        }
        if others {
            self.flush_pending();
            self.live_rescan();
        }
    }

    // MARK: - What the preview tells

    /// What the preview of the start numbered `generation` told; an earlier start's is
    /// past news.
    pub fn live_event(&mut self, generation: u64, event: LiveEvent) {
        if generation != self.live.generation {
            return;
        }
        let live = &mut self.live;
        match event {
            LiveEvent::Page { page, path } => {
                live.serial += 1;
                let page = json!({ "page": page, "path": path, "serial": live.serial });
                self.emit("live_page", page);
            }
            LiveEvent::Document {
                path,
                pages,
                run,
                changed,
            } => {
                (live.version, live.serial) = (live.version + 1, live.serial + 1);
                if pages > 0 {
                    live.document_seen = true;
                    let complete = !matches!(run.as_deref(), Some("stopped" | "partial"));
                    let document = json!({
                        "path": path,
                        "version": live.version,
                        "serial": live.serial,
                        "pages": pages,
                        "changed": changed,
                        "complete": complete,
                    });
                    self.emit("live_document", document);
                }
                if let Some(run) = run {
                    self.run_ended(&run);
                }
            }
            LiveEvent::Done(run) => self.run_ended(&run),
            // Sent with the next `live` event, while the host shows the log.
            LiveEvent::Log if live.log_shown => {
                let at = Instant::now() + LOG_EVERY;
                self.timers.entry(Timer::Log).or_insert(at);
            }
            LiveEvent::Log => {}
            LiveEvent::Ended(error) => {
                let restartable = error.is_some()
                    && live.owns
                    && live
                        .started
                        .is_some_and(|at| at.elapsed() > self.t.restartable_after);
                // A rename, a new main file or a file gone stopped it, to start again after.
                let planned = self.timers.contains_key(&Timer::Restart);
                if restartable || planned {
                    return self.restarting(restartable);
                }
                if let Some(error) = error {
                    live.failure = Some(error);
                    self.report();
                }
                self.ended();
            }
        }
    }

    /// A brace or a dollar half typed stops TeX for a moment at every other key,
    /// so a stopped run is said so only once it has lasted a while (`live_halted`).
    fn run_ended(&mut self, run: &str) {
        match run {
            "partial" => {}
            "stopped" => {
                if !self.live.halted {
                    let at = Instant::now() + self.t.halts_after;
                    self.timers.entry(Timer::Halting).or_insert(at);
                }
            }
            _ => {
                self.timers.remove(&Timer::Halting);
                if self.live.halted {
                    self.live.halted = false;
                    self.publish_live(false);
                }
            }
        }
    }

    /// A stopped run has lasted: it shows as halted.
    pub fn live_halted(&mut self) {
        self.live.halted = true;
        self.publish_live(false);
    }
}

/// The files the editor opens as text, as the Mac app's `isTextFile` has them: those
/// `file_kind` gives as text, but for hidden ones.
fn is_text_file(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    !name.starts_with('.') && matches!(file_kind(name), "tex" | "bib" | "text")
}
