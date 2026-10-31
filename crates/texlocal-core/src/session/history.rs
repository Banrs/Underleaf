use std::fs;
use std::io::ErrorKind;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};

use texlocal_latex::diff::{DiffLine, compare, edit_to};

use super::actor::Actor;
use super::edits::DocumentEdits;
use super::{Msg, Pending};
use crate::messages;
use crate::paths::RelPath;
use crate::projects::{self, History, Snapshot, Taken};
use crate::{CoreError, lf, lossy_string};

pub(crate) type Then<T> =
    Box<dyn FnOnce(&mut Actor, Option<String>) -> Result<T, CoreError> + Send>;

pub(super) fn now() -> i64 {
    let since = SystemTime::now().duration_since(UNIX_EPOCH);
    since.map_or(0, |since| since.as_millis() as i64)
}

impl Actor {
    fn off_thread<T: 'static>(
        &self,
        job: impl FnOnce(&History) -> T + Send + 'static,
        done: impl FnOnce(Option<T>) + Send + 'static,
    ) {
        let open = Arc::clone(&self.writes_history);
        let job = move |history: &History| done(open.load(Ordering::Acquire).then(|| job(history)));
        let _ = self.history.send(Box::new(job));
    }

    pub fn snapshot_soon(&self) {
        let root = self.project.root.clone();
        self.off_thread(move |history| history.take(&root, now(), Taken::Auto), drop);
    }

    pub fn stop_history(&self) {
        self.writes_history.store(false, Ordering::Release);
        let (done, drained) = std::sync::mpsc::channel::<()>();
        let _ = self.history.send(Box::new(move |_| drop(done)));
        let _ = drained.recv();
    }

    pub fn beside<T: 'static>(
        &self,
        job: Result<impl FnOnce(&History) -> Result<T, CoreError> + Send + 'static, CoreError>,
        reply: Pending<T>,
    ) {
        match job {
            Ok(job) => self.off_thread(job, |done| {
                reply.send(done.unwrap_or_else(|| Err(super::gone())));
            }),
            Err(err) => reply.send(Err(err)),
        }
    }

    pub fn history_list(&self, reply: Pending<Vec<Snapshot>>) {
        self.beside(Ok(History::list), reply);
    }

    pub fn history_save(&mut self, name: String, reply: Pending<Option<Snapshot>>) {
        let name = name.trim().to_owned();
        let save = if name.is_empty() {
            Err(CoreError::bad_request(messages::version_needs_name()))
        } else {
            self.save_first()
        };
        let root = self.project.root.clone();
        let save = save.map(|()| {
            move |history: &History| {
                history.take(&root, now(), Taken::Named(name))?;
                Ok(history.list()?.into_iter().next())
            }
        });
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
        self.beside(Ok(compared), reply);
    }

    fn then_on_actor<U: Send + 'static, T: 'static>(
        &self,
        job: impl FnOnce(&History) -> Result<U, CoreError> + Send + 'static,
        then: impl FnOnce(&mut Self, U) -> Result<T, CoreError> + Send + 'static,
        reply: Pending<T>,
    ) {
        let tx = self.tx.clone();
        self.off_thread(job, move |done| {
            let done = done.unwrap_or_else(|| Err(super::gone()));
            let finish =
                move |actor: &mut Self| reply.send(done.and_then(|done| then(actor, done)));
            let _ = tx.send(Msg::Snapshotted(Box::new(finish)));
        });
    }

    pub fn before<T: 'static>(
        &self,
        reason: &'static str,
        then: Result<Then<T>, CoreError>,
        reply: Pending<T>,
    ) {
        let then = match then {
            Ok(then) => then,
            Err(err) => return reply.send(Err(err)),
        };
        let root = self.project.root.clone();
        let take = move |history: &History| history.take(&root, now(), Taken::Before(reason));
        let then =
            move |actor: &mut Self, id: Option<i64>| then(actor, id.map(|id| id.to_string()));
        self.then_on_actor(take, then, reply);
    }

    pub fn history_restore(
        &mut self,
        id: String,
        paths: Option<Vec<RelPath>>,
        reply: Pending<Option<DocumentEdits>>,
    ) {
        let open = match self.texts_to_edit() {
            Ok(open) => open,
            Err(err) => return reply.send(Err(err)),
        };
        let root = self.project.root.clone();
        let restore = move |history: &History| {
            let chosen = |path: &str| {
                paths
                    .as_ref()
                    .is_none_or(|paths| paths.iter().any(|p| p.0 == path))
            };
            let (mut edits, mut others) = (Vec::new(), Vec::new());
            for (path, bytes) in history.files(&id, chosen)? {
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
                    None => others.push((path, bytes)),
                }
            }
            if edits.len() > 1 {
                return Err(CoreError::conflict(messages::one_document()));
            }
            history.take(&root, now(), Taken::Before("Before Restore"))?;
            Ok((edits.pop(), others))
        };
        let put_back = |actor: &mut Self, (edits, others): (_, Vec<(String, _)>)| {
            let others = others.into_iter().filter(|(path, _)| !actor.deleting(path));
            if !projects::put_back(&actor.project.root, others.collect())?.is_empty() {
                actor.reload_tree();
            }
            Ok(edits)
        };
        self.then_on_actor(restore, put_back, reply);
    }
}
