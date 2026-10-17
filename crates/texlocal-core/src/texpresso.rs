//! Optional persistent TeXpresso viewer. Author buffers stay in its VFS; the
//! ordinary latexmk build and PDF continue to use saved project files.
//!
//! A build with Underleaf's patch (tools/texpresso) shows nothing itself: it writes the
//! pages the client says it is showing as one-page PDFs the moment they are typeset again,
//! and the whole document when a run has ended. `Manager::wait` hands those to the client
//! as they come; `Manager::edit` takes a keystroke without waiting for anything. A client
//! that gives no pane gets TeXpresso's own window instead, which draws with MuPDF.
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ropey::Rope;
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt};
use tokio::process::ChildStdin;
use tokio::sync::{Notify, mpsc};

use crate::atomic::Stamp;
use crate::compile::{Tree, find_tool, program_at};
use crate::{BUILD_DIR, CoreError, SETTINGS_FILE, lock, paths, settings, tail};

const MAX_FILE: usize = 8 * 1024 * 1024;
const MAX_FILES: usize = 256;
const MAX_TOTAL: usize = 64 * 1024 * 1024;
/// The end kept of each stream TeXpresso writes (TeX's output and log, its stderr), and
/// of the log a status gives.
const STREAM_TAIL: usize = 128 * 1024;
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
/// How long TeXpresso may leave what it was sent unread before the session is given up:
/// it reads nothing while it makes its TeX formats, five seconds and more the first time.
const UNREAD: Duration = Duration::from_secs(60);
const MISSING: &str = if cfg!(windows) {
    "TeXpresso wasn't found. Choose the folder it's in, in Settings."
} else {
    "TeXpresso wasn't found. Choose the folder it's in, in Settings, or install it in /opt/homebrew/bin or /usr/local/bin."
};
/// For a session whose preview another session's Start took over, or its own Stop ended.
const REPLACED: &str =
    "Another window started TeXpresso for this project. Start TeXpresso again to preview here.";
const TOO_MANY: &str = "Too many files for TeXpresso (limit 256 files / 64 MB).";
const TOO_LARGE: &str = "TeXpresso takes files of up to 8 MB.";
const UNFIT: &str = "The edit doesn't fit the text TeXpresso has. Send the whole text.";
const INVALID: &str = "A file sent to TeXpresso has an invalid path or text.";

/// Rises with every change of every session's status, so a restarted preview's is past the last.
static REVISION: AtomicU64 = AtomicU64::new(0);

fn next_revision() -> u64 {
    REVISION.fetch_add(1, Ordering::Relaxed) + 1
}

#[derive(Debug)]
pub struct FileBuffer {
    pub path: String,
    pub text: String,
}

/// A place in a file, in UTF-16 units as the editors count.
#[derive(Debug)]
pub struct Caret {
    pub path: String,
    pub offset: usize,
}

/// A client that shows the document itself, in its own pane: the pages it shows there,
/// from 0, and where its caret is, for a build with Underleaf's patch to have those pages
/// first and a snapshot ready where the first key will land.
#[derive(Debug, Default)]
pub struct Pane {
    pub view: Option<(u32, u32)>,
    pub caret: Option<Caret>,
}

#[derive(Debug, Default)]
pub struct Status {
    pub running: bool,
    pub log: String,
    pub output: String,
    pub error: Option<String>,
    pub revision: u64,
}

/// A page typeset again, alone in a PDF that is complete on disk.
#[derive(Debug, Clone)]
pub struct PageUpdate {
    /// From 0.
    pub page: u32,
    pub path: String,
    /// Rises with every event of the session: a later page or document has a higher one.
    pub serial: u64,
}

/// The whole document, complete on disk, its SyncTeX beside it.
#[derive(Debug, Clone)]
pub struct Document {
    pub path: String,
    /// Rises by one with each document the session writes.
    pub version: u64,
    pub serial: u64,
    pub pages: u32,
    /// How the run that wrote it ended: `complete` at the document's end, `stopped` on an
    /// error before it, `partial` while it is still being typeset. None from a build
    /// that doesn't say.
    pub run: Option<String>,
    /// Ranges of pages, first and last, that differ from the document before; None from a
    /// build that doesn't say, when any may.
    pub changed: Option<Vec<[u32; 2]>>,
}

/// What is new for a client since the `seq` it last had (`Manager::wait`).
#[derive(Debug, Clone, Default)]
pub struct Events {
    pub seq: u64,
    pub running: bool,
    pub error: Option<String>,
    /// `Status::revision`: when it has risen, the log or output may have changed.
    pub revision: u64,
    /// The document, when a new one was written; it comes before `pages`.
    pub pdf: Option<Document>,
    /// The latest of each page written since `pdf`, lowest page first.
    pub pages: Vec<PageUpdate>,
    /// How a run of TeX that is over ended: `complete` or `stopped`, as `Document::run`.
    pub done: Option<String>,
}

/// A bounded tail of a stream TeXpresso writes at absolute byte offsets, which it
/// rewrites from an earlier one as TeX backtracks.
#[derive(Default)]
struct Output {
    base: u64,
    bytes: Vec<u8>,
}

impl Output {
    fn end(&self) -> u64 {
        self.base + self.bytes.len() as u64
    }
    fn truncate(&mut self, end: u64) {
        match end.checked_sub(self.base) {
            Some(kept) => self.bytes.truncate(kept.try_into().unwrap_or(usize::MAX)),
            None => {
                self.base = end;
                self.bytes.clear();
            }
        }
    }
    fn append(&mut self, offset: u64, text: &[u8]) {
        self.truncate(offset);
        if offset > self.end() {
            self.base = offset;
            self.bytes.clear();
        }
        self.bytes.extend_from_slice(text);
        let excess = self.bytes.len().saturating_sub(STREAM_TAIL);
        self.bytes.drain(..excess);
        self.base += excess as u64;
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}

/// A file's text as TeXpresso has it: an edit the editor gives in UTF-16 units finds
/// its bytes in the rope's index, however long the file.
struct Text(Rope);

impl Text {
    fn bytes(&self) -> usize {
        self.0.len_bytes()
    }
    /// The character `units` UTF-16 units in; None inside a character or past the end.
    fn char_at(&self, units: usize) -> Option<usize> {
        let at = self.0.try_utf16_cu_to_char(units).ok()?;
        (self.0.char_to_utf16_cu(at) == units).then_some(at)
    }
    /// The byte offset of a place given in UTF-16 units.
    fn byte_offset(&self, units: usize) -> Option<usize> {
        Some(self.0.char_to_byte(self.char_at(units)?))
    }
    /// Replaces the characters `from..to`: the same in bytes, as TeXpresso takes it.
    fn replace(&mut self, from: usize, to: usize, inserted: &str) -> (usize, usize) {
        let (offset, end) = (self.0.char_to_byte(from), self.0.char_to_byte(to));
        self.0.remove(from..to);
        self.0.insert(from, inserted);
        (offset, end - offset)
    }
    /// Replaces `remove` UTF-16 units at `start` with `inserted`, or nothing (None) when
    /// the range isn't the text's.
    fn edit(&mut self, start: usize, remove: usize, inserted: &str) -> Option<(usize, usize)> {
        let from = self.char_at(start)?;
        let to = self.char_at(start.checked_add(remove)?)?;
        Some(self.replace(from, to, inserted))
    }
    /// Becomes `new` by replacing what lies between the start and the end the two share:
    /// that change in bytes, as TeXpresso takes it. A chunk of the rope that is the same in
    /// both compares as one memcmp, with no copy of either text.
    fn update<'a>(&mut self, new: &'a str) -> (usize, usize, &'a str) {
        let (old, bytes) = (self.bytes(), new.as_bytes());
        let mut start = 0;
        for chunk in self.0.chunks().map(str::as_bytes) {
            let rest = &bytes[start..];
            if !rest.starts_with(chunk) {
                start += common(chunk.iter(), rest.iter());
                break;
            }
            start += chunk.len();
        }
        // The bytes before `start` and after the shared end are the same in both texts,
        // so a character boundary in one is one in the other.
        while !new.is_char_boundary(start) {
            start -= 1;
        }
        let room = old.min(new.len()) - start;
        let mut suffix = 0;
        for chunk in self.0.chunks_at_byte(old).0.reversed().map(str::as_bytes) {
            let rest = &bytes[..new.len() - suffix];
            if suffix + chunk.len() > room || !rest.ends_with(chunk) {
                suffix += common(chunk.iter().rev(), rest.iter().rev()).min(room - suffix);
                break;
            }
            suffix += chunk.len();
        }
        while !new.is_char_boundary(new.len() - suffix) {
            suffix -= 1;
        }
        let inserted = &new[start..new.len() - suffix];
        let (from, to) = (
            self.0.byte_to_char(start),
            self.0.byte_to_char(old - suffix),
        );
        let (offset, removed) = self.replace(from, to, inserted);
        (offset, removed, inserted)
    }
}

