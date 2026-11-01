use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::diff::map_line;
use texlocal_latex::logparse::{LogItem, parse_live_log};
use texlocal_latex::message::Message;
use texlocal_latex::syntax::{SyncLines, TextEdit, sync_lines};
use texlocal_latex::{is_text, utf16};

use super::Msg;
use super::actor::{Actor, Later, Timer};
use super::build::{IssueLine, issue_lines};
use super::state::SessionSection;
use crate::events::{Event, LiveDocument, LivePage};
use crate::projects::read_capped;
use crate::settings::{self, Engine};
use crate::texpresso::{FileBuffer, LiveEvent, LiveRun, Pane, RunEnd};
use crate::{paths, synctex};

pub(crate) const MAX_FILE: u64 = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum LivePhase {
    #[default]
    Stopped,
    Starting,
    Running,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct LiveState {
    phase: LivePhase,
    engine: Engine,
    halted: bool,
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
    failure: Option<Message>,
    reported: Option<Message>,
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
    typeset: HashMap<String, Arc<str>>,
    follow: bool,
    follows: u64,
    pub run: Option<Arc<dyn LiveRun>>,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, LivePhase::Starting | LivePhase::Running)
    }

    fn running(&self) -> Option<Arc<dyn LiveRun>> {
        self.run
            .clone()
            .filter(|_| self.phase == LivePhase::Running)
    }

    fn fits(&self, path: &str) -> bool {
        self.phase == LivePhase::Running && !self.pending.contains_key(path)
    }

    fn stop(&mut self) {
        if let Some(run) = self.run.take() {
            run.stop();
        }
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
            failures: live.failure.iter().cloned().collect(),
            lines: lines.collect(),
        }
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
        self.publish_live_log();
    }

    pub fn publish_live_log(&mut self) {
        if self.live.log_shown {
            let log = self.live.run.as_ref().map(|run| run.log());
            self.publish(SessionSection::LiveLog(log.unwrap_or_default()));
        }
    }

    fn report(&mut self) {
        let failure = &self.live.failure;
        let alert = failure.is_some() && *failure != self.live.reported;
        self.live.reported.clone_from(failure);
        self.publish_live(alert);
    }

    fn live_reset(&mut self) {
        for timer in [Timer::Caret, Timer::Follow, Timer::Halting, Timer::Issues] {
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
        live.typeset.clear();
        live.follow = false;
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

    fn ended(&mut self) {
        self.live.phase = LivePhase::Stopped;
        self.live_reset();
        self.live.document_seen = false;
        self.publish_live(false);
        self.publish_live_log();
        self.publish_pdf();
        if self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
    }

    fn remember_live(&self, on: bool) {
        let _ = settings::store_ui(&self.project.ui, |ui| {
            ui.live_preview = on;
            Ok(())
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
        live.stop();
        live.phase = LivePhase::Starting;
        (live.failure, live.reported) = (None, None);
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
        match (self.preview).start(&self.project, &files, &path_env, &pane, sink) {
            Ok(run) => {
                let live = &mut self.live;
                (live.run, live.phase) = (Some(run), LivePhase::Running);
                live.synced = versions.keys().cloned().collect();
                live.sent = versions;
                (live.sent_view, live.caret) = (live.view, caret);
                self.publish_live(false);
                self.publish_live_log();
                self.flush_pending();
            }
            Err(error) => {
                self.live.failure = Some(error.message);
                self.report();
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
        self.live.stop();
        if self.live.phase != LivePhase::Stopped {
            self.ended();
        }
    }

    pub fn live_follow(&mut self) {
        if self.live.active() {
            self.after(Timer::Restart);
        }
    }

    pub fn live_restart(&mut self) {
        if let Some(run) = &self.live.run {
            run.stop();
        }
        self.live_follow();
    }

    pub fn live_edited(&mut self, path: &str, version: u64, edit: &TextEdit) {
        if !self.live.active() {
            return;
        }
        let end = edit.start as usize + utf16::len(&edit.text);
        self.live.caret = Some((path.to_owned(), end));
        self.follow_soon();
        let live = &self.live;
        if live.sent.get(path).is_some_and(|sent| version <= *sent) {
            return;
        }
        let (start, length) = (edit.start as usize, edit.length as usize);
        let run = live.run.as_ref().filter(|_| live.fits(path));
        if run.is_some_and(|run| run.edit(path, start, length, &edit.text)) {
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
        let Some(run) = self.live.running() else {
            return;
        };
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
            run.update(&path, &text);
            if let Some(version) = version {
                self.live.sent.insert(path.clone(), version);
            }
            self.live.synced.insert(path);
            self.mark_sent();
        }
    }

    pub fn live_rescan(&mut self) {
        if let Some(run) = self.live.running() {
            run.rescan();
        }
    }

    pub fn live_view(&mut self, first: u32, last: u32) {
        let pages = (first, last.max(first));
        self.live.view = Some(pages);
        if let Some(run) = self.live.running()
            && self.live.sent_view != Some(pages)
        {
            run.view(pages.0, pages.1);
            self.live.sent_view = Some(pages);
        }
    }

    pub fn live_caret(&mut self, path: String, offset: usize) {
        self.live.wanted = Some((path, offset));
        if self.live.phase == LivePhase::Running {
            self.after(Timer::Caret);
            self.follow_soon();
        }
    }

    fn follow_soon(&mut self) {
        self.live.follow = true;
        self.soon(Timer::Follow);
    }

    pub fn follow(&mut self) {
        if !std::mem::take(&mut self.live.follow) {
            return;
        }
        let Some((path, offset)) = self.live.wanted.clone() else {
            return;
        };
        let (Some(doc), Some(typeset)) = (self.docs.get(&path), self.live.typeset.get(&path))
        else {
            return;
        };
        let (doc, typeset) = (doc.doc.clone(), Arc::clone(typeset));
        let Ok(Some(pdf)) = self.live_pdf() else {
            return;
        };
        let live = &mut self.live;
        live.follows += 1;
        let (tx, project) = (self.tx.clone(), self.project.clone());
        let (generation, follows) = (live.generation, live.follows);
        tokio::task::spawn_blocking(move || {
            let (text, line) = doc.with(|source| (source.text(), source.line_at(offset as u32)));
            let lines = sync_lines(&typeset, map_line(&typeset, &text, line));
            if matches!(lines, SyncLines::Whole(_)) {
                return;
            }
            let Ok(loc) = synctex::forward(&project, &path, &lines, Some(&pdf)) else {
                return;
            };
            let followed = move |actor: &mut Self| {
                let live = &actor.live;
                if (live.generation, live.follows) == (generation, follows) {
                    actor.emit(Event::LiveFollow(loc));
                }
            };
            let _ = tx.send(Msg::Snapshotted(Box::new(followed)));
        });
    }

    pub fn caret_settled(&mut self) {
        let live = &mut self.live;
        let Some((path, offset)) = live.wanted.clone() else {
            return;
        };
        if live.fits(&path)
            && live.caret != live.wanted
            && let Some(run) = &live.run
        {
            live.caret.clone_from(&live.wanted);
            run.caret(&path, offset);
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
                    self.keep_typeset();
                    self.publish_pdf();
                    self.emit(Event::LiveDocument(LiveDocument { path, changed }));
                }
                self.run_ended(run);
            }
            LiveEvent::Done(run) => self.run_ended(run),
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

    fn keep_typeset(&mut self) {
        let Some(run) = &self.live.run else {
            return;
        };
        if let Ok(pdf) = run.pdf() {
            synctex::warm(pdf);
        }
        let typeset = self
            .docs
            .keys()
            .filter_map(|path| Some((path.clone(), run.text(path)?.into())));
        self.live.typeset = typeset.collect();
    }

    fn run_ended(&mut self, run: RunEnd) {
        self.after(Timer::Issues);
        match run {
            RunEnd::Partial => {}
            RunEnd::Stopped => self.soon(Timer::Halting),
            RunEnd::Complete => {
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
        if let Some(run) = &self.live.run {
            run.mark(self.edits);
        }
    }

    pub fn live_issues_settled(&mut self) {
        let live = &self.live;
        if live.phase != LivePhase::Running || live.mark_read != live.mark_sent {
            return;
        }
        let log = live.run.as_ref().and_then(|run| run.tex_log());
        let (Some(log), Some(main)) = (log, &self.tree.main) else {
            return;
        };
        let files = self.tree.files.iter();
        let files: HashMap<String, &String> = files.map(|f| (paths::fold_case(f), f)).collect();
        let ours = |name: &str| {
            let path = paths::rel_key(name).ok()?;
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
