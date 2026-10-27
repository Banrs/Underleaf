use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use serde_json::{Value, json};
use texlocal_latex::logparse::{Fix, LogItem, Severity};

use super::actor::{Actor, Later, Timer};
use super::{Document, Msg, Pending};
use crate::CoreError;
use crate::compile::{CompileManager, CompileResult};
use crate::paths::Project;
use crate::paths::disk_spelling;
use crate::service::Service;

pub(crate) type Fut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

pub(crate) trait Compiler: Send + Sync {
    fn compile(&self, project: Project, auto: bool) -> Fut<Result<CompileResult, CoreError>>;
    fn stop_compile(&self, root: &Path);
    fn clean(&self, build: PathBuf) -> Fut<Result<(), CoreError>>;
}

impl Compiler for Arc<Service> {
    fn compile(&self, project: Project, auto: bool) -> Fut<Result<CompileResult, CoreError>> {
        let service = Self::clone(self);
        Box::pin(async move {
            let tex_path = service.tool_paths().0;
            service.compile.compile(&project, &tex_path, auto).await
        })
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

#[derive(Default)]
pub(crate) struct Builds {
    pub compiling: bool,
    pub queued: Option<bool>,
    auto: bool,
    built: u64,
    pub waiting_for_tex: bool,
    pub pdf: bool,
    outdated: bool,
    issues: Vec<LogItem>,
    error_count: usize,
    checks: Option<Vec<LogItem>>,
    checks_shown: Value,
    checked: u64,
    result_edits: u64,
    pub cleaners: Vec<Pending<()>>,
    cleaning: Option<(bool, u64)>,
    shown: Value,
}

impl Builds {
    fn checks(&self) -> impl Iterator<Item = &LogItem> {
        let checks = self.checks.iter().flatten();
        checks.filter(|check| {
            let built = |issue: &LogItem| issue.file == check.file && issue.line == check.line;
            !self.issues.iter().any(built)
        })
    }

    fn listed(&self) -> impl Iterator<Item = &LogItem> {
        self.issues.iter().chain(self.checks())
    }
}

impl Actor {
    fn has_pdf(&self) -> bool {
        self.builds.pdf || self.live.document_seen
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
        let builds = &mut self.builds;
        if result.pdf.is_some() {
            builds.pdf = true;
            builds.outdated = self.edits != builds.built;
        }
        let before = builds.error_count;
        builds.issues = result
            .errors
            .iter()
            .chain(&result.warnings)
            .cloned()
            .collect();
        builds.error_count = result.errors.len();
        builds.result_edits = builds.built;
        let auto = builds.auto;
        let announce = !result.stopped && (!auto || builds.error_count != before);
        let outdated = builds.outdated;
        self.mark_issues();
        self.publish_checks();
        if !result.stopped {
            self.live_rescan();
        }
        let fields =
            json!({ "auto": auto, "announce": announce, "outdated": outdated, "result": result });
        self.emit("build_finished", fields);
        self.builds.compiling = false;
        if !self.builds.cleaners.is_empty() && self.builds.cleaning.is_none() {
            self.start_clean();
        }
        if let Some(auto) = self.builds.queued.take() {
            let _ = self.compile(auto);
        }
        self.publish_build();
    }

    fn build_state(&self) -> Value {
        let builds = &self.builds;
        json!({
            "compiling": builds.compiling,
            "auto": builds.compiling && builds.auto,
            "outdated": builds.outdated,
        })
    }

    fn publish_build(&mut self) {
        let state = self.build_state();
        if state != self.builds.shown {
            self.builds.shown = state.clone();
            self.emit("build", state);
        }
    }

    pub fn mark_outdated(&mut self) {
        if self.has_pdf() && !self.builds.outdated {
            self.builds.outdated = true;
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
            (builds.pdf, builds.outdated) = (false, false);
            (builds.issues, builds.error_count) = (Vec::new(), 0);
            self.mark_issues();
            self.publish_checks();
            self.publish_build();
            self.emit("build_cleaned", json!({}));
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
        (self.builds.checked, self.builds.checks) = (edits, Some(checks));
        self.publish_checks();
        self.mark_issues();
    }

    fn publish_checks(&mut self) {
        if self.builds.checks.is_none() {
            return;
        }
        let items = json!(self.builds.checks().collect::<Vec<_>>());
        if items != self.builds.checks_shown {
            self.builds.checks_shown = items.clone();
            self.emit("checks", json!({ "items": items }));
        }
    }

    pub fn clear_issues(&mut self, path: &str) {
        if let Some(doc) = self.docs.get_mut(path)
            && !doc.issues.is_empty()
        {
            doc.issues.clear();
            self.emit("issues", json!({ "path": path, "lines": [] }));
        }
    }

    pub fn mark_issues(&mut self) {
        let mut changed = Vec::new();
        let builds = &self.builds;
        for (path, doc) in self.docs.iter_mut() {
            let edits = self.last_edits.get(path).copied().unwrap_or(0);
            let built = builds
                .issues
                .iter()
                .filter(|_| edits <= builds.result_edits);
            let checks = builds.checks.iter().flatten();
            let checks = checks.filter(|_| edits <= builds.checked);
            let index = |line| {
                let on =
                    |item: &LogItem| item.file.as_ref() == Some(path) && item.line == Some(line);
                builds.listed().position(on)
            };
            let lines = issue_lines(built.chain(checks), path, &doc.doc, index);
            if lines != doc.issues {
                doc.issues.clone_from(&lines);
                changed.push(json!({ "path": path, "lines": lines }));
            }
        }
        for issues in changed {
            self.emit("issues", issues);
        }
    }
}

pub(super) fn issue_lines<'a>(
    issues: impl IntoIterator<Item = &'a LogItem>,
    path: &str,
    doc: &Document,
    index: impl Fn(u32) -> Option<usize>,
) -> Vec<Value> {
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
        let others: Vec<&str> = others.iter().map(|other| other.message.as_str()).collect();
        json!({
            "line": line,
            "error": item.kind == Severity::Error,
            "message": item.message,
            "short": item.short,
            "compact": compact,
            "tokens": tokens,
            "others": others,
            "index": index(line),
        })
    };
    lines.into_iter().map(line).collect()
}