impl From<&str> for Text {
    fn from(text: &str) -> Self {
        Self(Rope::from_str(text))
    }
}

/// How many items two runs share at their start.
fn common<T: PartialEq>(a: impl Iterator<Item = T>, b: impl Iterator<Item = T>) -> usize {
    a.zip(b).take_while(|(a, b)| a == b).count()
}

/// A session's state, under one lock that is never held across a wait: a keystroke takes it
/// on the editor's own thread.
#[derive(Default)]
struct Inner {
    tree: Option<Tree>,
    /// Lines for TeXpresso's stdin, written in order by the session's writer, until it stops.
    lines: Option<mpsc::UnboundedSender<Vec<u8>>>,
    texts: HashMap<PathBuf, Text>,
    /// Where the paths clients send lead, found once: a session's files
    /// don't move under it, as a rename or delete stops it.
    paths: HashMap<String, PathBuf>,
    bytes: usize,
    error: Option<String>,
    revision: u64,
    output: Output,
    log: Output,
    stderr: Output,
    /// Whether TeXpresso has sent TeX's log or output.
    protocol_seen: bool,
    /// Whether TeXpresso has said anything.
    spoken: bool,
    /// The page protocol it said it speaks: 1 from a build that sends pages as they change,
    /// None from one that only writes the whole document.
    live: Option<u32>,
    /// The settings file as last seen, by `settings_stamp`.
    settings: Option<Stamp>,
    /// The number of the latest event. The events a client may not have had yet follow,
    /// each with the number it came at.
    seq: u64,
    pdf_version: u64,
    document: Option<Document>,
    pages: BTreeMap<u32, PageUpdate>,
    done: Option<(u64, String)>,
}

/// `message` as a line of JSON for TeXpresso.
fn line(lines: &mut Vec<u8>, message: impl Serialize) {
    serde_json::to_writer(&mut *lines, &message).expect("messages serialize");
    lines.push(b'\n');
}

impl Inner {
    /// A message for TeXpresso, after those before it: nothing here waits for it.
    fn send(&self, message: impl Serialize) {
        if let Some(sender) = &self.lines {
            let mut lines = Vec::new();
            line(&mut lines, message);
            // A writer that has gone has stopped the session, or is about to.
            let _ = sender.send(lines);
        }
    }
    fn bump(&mut self) {
        self.revision = next_revision();
    }
    fn events(&self, after: u64) -> Events {
        let pages = self.pages.values().filter(|page| page.serial > after);
        let done = self.done.as_ref().filter(|(serial, _)| *serial > after);
        Events {
            seq: self.seq,
            running: self.tree.is_some(),
            error: self.error.clone(),
            revision: self.revision,
            pdf: self.document.clone().filter(|d| d.serial > after),
            pages: pages.cloned().collect(),
            done: done.map(|(_, end)| end.clone()),
        }
    }
}

struct Session {
    /// The project's folder, resolved.
    root: PathBuf,
    main: String,
    /// Where a patched build writes the document, in a folder of the session's own, when
    /// the client shows it.
    pdf: Option<PathBuf>,
    inner: Mutex<Inner>,
    changed: Notify,
}

impl Session {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        lock(&self.inner)
    }
    /// Something a waiting client is told at once. Its number.
    fn event(&self, inner: &mut Inner) -> u64 {
        inner.bump();
        inner.seq += 1;
        self.changed.notify_waiters();
        inner.seq
    }
    /// For its owner: whether it still runs, stopped first if the main file has
    /// changed since the start.
    fn still_running(&self) -> bool {
        let stamp = settings_stamp(&self.root);
        let seen = std::mem::replace(&mut self.lock().settings, stamp);
        if seen != stamp && settings::read_settings(&self.root).main_file != self.main {
            self.stop(Some("The main file changed. Start TeXpresso again.".into()));
        }
        self.lock().tree.is_some()
    }
    fn stop(&self, error: Option<String>) {
        let mut inner = self.lock();
        if let Some(tree) = inner.tree.take() {
            // The viewer starts an engine: stopping just its parent leaks it.
            tree.kill();
            remove_pdf_folder(self.pdf.as_deref());
            inner.error = error;
            inner.lines = None;
            inner.texts.clear();
            inner.bytes = 0;
            self.event(&mut inner);
        }
    }
    fn status(&self) -> Status {
        let inner = self.lock();
        let mut log = inner.log.text();
        // stderr includes historical TeX diagnostics and echoed VFS commands.
        // The protocol buffers alone track the engine's current backtracking.
        if !inner.protocol_seen || inner.error.is_some() {
            log.push_str(tail(&inner.stderr.text(), 16 * 1024));
        }
        log.drain(..log.len() - tail(&log, STREAM_TAIL).len());
        Status {
            running: inner.tree.is_some(),
            output: inner.output.text(),
            log,
            error: inner.error.clone(),
            revision: inner.revision,
        }
    }
    /// Whether to send what only a build that sends pages knows: it has said it is one,
    /// or nothing at all yet. Another would only report a command it doesn't know.
    fn sends_pages(&self, inner: &Inner) -> bool {
        self.pdf.is_some() && (inner.live.is_some() || !inner.spoken)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop(None);
        remove_pdf_folder(self.pdf.as_deref());
    }
}

fn remove_pdf_folder(pdf: Option<&Path>) {
    if let Some(folder) = pdf.and_then(Path::parent) {
        let _ = fs::remove_dir_all(folder);
    }
}

#[derive(Default)]
pub struct Manager {
    /// Each preview by the project session that owns it, by the number its host gave the
    /// session: a session has one preview, and a project one, which a session's Start takes
    /// over.
    sessions: Mutex<HashMap<u64, Arc<Session>>>,
    shutdown: AtomicBool,
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.kill_all();
    }
}

