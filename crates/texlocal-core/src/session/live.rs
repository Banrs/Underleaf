//! The session's side of live preview. Starts, stops and whole texts go one at a time; a
//! key's edit goes on as the editor makes it; what the preview tells comes back as
//! `Msg::Live` and goes on to the host as events.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde::Serialize;
use serde_json::{Value, json};

use super::Msg;
use super::actor::{Actor, Later, Timer};
use crate::CoreError;
use crate::projects::is_text;
use crate::syntax::TextEdit;
use crate::texpresso::{FileBuffer, LiveEvent, Pane};

/// TeXpresso's own limit on a file sent to it; one larger it reads from the disk at the rescan.
pub(crate) const MAX_FILE: u64 = 8 * 1024 * 1024;
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
    phase: Phase,
    /// Whole texts to send: an open document's as it is then, or another file's as read.
    pending: BTreeMap<String, Option<String>>,
    /// TeXpresso keeps these through a rescan: only a new start drops one whose file went.
    synced: HashSet<String>,
    sent: HashMap<String, u64>,
    rejected: BTreeMap<String, String>,
    failure: Option<String>,
    reported: BTreeSet<String>,
    error: Option<String>,
    log_shown: bool,
    halted: bool,
    view: Option<(u32, u32)>,
    sent_view: Option<(u32, u32)>,
    wanted: Option<(String, usize)>,
    caret: Option<(String, usize)>,
    pub disk_paths: BTreeSet<String>,
    /// Rises with each Start the user asks for and each Stop: a restart for an older one is dropped.
    pub intent: u64,
    /// Rises with each start and each end: what an earlier start's preview tells is dropped.
    generation: u64,
    pub document_seen: bool,
    shown: Value,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, Phase::Starting | Phase::Running)
    }

    /// No whole text is waiting to go before it. One its copy can't take is refused (412).
    fn fits(&self, path: &str) -> bool {
        self.phase == Phase::Running && !self.pending.contains_key(path)
    }

    fn errors(&self) -> Vec<String> {
        let rejected = self.rejected.iter();
        let rejected = rejected.map(|(path, error)| format!("{path}: {error}"));
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
            "error": live.error,
        })
    }

    fn live_log(&self, failure: Option<&str>) -> String {
        let mut parts: Vec<&str> = failure.into_iter().collect();
        let status = self.preview.status(self.id);
        if let Ok(status) = &status {
            let error = status.error.as_deref();
            parts.extend(error.filter(|&error| Some(error) != failure));
            let texts = [status.log.as_str(), status.output.as_str()];
            parts.extend(texts.into_iter().filter(|text| !text.is_empty()));
        }
        parts.join("\n\n")
    }

    pub fn publish_live(&mut self, alert: bool) {
        let mut state = self.live_state();
        if state != self.live.shown || alert {
            self.live.shown = state.clone();
            state["alert"] = alert.into();
            if alert && !self.live.log_shown {
                state["log"] = self.live_log(state["failure"].as_str()).into();
            }
            self.emit("live", state);
        }
    }

    pub fn show_live_log(&mut self, shown: bool) {
        self.live.log_shown = shown;
        if shown {
            self.publish_live(false);
        }
    }

    /// An error not reported before alerts.
    fn report(&mut self) {
        let mut errors: BTreeSet<String> = self.live.errors().into_iter().collect();
        errors.extend(self.live.error.clone());
        let alert = !errors.is_subset(&self.live.reported);
        self.live.reported = errors;
        self.publish_live(alert);
    }

    fn live_reset(&mut self) {
        for timer in [Timer::Caret, Timer::Halting, Timer::Retry] {
            self.timers.remove(&timer);
        }
        let live = &mut self.live;
        live.generation += 1;
        live.pending.clear();
        live.synced.clear();
        live.sent.clear();
        (live.halted, live.sent_view, live.caret) = (false, None, None);
    }

    fn live_cancel_work(&mut self) {
        self.live.intent += 1;
        self.timers.remove(&Timer::Restart);
        self.timers.remove(&Timer::Disk);
        self.live.disk_paths.clear();
    }

    pub fn live_previewing(&self) -> bool {
        self.live.active() || self.timers.contains_key(&Timer::Restart)
    }

    fn fail(&mut self, error: CoreError) {
        self.live.failure = Some(error.message);
        self.report();
    }

    fn ended(&mut self) {
        self.live.phase = Phase::Stopped;
        self.live_reset();
        self.live.rejected.clear();
        self.live.document_seen = false;
        self.publish_live(false);
        if self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
    }

    /// A restart still pending gives way to a user's Start: it would stop the preview this starts.
    pub fn live_start_asked(&mut self) -> Value {
        if self.live.phase == Phase::Stopped {
            self.live_cancel_work();
            self.live_start();
        }
        self.live_state()
    }

    /// In place of a preview running, as a restart.
    pub fn live_start(&mut self) {
        let live = &mut self.live;
        live.phase = Phase::Starting;
        live.failure = None;
        live.rejected.clear();
        live.reported.clear();
        self.live_reset();
        self.publish_live(false);
        let (mut files, mut versions) = (Vec::new(), HashMap::new());
        for (path, doc) in &self.docs {
            let (text, version) = doc.doc.snapshot();
            versions.insert(path.clone(), version);
            let path = path.clone();
            files.push(FileBuffer { path, text });
        }
        let caret = self.live.wanted.clone();
        let pane = Pane {
            view: self.live.view,
            caret: caret.clone(),
        };
        let (tx, generation) = (self.tx.clone(), self.live.generation);
        let sink = Box::new(move |event| {
            let _ = tx.send(Msg::Live(generation, event));
        });
        let path_env = self.service.tool_paths().1;
        match (self.preview).start(self.id, &self.project, &files, &path_env, &pane, sink) {
            Ok(status) => {
                self.live.synced = versions.keys().cloned().collect();
                self.live.sent = versions;
                (self.live.sent_view, self.live.caret) = (self.live.view, caret);
                if status.running {
                    self.live.phase = Phase::Running;
                } else if status.error.is_none() {
                    self.live.failure = Some(DIDNT_START.into());
                }
                self.live.error = status.error;
                self.report();
                if status.running {
                    self.flush_pending();
                } else {
                    self.ended();
                }
            }
            Err(error) => {
                self.fail(error);
                self.ended();
            }
        }
    }

    pub fn live_stop(&mut self) {
        self.live_cancel_work();
        if self.live.phase == Phase::Stopped {
            self.preview.stop_request(self.id);
            return;
        }
        self.live.phase = Phase::Stopping;
        self.live_reset();
        self.publish_live(false);
        self.live.error = self.preview.stop_request(self.id).error;
        self.ended();
    }

    pub fn live_follow(&mut self) {
        if self.live.active() {
            self.after(Timer::Restart);
        }
    }

    // MARK: - Edits

    pub fn live_edited(&mut self, path: &str, version: u64, edit: &TextEdit) {
        if !self.live.active() {
            return;
        }
        let end = edit.start as usize + edit.text.encode_utf16().count();
        self.live.caret = Some((path.to_owned(), end));
        let live = &self.live;
        if live.sent.get(path).is_some_and(|sent| version <= *sent) {
            return;
        }
        let (start, length) = (edit.start as usize, edit.length as usize);
        if live.fits(path)
            && self
                .preview
                .edit(self.id, path, start, length, &edit.text)
                .is_ok()
        {
            return;
        }
        self.live.pending.insert(path.to_owned(), None);
        self.flush_pending();
    }

    pub fn live_whole(&mut self, path: &str) {
        if self.live.active() {
            self.live.pending.insert(path.to_owned(), None);
            self.later.push_back(Later::FlushLive);
        }
    }

    pub fn flush_pending(&mut self) {
        if self.live.phase != Phase::Running {
            return;
        }
        self.timers.remove(&Timer::Retry);
        while let Some((path, text)) = self.live.pending.pop_first() {
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
                    self.live.pending.entry(path).or_insert(Some(text));
                    self.after(Timer::Retry);
                    return;
                }
            }
        }
    }

    pub fn live_rescan(&mut self) {
        if self.live.phase == Phase::Running
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
        self.live.wanted = Some((path, offset));
        if self.live.phase == Phase::Running {
            self.after(Timer::Caret);
        }
    }

    pub fn caret_settled(&mut self) {
        let live = &mut self.live;
        let Some((path, offset)) = live.wanted.clone() else {
            return;
        };
        if live.fits(&path) && live.caret != live.wanted {
            live.caret.clone_from(&live.wanted);
            let _ = self.preview.caret(self.id, &path, offset);
        }
    }

    // MARK: - Files on disk

    /// TeXpresso keeps the texts it has through a rescan, so only a new session drops one
    /// whose file went.
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

    /// A save of an open document isn't news to TeXpresso: a rescan as it typesets the edit
    /// stalled it (TeXpresso e8df770).
    pub fn refresh_live_disk(&mut self) {
        let paths = std::mem::take(&mut self.live.disk_paths);
        if !self.live.active() {
            return;
        }
        let mut others = false;
        for path in paths {
            if self.docs.contains_key(&path) {
                continue;
            }
            others = true;
            let file = self.project.root.join(&path);
            let name = path.rsplit('/').next().unwrap_or(&path);
            if !name.starts_with('.')
                && is_text(name)
                && std::fs::metadata(&file).is_ok_and(|meta| meta.len() <= MAX_FILE)
                && let Ok(bytes) = std::fs::read(&file)
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

    pub fn live_event(&mut self, generation: u64, event: LiveEvent) {
        if generation != self.live.generation {
            return;
        }
        match event {
            LiveEvent::Page { page, path } => {
                self.emit("live_page", json!({ "page": page, "path": path }));
            }
            LiveEvent::Document {
                path,
                pages,
                run,
                changed,
            } => {
                if pages > 0 {
                    self.live.document_seen = true;
                    let complete = !matches!(run.as_deref(), Some("stopped" | "partial"));
                    let document = json!({
                        "path": path,
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
            LiveEvent::Log if self.live.log_shown => self.soon(Timer::Log),
            LiveEvent::Log => {}
            LiveEvent::Ended(error) => {
                // It stays `starting` meanwhile: a host that saw it stop would show the build's PDF
                // until the new run's first page came.
                if self.timers.contains_key(&Timer::Restart) {
                    self.live.phase = Phase::Starting;
                    self.live_reset();
                    return self.publish_live(false);
                }
                if let Some(error) = error {
                    self.live.failure = Some(error);
                    self.report();
                }
                self.ended();
            }
        }
    }

    fn run_ended(&mut self, run: &str) {
        match run {
            "partial" => {}
            // A brace or a dollar half typed stops TeX for a moment at every other key, so a
            // stopped run shows as halted only once it has lasted.
            "stopped" => self.soon(Timer::Halting),
            _ => {
                self.timers.remove(&Timer::Halting);
                self.live_halted(false);
            }
        }
    }

    pub fn live_halted(&mut self, halted: bool) {
        if self.live.halted != halted {
            self.live.halted = halted;
            self.publish_live(false);
        }
    }
}
