use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::Path;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::logparse::{LogItem, parse_live_log};
use texlocal_latex::syntax::TextEdit;
use texlocal_latex::{is_text, utf16};

use super::Msg;
use super::actor::{Actor, Later, Timer};
use super::build::{IssueLine, issue_lines};
use super::state::SessionSection;
use crate::events::{Event, LiveDocument, LivePage};
use crate::messages;
use crate::projects::read_capped;
use crate::settings::{self, Engine};
use crate::texpresso::{FileBuffer, LiveEvent, Pane};
use crate::{CoreError, paths};
use texlocal_latex::message::Message;

pub(crate) const MAX_FILE: u64 = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum LivePhase {
    #[default]
    Stopped,
    Starting,
    Running,
    Stopping,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct LiveState {
    phase: LivePhase,
    engine: Engine,
    halted: bool,
    log: Option<String>,
    failures: Vec<Message>,
    lines: BTreeMap<String, Vec<IssueLine>>,
}

struct Issue {
    item: LogItem,
    at: u32,
}

#[derive(Default)]
pub(crate) struct Live {
    phase: LivePhase,
    pending: BTreeMap<String, Option<String>>,
    synced: HashSet<String>,
    sent: HashMap<String, u64>,
    rejected: BTreeMap<String, Message>,
    failure: Option<Message>,
    reported: Vec<Message>,
    error: Option<Message>,
    log_shown: bool,
    halted: bool,
    view: Option<(u32, u32)>,
    sent_view: Option<(u32, u32)>,
    wanted: Option<(String, usize)>,
    caret: Option<(String, usize)>,
    pub disk_paths: BTreeSet<String>,
    pub intent: u64,
    generation: u64,
    pub document_seen: bool,
    mark_sent: u64,
    mark_read: u64,
    issues: Vec<Issue>,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, LivePhase::Starting | LivePhase::Running)
    }

    fn fits(&self, path: &str) -> bool {
        self.phase == LivePhase::Running && !self.pending.contains_key(path)
    }

    fn failures(&self) -> Vec<Message> {
        let rejected = self.rejected.iter();
        let rejected = rejected.map(|(path, error)| messages::live_rejected(path, error));
        let mut failures: Vec<Message> = self.failure.iter().cloned().chain(rejected).collect();
        failures.extend(self.error.clone().filter(|error| !failures.contains(error)));
        failures
    }
}

impl Actor {
    fn live_state(&self) -> LiveState {
        let live = &self.live;
        let lines = self.docs.iter().filter_map(|(path, doc)| {
            let items = live.issues.iter().map(|issue| &issue.item);
            let lines = issue_lines(items, path, &doc.doc, |_| None);
            (!lines.is_empty()).then(|| (path.clone(), lines))
        });
        LiveState {
            phase: live.phase,
            engine: Engine::Xelatex,
            halted: live.halted,
            log: live.log_shown.then(|| self.live_log()),
            failures: live.failures(),
            lines: lines.collect(),
        }
    }

    fn live_log(&self) -> String {
        let Ok(status) = self.preview.status(self.id) else {
            return String::new();
        };
        let texts = [status.log, status.output];
        let texts: Vec<String> = texts.into_iter().filter(|text| !text.is_empty()).collect();
        texts.join("\n\n")
    }

    pub fn publish_live(&mut self, alert: bool) {
        let state = self.live_state();
        self.publish(SessionSection::Live(state));
        if alert {
            self.emit(Event::LiveAlert);
        }
    }

    pub fn show_live_log(&mut self, shown: bool) {
        self.live.log_shown = shown;
        if shown {
            self.publish_live(false);
        }
    }

    fn report(&mut self) {
        let failures = self.live.failures();
        let alert = failures.iter().any(|f| !self.live.reported.contains(f));
        self.live.reported = failures;
        self.publish_live(alert);
    }

    fn live_reset(&mut self) {
        for timer in [Timer::Caret, Timer::Halting, Timer::Retry, Timer::Issues] {
            self.timers.remove(&timer);
        }
        let live = &mut self.live;
        live.generation += 1;
        live.pending.clear();
        live.synced.clear();
        live.sent.clear();
        (live.halted, live.sent_view, live.caret) = (false, None, None);
        (live.mark_sent, live.mark_read) = (0, 0);
        live.issues.clear();
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
        self.live.phase = LivePhase::Stopped;
        self.live_reset();
        self.live.rejected.clear();
        self.live.document_seen = false;
        self.publish_live(false);
        self.publish_pdf();
        if self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
    }

    fn remember_live(&self, on: bool) {
        let _ = self.service.with_project(&self.project_id, |project| {
            settings::store_ui(&project.ui, |ui| {
                ui.live_preview = on;
                Ok(())
            })
        });
    }

    pub fn live_start_asked(&mut self) {
        self.remember_live(true);
        if self.live.phase == LivePhase::Stopped {
            self.live_cancel_work();
            self.live_start();
        }
    }

