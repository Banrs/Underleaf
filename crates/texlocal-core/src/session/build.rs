use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::logparse::{Fix, LogItem, Severity};
use texlocal_latex::message::Message;
use texlocal_latex::syntax::TextRange;

use super::actor::{Actor, Core, Later, Timer};
use super::documents::Docs;
use super::state::SessionSection;
use super::{Document, Msg, Pending};
use crate::CoreError;
use crate::compile::{CompileManager, CompileResult};
use crate::events::{BuildFinished, Event};
use crate::messages;
use crate::paths::{Project, disk_spelling};
use crate::service::Service;
use crate::{settings, synctex};

pub(crate) type Fut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

pub trait Compiler: Send + Sync {
    fn compile(&self, project: Project, auto: bool) -> Fut<Result<CompileResult, CoreError>>;
    fn stop_compile(&self, root: &Path);
    fn clean(&self, build: PathBuf) -> Fut<Result<(), CoreError>>;
}

impl Compiler for Arc<Service> {
    fn compile(&self, project: Project, auto: bool) -> Fut<Result<CompileResult, CoreError>> {
        let started = self.compile.start(&project, &self.tool_paths().0);
        let service = Self::clone(self);
        Box::pin(async move { service.compile.wait(started?, auto).await })
    }

    fn stop_compile(&self, root: &Path) {
        self.compile.stop(root);
    }

