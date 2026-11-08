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

use super::actor::{Actor, Core, Later, Timer};
use super::build::{IssueLine, issue_lines};
use super::documents::Docs;
use super::state::SessionSection;
use super::watch::TreeIndex;
use super::{Document, Msg};
use crate::CoreError;
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
/// 400-page fixture, against 5 ms to scan the text typeset whole. Both happen under one lock, since an edit between them
/// would have the edited text's lines read as the typeset text's. A document edited since is scanned whole outside its
/// lock, which its edits wait on.
pub(crate) fn document_lines(doc: &Document, typeset: Option<&str>, line: u32) -> SyncLines {
    let edited = doc.with(|source| match typeset {
        Some(typeset) if !source.holds(typeset) => Err((typeset, source.text())),
        _ => Ok(source.sync_lines(line)),
    });
    edited.unwrap_or_else(|(typeset, text)| typeset_lines(typeset, &text, line))
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
    disk_paths: BTreeSet<String>,
    generation: u64,
    issues: Vec<Issue>,
    follow: bool,
    follows: u64,
    run: Option<Arc<dyn LiveRun>>,
}

impl Live {
    pub fn active(&self) -> bool {
        matches!(self.phase, LivePhase::Starting | LivePhase::Running)
    }

    pub fn typeset(&self) -> &HashMap<String, Arc<str>> {
        &self.typeset
    }

    fn running(&self) -> Option<Arc<dyn LiveRun>> {
        self.run
            .clone()
            .filter(|_| self.phase == LivePhase::Running)
    }

    fn stop_run(&mut self) {
        if let Some(run) = self.run.take() {
            run.stop();
        }
    }

    pub fn pdf(&self, cx: &Core) -> Result<Option<PathBuf>, CoreError> {
        let Some(pdf) = cx.pdf.live.as_ref().filter(|_| self.active()) else {
            return Ok(None);
        };
        if synctex::synctex_file(pdf).is_none() {
            return Err(CoreError::not_found(messages::texpresso_unsynced()));
        }
        Ok(Some(pdf.clone()))
    }

    fn state(&self, docs: &Docs) -> LiveState {
        let lines = docs.iter().filter_map(|(path, doc)| {
            let items = self.issues.iter().map(|issue| &issue.item);
            let lines = issue_lines(items, path, &doc.doc, |_| None);
            (!lines.is_empty()).then(|| (path.clone(), lines))
        });
        LiveState {
            phase: self.phase,
            engine: Engine::Xelatex,
            halted: self.halted,
            attention: self.halted || self.failure.is_some() && !self.seen,
            failures: self.failure.iter().cloned().collect(),
            lines: lines.collect(),
        }
    }

    pub fn publish(&self, cx: &mut Core, docs: &Docs, alert: bool) {
        cx.publish(SessionSection::Live(self.state(docs)));
        if alert {
            cx.emit(Event::LiveAlert);
        }
    }

    pub fn show_log(&mut self, cx: &mut Core, docs: &Docs, shown: bool) {
        self.log_shown = shown;
        if !shown && self.phase == LivePhase::Stopped && !self.seen {
            self.seen = true;
            self.publish(cx, docs, false);
        }
        self.publish_log(cx);
    }

    pub fn publish_log(&self, cx: &mut Core) {
        if self.log_shown {
            let log = self.run.as_ref().map(|run| run.log());
            cx.publish(SessionSection::LiveLog(log.unwrap_or_default()));
        }
    }

    fn report(&mut self, cx: &mut Core, docs: &Docs) {
        let alert = self.failure.is_some() && self.failure != self.reported;
        self.reported.clone_from(&self.failure);
        self.seen &= !alert;
        self.publish(cx, docs, alert);
    }

    fn reset(&mut self, cx: &mut Core) {
        for timer in [Timer::Caret, Timer::Follow, Timer::Halting, Timer::Issues] {
            cx.timers.remove(&timer);
        }
        self.generation += 1;
        (self.sources, self.sent) = (Sources::default(), HashMap::new());
        self.typeset.clear();
        (self.halted, self.caret) = (false, None);
        self.issues.clear();
        self.follow = false;
    }

    fn cancel_work(&mut self, cx: &mut Core) {
        cx.timers.remove(&Timer::Restart);
        cx.timers.remove(&Timer::Disk);
        self.disk_paths.clear();
    }