impl Manager {
    pub fn kill_all(&self) {
        self.shutdown.store(true, Ordering::Release);
        for session in lock(&self.sessions).values() {
            session.stop(None);
        }
    }
    /// The owner's preview; refused once another session's Start has taken the project
    /// over, or the owner's own Stop has ended it, so late calls change nothing.
    fn owned(&self, owner: u64) -> Result<Arc<Session>, CoreError> {
        let session = lock(&self.sessions).get(&owner).cloned();
        session.ok_or_else(|| CoreError::conflict(REPLACED))
    }
    /// Stops the previews of the project at the resolved `root`, and with `owner`, that
    /// owner's.
    fn stop_previews(&self, root: &Path, owner: Option<u64>) {
        let sessions = lock(&self.sessions);
        let of = |(&key, session): (&u64, &Arc<Session>)| {
            (session.root == root || Some(key) == owner).then(|| Arc::clone(session))
        };
        let previews: Vec<_> = sessions.iter().filter_map(of).collect();
        drop(sessions);
        for session in previews {
            session.stop(None);
        }
    }
    /// The owner's Stop. It ends the ownership too; a rename or a new main file stops the
    /// preview with `stop`, which keeps it, so the owner's restart can take it back.
    pub fn stop_request(&self, owner: u64) -> Result<Status, CoreError> {
        let session = lock(&self.sessions).remove(&owner);
        let session = session.ok_or_else(|| CoreError::conflict(REPLACED))?;
        session.stop(None);
        Ok(session.status())
    }
    /// The live document the owner's preview last wrote, which has its SyncTeX beside it.
    pub fn live_pdf(&self, owner: u64) -> Result<PathBuf, CoreError> {
        let session = self.owned(owner)?;
        let written = session.lock().pdf_version > 0;
        let pdf = session.pdf.as_ref();
        let pdf = pdf.filter(|pdf| written && pdf.with_extension("synctex").is_file());
        pdf.cloned().ok_or_else(|| {
            CoreError::not_found("TeXpresso hasn't written a document to sync with yet")
        })
    }
    /// Stops the project's preview and keeps its owner, as a project about to move or go,
    /// a rename and a new main file do.
    pub fn stop(&self, root: &Path) -> Result<(), CoreError> {
        self.stop_previews(&dunce::canonicalize(root)?, None);
        Ok(())
    }
    /// The owner's preview as it is now, its log and output with it.
    pub fn status(&self, owner: u64) -> Result<Status, CoreError> {
        let session = self.owned(owner)?;
        session.still_running();
        Ok(session.status())
    }
    /// A preview of the project at `root` for the session `owner`, which takes the project
    /// over from any other session's. `replacing`: the owner's own restart, which takes back
    /// only a preview still its own. With a `pane`, a build with Underleaf's patch writes
    /// the document for it instead of opening a window; upstream opens its window all the
    /// same.
    pub fn start(
        &self,
        owner: u64,
        root: &Path,
        files: &[FileBuffer],
        replacing: bool,
        path_env: &str,
        pane: Option<&Pane>,
    ) -> Result<Status, CoreError> {
        let root = dunce::canonicalize(root)?;
        if replacing {
            self.owned(owner)?;
        }
        let settings = settings_stamp(&root);
        let main = settings::read_settings(&root).main_file;
        let mut inner = Inner::default();
        let main_path = validate_buffer(&root, &main, "", &inner.paths)?;
        if !main_path.is_file() {
            return Err(CoreError::bad_request("The main file does not exist."));
        }
        let mut lines = Vec::new();
        for file in files {
            let path = validate_buffer(&root, &file.path, &file.text, &inner.paths)?;
            line(&mut lines, ("open", &path, &file.text));
            inner.paths.insert(file.path.clone(), path.clone());
            inner.bytes += file.text.len();
            if inner.texts.insert(path, Text::from(&*file.text)).is_some() {
                return Err(CoreError::bad_request(
                    "Files sent to TeXpresso repeat a path.",
                ));
            }
        }
        check_limits(inner.texts.len(), inner.bytes)?;
        // TeXpresso's idle reruns stay off: each starts TeX again from nothing after a pause
        // in typing and shows no page until it is over. A build that sends pages makes its
        // finishing passes beside the document.
        if let Some((first, last)) = pane.and_then(|pane| pane.view) {
            line(&mut lines, ("view", first, last.max(first)));
        }
        // Where the caret is in bytes, as TeXpresso counts, from the text just sent.
        if let Some(caret) = pane.and_then(|pane| pane.caret.as_ref())
            && let Some(path) = inner.paths.get(&caret.path)
            && let Some(text) = inner.texts.get(path)
            && let Some(offset) = text.byte_offset(caret.offset)
        {
            line(&mut lines, ("caret", path, offset));
        }
        let failed = |error: String| {
            let (error, revision) = (Some(error), REVISION.load(Ordering::Relaxed));
            Ok(Status {
                error,
                revision,
                ..Status::default()
            })
        };
        let Some(executable) = discover(path_env) else {
            return failed(MISSING.into());
        };
        let build = paths::safe_path(&root, BUILD_DIR)?;
        fs::create_dir_all(&build)?;
        let build = dunce::canonicalize(build)?;
        self.stop_previews(&root, Some(owner));
        // The session's own folder, for its owner alone: no build output or
        // other session shares it. The session removes it as it stops.
        let pdf = match pane {
            Some(_) => {
                let mut folder = tempfile::Builder::new();
                folder.prefix("texlocal-texpresso-");
                // tempfile makes folders 0o777 less the umask.
                #[cfg(unix)]
                folder.permissions(std::os::unix::fs::PermissionsExt::from_mode(0o700));
                Some(dunce::canonicalize(folder.tempdir()?.keep())?.join("live.pdf"))
            }
            None => None,
        };
        let mut command = tokio::process::Command::new(&executable);
        command
            .args(["-json", "-texlive", "-I"])
            .arg(&build)
            .arg(&main_path)
            .current_dir(&root)
            .env("PATH", path_env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(pdf) = &pdf {
            command.env("TEXPRESSO_PDF_OUTPUT", pdf);
        }
        // A Mac app runs with signals ignored or blocked that a child inherits across exec.
        // TeXpresso stops a stale TeX worker with SIGTERM, and ignored it never ends: the
        // snapshot waiting on it never resumes, and live preview stops at the first edit.
        // SAFETY: only async-signal-safe calls, between fork and exec.
        #[cfg(unix)]
        unsafe {
            command.pre_exec(|| {
                for signal in 1..32 {
                    libc::signal(signal, libc::SIG_DFL);
                }
                let mut none: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&raw mut none);
                libc::sigprocmask(libc::SIG_SETMASK, &raw const none, std::ptr::null_mut());
                Ok(())
            });
        }
        let (mut child, tree) = match Tree::spawn(&mut command) {
            Ok(spawned) => spawned,
            Err(err) => {
                remove_pdf_folder(pdf.as_deref());
                return failed(format!(
                    "Couldn't start TeXpresso: {err}. Check TEXLOCAL_TEXPRESSO and its dependencies."
                ));
            }
        };
        let (sender, queued) = mpsc::unbounded_channel();
        let _ = sender.send(lines);
        inner.tree = Some(tree);
        inner.lines = Some(sender);
        inner.revision = next_revision();
        inner.settings = settings;
        let session = Arc::new(Session {
            root: root.clone(),
            main,
            pdf,
            inner: Mutex::new(inner),
            changed: Notify::new(),
        });
        {
            let mut sessions = lock(&self.sessions);
            if self.shutdown.load(Ordering::Acquire) {
                session.stop(None);
            }
            // Another session's preview of the project is over: its late calls are refused.
            sessions.retain(|_, other| other.root != root);
            sessions.insert(owner, Arc::clone(&session));
        }
        let stdin = child.stdin.take().expect("stdin piped");
        let stdout = child.stdout.take().expect("stdout piped");
        let stderr = child.stderr.take().expect("stderr piped");
        let ended = Ended(Arc::clone(&session));
        tokio::spawn(async move {
            let session = &ended.0;
            let exited = async {
                let error = match child.wait().await {
                    Ok(status) if status.success() => None,
                    result => Some(format!(
                        "TeXpresso exited ({}). Check its log and start TeXpresso again.",
                        result.map_or_else(|e| e.to_string(), |s| s.to_string())
                    )),
                };
                session.stop(error);
            };
            tokio::join!(
                exited,
                write_lines(stdin, queued, session),
                read_output(stdout, session, true),
                read_output(stderr, session, false),
            );
        });
        Ok(session.status())
    }
    /// The whole text of a file: sent as the change from the buffer TeXpresso has, or
    /// whole when it has none. It is also what repairs a copy `edit` refused to change.
    pub fn update(&self, owner: u64, rel: &str, text: &str) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        if !session.still_running() {
            return Ok(());
        }
        let mut inner = session.lock();
        let inner = &mut *inner;
        let path = validate_buffer(&session.root, rel, text, &inner.paths)?;
        let held = inner.texts.get(&path).map(Text::bytes);
        let count = inner.texts.len() + usize::from(held.is_none());
        let bytes = inner.bytes - held.unwrap_or(0) + text.len();
        check_limits(count, bytes)?;
        inner.bytes = bytes;
        match inner.texts.get_mut(&path) {
            Some(held) => match held.update(text) {
                (_, 0, "") => return Ok(()),
                (offset, removed, new) => inner.send(("change", &path, offset, removed, new)),
            },
            None => {
                inner.send(("open", &path, text));
                inner.texts.insert(path.clone(), Text::from(text));
            }
        }
        inner.paths.insert(rel.to_owned(), path);
        inner.bump();
        Ok(())
    }
    /// A keystroke, as the editor has it: `remove` UTF-16 units at `start` of a file the
    /// session has, replaced by `text`. It waits for nothing (no disk, no TeXpresso), so
    /// the editor can call it where the edit is made. A session that has ended takes it as
    /// nothing. An edit that doesn't fit the session's copy is refused with status 412 and
    /// changes nothing: `update` with the whole text then puts both right.
    pub fn edit(
        &self,
        owner: u64,
        rel: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        if text.contains('\0') {
            return Err(CoreError::bad_request(INVALID));
        }
        let mut inner = session.lock();
        let inner = &mut *inner;
        if inner.tree.is_none() {
            return Ok(());
        }
        let unfit = || CoreError::unfit(UNFIT);
        let path = inner.paths.get(rel).ok_or_else(unfit)?;
        let held = inner.texts.get_mut(path).ok_or_else(unfit)?;
        if held.bytes() + text.len() > MAX_FILE {
            return Err(CoreError::bad_request(TOO_LARGE));
        }
        if inner.bytes + text.len() > MAX_TOTAL {
            return Err(CoreError::bad_request(TOO_MANY));
        }
        let (offset, removed) = held.edit(start, remove, text).ok_or_else(unfit)?;
        inner.bytes = inner.bytes + text.len() - removed;
        inner.send(("change", path, offset, removed, text));
        Ok(())
    }
    /// The pages the client shows, from 0: a patched build typesets as far as the last of
    /// them first, and sends each as it changes.
    pub fn view(&self, owner: u64, first: u32, last: u32) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        let inner = session.lock();
        if session.sends_pages(&inner) {
            inner.send(("view", first, last.max(first)));
        }
        Ok(())
    }
    /// Where the client's caret has settled: a patched build takes a snapshot there, so
    /// the first key typed there is answered as quickly as the ones after it. Refused as
    /// `edit` is for a file or place the session's copy doesn't have.
    pub fn caret(&self, owner: u64, rel: &str, offset: usize) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        let inner = session.lock();
        let unfit = || CoreError::unfit(UNFIT);
        let path = inner.paths.get(rel).ok_or_else(unfit)?;
        let text = inner.texts.get(path).ok_or_else(unfit)?;
        let offset = text.byte_offset(offset).ok_or_else(unfit)?;
        if session.sends_pages(&inner) {
            inner.send(("caret", path, offset));
        }
        Ok(())
    }
    /// Waits until the session has something a client at `after` hasn't had (`Events`) or
    /// it ends, and answers with what is new; other calls go on meanwhile. `after` is the
    /// `seq` of the last answer, 0 at first.
    pub async fn wait(&self, owner: u64, after: u64) -> Result<Events, CoreError> {
        let session = self.owned(owner)?;
        session.still_running();
        loop {
            let changed = session.changed.notified();
            tokio::pin!(changed);
            // Listening before the look: an event in between isn't missed.
            changed.as_mut().enable();
            {
                let inner = session.lock();
                // A `seq` from another session is no place in this one's events.
                let after = if after > inner.seq { 0 } else { after };
                if inner.seq > after || inner.tree.is_none() {
                    return Ok(inner.events(after));
                }
            }
            changed.await;
        }
    }
    pub fn rescan(&self, owner: u64) -> Result<Status, CoreError> {
        let session = self.owned(owner)?;
        if session.still_running() {
            session.lock().send(["rescan"]);
        }
        Ok(session.status())
    }
}

