//! The project's history as the session keeps it: a snapshot as it opens and after saves, one
//! before each change across files, and the commands that list, compare and restore them.

use std::fs;
use std::io::ErrorKind;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::Reply;
use super::actor::Actor;
use crate::paths::{self, Project};
use crate::projects::{self, History, Taken};
use crate::service::{arg, out, string_arg};
use crate::syntax::TextEdit;
use crate::{CoreError, lf, lock, lossy_string};

type Job = Box<dyn FnOnce(&History) -> Result<Value, CoreError> + Send>;

/// The history's jobs, taken in turn off the session's task, so no save waits on the store. A
/// snapshot a change waits for is taken on the session's task, the lock keeping it from a job's.
pub(crate) struct HistoryQueue {
    history: Arc<Mutex<History>>,
    jobs: mpsc::UnboundedSender<(Job, Option<Reply>)>,
}

impl HistoryQueue {
    pub fn new(project: &Project) -> Self {
        let history = Arc::new(Mutex::new(History::of(project)));
        let (jobs, mut queue) = mpsc::unbounded_channel::<(Job, Option<Reply>)>();
        let shared = Arc::clone(&history);
        tokio::spawn(async move {
            while let Some((job, reply)) = queue.recv().await {
                let history = Arc::clone(&shared);
                let _ = tokio::task::spawn_blocking(move || {
                    let answer = job(&lock(&history));
                    if let Some(reply) = reply {
                        reply.send(answer);
                    }
                })
                .await;
            }
        });
        Self { history, jobs }
    }

    fn queue(&self, job: Job, reply: Option<Reply>) {
        let _ = self.jobs.send((job, reply));
    }
}

fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

impl Actor {
    /// As the session opens, so the files as they were before its edits are kept, and after each
    /// save.
    pub fn snapshot_soon(&self) {
        let job = |history: &History| history.take(now(), Taken::Auto).map(|_| Value::Null);
        self.history.queue(Box::new(job), None);
    }

    pub fn snapshot_before(&self, reason: &'static str) -> Result<(), CoreError> {
        let history = lock(&self.history.history);
        history.take(now(), Taken::Before(reason)).map(drop)
    }

    /// List, save and compare, which read the store but change no file of the project's.
    pub fn history_command(&self, name: &str, args: &Value, reply: Reply) {
        match self.history_job(name, args) {
            Ok(job) => self.history.queue(job, Some(reply)),
            Err(err) => reply.send(Err(err)),
        }
    }

    fn history_job(&self, name: &str, args: &Value) -> Result<Job, CoreError> {
        Ok(match name {
            "history_list" => Box::new(|history| out(history.list()?)),
            "history_save" => {
                let name = string_arg(args, "name")?.trim().to_owned();
                if name.is_empty() {
                    return Err(CoreError::bad_request("A version needs a name."));
                }
                Box::new(move |history| {
                    history.take(now(), Taken::Named(name))?;
                    out(history.list()?.first())
                })
            }
            _ => {
                let id = string_arg(args, "id")?.to_owned();
                let path = paths::rel_key(string_arg(args, "path")?)?;
                if !projects::is_text(&path) {
                    return Err(CoreError::bad_request("Only a text file can be compared."));
                }
                let edited = self.docs.get(&path).map(|doc| doc.doc.snapshot().0);
                let abs = self.project.root.join(&path);
                Box::new(move |history| {
                    let text = |bytes| lf(lossy_string(bytes));
                    let old = history.files(&id, |p| p == path)?.pop();
                    let new = match (edited, fs::read(abs)) {
                        (Some(edited), _) => Some(edited),
                        (None, Err(err)) if err.kind() == ErrorKind::NotFound => None,
                        (None, read) => Some(text(read?)),
                    };
                    Ok(json!({ "old": old.map(|(_, bytes)| text(bytes)), "new": new }))
                })
            }
        })
    }

    /// The snapshot's files, or those of them `paths` names, as they were: an open document's as
    /// edits, the others written, all or none, as a replace does.
    pub fn history_restore(&mut self, args: &Value) -> Result<Value, CoreError> {
        let paths: Option<Vec<String>> = arg(args, "paths")?;
        let paths = paths.map(|paths| paths.iter().map(|p| paths::rel_key(p)).collect());
        let paths: Option<Vec<String>> = paths.transpose()?;
        let open = self.texts_to_edit("restored")?;
        let chosen = |path: &str| {
            paths
                .as_ref()
                .is_none_or(|paths| paths.iter().any(|p| p == path))
        };
        let files = lock(&self.history.history).files(string_arg(args, "id")?, chosen)?;
        let (mut edits, mut others) = (Vec::new(), Vec::new());
        for (path, bytes) in files {
            match open.iter().find(|(open, ..)| *open == path) {
                Some((_, text, version)) => {
                    if let Some(edit) = edit_to(text, &lf(lossy_string(bytes))) {
                        edits.push(json!({ "path": path, "version": version, "edits": [edit] }));
                    }
                }
                None if !self.deleting(&path) => others.push((path, bytes)),
                None => {}
            }
        }
        if edits.len() > 1 {
            return Err(CoreError::conflict(super::actor::ONE_DOCUMENT));
        }
        self.snapshot_before("Before Restore")?;
        let written = self.service.with_project(&self.project_id, |project| {
            projects::put_back(&project.root, others)
        })?;
        if !written.is_empty() {
            self.reload_tree();
        }
        Ok(json!({ "edits": edits.pop(), "written": written }))
    }
}

/// One edit making `text` into `to`: what lies between their common start and end, in UTF-16
/// units, so the editor keeps its place around it.
fn edit_to(text: &str, to: &str) -> Option<TextEdit> {
    if text == to {
        return None;
    }
    let same = |a: char, b: char| (a == b).then_some(a.len_utf8());
    let start: usize = text
        .chars()
        .zip(to.chars())
        .map_while(|(a, b)| same(a, b))
        .sum();
    let ends = text[start..].chars().rev().zip(to[start..].chars().rev());
    let end: usize = ends.map_while(|(a, b)| same(a, b)).sum();
    let units = |s: &str| s.encode_utf16().count() as u32;
    Some(TextEdit {
        start: units(&text[..start]),
        length: units(&text[start..text.len() - end]),
        text: to[start..to.len() - end].to_owned(),
    })
}
