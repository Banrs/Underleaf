use std::borrow::Cow;
use std::collections::VecDeque;
use std::fs;
use std::io::ErrorKind;
use std::path::Path;
use std::sync::Arc;

use serde::Serialize;
use serde_json::{Value, json};
use texlocal_latex::syntax::TextEdit;

use super::Document;
use super::actor::{Actor, Later, Timer};
use crate::paths::{self, within};
use crate::projects;
use crate::stamp::Stamp;
use crate::{CoreError, lf, lock, newline};

const NOT_UTF8: &str =
    "It isn't UTF-8 text, and saving it here would change it. Convert it to UTF-8 to edit it.";
pub(super) const MAX_EDITED: u64 = 64 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Conflict {
    Changed,
    Gone,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reload {
    Disk,
    Revert,
}

pub(crate) struct Doc {
    pub doc: Document,
    pub path: String,
    saved: u64,
    force: bool,
    disk_text: Option<String>,
    newline: &'static str,
    disk_stamp: Option<Stamp>,
    pub conflict: Option<Conflict>,
    pub asking: Option<Conflict>,
    held: bool,
    error: Option<String>,
    pub reloads: VecDeque<Reload>,
    composing: bool,
    pub issues: Vec<Value>,
    pub live_issues: Vec<Value>,
    pub shown: Value,
}

impl Doc {
    pub fn dirty(&self) -> bool {
        self.force || self.doc.version() != self.saved
    }

    pub fn state(&self) -> Value {
        json!({ "path": self.path, "error": self.error, "held": self.held })
    }
}

impl Actor {
    pub fn composing(&mut self, path: &str, composing: bool) {
        if let Some(doc) = self.docs.get_mut(path) {
            doc.composing = composing;
            if !composing && doc.dirty() {
                self.after(Timer::Autosave);
            }
        }
    }

    pub fn open_document(&mut self, path: &str) -> Result<(), CoreError> {
        let path =
            &paths::disk_spelling(&self.project.root, path).unwrap_or_else(|| path.to_owned());
        if let Some(doc) = self.docs.get(path) {
            let id = doc.doc.id();
            if id != self.shown {
                self.shown = id;
                self.after(Timer::Symbols);
            }
            return Ok(());
        }
        let abs = paths::safe_path(&self.project.root, path)?;
        let size = fs::metadata(&abs).map_err(CoreError::at(&abs))?.len();
        if size > MAX_EDITED {
            return Err(CoreError::bad_request(format!(
                "It's {} MB, too large to edit here. Open it in another app.",
                size >> 20
            )));
        }
        let (disk, stamp) = read_disk(&abs)?;
        let (text, newline) = disk.ok_or_else(|| CoreError::bad_request(NOT_UTF8))?;
        let id = self.next_doc;
        self.next_doc += 1;
        self.shown = id;
        let symbols = Arc::clone(&self.symbols);
        let document = Document::new(id, path, &text, self.tx.clone(), symbols);
        let doc = Doc {
            doc: document.clone(),
            path: path.to_owned(),
            saved: 0,
            force: false,
            disk_text: Some(text),
            newline,
            disk_stamp: stamp,
            conflict: None,
            asking: None,
            held: false,
            error: None,
            reloads: VecDeque::new(),
            composing: false,
            issues: Vec::new(),
            live_issues: Vec::new(),
            shown: Value::Null,
        };
        self.docs.insert(path.to_owned(), doc);
        lock(&self.shared).insert(path.to_owned(), document);
        self.after(Timer::Symbols);
        self.publish_doc(path);
        self.mark_issues();
        self.live_issues_opened(path);
        self.live_whole(path);
        Ok(())
    }

    pub fn close_document(&mut self, path: &str) -> Result<Value, CoreError> {
        let closed = self.flush(Some(path), true)?;
        if closed {
            self.close_doc(path, "closed");
        }
        Ok(json!({ "closed": closed }))
    }

    pub fn close_doc(&mut self, path: &str, reason: &str) {
        if self.docs.remove(path).is_some() {
            lock(&self.shared).remove(path);
            self.emit("document_closed", json!({ "path": path, "reason": reason }));
        }
    }

    pub fn changed(&mut self, id: u64, version: u64, edit: Option<TextEdit>) {
        let Some(doc) = self.docs.values().find(|doc| doc.doc.id() == id) else {
            return;
        };
        let path = doc.path.clone();
        self.edits += 1;
        self.last_edits.insert(path.clone(), self.edits);
        self.clear_issues(&path);
        self.live_issues_edited(&path, edit.as_ref());
        self.mark_outdated();
        match edit {
            Some(edit) => {
                self.after(Timer::Autosave);
                self.live_edited(&path, version, &edit);
                let doc = self.docs.get_mut(&path).expect("found by its id");
                if !doc.reloads.is_empty() {
                    doc.reloads.clear();
                    doc.conflict = Some(Conflict::Changed);
                    self.ask(&path, Conflict::Changed);
                }
            }
            None => self.reloaded(&path, version),
        }
    }

    fn reloaded(&mut self, path: &str, version: u64) {
        self.after(Timer::Symbols);
        let doc = self.docs.get_mut(path).expect("found by its id");
        doc.saved = version;
        let reason = doc.reloads.pop_front();
        doc.force |= reason == Some(Reload::Revert);
        self.live_whole(path);
        match reason {
            Some(Reload::Revert) => {
                if self.save_doc(path, true, false).unwrap_or(false) && self.auto_compile {
                    self.later.push_back(Later::Compile(true));
                }
            }
            Some(Reload::Disk) if self.auto_compile => self.later.push_back(Later::Compile(true)),
            _ => {}
        }
    }

    pub fn publish_doc(&mut self, path: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        let state = doc.state();
        if state != doc.shown {
            doc.shown = state.clone();
            self.emit("document", state);
        }
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
            let deleting = self.deleting(path);
            let Some(doc) = self.docs.get_mut(path) else {
                return Ok(true);
            };
            if !doc.dirty() {
                return Ok(true);
            }
            if !doc.reloads.is_empty()
                || deleting
                || doc.asking.is_some()
                || autosave && doc.composing
            {
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
            let written = self.service.with_project(&self.project_id, |project| {
                let abs = paths::safe_write_path(&project.root, path)?;
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
                    (doc.saved, doc.force, doc.held, doc.error) = (version, false, false, None);
                    self.after(Timer::Symbols);
                    self.snapshot_soon();
                    Ok(true)
                }
                Err(err) => {
                    doc.error = Some(err.message.clone());
                    Err(err)
                }
            };
            self.publish_doc(path);
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

    pub fn save_edits(&mut self, reporting: bool) -> Result<bool, CoreError> {
        let edited = !self.dirty_paths().is_empty();
        let saved = self.flush_all(reporting)?;
        if saved && edited && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        Ok(saved)
    }

    fn ask(&mut self, path: &str, kind: Conflict) {
        if let Some(doc) = self.docs.get_mut(path) {
            doc.asking = Some(kind);
            self.emit("conflict", json!({ "path": path, "kind": kind }));
            self.publish_doc(path);
        }
    }

    pub fn resolve(&mut self, path: &str, answer: &str) -> Result<Value, CoreError> {
        let doc = self
            .docs
            .get_mut(path)
            .ok_or_else(|| CoreError::not_found("The document isn't open"))?;
        let Some(kind) = doc.asking.or(doc.conflict) else {
            return Ok(Value::Null);
        };
        match (kind, answer) {
            (_, "cancel") => (doc.asking, doc.held) = (None, true),
            (Conflict::Changed, "save") => {
                (doc.asking, doc.conflict, doc.force) = (None, None, true);
            }
            (Conflict::Changed, "revert") | (Conflict::Gone, "save") => {
                (doc.asking, doc.conflict) = (None, None);
            }
            (Conflict::Gone, "close") => {
                self.close_doc(path, "closed");
                return Ok(Value::Null);
            }
            _ => {
                return Err(CoreError::bad_request(format!(
                    "Can't answer “{answer}” here"
                )));
            }
        }
        self.publish_doc(path);
        match answer {
            "save" => Ok(json!({ "saved": self.save_edits(true)? })),
            "revert" => {
                match self.docs[path].disk_text.clone() {
                    Some(text) => self.request_reload(path, &text, Reload::Revert),
                    None => self.close_doc(path, "gone"),
                }
                Ok(Value::Null)
            }
            _ => Ok(Value::Null),
        }
    }

    fn request_reload(&mut self, path: &str, text: &str, reason: Reload) {
        if let Some(doc) = self.docs.get_mut(path) {
            let seen = match reason {
                Reload::Disk => doc.saved,
                Reload::Revert => doc.doc.version(),
            };
            doc.doc.expect_reload(seen);
            doc.reloads.push_back(reason);
            self.emit("document_reload", json!({ "path": path, "text": text }));
        }
    }

    pub fn check_disk(&mut self, path: &str) {
        let abs = self.project.root.join(path);
        if fs::metadata(&abs).is_err_and(|err| err.kind() == ErrorKind::NotFound) {
            return self.file_gone(path);
        }
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        if doc.conflict == Some(Conflict::Gone) {
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
                    self.publish_doc(path);
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
            (_, true) => {
                if doc.conflict.replace(Conflict::Changed).is_none() {
                    self.ask(path, Conflict::Changed);
                }
            }
            (Some(text), false) => self.request_reload(path, &text, Reload::Disk),
            (None, false) => self.close_doc(path, "gone"),
        }
    }

    fn file_gone(&mut self, path: &str) {
        let Some(doc) = self.docs.get_mut(path) else {
            return;
        };
        if !doc.dirty() {
            return self.close_doc(path, "gone");
        }
        doc.disk_stamp = None;
        if doc.conflict.replace(Conflict::Gone) != Some(Conflict::Gone) {
            self.ask(path, Conflict::Gone);
        }
    }
}

fn as_left(abs: &Path, stamp: Option<Stamp>, text: Option<&str>) -> bool {
    let now = fs::metadata(abs).ok().map(|meta| Stamp::of(&meta));
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
    let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
    let disk = String::from_utf8(fs::read(path)?).ok().map(|text| {
        let newline = newline(&text);
        (lf(text), newline)
    });
    Ok((disk, stamp))
}

type DiskText = (String, &'static str);