    pub fn previewing(&self, cx: &Core) -> bool {
        self.active() || cx.timers.contains_key(&Timer::Restart)
    }

    fn ended(&mut self, cx: &mut Core, docs: &Docs) {
        self.phase = LivePhase::Stopped;
        self.reset(cx);
        cx.pdf.live = None;
        self.publish(cx, docs, false);
        self.publish_log(cx);
        cx.publish_pdf();
        if cx.auto_compile {
            cx.later.push_back(Later::Compile(true));
        }
    }

    pub fn start_asked(&mut self, cx: &mut Core, docs: &Docs) {
        remember(cx, true);
        if self.phase == LivePhase::Stopped {
            self.cancel_work(cx);
            self.start(cx, docs);
        }
    }

    pub fn start(&mut self, cx: &mut Core, docs: &Docs) {
        self.stop_run();
        self.phase = LivePhase::Starting;
        (self.failure, self.reported) = (None, None);
        self.reset(cx);
        self.publish(cx, docs, false);
        let (tx, generation) = (cx.tx.clone(), self.generation);
        let sink = Box::new(move |event| {
            let _ = tx.send(Msg::Live(generation, event));
        });
        let (path_env, texpresso) = cx.service.tool_paths();
        match cx.preview.start(&cx.project, &texpresso, &path_env, sink) {
            Ok(run) => {
                (self.run, self.phase) = (Some(Arc::clone(&run)), LivePhase::Running);
                for path in docs.keys() {
                    self.send(docs, path);
                }
                if let Some((first, last)) = self.view {
                    run.view(first, last);
                }
                self.caret_settled();
                self.mark();
                self.publish(cx, docs, false);
                self.publish_log(cx);
            }
            Err(error) => {
                self.failure = Some(error.message);
                self.report(cx, docs);
                self.ended(cx, docs);
            }
        }
    }

    pub fn stop_asked(&mut self, cx: &mut Core, docs: &Docs) {
        remember(cx, false);
        self.stop(cx, docs);
    }

    pub fn stop(&mut self, cx: &mut Core, docs: &Docs) {
        self.cancel_work(cx);
        self.stop_run();
        if self.phase != LivePhase::Stopped {
            self.ended(cx, docs);
        }
    }

    pub fn restart_soon(&self, cx: &mut Core) {
        if self.active() {
            cx.after(Timer::Restart);
        }
    }

    pub fn restart(&self, cx: &mut Core) {
        if let Some(run) = &self.run {
            run.stop();
        }
        self.restart_soon(cx);
    }

    pub fn edited(
        &mut self,
        cx: &mut Core,
        docs: &Docs,
        path: &str,
        version: u64,
        edit: &TextEdit,
    ) {
        self.issues_edited(cx, docs, path, edit);
        let Some(run) = self.running() else {
            return;
        };
        // TeXpresso moves its caret to the end of each change it reads.
        let end = edit.start as usize + utf16::len(&edit.text);
        self.caret = Some((path.to_owned(), end));
        self.follow_soon(cx);
        if self.sent.get(path).is_some_and(|&sent| version <= sent) {
            return;
        }
        if !self.sources.edit(&*run, path, edit) {
            self.send(docs, path);
        }
        self.mark();
    }

    pub fn opened(&mut self, cx: &mut Core, docs: &Docs, path: &str) {
        self.issues_opened(cx, docs, path);
        self.send(docs, path);
        self.mark();
    }

    fn send(&mut self, docs: &Docs, path: &str) {
        let (Some(run), Some(doc)) = (self.running(), docs.get(path)) else {
            return;
        };
        let (text, version) = doc.doc.snapshot();
        self.sources.send(&*run, path, &text);
        self.sent.insert(path.to_owned(), version);
    }

    fn mark(&self) {
        if let Some(run) = self.running() {
            run.mark(self.sources.revision());
        }
    }

    pub fn rescan(&self) {
        if let Some(run) = self.running() {
            run.rescan();
        }
    }

    pub fn view(&mut self, first: u32, last: u32) {
        let pages = Some((first, last.max(first)));
        if self.view != pages {
            self.view = pages;
            if let Some(run) = self.running() {
                run.view(first, last.max(first));
            }
        }
    }

    pub fn caret(&mut self, cx: &mut Core, path: String, offset: usize) {
        let wanted = Some((path, offset));
        if self.wanted == wanted {
            return;
        }
        self.wanted = wanted;
        if self.phase == LivePhase::Running {
            cx.after(Timer::Caret);
            self.follow_soon(cx);
        }
    }

