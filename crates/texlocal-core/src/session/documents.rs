use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::ErrorKind;
use std::ops::Deref;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use texlocal_latex::diff::edit_to;
use texlocal_latex::message::Message;
use texlocal_latex::syntax::TextEdit;
use texlocal_latex::{file_kind, is_text};

use super::Document;
use super::actor::{Actor, Core, Later, Timer};
use super::edits::DocumentEdits;
use super::state::{DocumentState, OpenFile, SessionSection};
use super::watch::{Tree, TreeIndex};
use crate::events::Event;
use crate::messages;
use crate::paths::{self, within};
use crate::projects;
use crate::stamp::Stamp;
use crate::{CoreError, lf, lock, newline};

const MAX_EDITED: u64 = 64 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum DiskConflict {
    Changed,
    Gone,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Resolution {
    Save,
    Revert,
    Cancel,
    Close,
}

pub(crate) struct Doc {
    pub doc: Document,
    pub path: String,
    saved: u64,
    force: bool,
    disk_text: Option<String>,
    newline: &'static str,
    disk_stamp: Option<Stamp>,
    pub conflict: Option<DiskConflict>,
    asking: bool,
    /// The version a reload was asked at and its edit, which only the main thread applies.
    reloading: Option<(u64, TextEdit)>,
    pub error: Option<Message>,
}

impl Doc {
    fn dirty(&self) -> bool {
        self.force || self.doc.version() != self.saved
    }

    pub fn state(&self) -> DocumentState {
        DocumentState {
            path: self.path.clone(),
            error: self.error.clone(),
            conflict: self.conflict,
            asking: self.asking,
        }
    }
}

pub(crate) type Shared = Arc<Mutex<HashMap<String, Document>>>;

#[derive(Default)]
pub(crate) struct Docs {
    docs: BTreeMap<String, Doc>,
    shared: Shared,
    opened: u64,
    pub open: Option<String>,
    pub opens: Arc<AtomicU64>,
}

impl Deref for Docs {
    type Target = BTreeMap<String, Doc>;

    fn deref(&self) -> &Self::Target {
        &self.docs
    }
}

impl Docs {
    pub fn shared(&self) -> Shared {
        Arc::clone(&self.shared)
    }

    pub fn handles(&self) -> HashMap<String, Document> {
        lock(&self.shared).clone()
    }

    fn insert(&mut self, path: String, doc: Doc) {
        lock(&self.shared).insert(path.clone(), doc.doc.clone());
        self.docs.insert(path, doc);
    }

    fn remove(&mut self, path: &str) -> Option<Doc> {
        lock(&self.shared).remove(path);
        self.docs.remove(path)
    }

    fn discard(&mut self, path: &str) -> bool {
        self.remove(path).map(|doc| doc.doc.close()).is_some()
    }

    pub fn clear(&mut self) {
        lock(&self.shared).clear();
        for doc in std::mem::take(&mut self.docs).into_values() {
            doc.doc.close();
        }
    }

    pub fn publish(&self, cx: &mut Core) {
        let documents = self.docs.values().map(Doc::state).collect();
        cx.publish(SessionSection::Documents(documents));
    }

    pub fn publish_open(&mut self, cx: &mut Core, tree: &TreeIndex) {
        let gone = |open: &String| match is_text(open) {
            true => !self.docs.contains_key(open),
            false => !tree.files.contains(open),
        };
        if self.open.as_ref().is_some_and(gone) {
            self.open = None;
        }
        let open = self.open.clone().map(|path| OpenFile {
            kind: file_kind(&path),
            text: is_text(&path),
            path,
        });
        cx.publish(SessionSection::OpenFile(open));
    }

    pub fn load(&mut self, cx: &mut Core, path: &str, tree: &Tree) -> Result<bool, CoreError> {
        if self.docs.contains_key(path) {
            return Ok(false);
        }
        let abs = paths::safe_path(&cx.project.root, path)?;
        let size = fs::metadata(&abs).map_err(CoreError::at(&abs))?.len();
        if size > MAX_EDITED {
            return Err(CoreError::bad_request(messages::too_large_to_edit(
                size >> 20,
            )));
        }
        let (disk, stamp) = read_disk(&abs)?;
        let (text, newline) = disk.ok_or_else(|| CoreError::bad_request(messages::not_utf8()))?;
        self.opened += 1;
        let scan = Arc::clone(&tree.scan);
        let doc = Doc {
            doc: Document::new(self.opened, path, &text, cx.tx.clone(), scan),
            path: path.to_owned(),
            saved: 0,
            force: false,
            disk_text: Some(text),
            newline,
            disk_stamp: stamp,
            conflict: None,
            asking: false,
            reloading: None,
            error: None,
        };
        self.insert(path.to_owned(), doc);
        self.publish(cx);
        Ok(true)
    }

    pub fn show(&mut self, cx: &mut Core, tree: &TreeIndex, path: &str) -> bool {
        let was = self.open.replace(path.to_owned());
        if was.as_deref() == Some(path) {
            return false;
        }
        cx.after(Timer::Symbols);
        self.publish_open(cx, tree);
        was.is_some_and(|was| {
            self.flush(cx, Some(&was), true).unwrap_or(false) && self.close(cx, &was, true)
        })
    }

    pub fn close(&mut self, cx: &mut Core, path: &str, if_saved: bool) -> bool {
        let saved = |doc: &Doc| !doc.force && doc.doc.close_if(doc.saved);
        if if_saved && !self.docs.get(path).is_some_and(saved) || !self.discard(path) {
            return false;
        }
        self.publish(cx);
        true
    }

    pub fn moved(&mut self, from: &str, to: &str) -> Vec<(String, String)> {
        let moved = |path: &str| Some(format!("{to}{}", paths::after_entry(path, from)?));
        if let Some(open) = self.open.as_deref().and_then(moved) {
            self.open = Some(open);
        }
        let mut renamed = Vec::new();
        for old in self.within(from) {
            let new = moved(&old).expect("within");
            let mut doc = self.remove(&old).expect("listed");
            doc.path.clone_from(&new);
            doc.doc.moved(&new);
            self.insert(new.clone(), doc);
            renamed.push((old, new));
        }
        for path in self.within(to) {
            if !is_text(&path) {
                self.discard(&path);
            }
        }
        renamed
    }

    pub fn path_of(&self, id: u64) -> Option<String> {
        let doc = self.docs.values().find(|doc| doc.doc.id() == id);
        doc.map(|doc| doc.path.clone())
    }

    pub fn edited(&mut self, cx: &mut Core, path: &str, version: u64, edit: &TextEdit) -> bool {
        let Some(doc) = self.docs.get_mut(path) else {
            return false;
        };
        let conflict = doc.conflict;
        let reload = doc.reloading.take_if(|(base, _)| version > *base);
        let reloaded = reload.map(|(base, reload)| version == base + 1 && reload == *edit);
        cx.after(Timer::Autosave);
        if reloaded == Some(true) {
            doc.saved = version;
            cx.after(Timer::Symbols);
            return self.check_disk(cx, path);
        }
        if reloaded == Some(false) && conflict.is_none() {
            self.ask(cx, path, DiskConflict::Changed);
        }
        false
    }

    pub fn autosave(&mut self, cx: &mut Core) {
        let mut ok = true;
        for path in self.dirty_paths() {
            ok &= self.save_doc(cx, &path, false, true).unwrap_or(false);
        }
        if ok && cx.auto_compile {
            cx.later.push_back(Later::Compile(true));
        }
    }

    pub fn within(&self, dir: &str) -> Vec<String> {
        let docs = self.docs.keys();
        docs.filter(|p| within(p, dir)).cloned().collect()
    }

    pub fn dirty_paths(&self) -> Vec<String> {
        let docs = self.docs.values().filter(|doc| doc.dirty());
        docs.map(|doc| doc.path.clone()).collect()
    }

    fn save_doc(
        &mut self,
        cx: &mut Core,
        path: &str,
        reporting: bool,
        autosave: bool,
    ) -> Result<bool, CoreError> {
        for _ in 0..2 {
            let Some(doc) = self.docs.get_mut(path) else {
                return Ok(true);
            };
            if !doc.dirty() {
                return Ok(true);
            }
            if autosave && doc.doc.composing() {
                cx.after(Timer::Autosave);
                return Ok(false);
            }
            if doc.asking || doc.reloading.is_some() {
                return Ok(false);
            }
            if let Some(kind) = doc.conflict {
                if reporting {
                    self.ask(cx, path, kind);
                }
                return Ok(false);
            }
            let (text, version) = doc.doc.snapshot();
            let text = lf(text);
            let file = match doc.newline {
                "\n" => Cow::Borrowed(text.as_str()),
                ending => Cow::Owned(text.replace('\n', ending)),
            };
            let written = paths::safe_write_path(&cx.project, path).and_then(|abs| {
                if !as_left(&abs, doc.disk_stamp, doc.disk_text.as_deref()) {
                    return Ok(None);
                }
                projects::write_creating(&abs, file.as_bytes()).map(Some)
            });
            let result = match written {
                Ok(None) => {
                    self.check_disk(cx, path);
                    continue;
                }
                Ok(Some(stamp)) => {
                    (doc.disk_text, doc.disk_stamp) = (Some(text), Some(stamp));
                    (doc.saved, doc.force, doc.error) = (version, false, None);
                    cx.after(Timer::Symbols);
                    cx.snapshot_soon();
                    Ok(true)
                }
                Err(err) => {
                    doc.error = Some(err.message.clone());
                    Err(err)
                }
            };
            self.publish(cx);
            return result;
        }
        Ok(false)
    }

    pub fn flush_all(&mut self, cx: &mut Core, reporting: bool) -> Result<bool, CoreError> {
        cx.timers.remove(&Timer::Autosave);
        self.flush(cx, None, reporting)
    }

    fn flush(
        &mut self,
        cx: &mut Core,
        only: Option<&str>,
        reporting: bool,
    ) -> Result<bool, CoreError> {
        let mut failure = None;
        for _ in 0..3 {
            let mut dirty = self.dirty_paths();
            dirty.retain(|path| only.is_none_or(|only| only == path));
            if dirty.is_empty() {
                break;
            }
            let mut all = true;
            for path in dirty {
                match self.save_doc(cx, &path, reporting, false) {
                    Ok(saved) => all &= saved,
                    Err(err) => {
                        all = false;
                        failure.get_or_insert(err);
                    }
                }
            }
            if !all {
                return match failure {
                    Some(err) if reporting => Err(err),
                    _ => Ok(false),
                };
            }
        }
        Ok(self
            .docs
            .iter()
            .all(|(path, doc)| only.is_some_and(|only| only != path) || !doc.dirty()))
    }

    pub fn save_first(&mut self, cx: &mut Core) -> Result<(), CoreError> {
        if self.save_edits(cx, true)? {
            Ok(())
        } else {
            Err(CoreError::conflict(messages::edits_unsaved()))
        }
    }

    pub fn save_edits(&mut self, cx: &mut Core, reporting: bool) -> Result<bool, CoreError> {
        let edited = !self.dirty_paths().is_empty();
        let saved = self.flush_all(cx, reporting)?;
        if saved && edited && cx.auto_compile {
            cx.later.push_back(Later::Compile(true));
        }
        Ok(saved)
    }

    pub fn stopped(&mut self, cx: &mut Core) {
        for doc in self.docs.values_mut() {
            doc.doc.close();
            doc.error = Some(if doc.dirty() {
                messages::stopped_unsaved()
            } else {
                messages::stopped_saved()
            });
        }
        self.publish(cx);
    }

    fn ask(&mut self, cx: &mut Core, path: &str, kind: DiskConflict) {
        if let Some(doc) = self.docs.get_mut(path) {
            (doc.conflict, doc.asking) = (Some(kind), true);
            self.publish(cx);
        }
    }

    pub fn resolve(
        &mut self,
        cx: &mut Core,
        path: &str,
        answer: Resolution,
    ) -> Result<bool, CoreError> {
        let doc = self
            .docs
            .get_mut(path)
            .ok_or_else(|| CoreError::not_found(messages::document_not_open()))?;
        let Some(kind) = doc.conflict else {
            return Ok(false);
        };
        match (kind, answer) {
            (_, Resolution::Cancel) => doc.asking = false,
            (DiskConflict::Changed, Resolution::Save) => {
                (doc.asking, doc.conflict, doc.force) = (false, None, true);
            }
            (DiskConflict::Changed, Resolution::Revert) => {
                let version = doc.doc.version();
                (doc.asking, doc.conflict, doc.force, doc.saved) = (false, None, false, version);
            }
            (DiskConflict::Gone, Resolution::Save) => (doc.asking, doc.conflict) = (false, None),
            (DiskConflict::Gone, Resolution::Close) => return Ok(self.close(cx, path, false)),
            _ => return Err(CoreError::bad_request(messages::answer_unfit())),
        }
        self.publish(cx);
        match answer {
            Resolution::Save => self.save_edits(cx, true).map(|_| false),
            Resolution::Revert => Ok(match self.docs[path].disk_text.clone() {
                Some(text) if self.open.as_deref() == Some(path) => {
                    self.reload(cx, path, &text);
                    false
                }
                _ => self.close(cx, path, false),
            }),
            _ => Ok(false),
        }
    }

    /// Asks the main thread, the text's one writer, to take the disk's text, which an edit made first refuses.
    fn reload(&mut self, cx: &mut Core, path: &str, text: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        let (shown, version) = doc.doc.snapshot();
        if version != doc.saved {
            return self.ask(cx, path, DiskConflict::Changed);
        }
        let Some(edit) = edit_to(&shown, text) else {
            return;
        };
        let asked = TextEdit {
            text: edit.text.clone(),
            ..edit
        };
        doc.reloading = Some((version, edit));
        cx.emit(Event::Reload(DocumentEdits {
            path: path.to_owned(),
            version,
            edits: vec![asked],
        }));
    }

    pub fn check_disk(&mut self, cx: &mut Core, path: &str) -> bool {
        let abs = cx.project.root.join(path);
        if fs::metadata(&abs).is_err_and(|err| err.kind() == ErrorKind::NotFound) {
            return self.file_gone(cx, path);
        }
        let Some(doc) = self
            .docs
            .get_mut(path)
            .filter(|doc| doc.reloading.is_none())
        else {
            return false;
        };
        if as_left(&abs, doc.disk_stamp, doc.disk_text.as_deref()) {
            return false;
        }
        let (disk, stamp) = match read_disk(&abs) {
            Ok(read) => read,
            Err(err) => {
                if doc.dirty() {
                    doc.error = Some(err.message);
                    self.publish(cx);
                }
                return false;
            }
        };
        let returned = doc.conflict == Some(DiskConflict::Gone);
        if returned {
            (doc.conflict, doc.asking) = (None, false);
        }
        doc.disk_stamp = stamp;
        if let Some((text, newline)) = &disk {
            doc.newline = *newline;
            if doc.disk_text.as_ref() == Some(text) {
                if returned {
                    self.publish(cx);
                    cx.after(Timer::Autosave);
                }
                return false;
            }
        }
        doc.disk_text = disk.map(|(text, _)| text);
        match (doc.disk_text.clone(), doc.dirty()) {
            (_, true) if doc.conflict.is_some() => {}
            (Some(text), false) if self.open.as_deref() == Some(path) => {
                self.reload(cx, path, &text);
            }
            (_, false) if self.close(cx, path, true) => return true,
            _ => self.ask(cx, path, DiskConflict::Changed),
        }
        false
    }

    fn file_gone(&mut self, cx: &mut Core, path: &str) -> bool {
        if self.close(cx, path, true) {
            return true;
        }
        let Some(doc) = self.docs.get_mut(path) else {
            return false;
        };
        doc.disk_stamp = None;
        if doc.conflict != Some(DiskConflict::Gone) {
            self.ask(cx, path, DiskConflict::Gone);
        }
        false
    }
}

impl Actor {
    pub fn open(&mut self, path: &str) -> Result<Option<String>, CoreError> {
        if self.docs.opens.fetch_sub(1, Ordering::Relaxed) > 1 {
            return Ok(None);
        }
        let path =
            paths::disk_spelling(&self.core.project.root, path).unwrap_or_else(|| path.to_owned());
        if !self.tree.contains(&path) {
            self.reload_tree();
        }
        if !is_text(&path) && !self.tree.files.contains(&path) {
            return Err(CoreError::not_found(messages::not_in_project(&path)));
        }
        self.open_file(&path)?;
        Ok(Some(path))
    }

    pub fn open_file(&mut self, path: &str) -> Result<(), CoreError> {
        if is_text(path) {
            self.open_document(path)?;
        }
        if self.docs.show(&mut self.core, &self.tree, path) {
            self.closed();
        }
        Ok(())
    }

    pub fn reopen(&mut self, file: Option<String>) {
        let file = file
            .filter(|file| self.tree.files.contains(file))
            .or_else(|| self.tree.main.clone());
        if let Some(file) = file
            && (!is_text(&file) || self.open_document(&file).is_ok())
        {
            self.docs.open = Some(file);
        }
    }

    pub fn open_document(&mut self, path: &str) -> Result<(), CoreError> {
        if self.docs.load(&mut self.core, path, &self.tree)? {
            self.builds.publish(&mut self.core, &self.docs);
            self.live.opened(&mut self.core, &self.docs, path);
        }
        Ok(())
    }

    pub fn close_doc(&mut self, path: &str, if_saved: bool) {
        if self.docs.close(&mut self.core, path, if_saved) {
            self.closed();
        }
    }

    /// Closes documents kept open only because they couldn't be saved when another was shown, once they're saved.
    pub fn close_hidden(&mut self) {
        let shown = self.docs.open.as_ref();
        let hidden: Vec<String> = self
            .docs
            .keys()
            .filter(|path| Some(*path) != shown)
            .cloned()
            .collect();
        let mut closed = false;
        for path in hidden {
            closed |= self.docs.close(&mut self.core, &path, true);
        }
        if closed {
            self.closed();
        }
    }

    pub fn closed(&mut self) {
        self.builds.publish(&mut self.core, &self.docs);
        self.live.publish(&mut self.core, &self.docs, false);
        self.docs.publish_open(&mut self.core, &self.tree);
    }

    pub fn edited(&mut self, id: u64, version: u64, edit: &TextEdit) {
        let Some(path) = self.docs.path_of(id) else {
            return;
        };
        let (cx, docs) = (&mut self.core, &self.docs);
        self.builds.edited(cx, docs, Some(&path));
        self.live.edited(cx, docs, &path, version, edit);
        if self.docs.edited(cx, &path, version, edit) {
            self.closed();
        }
    }

    pub fn resolve(&mut self, path: &str, answer: Resolution) -> Result<(), CoreError> {
        if self.docs.resolve(&mut self.core, path, answer)? {
            let paths = BTreeSet::from([path.to_owned()]);
            self.live.disk_changed(&mut self.core, &paths);
            self.closed();
        }
        Ok(())
    }
}

fn as_left(abs: &Path, stamp: Option<Stamp>, text: Option<&str>) -> bool {
    let now = Stamp::at(abs).ok();
    match (stamp, now) {
        (Some(stamp), Some(now)) if stamp == now => {
            stamp.trusted()
                || fs::read(abs)
                    .is_ok_and(|bytes| String::from_utf8(bytes).ok().map(lf).as_deref() == text)
        }
        (stamp, now) => stamp.is_none() && now.is_none(),
    }
}

fn read_disk(path: &Path) -> Result<(Option<DiskText>, Option<Stamp>), CoreError> {
    let stamp = Stamp::at(path).ok();
    let disk = String::from_utf8(fs::read(path)?).ok().map(|text| {
        let newline = newline(&text);
        (lf(text), newline)
    });
    Ok((disk, stamp))
}

type DiskText = (String, &'static str);

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tokio::sync::mpsc;

    use super::*;
    use crate::session::tests::panicking;
    use crate::session::{Msg, Session};

    #[tokio::test(flavor = "multi_thread")]
    async fn a_delayed_edit_after_a_rejected_reload_keeps_the_deletion_conflict() {
        let (sessions, _heard, _dir) = panicking().await;
        let (tx, mut rx) = mpsc::unbounded_channel();
        let request = Session::parse("OpenProject", json!({ "id": "P", "autoCompile": false }));
        let Session::OpenProject(opening) = request.unwrap() else {
            unreachable!();
        };
        let (mut actor, _) = Actor::new(&sessions, 1, opening, Docs::default(), tx).unwrap();
        actor.open_file("main.tex").unwrap();
        let doc = actor.docs["main.tex"].doc.clone();
        let original = doc.snapshot().0;
        let path = actor.core.project.root.join("main.tex");
        fs::write(&path, "external\n").unwrap();
        actor.docs.check_disk(&mut actor.core, "main.tex");
        assert!(actor.docs["main.tex"].reloading.is_some());

        doc.edit(0, 0, "mine ", None, false).unwrap();
        fs::remove_file(&path).unwrap();
        actor.docs.check_disk(&mut actor.core, "main.tex");
        assert_eq!(actor.docs["main.tex"].conflict, Some(DiskConflict::Gone));

        let Msg::Edited { doc, version, edit } = rx.try_recv().unwrap() else {
            panic!("the document sent its edit");
        };
        actor.edited(doc, version, &edit);
        assert_eq!(actor.docs["main.tex"].conflict, Some(DiskConflict::Gone));
        actor.resolve("main.tex", Resolution::Save).unwrap();
        assert_eq!(
            fs::read_to_string(path).unwrap(),
            format!("mine {original}")
        );
    }
}