/// The task that waits on TeXpresso holds its session: dropped with its runtime, it stops
/// the session, which would otherwise leave the engines it started running.
struct Ended(Arc<Session>);

impl Drop for Ended {
    fn drop(&mut self) {
        self.0.stop(None);
    }
}

/// TEXLOCAL_TEXPRESSO, for development, else `texpresso` on the path.
pub(crate) fn discover(path_env: &str) -> Option<PathBuf> {
    if let Some(chosen) = std::env::var_os("TEXLOCAL_TEXPRESSO").filter(|p| !p.is_empty()) {
        return program_at(Path::new(&chosen));
    }
    find_tool("texpresso", path_env).and_then(|p| dunce::canonicalize(p).ok())
}

/// A buffer's path as TeXpresso opens it: through any link, from the
/// resolved `root`; found once per session, as `known` keeps it.
fn validate_buffer(
    root: &Path,
    path: &str,
    text: &str,
    known: &HashMap<String, PathBuf>,
) -> Result<PathBuf, CoreError> {
    if text.len() > MAX_FILE {
        return Err(CoreError::bad_request(TOO_LARGE));
    }
    if path.len() > 4096 || path.contains('\0') || text.contains('\0') {
        return Err(CoreError::bad_request(INVALID));
    }
    if let Some(known) = known.get(path) {
        return Ok(known.clone());
    }
    let path = root.join(paths::write_paths(root, path)?.1);
    if path.is_dir() {
        return Err(CoreError::bad_request(
            "TeXpresso opens files, not folders.",
        ));
    }
    Ok(path)
}

/// The settings file's stamp, or None while it is missing: every write the
/// app makes replaces it, so a changed main file shows here for one stat,
/// where reading and parsing it would take more.
fn settings_stamp(root: &Path) -> Option<Stamp> {
    let meta = fs::metadata(root.join(SETTINGS_FILE));
    meta.ok().map(|meta| Stamp::of(&meta))
}

fn check_limits(files: usize, bytes: usize) -> Result<(), CoreError> {
    if files > MAX_FILES || bytes > MAX_TOTAL {
        return Err(CoreError::bad_request(TOO_MANY));
    }
    Ok(())
}

/// The session's one writer to TeXpresso's stdin: callers queue lines and go on, and a
/// TeXpresso that has stopped reading stops the session instead of holding them.
async fn write_lines(
    mut stdin: ChildStdin,
    mut queued: mpsc::UnboundedReceiver<Vec<u8>>,
    session: &Session,
) {
    while let Some(lines) = queued.recv().await {
        let write = async {
            stdin.write_all(&lines).await?;
            stdin.flush().await
        };
        let error = match tokio::time::timeout(UNREAD, write).await {
            Ok(Ok(())) => continue,
            Ok(Err(err)) => err.to_string(),
            Err(_) => "viewer stopped reading commands".to_owned(),
        };
        let error = format!("Couldn't send changes to TeXpresso: {error}. Start TeXpresso again.");
        return session.stop(Some(error));
    }
}

