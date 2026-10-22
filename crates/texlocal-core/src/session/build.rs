//! The session's builds: one at a time with one more queued, Clean once the build
//! stops, and the issues of the last build on the editor's lines. latexmk is behind a seam
//! (`Engine`), so the session's rules are tested without it.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use serde_json::{Value, json};

use super::actor::{Actor, Later, Timer};
use super::{Document, Msg, Reply};
use crate::CoreError;
use crate::analyze::disk_spelling;
use crate::compile::{CompileManager, CompileResult};
use crate::logparse::{LogItem, SHELL_ESCAPE, Severity};
use crate::paths::Project;
use crate::service::Service;

pub(crate) type Fut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

pub(crate) trait Engine: Send + Sync {
    fn compile(&self, project: Project, auto: bool) -> Fut<Result<CompileResult, CoreError>>;
    fn stop_compile(&self, root: &Path);
    fn clean(&self, build: PathBuf) -> Fut<Result<(), CoreError>>;
}

impl Engine for Arc<Service> {
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
    /// None until the first scan has checked the project.
    checks: Option<Vec<LogItem>>,
    /// The session's count of edits as the checks' scan began.
    checked: u64,
    chosen: Option<usize>,
    result_edits: u64,
    pub cleaners: Vec<Reply>,
    /// Whether live preview ran as the clean began, and the Start it ran for.
    cleaning: Option<(bool, u64)>,
    shown: Value,
}

impl Builds {
    /// The session's issues: the last build's errors, then its warnings, then the checks.
    fn listed(&self) -> impl Iterator<Item = &LogItem> {
        self.issues.iter().chain(self.checks.iter().flatten())
    }
}

impl Actor {
    pub fn has_pdf(&self) -> bool {
        self.builds.pdf || self.live.document_seen
    }

    /// An automatic build waits while live preview runs, and for TeX to be found. Err: a save
    /// someone asked for failed.
    pub fn compile(&mut self, auto: bool) -> Result<(), CoreError> {
        if auto && self.live_previewing() {
            return Ok(());
        }
        if auto && !*self.service.tex_found.borrow() {
            self.builds.waiting_for_tex = true;
            return Ok(());
        }
        if self.builds.compiling {
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
            self.engine.compile(self.project.clone(), auto),
            self.tx.clone(),
        );
        tokio::spawn(async move {
            let _ = tx.send(Msg::BuildDone(build.await));
        });
        Ok(())
    }

    pub fn stop_compile(&mut self) {
        if self.builds.compiling {
            self.builds.queued = None;
            self.engine.stop_compile(&self.project.root);
        }
    }

    pub fn build_done(&mut self, result: Result<CompileResult, CoreError>) {
        let mut result = result.unwrap_or_else(|err| CompileResult {
            errors: vec![LogItem::error(err.message)],
            ..CompileResult::default()
        });
        // As the documents are kept, not as TeX wrote them.
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
        builds.chosen = None;
        let auto = builds.auto;
        let announce = !result.stopped && (!auto || builds.error_count != before);
        let outdated = builds.outdated;
        self.mark_issues();
        // Live Preview reads the build folder's .aux and .bbl; TeXpresso goes back only as far
        // as their first changed byte. A stopped build may have left them half written.
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
        // Published once the queued build has started: builds back to back show as one.
        if let Some(auto) = self.builds.queued.take() {
            let _ = self.compile(auto);
        }
        self.publish_build();
    }

    pub fn build_state(&self) -> Value {
        let builds = &self.builds;
        json!({
            "compiling": builds.compiling,
            "auto": builds.compiling && builds.auto,
            "outdated": builds.outdated,
        })
    }

    pub fn publish_build(&mut self) {
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

    pub fn clean(&mut self, reply: Reply) {
        self.stop_compile();
        self.builds.cleaners.push(reply);
        if !self.builds.compiling && self.builds.cleaning.is_none() {
            self.start_clean();
        }
    }

    fn start_clean(&mut self) {
        self.builds.cleaning = Some((self.live.active(), self.live.intent));
        let (clean, tx) = (
            self.engine.clean(self.project.build.clone()),
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
            (builds.issues, builds.error_count, builds.chosen) = (Vec::new(), 0, None);
            self.mark_issues();
            self.publish_build();
            self.emit("build_cleaned", json!({}));
            if self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
        for reply in std::mem::take(&mut self.builds.cleaners) {
            reply.send(result.clone().map(|()| Value::Null));
        }
    }

    // MARK: - Issues

    pub fn checks_done(&mut self, checks: Vec<LogItem>, edits: u64) {
        self.builds.checked = edits;
        if self.builds.checks.as_ref() != Some(&checks) {
            self.emit("checks", json!({ "items": checks }));
            self.builds.checks = Some(checks);
        }
        self.mark_issues();
    }

    pub fn clear_issues(&mut self, path: &str) {
        if let Some(doc) = self.docs.get_mut(path)
            && !doc.issues.is_empty()
        {
            doc.issues.clear();
            self.emit("issues", json!({ "path": path, "lines": [] }));
        }
    }

    /// A document edited since the last build or check began isn't marked with its issues: its
    /// lines may have moved.
    pub fn mark_issues(&mut self) {
        let mut changed = Vec::new();
        let builds = &self.builds;
        for (path, doc) in &mut self.docs {
            let edits = self.last_edits.get(path).copied().unwrap_or(0);
            let built = builds
                .issues
                .iter()
                .filter(|_| edits <= builds.result_edits);
            let checks = builds.checks.iter().flatten();
            let checks = checks.filter(|_| edits <= builds.checked);
            let lines = issue_lines(built.chain(checks), path, &doc.doc);
            if lines != doc.issues {
                doc.issues.clone_from(&lines);
                changed.push(json!({ "path": path, "lines": lines }));
            }
        }
        for issues in changed {
            self.emit("issues", issues);
        }
    }

    pub fn choose_issue(&mut self, index: Option<usize>) -> Value {
        self.builds.chosen = index;
        let issue = index.and_then(|index| self.builds.listed().nth(index));
        match (index, issue) {
            (Some(index), Some(issue)) => json!({ "index": index, "issue": issue }),
            _ => Value::Null,
        }
    }

    /// The next or previous issue with a place, round the list's ends.
    pub fn next_issue(&mut self, next: bool) -> Value {
        let issues = self.builds.listed().enumerate();
        let places: Vec<usize> = issues
            .filter(|(_, issue)| issue.file.is_some())
            .map(|(i, _)| i)
            .collect();
        let chosen = self.builds.chosen;
        let place = if next {
            let after = places.iter().find(|&&p| chosen.is_none_or(|c| p > c));
            after.or(places.first())
        } else {
            let before = places.iter().rev().find(|&&p| chosen.is_none_or(|c| p < c));
            before.or(places.last())
        };
        match place {
            Some(&place) => self.choose_issue(Some(place)),
            None => Value::Null,
        }
    }
}

/// Each line's first issue, with the messages of the others there. An undefined command's
/// issue has where the line has the command (`tokens`), and a `compact` message that names it
/// in fewer words; so does one that needs shell escape.
pub(super) fn issue_lines<'a>(
    issues: impl IntoIterator<Item = &'a LogItem>,
    path: &str,
    doc: &Document,
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
            None => (item.message == SHELL_ESCAPE).then(|| "Needs Shell Escape".to_owned()),
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
        })
    };
    lines.into_iter().map(line).collect()
}
