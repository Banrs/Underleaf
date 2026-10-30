use std::fs;
use std::io::ErrorKind;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};

use texlocal_latex::diff::{DiffLine, compare, edit_to};

use super::Pending;
use super::actor::Actor;
use super::edits::DocumentEdits;
use crate::messages;
use crate::paths::RelPath;
use crate::projects::{self, History, Snapshot, Taken};
use crate::{CoreError, lf, lock, lossy_string};

fn now() -> i64 {
    let since = SystemTime::now().duration_since(UNIX_EPOCH);
    since.map_or(0, |since| since.as_millis() as i64)
}

impl Actor {
    fn off_thread<T: 'static>(
        &self,
        job: impl FnOnce(&History) -> T + Send + 'static,
        done: impl FnOnce(Option<T>) + Send + 'static,
    ) {
        let (history, open) = (Arc::clone(&self.history), Arc::clone(&self.writes_history));
        tokio::task::spawn_blocking(move || {
            let history = lock(&history);
            done(open.load(Ordering::Acquire).then(|| job(&history)));
        });
    }

    pub fn snapshot_soon(&self) {
        let root = self.project.root.clone();
        self.off_thread(move |history| history.take(&root, now(), Taken::Auto), drop);
    }

    pub fn stop_history(&self) {
        self.writes_history.store(false, Ordering::Release);
        drop(lock(&self.history));
    }

    pub fn snapshot_before(&self, reason: &'static str) -> Result<Option<String>, CoreError> {
        let taken = lock(&self.history).take(&self.project.root, now(), Taken::Before(reason))?;
        Ok(taken.map(|id| id.to_string()))
    }

    fn beside<T: 'static>(
        &self,
        job: impl FnOnce(&History) -> Result<T, CoreError> + Send + 'static,
        reply: Pending<T>,
    ) {
        self.off_thread(job, |done| {
            reply.send(done.unwrap_or_else(|| Err(super::gone())));
        });
    }

    pub fn history_list(&self, reply: Pending<Vec<Snapshot>>) {
        self.beside(History::list, reply);
    }

    pub fn history_save(&mut self, name: String, reply: Pending<Option<Snapshot>>) {
        let name = name.trim().to_owned();
        if name.is_empty() {
            return reply.send(Err(CoreError::bad_request(messages::version_needs_name())));
        }
        if let Err(err) = self.save_first() {
            return reply.send(Err(err));
        }
        let root = self.project.root.clone();
        let save = move |history: &History| {
            history.take(&root, now(), Taken::Named(name))?;
            Ok(history.list()?.into_iter().next())
        };
        self.beside(save, reply);
    }

    pub fn history_compare(&self, id: String, path: String, reply: Pending<Vec<DiffLine>>) {
        if !texlocal_latex::is_text(&path) {
            let refused = CoreError::bad_request(messages::only_text_compared());
            return reply.send(Err(refused));
        }
        let edited = self.docs.get(&path).map(|doc| doc.doc.snapshot().0);
        let abs = self.project.root.join(&path);
        let compared = move |history: &History| {
            let text = |bytes| lf(lossy_string(bytes));
            let old = history.files(&id, |p| p == path)?.pop();
            let new = match (edited, fs::read(abs)) {
                (Some(edited), _) => edited,
                (None, Err(err)) if err.kind() == ErrorKind::NotFound => String::new(),
                (None, read) => text(read?),
            };
            Ok(compare(
                &old.map_or(String::new(), |(_, bytes)| text(bytes)),
                &new,
            ))
        };
        self.beside(compared, reply);
    }

    pub fn history_restore(
        &mut self,
        id: &str,
        paths: Option<Vec<RelPath>>,
    ) -> Result<Option<DocumentEdits>, CoreError> {
        let open = self.texts_to_edit()?;
        let chosen = |path: &str| {
            paths
                .as_ref()
                .is_none_or(|paths| paths.iter().any(|p| p.0 == path))
        };
        let files = lock(&self.history).files(id, chosen)?;
        let (mut edits, mut others) = (Vec::new(), Vec::new());
        for (path, bytes) in files {
            match open.iter().find(|(open, ..)| *open == path) {
                Some((_, text, version)) => {
                    if let Some(edit) = edit_to(text, &lf(lossy_string(bytes))) {
                        let version = *version;
                        edits.push(DocumentEdits {
                            path,
                            version,
                            edits: vec![edit],
                        });
                    }
                }
                None if !self.deleting(&path) => others.push((path, bytes)),
                None => {}
            }
        }
        if edits.len() > 1 {
            return Err(CoreError::conflict(messages::one_document()));
        }
        self.snapshot_before("Before Restore")?;
        let written = projects::put_back(&self.project.root, others)?;
        if !written.is_empty() {
            self.reload_tree();
        }
        Ok(edits.pop())
    }
}