/// TeXpresso's stdout, a JSON message a line, or its stderr, kept for the log.
async fn read_output(reader: impl AsyncRead + Unpin, session: &Session, protocol: bool) {
    let mut reader = tokio::io::BufReader::with_capacity(8192, reader);
    // The line read so far, cut at MAX_MESSAGE: one longer is no message.
    let mut pending = Vec::new();
    let keep = |pending: &mut Vec<u8>, bytes: &[u8]| {
        let room = MAX_MESSAGE.saturating_sub(pending.len());
        pending.extend_from_slice(&bytes[..bytes.len().min(room)]);
    };
    while let Ok(chunk) = reader.fill_buf().await
        && !chunk.is_empty()
    {
        let count = chunk.len();
        if protocol {
            let mut rest = chunk;
            while let Some(end) = memchr::memchr(b'\n', rest) {
                keep(&mut pending, &rest[..end]);
                if let Ok(message) = serde_json::from_slice::<Value>(&pending) {
                    apply_message(session, &message);
                }
                pending.clear();
                rest = &rest[end + 1..];
            }
            keep(&mut pending, rest);
        } else {
            let mut inner = session.lock();
            let end = inner.stderr.end();
            inner.stderr.append(end, chunk);
            inner.bump();
        }
        reader.consume(count);
    }
}

