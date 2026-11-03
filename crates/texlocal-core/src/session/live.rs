use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::Arc;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::diff::map_line;
use texlocal_latex::logparse::{LogItem, parse_live_log};
use texlocal_latex::message::Message;
use texlocal_latex::syntax::{SyncLines, TextEdit, sync_lines};
use texlocal_latex::{is_text, utf16};

use super::actor::{Actor, Later, Timer};
use super::build::{IssueLine, issue_lines};
use super::state::SessionSection;
use super::{Document, Msg};
use crate::events::{Event, LiveDocument, LivePage};
use crate::projects::read_capped;
use crate::settings::{self, Engine};
use crate::texpresso::{LiveEvent, LiveRun, RunEnd};
use crate::{messages, paths, synctex};

mod sources;
use sources::Sources;

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
    // Halted, or failed with the log not closed since, which the status bar marks.
    attention: bool,
    failures: Vec<Message>,
    lines: BTreeMap<String, Vec<IssueLine>>,
}

struct Issue {
    item: LogItem,
    at: u32,
}

pub(crate) fn typeset_lines(typeset: &str, text: &str, line: u32) -> SyncLines {
    sync_lines(typeset, map_line(typeset, text, line))
}

/// Reads the document's own checkpoints while it still holds the text typeset: comparing the two takes 0.6 ms on the
/// 400-page fixture, against 5 ms to scan the text typeset whole. A document edited since is scanned whole outside its
/// lock, which its edits wait on.
pub(crate) fn document_lines(doc: &Document, typeset: Option<&str>, line: u32) -> SyncLines {
    if let Some(typeset) = typeset
        && let Some(text) = doc.with(|source| (!source.holds(typeset)).then(|| source.text()))
    {
        return typeset_lines(typeset, &text, line);
    }
    doc.with(|source| source.sync_lines(line))
}