    fn follow_soon(&mut self, cx: &mut Core) {
        self.follow = true;
        cx.soon(Timer::Follow);
    }

    pub fn follow(&mut self, cx: &Core, docs: &Docs) {
        if !std::mem::take(&mut self.follow) {
            return;
        }
        let Some((path, offset)) = self.wanted.clone() else {
            return;
        };
        let (Some(doc), Some(typeset)) = (docs.get(&path), self.typeset.get(&path)) else {
            return;
        };
        let (doc, typeset) = (doc.doc.clone(), Arc::clone(typeset));
        let Ok(Some(pdf)) = self.pdf(cx) else {
            return;
        };
        self.follows += 1;
        let (tx, project) = (cx.tx.clone(), cx.project.clone());
        let (generation, follows) = (self.generation, self.follows);
        tokio::task::spawn_blocking(move || {
            let line = doc.with(|source| source.line_at(offset as u32));
            let lines = document_lines(&doc, Some(&typeset), line);
            if matches!(lines, SyncLines::Whole(_)) {
                return;
            }
            let Ok(loc) = synctex::forward(&project, &path, &lines, Some(&pdf)) else {
                return;
            };
            let followed = move |actor: &mut Actor| {
                let live = &actor.live;
                if (live.generation, live.follows) == (generation, follows) {
                    actor.core.emit(Event::LiveFollow(loc));
                }
            };
            let _ = tx.send(Msg::Snapshotted(Box::new(followed)));
        });
    }

    pub fn caret_settled(&mut self) {
        if let (Some(run), Some((path, offset))) = (self.running(), &self.wanted)
            && self.caret != self.wanted
            && self.sources.caret(&*run, path, *offset)
        {
            self.caret.clone_from(&self.wanted);
        }
    }

    pub fn files_changed(&self, cx: &mut Core, tree: &TreeIndex) {
        if !self.active() {
            return;
        }
        if self.sources.paths().all(|path| tree.contains(path)) {
            cx.later.push_back(Later::Rescan);
        } else {
            self.restart_soon(cx);
        }
    }

    pub fn disk_changed(&mut self, cx: &mut Core, paths: &BTreeSet<String>) {
        if self.active() {
            self.disk_paths.extend(paths.iter().cloned());
            if !self.disk_paths.is_empty() {
                cx.after(Timer::Disk);
            }
        }
    }

    pub fn refresh_disk(&mut self, cx: &Core, docs: &Docs) {
        let paths = std::mem::take(&mut self.disk_paths);
        let Some(run) = self.running() else {
            return;
        };
        let mut others = false;
        for path in paths {
            if docs.contains_key(&path) {
                continue;
            }
            others = true;
            let file = cx.project.root.join(&path);
            if is_text(&path)
                && let Ok(Some(bytes)) = read_capped(&file, MAX_FILE)
            {
                let text = crate::lossy_string(bytes);
                self.sources.send(&*run, &path, &text);
            }
        }
        if others {
            self.mark();
            run.rescan();
        }
    }

    pub fn event(&mut self, cx: &mut Core, docs: &Docs, generation: u64, event: LiveEvent) {
        if generation != self.generation {
            return;
        }
        match event {
            LiveEvent::Page { page, pdf } => cx.emit(Event::LivePage(LivePage { page, pdf })),
            LiveEvent::Document {
                path,
                pages,
                run,
                changed,
                revision,
            } => {
                if !self.acknowledged(cx, docs, revision) {
                    return;
                }
                if pages > 0 {
                    cx.pdf.live = Some(PathBuf::from(&path));
                    self.typeset.clone_from(&self.sources.read);
                    synctex::warm(PathBuf::from(&path));
                    cx.publish_pdf();
                    cx.emit(Event::LiveDocument(LiveDocument { path, changed }));
                }
                self.run_ended(cx, docs, run);
            }
            LiveEvent::Done(run) => self.run_ended(cx, docs, run),
            // A settled viewport can acknowledge changes without changing the whole PDF.
            LiveEvent::Synced(revision) => drop(self.acknowledged(cx, docs, revision)),
            LiveEvent::Log if self.log_shown => cx.soon(Timer::Log),
            LiveEvent::Log => {}
            LiveEvent::Ended(error) => {
                if cx.timers.contains_key(&Timer::Restart) {
                    self.phase = LivePhase::Starting;
                    self.reset(cx);
                    return self.publish(cx, docs, false);
                }
                if let Some(error) = error {
                    self.failure = Some(error);
                    self.report(cx, docs);
                }
                self.ended(cx, docs);
            }
        }
    }