fn apply_message(session: &Session, message: &Value) {
    let mut guard = session.lock();
    let inner = &mut *guard;
    let verb = message[0].as_str().unwrap_or_default();
    if verb == "reset-sync" {
        for (path, text) in &inner.texts {
            inner.send(("open", path, String::from(&text.0)));
        }
        return;
    }
    // A patched build's first word is that it sends pages.
    inner.spoken = true;
    let number = |index: usize| message[index].as_u64();
    match verb {
        "live" => {
            inner.live = number(1).map(|version| version as u32);
            session.event(inner);
        }
        // [page, index, path, ..]: one page, complete at a path in the session's folder.
        "page" => {
            let folder = session.pdf.as_deref().and_then(Path::parent);
            let path = message[2].as_str().filter(|path| {
                folder.is_some_and(|folder| Path::new(path).parent() == Some(folder))
            });
            if let (Some(page), Some(path)) = (number(1), path) {
                let page = page as u32;
                let (path, serial) = (path.to_owned(), session.event(inner));
                inner.pages.insert(page, PageUpdate { page, path, serial });
            }
        }
        // [pdf, path, pages], and from a patched build [.., run, changed, ..]: the whole
        // document written to the path it was given.
        "pdf" => {
            let Some(pdf) = &session.pdf else {
                return;
            };
            inner.pdf_version += 1;
            let changed = message[4].as_array().map(|ranges| {
                let page = |range: &Value, at: usize| range[at].as_u64().unwrap_or(0) as u32;
                ranges.iter().map(|r| [page(r, 0), page(r, 1)]).collect()
            });
            inner.document = Some(Document {
                path: pdf.to_string_lossy().into_owned(),
                version: inner.pdf_version,
                serial: session.event(inner),
                pages: number(2).unwrap_or(0) as u32,
                run: message[3].as_str().map(str::to_owned),
                changed,
            });
            // The pages written before it are in it, and their own files are going.
            inner.pages.clear();
        }
        // [done, pages, run]
        "done" => {
            if let Some(run) = message[2].as_str() {
                inner.done = Some((session.event(inner), run.to_owned()));
            }
        }
        // Upstream sends [truncate, buffer, end] and [append, buffer, byte-offset, text].
        "truncate" | "append" => {
            let output = match message[1].as_str() {
                Some("out") => &mut inner.output,
                Some("log") => &mut inner.log,
                _ => return,
            };
            match (verb, number(2), message[3].as_str()) {
                ("truncate", Some(end), _) => output.truncate(end),
                ("append", Some(offset), Some(text)) => output.append(offset, text.as_bytes()),
                _ => return,
            }
            inner.protocol_seen = true;
            inner.bump();
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_in_utf16_units_and_whole_texts_change_the_bytes_a_plain_string_would() {
        // What the editor has: UTF-16 units. What TeXpresso takes: bytes.
        let bytes_at = |text: &str, units: usize| {
            let mut seen = 0;
            for (at, c) in text.char_indices() {
                if seen >= units {
                    return (seen == units).then_some(at);
                }
                seen += c.len_utf16();
            }
            (seen == units).then_some(text.len())
        };
        let mut plain = "aé😀b\n".repeat(900);
        let mut held = Text::from(&*plain);
        let mut seed = 7u64;
        let mut next = |below: usize| {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (seed >> 33) as usize % below.max(1)
        };
        for round in 0..1500 {
            let units = plain.encode_utf16().count();
            let start = next(units + 1);
            let remove = [next(5000), next(3), 0, 0][round % 4].min(units - start);
            let long = "y".repeat(next(4000));
            let inserted = ["x", "é", "😀", "", "\\section{Ünïcode 😀}\n", &long][next(6)];
            let fits = bytes_at(&plain, start).zip(bytes_at(&plain, start + remove));
            if round % 3 > 0 {
                let changed = held.edit(start, remove, inserted);
                assert_eq!(changed, fits.map(|(from, to)| (from, to - from)), "{round}");
                if let Some((from, to)) = fits {
                    plain.replace_range(from..to, inserted);
                }
            } else if let Some((from, to)) = fits {
                // The same change as a whole text goes as the bytes that differ.
                let mut sent = plain.clone();
                plain.replace_range(from..to, inserted);
                let (offset, removed, inserted) = held.update(&plain);
                sent.replace_range(offset..offset + removed, inserted);
                assert_eq!(sent, plain, "{round}");
            }
            assert_eq!(held.bytes(), plain.len());
            assert_eq!(held.byte_offset(start), bytes_at(&plain, start));
        }
        assert_eq!(String::from(&held.0), plain);
        let units = plain.encode_utf16().count();
        for (start, remove) in [(units + 1, 0), (units, 1), (0, units + 1)] {
            assert_eq!(held.edit(start, remove, "x"), None);
        }
        assert_eq!(String::from(&held.0), plain);
        let mut pair = Text::from("a😀b");
        assert_eq!(pair.edit(2, 0, "x"), None);
        assert_eq!(pair.edit(1, 1, ""), None);
        assert_eq!(pair.byte_offset(2), None);
        assert_eq!(pair.edit(1, 2, "é"), Some((1, 4)));
        let mut empty = Text::from("");
        assert_eq!(empty.edit(0, 0, "é"), Some((0, 0)));
        assert_eq!(empty.edit(1, 0, "x"), Some((2, 0)));
        let texts = (String::from(&pair.0), String::from(&empty.0));
        assert_eq!(texts, ("aéb".into(), "éx".into()));
    }

    #[test]
    fn a_whole_text_goes_as_the_change_between_character_boundaries() {
        let pairs = [
            ("é😀tail", "ê😃tail"),
            ("é", ""),
            ("", "你好"),
            ("αtestβ", "αβ"),
            ("ab", "abab"),
            ("abc", "abc"),
        ];
        // Past the rope's chunks, which hold a kilobyte or so.
        for padding in [0, 1, 63, 64, 65, 1000, 3000] {
            for (old, new) in pairs {
                let pad = |text| format!("{}{text}{}", "é".repeat(padding), "😀".repeat(padding));
                let (old, new) = (pad(old), pad(new));
                let mut held = Text::from(&*old);
                let (start, remove, inserted) = held.update(&new);
                let sent = format!("{}{inserted}{}", &old[..start], &old[start + remove..]);
                assert_eq!((sent, String::from(&held.0)), (new.clone(), new));
            }
        }
        assert_eq!(Text::from("abc").update("abXc"), (2, 0, "X"));
        assert_eq!(Text::from("abc").update("abc"), (3, 0, ""));
    }

    #[test]
    fn bounded_output_keeps_offsets_after_backtracking() {
        let mut output = Output::default();
        output.append(0, &vec![b'x'; STREAM_TAIL + 10]);
        assert_eq!(output.base, 10);
        output.append(12, b"ok");
        assert_eq!(output.text(), "xxok");
        output.truncate(0);
        output.append(0, "é".as_bytes());
        assert_eq!(output.text(), "é");
    }

    #[tokio::test]
    async fn output_is_read_a_line_at_a_time_and_an_overlong_line_is_no_message() {
        let session = Arc::new(Session {
            root: PathBuf::new(),
            main: "main.tex".into(),
            pdf: None,
            inner: Mutex::default(),
            changed: Notify::new(),
        });
        // Over many reads, the long line's end among them.
        let long = format!(r#"["append","out",3,"{}"]"#, "x".repeat(MAX_MESSAGE));
        let text = format!(
            "[\"append\",\"out\",0,\"rea\"]\n{long}\n[\"append\",\"out\",3,\"dy\"]\n[\"append\",\"log\",0,\"cut"
        );
        read_output(text.as_bytes(), &session, true).await;
        // The last line never ended.
        let status = session.status();
        assert_eq!((status.output.as_str(), status.log.as_str()), ("ready", ""));
    }

    /// Through a stub TeXpresso, a shell script.
    #[cfg(unix)]
    mod stub {
        use super::*;
        use serde_json::json;
        use std::time::Instant;

        /// A stub that starts an "engine", prints output and a document, and keeps what it is
        /// sent, until EXIT_CLEAN or EXIT_STUB.
        const UPSTREAM: &str = r#"/bin/sleep 300 &
echo $! > "$STUB/engine.pid"
printf '["append","out",0,"ready"]\n'
printf '["pdf","%s",1]\n' "$TEXPRESSO_PDF_OUTPUT"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$STUB/commands"
  case "$line" in *EXIT_CLEAN*) exit 0;; *EXIT_STUB*) exit 7;; esac
done
"#;
        /// A stub that speaks as a build with Underleaf's patch does: it says so first, writes
        /// "the document", answers each change with page 1 in a file of its own, and a request
        /// for a finishing pass with a new document.
        const PATCHED: &str = r#"dir=${TEXPRESSO_PDF_OUTPUT%/*}
n=0
printf '["live",1]\n["pdf","%s",3,"partial",[[0,2]],0]\n' "$TEXPRESSO_PDF_OUTPUT"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$STUB/commands"
  case "$line" in
    '["change",'*) n=$((n + 1))
      printf '["page",1,"%s/page-1-%s.pdf",0]\n' "$dir" "$n";;
    *rerun-once*) printf '["pdf","%s",4,"complete",[[1,1],[3,3]],0]\n["done",4,"complete"]\n' "$TEXPRESSO_PDF_OUTPUT";;
  esac
done
"#;
        /// The project session numbered 1, a host's first.
        const OWNER: u64 = 1;
        const SOON: Duration = Duration::from_secs(3);

        struct Stub {
            tmp: tempfile::TempDir,
            root: PathBuf,
            path_env: String,
            manager: Arc<Manager>,
        }

        impl Stub {
            fn new(script: &str) -> Self {
                use std::os::unix::fs::PermissionsExt;
                let tmp = tempfile::tempdir().unwrap();
                let (root, bin) = (tmp.path().join("project"), tmp.path().join("bin"));
                fs::create_dir(&root).unwrap();
                fs::create_dir(&bin).unwrap();
                fs::write(root.join("main.tex"), "disk text").unwrap();
                let stub = bin.join("texpresso");
                let here = tmp.path().display();
                fs::write(&stub, format!("#!/bin/sh\nSTUB='{here}'\n{script}")).unwrap();
                fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
                let path_env = bin.to_string_lossy().into_owned();
                let manager = Arc::default();
                Self {
                    tmp,
                    root,
                    path_env,
                    manager,
                }
            }
            fn start(
                &self,
                owner: u64,
                main: Option<&str>,
                replacing: bool,
                pane: Option<&Pane>,
            ) -> Result<Status, CoreError> {
                let file = |text: &str| FileBuffer {
                    path: "main.tex".into(),
                    text: text.into(),
                };
                let files: Vec<_> = main.map(file).into_iter().collect();
                let manager = &self.manager;
                manager.start(owner, &self.root, &files, replacing, &self.path_env, pane)
            }
            /// The user's Start, with the main file open as `main` says.
            fn begin(&self, owner: u64, main: Option<&str>) -> Status {
                self.start(owner, main, false, Some(&Pane::default()))
                    .unwrap()
            }
            /// The owner's own restart, which takes back only a preview still its own.
            fn restart(&self, owner: u64) -> Result<Status, CoreError> {
                self.start(owner, None, true, Some(&Pane::default()))
            }
            fn commands(&self) -> Vec<Value> {
                let sent = fs::read_to_string(self.tmp.path().join("commands"));
                let lines = sent.unwrap_or_default();
                let parse = |line| serde_json::from_str(line).unwrap();
                lines.lines().map(parse).collect()
            }
            /// The commands once the stub has had those `ready` waits for.
            async fn sent(&self, ready: impl Fn(&[Value]) -> bool) -> Vec<Value> {
                until(|| ready(&self.commands())).await;
                self.commands()
            }
            fn main(&self) -> PathBuf {
                dunce::canonicalize(self.root.join("main.tex")).unwrap()
            }
            async fn wait(&self, owner: u64, after: u64) -> Events {
                let wait = self.manager.wait(owner, after);
                let answer = tokio::time::timeout(SOON, wait).await;
                answer.expect("an answer").unwrap()
            }
            /// The first document the session hands its client.
            async fn first_document(&self) -> Document {
                let mut events = self.wait(OWNER, 0).await;
                while events.pdf.is_none() {
                    events = self.wait(OWNER, events.seq).await;
                }
                events.pdf.unwrap()
            }
        }

        async fn until(mut check: impl FnMut() -> bool) {
            tokio::time::timeout(SOON, async {
                while !check() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .expect("stub made progress");
        }
        fn has(verb: &'static str) -> impl Fn(&[Value]) -> bool {
            move |sent| sent.iter().any(|c| c[0] == verb)
        }
        fn verbs(sent: &[Value]) -> Vec<Value> {
            sent.iter().map(|c| c[0].clone()).collect()
        }
        /// The status code of a refusal.
        fn refused<T>(result: Result<T, CoreError>) -> u16 {
            result.err().expect("refused").status
        }
        /// `text` with a change TeXpresso was sent made to it.
        fn apply(text: &mut String, change: &Value) {
            let start = change[2].as_u64().unwrap() as usize;
            let end = start + change[3].as_u64().unwrap() as usize;
            text.replace_range(start..end, change[4].as_str().unwrap());
        }

        #[tokio::test]
        async fn a_preview_has_the_buffers_their_changes_and_a_folder_of_its_own() {
            use std::os::unix::fs::PermissionsExt;
            let stub = Stub::new(UPSTREAM);
            let (original, updated) = ("prefix é😀 suffix", "prefix ê😃 suffix");
            // A main file named texpresso-live.tex builds this; live preview leaves it.
            fs::create_dir_all(stub.root.join(BUILD_DIR)).unwrap();
            let normal = stub.root.join(BUILD_DIR).join("texpresso-live.pdf");
            fs::write(&normal, "normal build").unwrap();
            let first = stub.begin(OWNER, Some(original));
            assert!(first.running);
            // The session's own, outside the project, for its owner alone: never a build's.
            let pdf = PathBuf::from(stub.first_document().await.path);
            let root = dunce::canonicalize(&stub.root).unwrap();
            assert!(pdf.ends_with("live.pdf") && !pdf.starts_with(root));
            let folder = pdf.parent().unwrap().to_owned();
            let mode = fs::metadata(&folder).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);
            assert_eq!(fs::read(&normal).unwrap(), b"normal build");
            let sent = stub.sent(has("open")).await;
            assert_eq!(sent[0], json!(["open", stub.main(), original]));

            stub.manager.update(OWNER, "main.tex", updated).unwrap();
            let second = stub.manager.status(OWNER).unwrap();
            assert!(second.running && second.revision > first.revision);
            let sent = stub.sent(has("change")).await;
            let mut text = original.to_owned();
            apply(&mut text, &sent[1]);
            assert_eq!(text, updated);
            let disk = fs::read_to_string(stub.root.join("main.tex")).unwrap();
            assert_eq!(disk, "disk text");
            let too_large = "x".repeat(MAX_FILE + 1);
            let outside = [("../escape.tex", "bad"), ("build/out.tex", "bad")];
            for (path, text) in outside.into_iter().chain([("main.tex", &*too_large)]) {
                assert!(stub.manager.update(OWNER, path, text).is_err());
            }
            stub.manager.rescan(OWNER).unwrap();
            stub.sent(has("rescan")).await;

            // The owner's Stop ends its ownership and removes the folder.
            assert!(!stub.manager.stop_request(OWNER).unwrap().running);
            assert!(!folder.exists());
            assert_eq!(refused(stub.restart(OWNER)), 409);
            let restarted = stub.begin(OWNER, None);
            assert!(restarted.running && restarted.revision > second.revision);
            stub.manager
                .update(OWNER, "main.tex", "EXIT_CLEAN")
                .unwrap();
            until(|| !stub.manager.status(OWNER).unwrap().running).await;
            assert!(stub.manager.status(OWNER).unwrap().error.is_none());
            stub.begin(OWNER, None);
            stub.manager.kill_all();
            assert!(!stub.manager.status(OWNER).unwrap().running);
        }

        #[tokio::test]
        async fn whole_texts_follow_one_another_and_a_new_main_file_stops_the_session() {
            let stub = Stub::new(UPSTREAM);
            stub.begin(OWNER, Some("abc"));
            let changes = || -> Vec<Value> {
                let sent = stub.commands().into_iter();
                sent.filter(|c| c[0] == "change").collect()
            };
            // TeXpresso's copy, rebuilt from the changes it is sent; the same text again
            // sends none.
            let mut text = String::from("abc");
            for edit in ["abXc", "aXc", "aXc", "aXcd"] {
                let before = changes().len();
                stub.manager.update(OWNER, "main.tex", edit).unwrap();
                if text != edit {
                    until(|| changes().len() > before).await;
                    apply(&mut text, changes().last().unwrap());
                }
                assert_eq!(text, edit);
            }
            assert_eq!(changes().len(), 3);

            fs::write(stub.root.join("other.tex"), "").unwrap();
            let other = json!({ "mainFile": "other.tex" });
            crate::settings::write_settings(&stub.root, &other).unwrap();
            stub.manager.update(OWNER, "main.tex", "abc").unwrap();
            let status = stub.manager.status(OWNER).unwrap();
            assert!(!status.running);
            assert!(status.error.unwrap().contains("main file changed"));
        }

        /// The log follows TeX's backtracking, and has the program's own output only once it
        /// has failed; the output stays, and the engine goes with it.
        #[tokio::test]
        async fn an_unexpected_exit_keeps_the_output_and_stops_the_engines_group() {
            let stub = Stub::new(UPSTREAM);
            stub.begin(OWNER, None);
            let pid = stub.tmp.path().join("engine.pid");
            let status = || stub.manager.status(OWNER).unwrap();
            until(|| fs::read_to_string(&pid).is_ok() && status().output == "ready").await;
            let pid: i32 = fs::read_to_string(&pid).unwrap().trim().parse().unwrap();
            // Backtracking drops TeX's log, and stderr's history is not put in its place.
            let session = stub.manager.owned(OWNER).unwrap();
            let diagnostic = "Undefined control sequence";
            session.lock().stderr.append(0, diagnostic.as_bytes());
            apply_message(&session, &json!(["append", "log", 0, diagnostic]));
            assert!(status().log.contains(diagnostic));
            apply_message(&session, &json!(["truncate", "log", 0]));
            assert!(!status().log.contains(diagnostic));

            stub.manager.update(OWNER, "main.tex", "EXIT_STUB").unwrap();
            until(|| !status().running).await;
            let ended = status();
            assert_eq!(ended.output, "ready");
            assert!(ended.error.unwrap().contains("exited") && ended.log.contains(diagnostic));
            assert!(!stub.wait(OWNER, 0).await.running);
            until(|| unsafe { libc::kill(pid, 0) == -1 }).await;
        }

        #[tokio::test]
        async fn another_sessions_start_takes_over_and_a_stop_ends_ownership() {
            let stub = Stub::new(UPSTREAM);
            let manager = &stub.manager;
            let (old, current) = (OWNER, OWNER + 1);
            stub.begin(old, None);
            stub.begin(current, Some("owner B"));
            // The old owner's late calls change nothing.
            assert_eq!(refused(manager.update(old, "main.tex", "stale A")), 409);
            assert_eq!(refused(manager.edit(old, "main.tex", 0, 0, "x")), 409);
            assert_eq!(refused(manager.status(old)), 409);
            assert_eq!(refused(manager.rescan(old)), 409);
            assert_eq!(refused(manager.stop_request(old)), 409);
            assert_eq!(refused(manager.wait(old, 0).await), 409);
            assert_eq!(refused(stub.restart(old)), 409);
            assert!(manager.status(current).unwrap().running);
            let session = manager.owned(current).unwrap();
            let held = String::from(&session.lock().texts[&stub.main()].0);
            assert_eq!(held, "owner B");
            // A rename's stop keeps the owner, whose restart takes the preview back.
            manager.stop(&stub.root).unwrap();
            assert!(!manager.status(current).unwrap().running);
            let restarted = stub.restart(current).unwrap();
            assert!(restarted.running && !session.status().running);
            // The stopped one's task has let it go: its writer, readers and wait are over.
            until(|| Arc::strong_count(&session) == 1).await;
            // The owner's Stop ends its ownership too.
            assert!(!manager.stop_request(current).unwrap().running);
            assert_eq!(refused(stub.restart(current)), 409);
        }

        #[tokio::test]
        async fn a_keystroke_goes_as_bytes_at_once_and_one_that_does_not_fit_is_refused() {
            let stub = Stub::new(PATCHED);
            let manager = &stub.manager;
            let caret = Caret {
                path: "main.tex".into(),
                offset: 4,
            };
            let pane = Pane {
                view: Some((2, 3)),
                caret: Some(caret),
            };
            stub.start(OWNER, Some("aé😀b"), false, Some(&pane))
                .unwrap();
            let path = stub.main();
            // Four units in: after a, é and the pair, seven bytes in.
            manager.edit(OWNER, "main.tex", 4, 0, "X").unwrap();
            manager.edit(OWNER, "main.tex", 1, 3, "").unwrap();
            manager.view(OWNER, 5, 4).unwrap();
            manager.caret(OWNER, "main.tex", 2).unwrap();
            let sent = stub.sent(|sent| sent.len() >= 7).await;
            assert_eq!(
                sent[1..],
                [
                    json!(["view", 2, 3]),
                    json!(["caret", path, 7]),
                    json!(["change", path, 7, 0, "X"]),
                    json!(["change", path, 1, 6, ""]),
                    json!(["view", 5, 5]),
                    json!(["caret", path, 2]),
                ]
            );

            // The copy is "aXb" now: nothing below is in it, and nothing is sent or changed.
            let unfit = [("main.tex", 4, 0), ("main.tex", 2, 2), ("other.tex", 0, 0)];
            for (file, start, remove) in unfit {
                assert_eq!(refused(manager.edit(OWNER, file, start, remove, "no")), 412);
            }
            assert_eq!(refused(manager.caret(OWNER, "main.tex", 9)), 412);
            assert_eq!(refused(manager.edit(OWNER, "main.tex", 0, 0, "\0")), 400);
            assert_eq!(refused(manager.edit(OWNER + 1, "main.tex", 0, 0, "x")), 409);
            // The whole text puts the copy right, sent as the change from what TeXpresso has.
            manager.update(OWNER, "main.tex", "aXb😀").unwrap();
            manager.edit(OWNER, "main.tex", 5, 0, "!").unwrap();
            let sent = stub.sent(|sent| sent.len() >= 9).await;
            let changes = [
                json!(["change", path, 3, 0, "😀"]),
                json!(["change", path, 7, 0, "!"]),
            ];
            assert_eq!(sent[7..], changes);
            // No finishing passes of upstream's kind, which start the document over.
            assert!(!has("rerun")(&sent));
            // A session that has ended takes an edit as nothing, and refuses none.
            manager.stop(&stub.root).unwrap();
            manager.edit(OWNER, "main.tex", 0, 0, "x").unwrap();
        }

        #[tokio::test]
        async fn waiting_hands_over_the_latest_of_each_page_and_ends_with_the_session() {
            let stub = Stub::new(PATCHED);
            stub.begin(OWNER, Some("abc"));
            let wait = |after: u64| {
                let manager = Arc::clone(&stub.manager);
                async move { manager.wait(OWNER, after).await.unwrap() }
            };
            let session = stub.manager.owned(OWNER).unwrap();
            // The build says what it speaks, then the first document.
            let document = stub.first_document().await;
            let first = stub.wait(OWNER, 0).await;
            assert_eq!(session.lock().live, Some(1));
            assert_eq!((document.version, document.pages), (1, 3));
            assert_eq!(document.run.as_deref(), Some("partial"));
            assert_eq!(document.changed, Some(vec![[0, 2]]));
            assert!(first.pages.is_empty() && first.done.is_none() && first.running);

            // Nothing new: the wait goes on, and other calls go on meanwhile.
            let began = Instant::now();
            let waiting = tokio::spawn(wait(first.seq));
            tokio::time::sleep(Duration::from_millis(50)).await;
            assert!(!waiting.is_finished());
            stub.manager.edit(OWNER, "main.tex", 3, 0, "d").unwrap();
            stub.manager.edit(OWNER, "main.tex", 4, 0, "e").unwrap();
            let mut events = waiting.await.unwrap();
            assert!(began.elapsed() < SOON && events.seq > first.seq);
            while !events.pages.iter().any(|p| p.path.ends_with("-2.pdf")) {
                events = stub.wait(OWNER, events.seq).await;
            }
            // Two edits wrote page 1 twice: a client that was away has only the later.
            let all = stub.wait(OWNER, 0).await;
            let folder = Path::new(&document.path).parent().unwrap();
            assert_eq!(all.pages.len(), 1);
            let page = &all.pages[0];
            assert_eq!(page.page, 1);
            assert_eq!(Path::new(&page.path), folder.join("page-1-2.pdf"));
            assert!(page.serial > document.serial && all.pdf.unwrap().serial == document.serial);
            // And one that has seen it is told nothing twice: its wait goes on.
            let quiet = tokio::time::timeout(Duration::from_millis(60), wait(all.seq)).await;
            assert!(quiet.is_err());

            // A new document takes the place of the pages before it: the stub writes one when
            // asked for a finishing pass, as upstream's build does.
            session.lock().send(["rerun-once"]);
            let mut events = stub.wait(OWNER, all.seq).await;
            while events.done.is_none() {
                events = stub.wait(OWNER, all.seq).await;
            }
            let document = events.pdf.unwrap();
            assert_eq!((document.version, document.pages), (2, 4));
            assert_eq!(document.run.as_deref(), Some("complete"));
            assert_eq!(document.changed, Some(vec![[1, 1], [3, 3]]));
            assert!(events.pages.is_empty());
            assert_eq!(events.done.unwrap(), "complete");

            // A page file from outside the session's folder is nobody's page.
            apply_message(&session, &json!(["page", 0, "/etc/passwd", 0]));
            assert!(session.lock().events(events.seq).pages.is_empty());

            // Stopping answers the wait at once.
            let waiting = tokio::spawn(wait(events.seq));
            tokio::time::sleep(Duration::from_millis(30)).await;
            let began = Instant::now();
            stub.manager.stop(&stub.root).unwrap();
            let ended = waiting.await.unwrap();
            assert!(!ended.running && began.elapsed() < Duration::from_secs(1));
            assert!(!stub.wait(OWNER, ended.seq).await.running);
            assert_eq!(refused(stub.manager.wait(OWNER + 1, 0).await), 409);
        }

        /// Only a build that has said it sends pages, or nothing yet, is told the view and the
        /// caret: an older one only writes the document, and without a pane TeXpresso shows the
        /// document in its own window, for which the session makes no folder and offers none.
        #[tokio::test]
        async fn texpresso_is_told_no_view_or_caret_by_an_older_build_or_without_a_pane() {
            let stub = Stub::new(UPSTREAM);
            stub.begin(OWNER, Some("abc"));
            // No word of pages before the document: the build is an older one.
            let document = stub.first_document().await;
            let live = stub.manager.owned(OWNER).unwrap().lock().live;
            assert_eq!((live, document.version, document.pages), (None, 1, 1));
            assert!(document.run.is_none() && document.changed.is_none());
            stub.manager.edit(OWNER, "main.tex", 3, 0, "d").unwrap();
            stub.manager.view(OWNER, 0, 1).unwrap();
            stub.manager.caret(OWNER, "main.tex", 1).unwrap();
            stub.manager.rescan(OWNER).unwrap();
            let sent = stub.sent(has("rescan")).await;
            assert_eq!(verbs(&sent), ["open", "change", "rescan"]);

            let stub = Stub::new(UPSTREAM);
            stub.start(OWNER, Some("abc"), false, None).unwrap();
            assert!(stub.manager.owned(OWNER).unwrap().pdf.is_none());
            stub.manager.view(OWNER, 0, 1).unwrap();
            stub.manager.caret(OWNER, "main.tex", 1).unwrap();
            stub.manager
                .update(OWNER, "main.tex", "EXIT_CLEAN")
                .unwrap();
            until(|| !stub.manager.status(OWNER).unwrap().running).await;
            // Its stub printed a document all the same, with no path to write it to.
            let events = stub.wait(OWNER, 0).await;
            assert!(events.pdf.is_none() && events.pages.is_empty());
            assert_eq!(verbs(&stub.commands()), ["open", "change"]);
        }
    }
}