#[derive(Default)]
pub(crate) struct Live {
    phase: LivePhase,
    sources: Sources,
    typeset: HashMap<String, Arc<str>>,
    /// The version of each document whose whole text was sent, so its edits up to then are skipped.
    sent: HashMap<String, u64>,
    failure: Option<Message>,
    reported: Option<Message>,
    seen: bool,
    log_shown: bool,
    halted: bool,
    view: Option<(u32, u32)>,
    wanted: Option<(String, usize)>,
    caret: Option<(String, usize)>,
    pub disk_paths: BTreeSet<String>,
    pub intent: u64,
    generation: u64,
    pub pdf: Option<PathBuf>,
    issues: Vec<Issue>,
    follow: bool,
    follows: u64,
    pub run: Option<Arc<dyn LiveRun>>,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, LivePhase::Starting | LivePhase::Running)
    }

    /// The text of each file that the PDF shown was typeset from.
    pub fn typeset(&self) -> &HashMap<String, Arc<str>> {
        &self.typeset
    }

    fn running(&self) -> Option<Arc<dyn LiveRun>> {
        self.run
            .clone()
            .filter(|_| self.phase == LivePhase::Running)
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
            attention: live.halted || live.failure.is_some() && !live.seen,
            failures: live.failure.iter().cloned().collect(),
            lines: lines.collect(),
        }
    }

    pub fn publish_live(&mut self, alert: bool) {
        let state = self.live_state();
        self.core.publish(SessionSection::Live(state));
        if alert {
            self.core.emit(Event::LiveAlert);
        }
    }

    pub fn show_live_log(&mut self, shown: bool) {
        self.live.log_shown = shown;
        if !shown && self.live.phase == LivePhase::Stopped && !self.live.seen {
            self.live.seen = true;
            self.publish_live(false);
        }
        self.publish_live_log();
    }

    pub fn publish_live_log(&mut self) {
        if self.live.log_shown {
            let log = self.live.run.as_ref().map(|run| run.log());
            self.core
                .publish(SessionSection::LiveLog(log.unwrap_or_default()));
        }
    }

    fn report(&mut self) {
        let failure = &self.live.failure;
        let alert = failure.is_some() && *failure != self.live.reported;
        self.live.reported.clone_from(failure);
        self.live.seen &= !alert;
        self.publish_live(alert);
    }

    fn live_reset(&mut self) {
        for timer in [Timer::Caret, Timer::Follow, Timer::Halting, Timer::Issues] {
            self.core.timers.remove(&timer);
        }
        let live = &mut self.live;
        live.generation += 1;
        (live.sources, live.sent) = (Sources::default(), HashMap::new());
        live.typeset.clear();
        (live.halted, live.caret) = (false, None);
        live.issues.clear();
        live.follow = false;
    }

    fn live_cancel_work(&mut self) {
        self.live.intent += 1;
        self.core.timers.remove(&Timer::Restart);
        self.core.timers.remove(&Timer::Disk);
        self.live.disk_paths.clear();
    }

    pub fn live_previewing(&self) -> bool {
        self.live.active() || self.core.timers.contains_key(&Timer::Restart)
    }

    fn ended(&mut self) {
        self.live.phase = LivePhase::Stopped;
        self.live_reset();
        self.live.pdf = None;
        self.publish_live(false);
        self.publish_live_log();
        self.publish_pdf();
        if self.core.auto_compile {
            self.core.later.push_back(Later::Compile(true));
        }
    }

    fn remember_live(&self, on: bool) {
        let _ = settings::store_ui(&self.core.project.ui, |ui| {
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
        let (tx, generation) = (self.core.tx.clone(), self.live.generation);
        let sink = Box::new(move |event| {
            let _ = tx.send(Msg::Live(generation, event));
        });
        let path_env = self.core.service.tool_paths().1;
        match (self.core.preview).start(&self.core.project, &path_env, sink) {
            Ok(run) => {
                (self.live.run, self.live.phase) = (Some(Arc::clone(&run)), LivePhase::Running);
                let paths: Vec<String> = self.docs.keys().cloned().collect();
                for path in paths {
                    self.live_send(&path);
                }
                if let Some((first, last)) = self.live.view {
                    run.view(first, last);
                }
                self.caret_settled();
                self.mark();
                self.publish_live(false);
                self.publish_live_log();
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
            self.core.after(Timer::Restart);
        }
    }

    pub fn live_restart(&mut self) {
        if let Some(run) = &self.live.run {
            run.stop();
        }
        self.live_follow();
    }

    pub fn live_edited(&mut self, path: &str, version: u64, edit: &TextEdit) {
        let Some(run) = self.live.running() else {
            return;
        };
        // TeXpresso moves its caret to the end of each change it reads.
        let end = edit.start as usize + utf16::len(&edit.text);
        self.live.caret = Some((path.to_owned(), end));
        self.follow_soon();
        if self
            .live
            .sent
            .get(path)
            .is_some_and(|&sent| version <= sent)
        {
            return;
        }
        if !self.live.sources.edit(&*run, path, edit) {
            self.live_send(path);
        }
        self.mark();
    }

    pub fn live_opened(&mut self, path: &str) {
        self.live_send(path);
        self.mark();
    }

    fn live_send(&mut self, path: &str) {
        let (Some(run), Some(doc)) = (self.live.running(), self.docs.get(path)) else {
            return;
        };
        let (text, version) = doc.doc.snapshot();
        self.live.sources.send(&*run, path, &text);
        self.live.sent.insert(path.to_owned(), version);
    }

    /// Asks TeXpresso to say when it has read everything sent, which settles its issues.
    fn mark(&self) {
        if let Some(run) = self.live.running() {
            run.mark(self.live.sources.revision());
        }
    }

    pub fn live_rescan(&mut self) {
        if let Some(run) = self.live.running() {
            run.rescan();
        }
    }

    pub fn live_view(&mut self, first: u32, last: u32) {
        let pages = Some((first, last.max(first)));
        if self.live.view != pages {
            self.live.view = pages;
            if let Some(run) = self.live.running() {
                run.view(first, last.max(first));
            }
        }
    }

    pub fn live_caret(&mut self, path: String, offset: usize) {
        let wanted = Some((path, offset));
        if self.live.wanted == wanted {
            return;
        }
        self.live.wanted = wanted;
        if self.live.phase == LivePhase::Running {
            self.core.after(Timer::Caret);
            self.follow_soon();
        }
    }

    fn follow_soon(&mut self) {
        self.live.follow = true;
        self.core.soon(Timer::Follow);
    }

    pub fn follow(&mut self) {
        if !std::mem::take(&mut self.live.follow) {
            return;
        }
        let Some((path, offset)) = self.live.wanted.clone() else {
            return;
        };
        let (Some(doc), Some(typeset)) = (self.docs.get(&path), self.live.typeset().get(&path))
        else {
            return;
        };
        let (doc, typeset) = (doc.doc.clone(), Arc::clone(typeset));
        let Ok(Some(pdf)) = self.live_pdf() else {
            return;
        };
        let live = &mut self.live;
        live.follows += 1;
        let (tx, project) = (self.core.tx.clone(), self.core.project.clone());
        let (generation, follows) = (live.generation, live.follows);
        tokio::task::spawn_blocking(move || {
            let line = doc.with(|source| source.line_at(offset as u32));
            let lines = document_lines(&doc, Some(&typeset), line);
            if matches!(lines, SyncLines::Whole(_)) {
                return;
            }
            let Ok(loc) = synctex::forward(&project, &path, &lines, Some(&pdf)) else {
                return;
            };
            let followed = move |actor: &mut Self| {
                let live = &actor.live;
                if (live.generation, live.follows) == (generation, follows) {
                    actor.core.emit(Event::LiveFollow(loc));
                }
            };
            let _ = tx.send(Msg::Snapshotted(Box::new(followed)));
        });
    }

    pub fn caret_settled(&mut self) {
        let live = &mut self.live;
        if let (Some(run), Some((path, offset))) = (live.running(), &live.wanted)
            && live.caret != live.wanted
            && live.sources.caret(&*run, path, *offset)
        {
            live.caret.clone_from(&live.wanted);
        }
    }

    pub fn live_files_changed(&mut self) {
        if !self.live.active() {
            return;
        }
        let tree = &self.tree;
        if self.live.sources.paths().all(|path| tree.contains(path)) {
            self.core.later.push_back(Later::Rescan);
        } else {
            self.live_follow();
        }
    }

    pub fn refresh_live_disk(&mut self) {
        let paths = std::mem::take(&mut self.live.disk_paths);
        let Some(run) = self.live.running() else {
            return;
        };
        let mut others = false;
        for path in paths {
            if self.docs.contains_key(&path) {
                continue;
            }
            others = true;
            let file = self.core.project.root.join(&path);
            if is_text(&path)
                && let Ok(Some(bytes)) = read_capped(&file, MAX_FILE)
            {
                let text = crate::lossy_string(bytes);
                self.live.sources.send(&*run, &path, &text);
            }
        }
        if others {
            self.mark();
            run.rescan();
        }
    }

    pub fn live_event(&mut self, generation: u64, event: LiveEvent) {
        if generation != self.live.generation {
            return;
        }
        match event {
            LiveEvent::Page { page, pdf } => {
                self.core.emit(Event::LivePage(LivePage { page, pdf }));
            }
            LiveEvent::Document {
                path,
                pages,
                run,
                changed,
                revision,
            } => {
                if !self.acknowledged(revision) {
                    return;
                }
                if pages > 0 {
                    self.live.pdf = Some(PathBuf::from(&path));
                    self.live.typeset.clone_from(&self.live.sources.read);
                    synctex::warm(PathBuf::from(&path));
                    self.publish_pdf();
                    self.core
                        .emit(Event::LiveDocument(LiveDocument { path, changed }));
                }
                self.run_ended(run);
            }
            LiveEvent::Done(run) => self.run_ended(run),
            // A settled viewport can acknowledge changes without changing the whole PDF.
            LiveEvent::Synced(revision) => drop(self.acknowledged(revision)),
            LiveEvent::Log if self.live.log_shown => self.core.soon(Timer::Log),
            LiveEvent::Log => {}
            LiveEvent::Ended(error) => {
                if self.core.timers.contains_key(&Timer::Restart) {
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

    /// Takes in what TeXpresso says it has read, and ends a preview that claims what it wasn't sent.
    fn acknowledged(&mut self, revision: u64) -> bool {
        if self.live.sources.acknowledge(revision).is_some() {
            return true;
        }
        self.live.failure = Some(messages::live_unpatched());
        self.report();
        self.live_stop();
        false
    }

    fn run_ended(&mut self, run: RunEnd) {
        self.core.after(Timer::Issues);
        match run {
            RunEnd::Partial => {}
            RunEnd::Stopped => self.core.soon(Timer::Halting),
            RunEnd::Complete => {
                self.core.timers.remove(&Timer::Halting);
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
    pub fn live_issues_settled(&mut self) {
        let live = &self.live;
        if live.phase != LivePhase::Running || !live.sources.settled() {
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
        let (count, mut moved) = (self.live.issues.len(), false);
        self.live.issues.retain_mut(|issue| {
            if !ours(issue) {
                return true;
            }
            let Some(edit) = edit else {
                return false;
            };
            if edit.start + edit.length <= issue.at {
                issue.at = issue.at - edit.length + inserted;
                let line = Some(doc.with(|source| source.line_at(issue.at)));
                moved |= issue.item.line != line;
                issue.item.line = line;
                true
            } else {
                edit.start > issue.at
            }
        });
        if moved || self.live.issues.len() != count {
            self.publish_live(false);
        }
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
