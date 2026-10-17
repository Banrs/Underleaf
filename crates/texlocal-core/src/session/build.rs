//! The session's builds: one at a time with one more queued, Clean once the
//! build stops, and the issues of the last build on the editor's lines.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::actor::Actor;
use super::{Msg, Reply};
use crate::CoreError;
use crate::compile::CompileResult;
use crate::logparse::LogItem;
use crate::syntax::TextRange;

#[derive(Default)]
pub(crate) struct Builds {
    pub compiling: bool,
    /// One more build asked for during this one; `Some(true)` while every request was automatic.
    pub queued: Option<bool>,
    auto: bool,
    /// The edit count when the build running began.
    built: u64,
    /// An automatic build was skipped as TeX wasn't found: one runs once `status` finds it.
    pub waiting_for_tex: bool,
    /// The last build left a PDF.
    pub pdf: bool,
    outdated: bool,
    issues: Vec<LogItem>,
    error_count: usize,
    chosen: Option<usize>,
    /// The edit count when the build whose issues these are began.
    result_edits: u64,
    /// The Cleans asked for: one runs once the build stops, and answers them all.
    pub cleaners: Vec<Reply>,
    /// The clean running: whether live preview ran as it began, and the user's intent then.
    cleaning: Option<(bool, u64)>,
    shown: Value,
}

impl Actor {
    pub fn has_pdf(&self) -> bool {
        self.builds.pdf || self.live.document_seen
    }

    pub fn live_previewing(&self) -> bool {
        self.live.active() || self.live.restart_at.is_some()
    }

