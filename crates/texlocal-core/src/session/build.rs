use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::logparse::{Fix, LogItem, Severity};
use texlocal_latex::syntax::TextRange;

use super::actor::{Actor, Later, Timer};
use super::state::SessionSection;
use super::{Document, Msg, Pending};
use crate::CoreError;
use crate::compile::{CompileManager, CompileResult};
use crate::events::{BuildFinished, Event};
use crate::paths::{Project, disk_spelling};
use crate::service::Service;
use crate::settings;

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
                .map_err(|err| CoreError::internal(err.to_string()))?
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
    message: String,
    short: String,
    compact: Option<String>,
    tokens: Vec<TextRange>,
    others: Vec<String>,
    index: Option<usize>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct ShownPdf {
    path: Option<String>,
    version: u64,
    live: bool,
}

#[derive(Default)]
pub(crate) struct Builds {
    pub compiling: bool,
    pub queued: Option<bool>,
    auto: bool,
    built: u64,
    pub waiting_for_tex: bool,
    pub pdf: Option<String>,
    version: u64,
    outdated: bool,
    result: Option<CompileResult>,
    result_edits: u64,
    checks: Vec<LogItem>,
    checked: u64,
    marked: BTreeSet<String>,
    pub cleaners: Vec<Pending<()>>,
    cleaning: Option<(bool, u64)>,
}

impl Builds {
    fn built(&self) -> impl Iterator<Item = &LogItem> {
        let result = self.result.iter();
        result.flat_map(|result| result.errors.iter().chain(&result.warnings))
    }

    fn checks(&self) -> impl Iterator<Item = &LogItem> {
        self.checks.iter().filter(|check| {
            let same = |issue: &LogItem| issue.file == check.file && issue.line == check.line;
            !self.built().any(same)
        })
    }

    fn listed(&self) -> impl Iterator<Item = &LogItem> {
        self.built().chain(self.checks())
    }
}

pub(super) fn built_pdf(project: &Project) -> Option<String> {
    let pdf = settings::read_settings(&project.settings).output(&project.build, "pdf");
    let pdf = pdf.ok().filter(|pdf| pdf.is_file())?;
    Some(pdf.to_string_lossy().into_owned())
}

impl Actor {
    fn has_pdf(&self) -> bool {
        self.builds.pdf.is_some() || self.live.document_seen
    }

    pub fn compile(&mut self, auto: bool) -> Result<(), CoreError> {
        if auto && self.live_previewing() {
            return Ok(());
        }
        if auto && !*self.service.tex_found.borrow() {
            self.builds.waiting_for_tex = true;
            return Ok(());
        }
        if self.builds.compiling || self.builds.cleaning.is_some() {
            self.builds.queued = Some(self.builds.queued.unwrap_or(true) && auto);
            return Ok(());
        }
        if !self.flush_all(!auto)? {
            return Ok(());
        }
        (self.builds.compiling, self.builds.auto) = (true, auto);
        self.builds.built = self.edits;
        self.publish_build();
        let (build, tx) = (
            self.compiler.compile(self.project.clone(), auto),
            self.tx.clone(),
        );
        tokio::spawn(async move {
            let _ = tx.send(Msg::BuildDone(build.await));
        });
        Ok(())
    }

    pub fn stop_compile(&mut self) {
        self.builds.queued = None;
        if self.builds.compiling {
            self.compiler.stop_compile(&self.project.root);
        }
    }