    fn acknowledged(&mut self, cx: &mut Core, docs: &Docs, revision: u64) -> bool {
        if self.sources.acknowledge(revision).is_some() {
            return true;
        }
        self.failure = Some(messages::live_unpatched());
        self.report(cx, docs);
        self.stop(cx, docs);
        false
    }

    fn run_ended(&mut self, cx: &mut Core, docs: &Docs, run: RunEnd) {
        cx.after(Timer::Issues);
        match run {
            RunEnd::Partial => {}
            RunEnd::Stopped => cx.soon(Timer::Halting),
            RunEnd::Complete => {
                cx.timers.remove(&Timer::Halting);
                self.halted(cx, docs, false);
            }
        }
    }

    pub fn halted(&mut self, cx: &mut Core, docs: &Docs, halted: bool) {
        if self.halted != halted {
            self.halted = halted;
            self.publish(cx, docs, false);
        }
    }

    pub fn issues_settled(&mut self, cx: &mut Core, docs: &Docs, tree: &TreeIndex) {
        if self.phase != LivePhase::Running || !self.sources.settled() {
            return;
        }
        let log = self.run.as_ref().and_then(|run| run.tex_log());
        let (Some(log), Some(main)) = (log, &tree.main) else {
            return;
        };
        let files = tree.files.iter();
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
                (Some(file), Some(line)) => docs
                    .get(file)
                    .map_or(0, |doc| doc.doc.with(|source| source.line_start(line))),
                _ => return None,
            };
            Some(Issue { item, at })
        });
        self.issues = placed.collect();
        self.publish(cx, docs, false);
    }

    fn issues_edited(&mut self, cx: &mut Core, docs: &Docs, path: &str, edit: &TextEdit) {
        let ours = |issue: &Issue| issue.item.file.as_deref() == Some(path);
        if !self.issues.iter().any(ours) {
            return;
        }
        let doc = &docs[path].doc;
        let inserted = utf16::len(&edit.text) as u32;
        let (count, mut moved) = (self.issues.len(), false);
        self.issues.retain_mut(|issue| {
            if !ours(issue) {
                return true;
            }
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
        if moved || self.issues.len() != count {
            self.publish(cx, docs, false);
        }
    }

    fn issues_opened(&mut self, cx: &mut Core, docs: &Docs, path: &str) {
        let doc = &docs[path].doc;
        let issues = self.issues.iter_mut();
        for issue in issues.filter(|issue| issue.item.file.as_deref() == Some(path)) {
            let line = issue.item.line.unwrap_or_default();
            issue.at = doc.with(|source| source.line_start(line));
        }
        self.publish(cx, docs, false);
    }
}

fn remember(cx: &Core, on: bool) {
    let _ = settings::store_ui(&cx.project.ui, |ui| {
        ui.live_preview = on;
        Ok(())
    });
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};

    use tokio::sync::mpsc;

    use super::*;

    #[test]
    fn a_forward_sync_racing_an_edit_reads_one_text_rather_than_the_edit_as_the_text_typeset() {
        let typeset =
            "\\documentclass{article}\n\\begin{document}\nOne.\n\nTwo.\n\\end{document}\n";
        let (above, added) = (
            utf16::len("\\documentclass{article}\n\\begin{document}\n") as u32,
            "A\nB\n",
        );
        let edited = typeset.replace("One.", &format!("{added}One."));
        let (tx, _rx) = mpsc::unbounded_channel();
        let doc = Document::new(1, "main.tex", typeset, tx, Arc::default());
        let line = 5;
        let either = [
            typeset_lines(typeset, typeset, line),
            typeset_lines(typeset, &edited, line),
        ];
        let done = AtomicBool::new(false);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                for _ in 0..20_000 {
                    doc.edit(above, 0, added, None, false);
                    doc.edit(above, utf16::len(added) as u32, "", None, false);
                }
                done.store(true, Ordering::Relaxed);
            });
            while !done.load(Ordering::Relaxed) {
                let lines = document_lines(&doc, Some(typeset), line);
                assert!(either.contains(&lines), "{lines:?} is neither {either:?}");
            }
        });
    }
}