    /// A request during a build queues one more. An automatic build waits
    /// while live preview runs, and for TeX to be found (`status`). Shown only
    /// once it runs: one whose saves can't go ahead builds nothing. Err: a save
    /// someone asked for failed.
    pub fn compile(&mut self, auto: bool) -> Result<(), CoreError> {
        if self.closed || auto && self.live_previewing() {
            return Ok(());
        }
        if auto && !self.service.tex_found() {
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
        let (build, tx) = (self.engine.compile(self.root.clone()), self.tx.clone());
        tokio::spawn(async move {
            let _ = tx.send(Msg::BuildDone(build.await));
        });
        Ok(())
    }

    pub fn stop_compile(&mut self) {
        if self.builds.compiling {
            self.builds.queued = None;
            self.engine.stop_compile(&self.root);
        }
    }

    pub fn build_done(&mut self, result: Result<CompileResult, CoreError>) {
        let result = result.unwrap_or_else(|err| CompileResult {
            errors: vec![LogItem::error(err.message)],
            ..CompileResult::default()
        });
        if !self.closed {
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
            let announce = !auto || builds.error_count != before;
            let outdated = builds.outdated;
            self.mark_issues();
            let fields = json!({ "auto": auto, "announce": announce, "outdated": outdated, "result": result });
            self.emit("build_finished", fields);
        }
        self.finish_build();
    }

    fn finish_build(&mut self) {
        self.builds.compiling = false;
        let again = self.builds.queued.take().filter(|_| !self.closed);
        if !self.builds.cleaners.is_empty() && self.builds.cleaning.is_none() {
            self.start_clean();
        }
        // Published once the queued build has started, if it could: builds back to
        // back show as one, with no `compiling: false` between them.
        if let Some(auto) = again {
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

    /// The PDF now shows text since changed (an edit, or the disk's text reloaded).
    pub fn mark_outdated(&mut self) {
        if self.has_pdf() && !self.builds.outdated {
            self.builds.outdated = true;
            self.publish_build();
        }
    }

    /// A Clean asked for while another waits or runs joins it, and has its answer.
    pub fn clean(&mut self, reply: Reply) {
        self.stop_compile();
        self.builds.cleaners.push(reply);
        if !self.builds.compiling && self.builds.cleaning.is_none() {
            self.start_clean();
        }
    }

    fn start_clean(&mut self) {
        self.builds.cleaning = Some((self.live.active(), self.live.intent));
        let (clean, tx) = (self.engine.clean(self.root.clone()), self.tx.clone());
        tokio::spawn(async move {
            let _ = tx.send(Msg::Cleaned(clean.await));
        });
    }

    pub fn cleaned(&mut self, result: Result<(), CoreError>) {
        let Some((live, intent)) = self.builds.cleaning.take() else {
            return;
        };
        self.keep_live(live, intent, result.is_ok());
        if result.is_ok() && !self.closed {
            let builds = &mut self.builds;
            (builds.pdf, builds.outdated) = (false, false);
            (builds.issues, builds.error_count, builds.chosen) = (Vec::new(), 0, None);
            self.mark_issues();
            self.publish_build();
            self.emit("build_cleaned", json!({}));
            if self.auto_compile {
                self.later.push_back(super::actor::Later::Compile(true));
            }
        }
        for reply in std::mem::take(&mut self.builds.cleaners) {
            reply.send(result.clone().map(|()| Value::Null));
        }
    }

    // MARK: - Issues

    pub fn clear_issues(&mut self, path: &str) {
        if let Some(doc) = self.docs.get_mut(path)
            && !doc.issues.is_empty()
        {
            doc.issues.clear();
            self.emit("issues", json!({ "path": path, "lines": [] }));
        }
    }

    /// The build's issues on the lines of each document not edited since it started.
    pub fn mark_issues(&mut self) {
        let mut changed = Vec::new();
        for (path, doc) in &mut self.docs {
            let last_edit = self.last_edits.get(path).copied().unwrap_or(0);
            let lines = if last_edit <= self.builds.result_edits {
                let tokens = |line, command: &str| {
                    doc.doc.with(|source| source.command_ranges(line, command))
                };
                issue_lines(&self.builds.issues, path, tokens)
            } else {
                Vec::new()
            };
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
        self.chosen_issue()
    }

    fn chosen_issue(&self) -> Value {
        let issues = &self.builds.issues;
        let Some(index) = self.builds.chosen.filter(|i| *i < issues.len()) else {
            return Value::Null;
        };
        json!({ "index": index, "issue": issues[index] })
    }

    /// The next (or previous) issue with a place in a file, round to the first.
    pub fn next_issue(&mut self, next: bool) -> Value {
        let issues = &self.builds.issues;
        let places: Vec<usize> = (0..issues.len())
            .filter(|&i| issues[i].file.is_some())
            .collect();
        let chosen = self.builds.chosen;
        let place = if next {
            let after = places.iter().find(|&&p| chosen.is_none_or(|c| p > c));
            after.or(places.first())
        } else {
            let before = places.iter().rev().find(|&&p| chosen.is_none_or(|c| p < c));
            before.or(places.last())
        };
        let Some(&place) = place else {
            return Value::Null;
        };
        self.choose_issue(Some(place))
    }
}

/// The build's issues on `path`'s lines, as the editor marks them: the
/// first issue of a line with the rest after it. An undefined command's
/// issue has where the line has the command (as `tokens` finds it, from the
/// line's start), and a `compact` message that names it in fewer words.
fn issue_lines(
    issues: &[LogItem],
    path: &str,
    tokens: impl Fn(u32, &str) -> Vec<TextRange>,
) -> Vec<Value> {
    let mut lines: BTreeMap<u32, (&LogItem, Vec<String>)> = BTreeMap::new();
    for item in issues.iter().rev() {
        let (Some(file), Some(line)) = (&item.file, item.line) else {
            continue;
        };
        if file != path {
            continue;
        }
        let others = lines.remove(&line).map(|(later, mut others)| {
            others.insert(0, later.message.clone());
            others
        });
        lines.insert(line, (item, others.unwrap_or_default()));
    }
    let lines = lines.into_iter();
    lines
        .map(|(line, (item, others))| {
            let command = item.command.as_deref();
            json!({
                "line": line,
                "error": item.kind == crate::logparse::Severity::Error,
                "message": item.message,
                "short": item.short,
                "compact": command.map(|command| format!("Undefined: {command}")),
                "tokens": command.map_or_else(Vec::new, |command| tokens(line, command)),
                "others": others,
            })
        })
        .collect()
}