    pub fn build_done(&mut self, result: Result<CompileResult, CoreError>) {
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
            let disk = || disk_spelling(&self.project.root, file).unwrap_or_else(|| file.clone());
            *file = spelt.entry(file.clone()).or_insert_with(disk).clone();
        }
        if !result.stopped {
            self.live_rescan();
        }
        let builds = &mut self.builds;
        if let Some(pdf) = &result.pdf {
            builds.pdf = Some(pdf.clone());
            builds.version += u64::from(result.pdf_changed);
            builds.outdated = self.edits != builds.built;
        }
        let before = builds
            .result
            .as_ref()
            .map_or(0, |result| result.errors.len());
        let auto = builds.auto;
        let announce = !result.stopped && (!auto || result.errors.len() != before);
        (builds.result, builds.result_edits) = (Some(result), builds.built);
        builds.compiling = false;
        if !builds.cleaners.is_empty() && builds.cleaning.is_none() {
            self.start_clean();
        }
        if let Some(auto) = self.builds.queued.take() {
            let _ = self.compile(auto);
        }
        self.publish_build();
        self.publish_pdf();
        self.emit(Event::BuildFinished(BuildFinished { auto, announce }));
    }

    pub fn publish_build(&mut self) {
        let builds = &self.builds;
        let lines = self.docs.iter().filter_map(|(path, doc)| {
            let edits = self.last_edits.get(path).copied().unwrap_or(0);
            let built = builds.built().filter(|_| edits <= builds.result_edits);
            let checks = builds.checks.iter().filter(|_| edits <= builds.checked);
            let index = |line| {
                let on =
                    |item: &LogItem| item.file.as_ref() == Some(path) && item.line == Some(line);
                builds.listed().position(on)
            };
            let lines = issue_lines(built.chain(checks), path, &doc.doc, index);
            (!lines.is_empty()).then(|| (path.clone(), lines))
        });
        let build = BuildState {
            compiling: builds.compiling,
            auto: builds.compiling && builds.auto,
            outdated: builds.outdated,
            result: builds.result.clone(),
            issues: builds.listed().cloned().collect(),
            lines: lines.collect(),
        };
        self.builds.marked = build.lines.keys().cloned().collect();
        self.publish(SessionSection::Build(build));
    }

    pub fn publish_pdf(&mut self) {
        let shown = ShownPdf {
            path: self.builds.pdf.clone(),
            version: self.builds.version,
            live: self.live.document_seen,
        };
        self.publish(SessionSection::ShownPdf(shown));
    }

    pub fn mark_outdated(&mut self, edited: Option<&str>) {
        let outdated = self.has_pdf() && !self.builds.outdated;
        self.builds.outdated |= outdated;
        if outdated || edited.is_some_and(|path| self.builds.marked.contains(path)) {
            self.publish_build();
        }
    }

    pub fn clean(&mut self, reply: Pending<()>) {
        self.stop_compile();
        self.builds.cleaners.push(reply);
        if !self.builds.compiling && self.builds.cleaning.is_none() {
            self.start_clean();
        }
    }

    fn start_clean(&mut self) {
        self.builds.cleaning = Some((self.live.active(), self.live.intent));
        let (clean, tx) = (
            self.compiler.clean(self.project.build.clone()),
            self.tx.clone(),
        );
        tokio::spawn(async move {
            let _ = tx.send(Msg::Cleaned(clean.await));
        });
    }

    pub fn cleaned(&mut self, result: Result<(), CoreError>) {
        let Some((live, intent)) = self.builds.cleaning.take() else {
            return;
        };
        if result.is_ok() {
            if live && intent == self.live.intent {
                self.after(Timer::Restart);
            }
            let builds = &mut self.builds;
            (builds.pdf, builds.outdated, builds.result) = (None, false, None);
            self.publish_build();
            self.publish_pdf();
        }
        let queued = self.builds.queued.take();
        if let Some(auto) = queued.or((result.is_ok() && self.auto_compile).then_some(true)) {
            self.later.push_back(Later::Compile(auto));
        }
        for reply in std::mem::take(&mut self.builds.cleaners) {
            reply.send(result.clone());
        }
    }

    pub fn checks_done(&mut self, checks: Vec<LogItem>, edits: u64) {
        (self.builds.checked, self.builds.checks) = (edits, checks);
        self.publish_build();
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
            Some(command) => Some(format!("Undefined: {command}")),
            None => (item.fix == Some(Fix::ShellEscape)).then(|| "Needs Shell Escape".to_owned()),
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
