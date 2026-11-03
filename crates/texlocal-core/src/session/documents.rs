use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::ErrorKind;
use std::ops::Deref;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use texlocal_latex::diff::edit_to;
use texlocal_latex::is_text;
use texlocal_latex::message::Message;
use texlocal_latex::syntax::TextEdit;

use super::Document;
use super::actor::{Actor, Later, Timer};
use super::edits::DocumentEdits;
use super::state::DocumentState;
use crate::events::Event;
use crate::messages;
use crate::paths::{self, within};
use crate::projects;
use crate::stamp::Stamp;
use crate::{CoreError, lf, lock, newline};

pub(super) const MAX_EDITED: u64 = 64 << 20;

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
    pub fn dirty(&self) -> bool {
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

    pub fn get_mut(&mut self, path: &str) -> Option<&mut Doc> {
        self.docs.get_mut(path)
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = (&String, &mut Doc)> {
        self.docs.iter_mut()
    }

    pub fn insert(&mut self, path: String, doc: Doc) {
        lock(&self.shared).insert(path.clone(), doc.doc.clone());
        self.docs.insert(path, doc);
    }

    pub fn remove(&mut self, path: &str) -> Option<Doc> {
        lock(&self.shared).remove(path);
        self.docs.remove(path)
    }

    pub fn close(&mut self, path: &str) -> bool {
        self.remove(path).map(|doc| doc.doc.close()).is_some()
    }

    pub fn clear(&mut self) {
        lock(&self.shared).clear();
        for doc in std::mem::take(&mut self.docs).into_values() {
            doc.doc.close();
        }
    }
}

impl Actor {
    pub fn open(&mut self, path: &str) -> Result<Option<String>, CoreError> {
        if self.opens.fetch_sub(1, Ordering::Relaxed) > 1 {
            return Ok(None);
        }
        let path =
            paths::disk_spelling(&self.project.root, path).unwrap_or_else(|| path.to_owned());
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
        let was = self.open.replace(path.to_owned());
        if was.as_deref() != Some(path) {
            self.after(Timer::Symbols);
            self.publish_open();
            if let Some(was) = was
                && self.flush(Some(&was), true).unwrap_or(false)
            {
                self.close_doc(&was, true);
            }
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
            self.open = Some(file);
        }
    }

    pub fn open_document(&mut self, path: &str) -> Result<(), CoreError> {
        if self.docs.contains_key(path) {
            return Ok(());
        }
        let abs = paths::safe_path(&self.project.root, path)?;
        let size = fs::metadata(&abs).map_err(CoreError::at(&abs))?.len();
        if size > MAX_EDITED {
            return Err(CoreError::bad_request(messages::too_large_to_edit(
                size >> 20,
            )));
        }
        let (disk, stamp) = read_disk(&abs)?;
        let (text, newline) = disk.ok_or_else(|| CoreError::bad_request(messages::not_utf8()))?;
        let id = self.next_doc;
        self.next_doc += 1;
        let doc = Doc {
            doc: Document::new(id, path, &text, self.tx.clone(), Arc::clone(&self.scan)),
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
        self.docs.insert(path.to_owned(), doc);
        self.publish_documents();
        self.publish_build();
        self.live_issues_opened(path);
        self.live_whole(path);
        Ok(())
    }

    /// Closes a document, or with `if_saved` only one with nothing typed since it was saved.
    pub fn close_doc(&mut self, path: &str, if_saved: bool) -> bool {
        let saved = |doc: &Doc| !doc.force && doc.doc.close_if(doc.saved);
        if if_saved && !self.docs.get(path).is_some_and(saved) || !self.docs.close(path) {
            return false;
        }
        self.publish_documents();
        self.publish_build();
        self.publish_live(false);
        self.publish_open();
        true
    }

    pub fn edited(&mut self, id: u64, version: u64, edit: &TextEdit) {
        let Some((path, doc)) = self.docs.iter_mut().find(|(_, doc)| doc.doc.id() == id) else {
            return;
        };
        let path = path.clone();
        let reload = doc.reloading.take_if(|(base, _)| version > *base);
        let reloaded = reload.map(|(base, reload)| version == base + 1 && reload == *edit);
        if reloaded == Some(true) {
            doc.saved = version;
        }
        self.touched(&path, Some(edit));
        self.after(Timer::Autosave);
        self.live_edited(&path, version, edit);
        match reloaded {
            Some(true) => {
                self.after(Timer::Symbols);
                self.check_disk(&path);
            }
            // An edit made before the main thread saw the reload refused it.
            Some(false) => self.ask(&path, DiskConflict::Changed),
            None => {}
        }
    }

    pub fn selected(&mut self, id: u64, caret: usize) {
        if let Some(path) = self.docs.values().find(|doc| doc.doc.id() == id) {
            self.live_caret(path.path.clone(), caret);
        }
    }

    fn touched(&mut self, path: &str, edit: Option<&TextEdit>) {
        self.edits += 1;
        self.last_edits.insert(path.to_owned(), self.edits);
        self.mark_outdated(Some(path));
        self.live_issues_edited(path, edit);
    }

    pub fn autosave(&mut self) {
        let mut ok = true;
        for path in self.dirty_paths() {
            ok &= self.save_doc(&path, false, true).unwrap_or(false);
        }
        if ok && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
    }

    pub fn docs_within(&self, dir: &str) -> Vec<String> {
        let docs = self.docs.keys();
        docs.filter(|p| within(p, dir)).cloned().collect()
    }

    pub fn dirty_paths(&self) -> Vec<String> {
        let docs = self.docs.values().filter(|doc| doc.dirty());
        docs.map(|doc| doc.path.clone()).collect()
    }

    fn save_doc(&mut self, path: &str, reporting: bool, autosave: bool) -> Result<bool, CoreError> {
        for _ in 0..2 {
            let Some(doc) = self.docs.get_mut(path) else {
                return Ok(true);
            };
            if !doc.dirty() {
                return Ok(true);
            }
            if autosave && doc.doc.composing() {
                self.after(Timer::Autosave);
                return Ok(false);
            }
            if doc.asking || doc.reloading.is_some() {
                return Ok(false);
            }
            if let Some(kind) = doc.conflict {
                if reporting {
                    self.ask(path, kind);
                }
                return Ok(false);
            }
            let (text, version) = doc.doc.snapshot();
            let text = lf(text);
            let file = match doc.newline {
                "\n" => Cow::Borrowed(text.as_str()),
                ending => Cow::Owned(text.replace('\n', ending)),
            };
            let written = paths::safe_write_path(&self.project.root, path).and_then(|abs| {
                if !as_left(&abs, doc.disk_stamp, doc.disk_text.as_deref()) {
                    return Ok(None);
                }
                projects::write_creating(&abs, file.as_bytes()).map(Some)
            });
            let result = match written {
                Ok(None) => {
                    self.check_disk(path);
                    continue;
                }
                Ok(Some(stamp)) => {
                    (doc.disk_text, doc.disk_stamp) = (Some(text), Some(stamp));
                    (doc.saved, doc.force, doc.error) = (version, false, None);
                    self.after(Timer::Symbols);
                    self.snapshot_soon();
                    Ok(true)
                }
                Err(err) => {
                    doc.error = Some(err.message.clone());
                    Err(err)
                }
            };
            self.publish_documents();
            return result;
        }
        Ok(false)
    }

    pub fn flush_all(&mut self, reporting: bool) -> Result<bool, CoreError> {
        self.timers.remove(&Timer::Autosave);
        self.flush(None, reporting)
    }

    fn flush(&mut self, only: Option<&str>, reporting: bool) -> Result<bool, CoreError> {
        let mut failure = None;
        for _ in 0..3 {
            let mut dirty = self.dirty_paths();
            dirty.retain(|path| only.is_none_or(|only| only == path));
            if dirty.is_empty() {
                break;
            }
            let mut all = true;
            for path in dirty {
                match self.save_doc(&path, reporting, false) {
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

    pub fn save_first(&mut self) -> Result<(), CoreError> {
        if self.flush_all(true)? {
            Ok(())
        } else {
            Err(CoreError::conflict(messages::edits_unsaved()))
        }
    }

    pub fn save_edits(&mut self, reporting: bool) -> Result<bool, CoreError> {
        let edited = !self.dirty_paths().is_empty();
        let saved = self.flush_all(reporting)?;
        if saved && edited && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        Ok(saved)
    }

    fn ask(&mut self, path: &str, kind: DiskConflict) {
        if let Some(doc) = self.docs.get_mut(path) {
            (doc.conflict, doc.asking) = (Some(kind), true);
            self.publish_documents();
        }
    }

    pub fn resolve(&mut self, path: &str, answer: Resolution) -> Result<(), CoreError> {
        let doc = self
            .docs
            .get_mut(path)
            .ok_or_else(|| CoreError::not_found(messages::document_not_open()))?;
        let Some(kind) = doc.conflict else {
            return Ok(());
        };
        match (kind, answer) {
            (_, Resolution::Cancel) => doc.asking = false,
            (DiskConflict::Changed, Resolution::Save) => {
                (doc.asking, doc.conflict, doc.force) = (false, None, true);
            }
            // The edits are let go, so the document counts as saved while the main thread takes the disk's text.
            (DiskConflict::Changed, Resolution::Revert) => {
                let version = doc.doc.version();
                (doc.asking, doc.conflict, doc.force, doc.saved) = (false, None, false, version);
            }
            (DiskConflict::Gone, Resolution::Save) => (doc.asking, doc.conflict) = (false, None),
            (DiskConflict::Gone, Resolution::Close) => {
                self.close_doc(path, false);
                return Ok(());
            }
            _ => {
                return Err(CoreError::bad_request(messages::answer_unfit()));
            }
        }
        self.publish_documents();
        match answer {
            Resolution::Save => self.save_edits(true).map(drop),
            Resolution::Revert => {
                match self.docs[path].disk_text.clone() {
                    Some(text) => self.reload(path, &text),
                    None => drop(self.close_doc(path, false)),
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    /// Asks the main thread, the text's one writer, to take the disk's text, which an edit made first refuses.
    fn reload(&mut self, path: &str, text: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        let (shown, version) = doc.doc.snapshot();
        if version != doc.saved {
            return self.ask(path, DiskConflict::Changed);
        }
        let Some(edit) = edit_to(&shown, text) else {
            return;
        };
        let asked = TextEdit {
            text: edit.text.clone(),
            ..edit
        };
        doc.reloading = Some((version, edit));
        let path = path.to_owned();
        let edits = vec![asked];
        self.emit(Event::Reload(DocumentEdits {
            path,
            version,
            edits,
        }));
    }

    pub fn check_disk(&mut self, path: &str) {
        let abs = self.project.root.join(path);
        if fs::metadata(&abs).is_err_and(|err| err.kind() == ErrorKind::NotFound) {
            return self.file_gone(path);
        }
        // A reload in flight checks the disk again once the main thread has taken it.
        let Some(doc) = self
            .docs
            .get_mut(path)
            .filter(|doc| doc.reloading.is_none())
        else {
            return;
        };
        if doc.conflict == Some(DiskConflict::Gone) {
            doc.conflict = None;
        }
        if as_left(&abs, doc.disk_stamp, doc.disk_text.as_deref()) {
            return;
        }
        let (disk, stamp) = match read_disk(&abs) {
            Ok(read) => read,
            Err(err) => {
                if doc.dirty() {
                    doc.error = Some(err.message);
                    self.publish_documents();
                }
                return;
            }
        };
        doc.disk_stamp = stamp;
        if let Some((text, newline)) = &disk {
            doc.newline = *newline;
            if doc.disk_text.as_ref() == Some(text) {
                return;
            }
        }
        doc.disk_text = disk.map(|(text, _)| text);
        match (doc.disk_text.clone(), doc.dirty()) {
            (_, true) if doc.conflict.is_some() => {}
            (Some(text), false) if self.open.as_deref() == Some(path) => self.reload(path, &text),
            (_, false) if self.close_doc(path, true) => {}
            _ => self.ask(path, DiskConflict::Changed),
        }
    }

    fn file_gone(&mut self, path: &str) {
        if self.close_doc(path, true) {
            return;
        }
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        doc.disk_stamp = None;
        if doc.conflict != Some(DiskConflict::Gone) {
            self.ask(path, DiskConflict::Gone);
        }
    }
}

fn as_left(abs: &Path, stamp: Option<Stamp>, text: Option<&str>) -> bool {
    let now = Stamp::at(abs).ok();
    match (stamp, now) {
        (Some(stamp), Some(now)) if stamp == now => {
            stamp.modified % 1_000_000_000 != 0
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