    pub fn live_start(&mut self) {
        let live = &mut self.live;
        live.phase = LivePhase::Starting;
        live.failure = None;
        live.rejected.clear();
        live.reported.clear();
        self.live_reset();
        self.publish_live(false);
        let (mut files, mut versions) = (Vec::new(), HashMap::new());
        for (path, doc) in self.docs.iter() {
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
                    self.live.phase = LivePhase::Running;
                } else if status.error.is_none() {
                    self.live.failure = Some(messages::texpresso_didnt_start());
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

    pub fn live_stop_asked(&mut self) {
        self.remember_live(false);
        self.live_stop();
    }

    pub fn live_stop(&mut self) {
        self.live_cancel_work();
        if self.live.phase == LivePhase::Stopped {
            self.preview.stop_request(self.id);
            return;
        }
        self.live.phase = LivePhase::Stopping;
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

    pub fn live_edited(&mut self, path: &str, version: u64, edit: &TextEdit) {
        if !self.live.active() {
            return;
        }
        let end = edit.start as usize + utf16::len(&edit.text);
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
            return self.mark_sent();
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
        if self.live.phase != LivePhase::Running {
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
                    self.mark_sent();
                    self.publish_live(false);
                }
                Err(error) if error.kind == crate::ErrorKind::Invalid => {
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
        if self.live.phase == LivePhase::Running
            && let Err(error) = self.preview.rescan(self.id)
        {
            self.fail(error);
        }
    }

    pub fn live_view(&mut self, first: u32, last: u32) {
        let pages = (first, last.max(first));
        self.live.view = Some(pages);
        if self.live.phase == LivePhase::Running && self.live.sent_view != Some(pages) {
            let _ = self.preview.view(self.id, pages.0, pages.1);
            self.live.sent_view = Some(pages);
        }
    }

    pub fn live_caret(&mut self, path: String, offset: usize) {
        self.live.wanted = Some((path, offset));
        if self.live.phase == LivePhase::Running {
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
            if is_text(&path)
                && let Ok(Some(bytes)) = read_capped(&file, MAX_FILE)
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

    pub fn live_event(&mut self, generation: u64, event: LiveEvent) {
        if generation != self.live.generation {
            return;
        }
        match event {
            LiveEvent::Page { page, pdf } => self.emit(Event::LivePage(LivePage { page, pdf })),
            LiveEvent::Document {
                path,
                pages,
                run,
                changed,
            } => {
                if pages > 0 {
                    self.live.document_seen = true;
                    self.publish_pdf();
                    let complete = !matches!(run.as_str(), "stopped" | "partial");
                    self.emit(Event::LiveDocument(LiveDocument {
                        path,
                        changed,
                        complete,
                    }));
                }
                self.run_ended(&run);
            }
            LiveEvent::Done(run) => self.run_ended(&run),
            LiveEvent::Synced(mark) => self.live.mark_read = mark,
            LiveEvent::Log if self.live.log_shown => self.soon(Timer::Log),
            LiveEvent::Log => {}
            LiveEvent::Ended(error) => {
                if self.timers.contains_key(&Timer::Restart) {
                    self.live.phase = LivePhase::Starting;
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
        self.after(Timer::Issues);
        match run {
            "partial" => {}
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

impl Actor {
    fn mark_sent(&mut self) {
        self.live.mark_sent = self.edits;
        let _ = self.preview.mark(self.id, self.edits);
    }

    pub fn live_issues_settled(&mut self) {
        let live = &self.live;
        if live.phase != LivePhase::Running || live.mark_read != live.mark_sent {
            return;
        }
        let (Some(log), Some(main)) = (self.preview.tex_log(self.id), &self.tree.main) else {
            return;
        };
        let folder = main.rsplit_once('/').map_or("", |(folder, _)| folder);
        let files = self.tree.files.iter();
        let files: HashMap<String, &String> = files.map(|f| (paths::fold_case(f), f)).collect();
        let ours = |name: &str| {
            let path = paths::rel_key(&Path::new(folder).join(name).to_string_lossy()).ok()?;
            files
                .get(&paths::fold_case(&path))
                .map(|&file| file.clone())
        };
        let errors = parse_live_log(&log, main, &ours);
        let placed = errors.into_iter().filter_map(|item| {
            let at = match (&item.file, item.line) {
                (Some(file), Some(line)) => self
                    .docs
                    .get(file)
                    .map_or(0, |doc| doc.doc.with(|source| source.line_start(line))),
                _ => return None,
            };
            Some(Issue { item, at })
        });
        self.live.issues = placed.collect();
        self.publish_live(false);
    }

    pub fn live_issues_edited(&mut self, path: &str, edit: Option<&TextEdit>) {
        let ours = |issue: &Issue| issue.item.file.as_deref() == Some(path);
        if !self.live.issues.iter().any(ours) {
            return;
        }
        let doc = &self.docs[path].doc;
        let inserted = edit.map_or(0, |edit| utf16::len(&edit.text) as u32);
        self.live.issues.retain_mut(|issue| {
            if !ours(issue) {
                return true;
            }
            let Some(edit) = edit else {
                return false;
            };
            if edit.start + edit.length <= issue.at {
                issue.at = issue.at - edit.length + inserted;
                issue.item.line = Some(doc.with(|source| source.line_at(issue.at)));
                true
            } else {
                edit.start > issue.at
            }
        });
        self.publish_live(false);
    }

    pub fn live_issues_opened(&mut self, path: &str) {
        let doc = &self.docs[path].doc;
        let issues = self.live.issues.iter_mut();
        for issue in issues.filter(|issue| issue.item.file.as_deref() == Some(path)) {
            let line = issue.item.line.unwrap_or_default();
            issue.at = doc.with(|source| source.line_start(line));
        }
        self.publish_live(false);
    }
}