    fn clean(&self, build: PathBuf) -> Fut<Result<(), CoreError>> {
        Box::pin(async move {
            tokio::task::spawn_blocking(move || CompileManager::clean(&build))
                .await
                .map_err(|err| CoreError::internal(messages::unexpected(err)))?
        })
    }
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct BuildState {
    compiling: bool,
    auto: bool,
    outdated: bool,
    result: Option<CompileResult>,
    issues: Vec<LogItem>,
    lines: BTreeMap<String, Vec<IssueLine>>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct IssueLine {
    line: u32,
    error: bool,
    message: Message,
    short: Message,
    compact: Option<Message>,
    tokens: Vec<TextRange>,
    others: Vec<Message>,
    index: Option<usize>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct ShownPdf {
    path: Option<String>,
    version: u64,
    live: bool,
}

/// The PDF shown: a live preview's while it has pages, or else the last build's.
#[derive(Default)]
pub(crate) struct Shown {
    pub built: Option<String>,
    pub version: u64,
    pub live: Option<PathBuf>,
}

impl Core {
    pub fn publish_pdf(&mut self) {
        let shown = ShownPdf {
            path: self.pdf.built.clone(),
            version: self.pdf.version,
            live: self.pdf.live.is_some(),
        };
        self.publish(SessionSection::ShownPdf(shown));
    }
}

/// A finished build's log and announcement, which wait for the build queued behind it to start.
pub(crate) struct Built(String, BuildFinished);

#[derive(Default)]
pub(crate) struct Builds {
    /// Counts each change to the project's text, which builds and checks are dated by.
    pub clock: u64,
    /// The time on the clock that each document was last edited.
    edited_at: HashMap<String, u64>,
    compiling: bool,
    queued: Option<bool>,
    auto: bool,
    built: u64,
    pub waiting_for_tex: bool,
    outdated: bool,
    result: Option<CompileResult>,
    result_edits: u64,
    checks: Vec<LogItem>,
    checked: u64,
    marked: BTreeSet<String>,
    cleaners: Vec<Pending<()>>,
    cleaning: Option<(bool, u64)>,
}

impl Builds {
    pub fn busy(&self) -> bool {
        self.compiling || self.cleaning.is_some()
    }

    fn built(&self) -> impl Iterator<Item = &LogItem> {
        let result = self.result.iter();
        result.flat_map(|result| result.errors.iter().chain(&result.warnings))
    }

    fn covered(&self, check: &LogItem) -> bool {
        let same = |issue: &LogItem| issue.file == check.file && issue.line == check.line;
        self.built().any(same)
    }

    fn checks(&self) -> impl Iterator<Item = &LogItem> {
        self.checks.iter().filter(|check| !self.covered(check))
    }

    fn listed(&self) -> impl Iterator<Item = &LogItem> {
        self.built().chain(self.checks())
    }

    /// Holds a build back while an auto build waits for TeX, or queues it behind the build or clean running.
    pub fn waits(&mut self, cx: &Core, auto: bool) -> bool {
        if auto && !*cx.service.tex_found.borrow() {
            self.waiting_for_tex = true;
        } else if self.busy() {
            self.queued = Some(self.queued.unwrap_or(true) && auto);
        } else {
            return false;
        }
        true
    }

    pub fn start(&mut self, cx: &mut Core, docs: &Docs, auto: bool) {
        (self.compiling, self.auto) = (true, auto);
        self.built = self.clock;
        self.publish(cx, docs);
        let (build, tx) = (cx.compiler.compile(cx.project.clone(), auto), cx.tx.clone());
        tokio::spawn(async move {
            let _ = tx.send(Msg::BuildDone(build.await));
        });
    }

    pub fn stop(&mut self, cx: &Core) {
        self.queued = None;
        if self.compiling {
            cx.compiler.stop_compile(&cx.project.root);
        }
    }

    pub fn tex_found(&mut self, cx: &mut Core) {
        self.waiting_for_tex = false;
        if cx.auto_compile {
            cx.later.push_back(Later::Compile(true));
        }
    }

    /// Takes in a build's result, and gives back the build queued behind it with what it announces once that starts.
    pub fn done(
        &mut self,
        cx: &mut Core,
        result: Result<CompileResult, CoreError>,
        live: (bool, u64),
    ) -> (Option<bool>, Built) {
        let mut result = result.unwrap_or_else(|err| CompileResult {
            errors: vec![LogItem::error(err.message)],
            ..CompileResult::default()
        });
        let mut spelt: HashMap<String, String> = HashMap::new();
        let items = result.errors.iter_mut().chain(&mut result.warnings);
        let files = items
            .chain(&mut result.bad_boxes)
            .filter_map(|item| item.file.as_mut());
        for file in files {
            let disk = || disk_spelling(&cx.project.root, file).unwrap_or_else(|| file.clone());
            *file = spelt.entry(file.clone()).or_insert_with(disk).clone();
        }
        if let Some(pdf) = &result.pdf {
            if result.pdf_changed {
                synctex::warm(pdf.into());
            }
            cx.pdf.built = Some(pdf.clone());
            cx.pdf.version += u64::from(result.pdf_changed);
            self.outdated = self.clock != self.built;
        } else {
            cx.pdf.built = built_pdf(&cx.project);
        }
        let before = self.result.as_ref().map_or(0, |result| result.errors.len());
        let auto = self.auto;
        let announce = !result.stopped && (!auto || result.errors.len() != before);
        let log = std::mem::take(&mut result.log);
        (self.result, self.result_edits) = (Some(result), self.built);
        self.compiling = false;
        if !self.cleaners.is_empty() {
            self.start_clean(cx, live);
        }
        let built = Built(log, BuildFinished { auto, announce });
        (self.queued.take(), built)
    }

    pub fn announce(&mut self, cx: &mut Core, docs: &Docs, Built(log, finished): Built) {
        self.publish(cx, docs);
        cx.publish(SessionSection::BuildLog(log));
        cx.publish_pdf();
        cx.emit(Event::BuildFinished(finished));
    }

    pub fn publish(&mut self, cx: &mut Core, docs: &Docs) {
        let lines = docs.iter().filter_map(|(path, doc)| {
            let edits = self.edited_at.get(path).copied().unwrap_or(0);
            let shown = edits <= self.result_edits;
            let built = self.built().filter(|_| shown);
            let checks = self
                .checks
                .iter()
                .filter(|check| edits <= self.checked && !(shown && self.covered(check)));
            let index = |line| {
                let on =
                    |item: &LogItem| item.file.as_ref() == Some(path) && item.line == Some(line);
                self.listed().position(on)
            };
            let lines = issue_lines(built.chain(checks), path, &doc.doc, index);
            (!lines.is_empty()).then(|| (path.clone(), lines))
        });
        let build = BuildState {
            compiling: self.compiling,
            auto: self.compiling && self.auto,
            outdated: self.outdated,
            result: self.result.clone(),
            issues: self.listed().cloned().collect(),
            lines: lines.collect(),
        };
        self.marked = build.lines.keys().cloned().collect();
        cx.publish(SessionSection::Build(build));
    }

    /// Dates a change to the project's text, which marks the PDF and the issues on a document edited out of date.
    pub fn edited(&mut self, cx: &mut Core, docs: &Docs, path: Option<&str>) {
        self.clock += 1;
        if let Some(path) = path {
            self.edited_at.insert(path.to_owned(), self.clock);
        }
        let outdated = (cx.pdf.built.is_some() || cx.pdf.live.is_some()) && !self.outdated;
        self.outdated |= outdated;
        if outdated || path.is_some_and(|path| self.marked.contains(path)) {
            self.publish(cx, docs);
        }
    }

    pub fn moved(&mut self, from: &str, to: &str) {
        if let Some(edit) = self.edited_at.remove(from) {
            self.edited_at.insert(to.to_owned(), edit);
        }
    }

    pub fn main_changed(&mut self, cx: &mut Core) {
        cx.pdf.built = built_pdf(&cx.project);
        cx.publish_pdf();
        let building = self.compiling;
        self.stop(cx);
        if cx.auto_compile || building {
            cx.later.push_back(Later::Compile(cx.auto_compile));
        }
    }

    pub fn clean(&mut self, cx: &Core, live: (bool, u64), reply: Pending<()>) {
        self.stop(cx);
        self.cleaners.push(reply);
        if !self.compiling && self.cleaning.is_none() {
            self.start_clean(cx, live);
        }
    }

    /// Notes the live preview running and the starts and stops asked of it, to restart it after the clean.
    fn start_clean(&mut self, cx: &Core, live: (bool, u64)) {
        self.cleaning = Some(live);
        let (clean, tx) = (cx.compiler.clean(cx.project.build.clone()), cx.tx.clone());
        tokio::spawn(async move {
            let _ = tx.send(Msg::Cleaned(clean.await));
        });
    }

    /// Whether to restart the live preview the clean stopped, or None for a clean not started.
    pub fn cleaned(
        &mut self,
        cx: &mut Core,
        docs: &Docs,
        result: Result<(), CoreError>,
        intent: u64,
    ) -> Option<bool> {
        let (live, asked) = self.cleaning.take()?;
        if result.is_ok() {
            (cx.pdf.built, self.outdated, self.result) = (None, false, None);
            self.publish(cx, docs);
            cx.publish(SessionSection::BuildLog(String::new()));
            cx.publish_pdf();
        }
        let queued = self.queued.take();
        if let Some(auto) = queued.or((result.is_ok() && cx.auto_compile).then_some(true)) {
            cx.later.push_back(Later::Compile(auto));
        }
        for reply in std::mem::take(&mut self.cleaners) {
            reply.send(result.clone());
        }
        Some(result.is_ok() && live && asked == intent)
    }

    pub fn checks_done(&mut self, cx: &mut Core, docs: &Docs, checks: Vec<LogItem>, edits: u64) {
        (self.checked, self.checks) = (edits, checks);
        self.publish(cx, docs);
    }

    pub fn stopped(&mut self) {
        for reply in std::mem::take(&mut self.cleaners) {
            reply.send(Err(super::stopped()));
        }
    }
}

pub(super) fn built_pdf(project: &Project) -> Option<String> {
    let pdf = settings::read_settings(&project.settings).output(&project.build, "pdf");
    let pdf = pdf.ok().filter(|pdf| pdf.is_file())?;
    Some(pdf.to_string_lossy().into_owned())
}

impl Actor {
    pub fn compile(&mut self, auto: bool) -> Result<(), CoreError> {
        if auto && self.live.previewing(&self.core) || self.builds.waits(&self.core, auto) {
            return Ok(());
        }
        if self.docs.flush_all(&mut self.core, !auto)? {
            self.builds.start(&mut self.core, &self.docs, auto);
        }
        Ok(())
    }

    pub fn build_done(&mut self, result: Result<CompileResult, CoreError>) {
        if !result.as_ref().is_ok_and(|result| result.stopped) {
            self.live.rescan();
        }
        let (queued, built) = self.builds.done(&mut self.core, result, self.live.asked());
        if let Some(auto) = queued {
            let _ = self.compile(auto);
        }
        self.builds.announce(&mut self.core, &self.docs, built);
        self.close_when_idle();
    }

    pub fn cleaned(&mut self, result: Result<(), CoreError>) {
        let (_, intent) = self.live.asked();
        if let Some(restart) = self
            .builds
            .cleaned(&mut self.core, &self.docs, result, intent)
        {
            if restart {
                self.core.after(Timer::Restart);
            }
            self.close_when_idle();
        }
    }
}

pub(super) fn issue_lines<'a>(
    issues: impl IntoIterator<Item = &'a LogItem>,
    path: &str,
    doc: &Document,
    index: impl Fn(u32) -> Option<usize>,
) -> Vec<IssueLine> {
    let mut lines: BTreeMap<u32, Vec<&LogItem>> = BTreeMap::new();
    for item in issues
        .into_iter()
        .filter(|item| item.file.as_deref() == Some(path))
    {
        if let Some(line) = item.line {
            lines.entry(line).or_default().push(item);
        }
    }
    let line = |(line, items): (u32, Vec<&LogItem>)| {
        let (item, others) = (items[0], &items[1..]);
        let command = item.command.as_deref();
        let compact = match command {
            Some(command) => Some(messages::compact_undefined(command)),
            None => (item.fix == Some(Fix::ShellEscape)).then(messages::compact_shell_escape),
        };
        let tokens = command.map_or_else(Vec::new, |command| {
            doc.with(|source| source.command_ranges(line, command))
        });
        IssueLine {
            line,
            error: item.kind == Severity::Error,
            message: item.message.clone(),
            short: item.short.clone(),
            compact,
            tokens,
            others: others.iter().map(|other| other.message.clone()).collect(),
            index: index(line),
        }
    };
    lines.into_iter().map(line).collect()
}
