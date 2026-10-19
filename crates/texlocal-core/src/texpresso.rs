//! Optional persistent TeXpresso viewer. Author buffers stay in its VFS; the
//! ordinary latexmk build and PDF continue to use saved project files.
//!
//! A build with Underleaf's patch (tools/texpresso) shows nothing itself: it writes the
//! pages the client says it is showing as one-page PDFs the moment they are typeset again,
//! and the whole document when a run has ended. Each goes to the client's `Sink` as it
//! comes; `edit` takes a keystroke without waiting for anything. A client that gives no
//! pane gets TeXpresso's own window instead, which draws with MuPDF.
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ropey::Rope;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt};
use tokio::process::ChildStdin;
use tokio::sync::mpsc;

use crate::process::{self, Tree};
use crate::tex::{find_tool, program_at};
use crate::{BUILD_DIR, CoreError, lock, paths, settings, tail};

const MAX_OUTPUT: usize = 128 * 1024;
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
/// How long TeXpresso may leave what it was sent unread before the session is given up:
/// it reads nothing while it makes its TeX formats, five seconds and more the first time.
const UNREAD: Duration = Duration::from_secs(60);
const MISSING: &str = if cfg!(windows) {
    "TeXpresso wasn't found. Choose the folder it's in, in Settings."
} else {
    "TeXpresso wasn't found. Choose the folder it's in, in Settings, or install it in /opt/homebrew/bin or /usr/local/bin."
};
const NOT_RUNNING: &str = "Live Preview isn't running.";
const UNFIT: &str = "The edit doesn't fit the text TeXpresso has. Send the whole text.";
const INVALID: &str = "A file sent to TeXpresso has an invalid path or text.";
const REPEATED: &str = "Files sent to TeXpresso repeat a path.";
const FOLDER: &str = "TeXpresso opens files, not folders.";

#[derive(Debug)]
pub struct FileBuffer {
    pub path: String,
    pub text: String,
}

/// A client that shows the document itself, in its own pane: the pages it shows there,
/// from 0, and where its caret is (a path, and UTF-16 units in, as the editors count), for
/// a build with Underleaf's patch to have those pages first and a snapshot ready where the
/// first key will land.
#[derive(Debug, Default)]
pub struct Pane {
    pub view: Option<(u32, u32)>,
    pub caret: Option<(String, usize)>,
}

#[derive(Debug, Default)]
pub struct Status {
    pub running: bool,
    pub log: String,
    pub output: String,
    pub error: Option<String>,
}

/// What a preview tells its client, as TeXpresso says it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveEvent {
    /// A page (from 0) typeset again, alone in a PDF that is complete on disk.
    Page { page: u32, path: String },
    /// The whole document, complete on disk, its SyncTeX beside it. `run`: how the run that
    /// wrote it ended, `complete` at the document's end, `stopped` on an error before it,
    /// `partial` while it is still being typeset. `changed`: ranges of pages, first and
    /// last, that differ from the document before. Both None from a build that doesn't say.
    Document {
        path: String,
        pages: u32,
        run: Option<String>,
        changed: Option<Vec<[u32; 2]>>,
    },
    /// A run of TeX is over, `complete` or `stopped`.
    Done(String),
    /// TeX's log or output, or TeXpresso's own messages, changed.
    Log,
    /// The preview has ended, with what went wrong if anything did.
    Ended(Option<String>),
}

/// Where a preview's events go, from the threads that read TeXpresso.
pub type Sink = Box<dyn Fn(LiveEvent) + Send + Sync>;

/// The live preview as a project session drives it, by the session's number (`owner`):
/// the Manager's, or its tests' fake.
pub(crate) trait Preview: Send + Sync {
    /// A preview of the project at `root` for the session `owner`, in place of any the
    /// owner had. With a `pane`, a build with Underleaf's patch writes the document for it
    /// instead of opening a window; upstream opens its window all the same. What it shows
    /// from then on goes to `sink`.
    fn start(
        &self,
        owner: u64,
        root: &Path,
        files: &[FileBuffer],
        path_env: &str,
        pane: Option<&Pane>,
        sink: Sink,
    ) -> Result<Status, CoreError>;
    /// The whole text of a file: sent as the change from the buffer TeXpresso has, or
    /// whole when it has none. It is also what repairs a copy `edit` refused to change.
    fn update(&self, owner: u64, rel: &str, text: &str) -> Result<(), CoreError>;
    /// A keystroke, as the editor has it: `remove` UTF-16 units at `start` of a file the
    /// session has, replaced by `text`. It waits for nothing (no disk, no TeXpresso), so
    /// the editor can call it where the edit is made. A session that has ended takes it as
    /// nothing. An edit that doesn't fit the session's copy is refused with status 412 and
    /// changes nothing: `update` with the whole text then puts both right.
    fn edit(
        &self,
        owner: u64,
        rel: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<(), CoreError>;
    /// The pages the client shows, from 0: a patched build typesets as far as the last of
    /// them first, and sends each as it changes.
    fn view(&self, owner: u64, first: u32, last: u32) -> Result<(), CoreError>;
    /// Where the client's caret has settled: a patched build takes a snapshot there, so
    /// the first key typed there is answered as quickly as the ones after it. Refused as
    /// `edit` is for a file or place the session's copy doesn't have.
    fn caret(&self, owner: u64, rel: &str, offset: usize) -> Result<(), CoreError>;
    /// Files changed on disk: TeXpresso reads again those it hasn't been sent.
    fn rescan(&self, owner: u64) -> Result<(), CoreError>;
    /// The owner's preview as it is now, its log and output with it.
    fn status(&self, owner: u64) -> Result<Status, CoreError>;
    /// The owner's Stop: its preview is gone, and how it ended is answered.
    fn stop_request(&self, owner: u64) -> Status;
    /// Stops the project's preview, as a project about to move or go, a rename and a new
    /// main file do. Its status stays the owner's until a start replaces it.
    fn stop(&self, root: &Path) -> Result<(), CoreError>;
}

// Retain a bounded tail while preserving absolute byte offsets for backtracking.
#[derive(Default)]
struct Output {
    base: u64,
    bytes: Vec<u8>,
}
impl Output {
    fn truncate(&mut self, end: u64) {
        if end < self.base {
            self.base = end;
            self.bytes.clear();
        } else {
            self.bytes
                .truncate((end - self.base).min(self.bytes.len() as u64) as usize);
        }
    }
    fn append(&mut self, offset: u64, text: &[u8]) {
        self.truncate(offset);
        if offset > self.base + self.bytes.len() as u64 {
            self.bytes.clear();
            self.base = offset;
        }
        self.bytes.extend_from_slice(text);
        if self.bytes.len() > MAX_OUTPUT {
            let excess = self.bytes.len() - MAX_OUTPUT;
            self.bytes.drain(..excess);
            self.base += excess as u64;
        }
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}

/// A file's text as TeXpresso has it: an edit the editor gives in UTF-16 units finds
/// its bytes in the rope's index, however long the file.
struct Text(Rope);
impl Text {
    fn new(text: &str) -> Self {
        Self(Rope::from_str(text))
    }
    fn string(&self) -> String {
        String::from(&self.0)
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
    /// Replaces `remove` UTF-16 units at `start` with `inserted`. The same in bytes, as
    /// TeXpresso takes it, or None (and nothing replaced) when the range isn't the text's.
    fn edit(&mut self, start: usize, remove: usize, inserted: &str) -> Option<(usize, usize)> {
        let from = self.char_at(start)?;
        let to = self.char_at(start.checked_add(remove)?)?;
        let (offset, end) = (self.0.char_to_byte(from), self.0.char_to_byte(to));
        self.0.remove(from..to);
        self.0.insert(from, inserted);
        Some((offset, end - offset))
    }
}

#[derive(Default)]
struct State {
    tree: Option<Tree>,
    output: Output,
    log: Output,
    protocol_seen: bool,
    stderr: Output,
    error: Option<String>,
    /// Whether TeXpresso has said anything.
    spoken: bool,
    /// The page protocol it said it speaks: 1 from a build that sends pages as they change,
    /// None from one that only writes the whole document.
    live: Option<u32>,
}

#[derive(Default)]
struct Files {
    texts: HashMap<PathBuf, Text>,
    /// Where the paths clients send lead, found once: a session's files
    /// don't move under it, as a rename or delete stops it.
    paths: HashMap<String, PathBuf>,
}
struct Session {
    /// The project's folder, resolved.
    root: PathBuf,
    /// Where a patched build writes the document, in a folder of the session's own, when
    /// the client shows it.
    pdf: Option<PathBuf>,
    state: Mutex<State>,
    /// A keystroke takes it on the editor's own thread.
    files: Mutex<Files>,
    /// Lines for TeXpresso's stdin, written in order by the session's writer.
    lines: mpsc::UnboundedSender<Vec<u8>>,
    sink: Sink,
}
impl Session {
    fn running(&self) -> bool {
        lock(&self.state).tree.is_some()
    }
    fn stop(&self, error: Option<String>) {
        let mut state = lock(&self.state);
        if let Some(tree) = state.tree.take() {
            // The viewer starts an engine: stopping just its parent leaks it.
            tree.kill();
            remove_pdf_folder(self.pdf.as_deref());
            state.error.clone_from(&error);
            if let Ok(mut files) = self.files.try_lock() {
                files.texts.clear();
            }
            (self.sink)(LiveEvent::Ended(error));
        }
    }
    fn status(&self) -> Status {
        let state = lock(&self.state);
        let mut log = state.log.text();
        // stderr includes historical TeX diagnostics and echoed VFS commands.
        // The protocol buffers alone track the engine's current backtracking.
        if !state.protocol_seen || state.error.is_some() {
            log.push_str(tail(&state.stderr.text(), 16 * 1024));
        }
        if log.len() > MAX_OUTPUT {
            let cut = log.len() - tail(&log, MAX_OUTPUT).len();
            log.drain(..cut);
        }
        Status {
            running: state.tree.is_some(),
            output: state.output.text(),
            log,
            error: state.error.clone(),
        }
    }
    /// Messages for TeXpresso, in the order of the calls: nothing here waits for it.
    fn send(&self, messages: &[Value]) {
        let mut lines = Vec::new();
        for message in messages {
            serde_json::to_writer(&mut lines, message).expect("JSON values serialize");
            lines.push(b'\n');
        }
        // A writer that has gone has stopped the session, or is about to.
        let _ = self.lines.send(lines);
    }
    /// Whether to send what only a build that sends pages knows: it has said it is one,
    /// or nothing at all yet. Another would only report a command it doesn't know.
    fn sends_pages(&self) -> bool {
        let state = lock(&self.state);
        self.pdf.is_some() && (state.live.is_some() || !state.spoken)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.stop(None);
    }
}
fn remove_pdf_folder(pdf: Option<&Path>) {
    if let Some(folder) = pdf.and_then(Path::parent) {
        let _ = fs::remove_dir_all(folder);
    }
}

#[derive(Default)]
pub struct Manager {
    /// Each preview by the project session it is for, by the number its host gave the
    /// session: a session has one.
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
    /// The owner's preview, from its start until its Stop.
    fn owned(&self, owner: u64) -> Result<Arc<Session>, CoreError> {
        lock(&self.sessions)
            .get(&owner)
            .cloned()
            .ok_or_else(|| CoreError::not_found(NOT_RUNNING))
    }
    /// The live document the owner's preview last wrote, which has its SyncTeX beside it:
    /// the session's folder is its own, so none is there before it writes one.
    pub fn live_pdf(&self, owner: u64) -> Result<PathBuf, CoreError> {
        let session = self.owned(owner)?;
        session
            .pdf
            .clone()
            .filter(|pdf| pdf.with_extension("synctex").is_file())
            .ok_or_else(|| {
                CoreError::not_found("TeXpresso hasn't written a document to sync with yet")
            })
    }
}

impl Preview for Manager {
    fn start(
        &self,
        owner: u64,
        root: &Path,
        files: &[FileBuffer],
        path_env: &str,
        pane: Option<&Pane>,
        sink: Sink,
    ) -> Result<Status, CoreError> {
        let root = dunce::canonicalize(root)?;
        let main = settings::read_settings(&root).main_file;
        let mut buffers = Files::default();
        let main_path = validate_buffer(&root, &main, "", &buffers.paths)?;
        if !main_path.is_file() {
            return Err(CoreError::bad_request("The main file does not exist."));
        }
        let mut opened = Vec::new();
        for file in files {
            let path = validate_buffer(&root, &file.path, &file.text, &buffers.paths)?;
            buffers.paths.insert(file.path.clone(), path.clone());
            opened.push(json!(["open", path, file.text]));
            if buffers.texts.insert(path, Text::new(&file.text)).is_some() {
                return Err(CoreError::bad_request(REPEATED));
            }
        }
        let failed = |error: String| {
            Ok(Status {
                error: Some(error),
                ..Status::default()
            })
        };
        let Some(executable) = discover(path_env) else {
            return failed(MISSING.into());
        };
        let build = paths::safe_path(&root, BUILD_DIR)?;
        fs::create_dir_all(&build)?;
        let build = dunce::canonicalize(build)?;
        if let Some(previous) = lock(&self.sessions).get(&owner) {
            previous.stop(None);
        }
        // The session's own folder, for its owner alone: no build output or
        // other session shares it. The session removes it as it stops.
        let pdf = match pane {
            Some(_) => {
                let mut folder = tempfile::Builder::new();
                folder.prefix("texlocal-texpresso-");
                // tempfile makes folders 0o777 less the umask.
                #[cfg(unix)]
                folder.permissions(std::os::unix::fs::PermissionsExt::from_mode(0o700));
                let folder = folder.tempdir()?.keep();
                Some(dunce::canonicalize(folder)?.join("live.pdf"))
            }
            None => None,
        };
        let mut command = process::tool(&executable, path_env);
        command
            .args(["-json", "-texlive", "-I"])
            .arg(&build)
            .arg(&main_path)
            .current_dir(&root)
            .stdin(Stdio::piped());
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
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let (lines, queued) = mpsc::unbounded_channel();
        // Where the caret is in bytes, as TeXpresso counts, from the text just sent.
        let caret = pane
            .and_then(|pane| pane.caret.as_ref())
            .and_then(|(rel, offset)| {
                let path = buffers.paths.get(rel)?;
                let offset = buffers.texts.get(path)?.byte_offset(*offset)?;
                Some(json!(["caret", path, offset]))
            });
        let session = Arc::new(Session {
            root: root.clone(),
            pdf,
            files: Mutex::new(buffers),
            lines,
            sink,
            state: Mutex::new(State {
                tree: Some(tree),
                ..State::default()
            }),
        });
        {
            let mut sessions = lock(&self.sessions);
            // Under the map's lock, so `kill_all` stops it either way.
            if self.shutdown.load(Ordering::Acquire) {
                session.stop(None);
            }
            sessions.insert(owner, Arc::clone(&session));
        }
        tokio::spawn(write_lines(
            child.stdin.take().unwrap(),
            queued,
            Arc::downgrade(&session),
        ));
        tokio::spawn(read_output(stdout, Arc::clone(&session), true));
        tokio::spawn(read_output(stderr, Arc::clone(&session), false));
        let weak = Arc::downgrade(&session);
        tokio::spawn(async move {
            struct Cleanup(std::sync::Weak<Session>);
            impl Drop for Cleanup {
                fn drop(&mut self) {
                    if let Some(session) = self.0.upgrade() {
                        session.stop(None);
                    }
                }
            }
            let _cleanup = Cleanup(weak.clone());
            let result = child.wait().await;
            if let Some(session) = weak.upgrade() {
                let error = match result {
                    Ok(status) if status.success() => None,
                    result => Some(format!(
                        "TeXpresso exited ({}). Check its log and start TeXpresso again.",
                        result.map_or_else(|e| e.to_string(), |s| s.to_string())
                    )),
                };
                session.stop(error);
            }
        });
        // TeXpresso's idle reruns stay off: each starts TeX again from nothing after a pause
        // in typing and shows no page until it is over. A build that sends pages makes its
        // finishing passes beside the document.
        if let Some((first, last)) = pane.and_then(|pane| pane.view) {
            opened.push(json!(["view", first, last.max(first)]));
        }
        opened.extend(caret);
        session.send(&opened);
        Ok(session.status())
    }
    fn update(&self, owner: u64, rel: &str, text: &str) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        if !session.running() {
            return Ok(());
        }
        let mut files = lock(&session.files);
        let files = &mut *files;
        let path = validate_buffer(&session.root, rel, text, &files.paths)?;
        let previous = files.texts.get(&path).map(Text::string);
        let message = match previous.as_deref().map(|previous| delta(previous, text)) {
            Some((_, 0, "")) => return Ok(()),
            Some((offset, remove, inserted)) => {
                json!(["change", path, offset, remove, inserted])
            }
            None => json!(["open", path, text]),
        };
        session.send(&[message]);
        files.paths.insert(rel.to_owned(), path.clone());
        files.texts.insert(path, Text::new(text));
        Ok(())
    }
    fn edit(
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
        let mut files = lock(&session.files);
        let files = &mut *files;
        if !session.running() {
            return Ok(());
        }
        let unfit = || CoreError::unfit(UNFIT);
        let path = files.paths.get(rel).ok_or_else(unfit)?;
        let held = files.texts.get_mut(path).ok_or_else(unfit)?;
        let (offset, removed) = held.edit(start, remove, text).ok_or_else(unfit)?;
        session.send(&[json!(["change", path, offset, removed, text])]);
        Ok(())
    }
    fn view(&self, owner: u64, first: u32, last: u32) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        if session.sends_pages() {
            session.send(&[json!(["view", first, last.max(first)])]);
        }
        Ok(())
    }
    fn caret(&self, owner: u64, rel: &str, offset: usize) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        let files = lock(&session.files);
        let unfit = || CoreError::unfit(UNFIT);
        let path = files.paths.get(rel).ok_or_else(unfit)?;
        let text = files.texts.get(path).ok_or_else(unfit)?;
        let offset = text.byte_offset(offset).ok_or_else(unfit)?;
        if session.sends_pages() {
            session.send(&[json!(["caret", path, offset])]);
        }
        Ok(())
    }
    fn rescan(&self, owner: u64) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        if session.running() {
            session.send(&[json!(["rescan"])]);
        }
        Ok(())
    }
    fn status(&self, owner: u64) -> Result<Status, CoreError> {
        Ok(self.owned(owner)?.status())
    }
    fn stop_request(&self, owner: u64) -> Status {
        let session = lock(&self.sessions).remove(&owner);
        session.map_or_else(Status::default, |session| {
            session.stop(None);
            session.status()
        })
    }
    fn stop(&self, root: &Path) -> Result<(), CoreError> {
        let root = dunce::canonicalize(root)?;
        for session in lock(&self.sessions).values().filter(|s| s.root == root) {
            session.stop(None);
        }
        Ok(())
    }
}

/// TEXLOCAL_TEXPRESSO, for development, else `texpresso` on the path.
pub(crate) fn discover(path_env: &str) -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("TEXLOCAL_TEXPRESSO").filter(|p| !p.is_empty()) {
        return program_at(Path::new(&override_path));
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
    if path.len() > 4096 || path.contains('\0') || text.contains('\0') {
        return Err(CoreError::bad_request(INVALID));
    }
    if let Some(known) = known.get(path) {
        return Ok(known.clone());
    }
    let path = root.join(paths::write_paths(root, path)?.1);
    if path.is_dir() {
        return Err(CoreError::bad_request(FOLDER));
    }
    Ok(path)
}
/// How many items two runs share at their start.
fn common<T: PartialEq>(a: impl Iterator<Item = T>, b: impl Iterator<Item = T>) -> usize {
    a.zip(b).take_while(|(a, b)| a == b).count()
}
/// The change from one whole text to the next, in bytes. It runs for whole texts only (an
/// open, a change on disk, an edit that didn't fit), never per key. Both boundaries must be
/// UTF-8 boundaries even when differing characters share leading or trailing bytes.
fn delta<'a>(old: &str, new: &'a str) -> (usize, usize, &'a str) {
    let (a, b) = (old.as_bytes(), new.as_bytes());
    let mut start = common(a.iter(), b.iter());
    while !old.is_char_boundary(start) || !new.is_char_boundary(start) {
        start -= 1;
    }
    let (a, b) = (&a[start..], &b[start..]);
    let mut suffix = common(a.iter().rev(), b.iter().rev());
    while !old.is_char_boundary(old.len() - suffix) || !new.is_char_boundary(new.len() - suffix) {
        suffix -= 1;
    }
    (
        start,
        old.len() - start - suffix,
        &new[start..new.len() - suffix],
    )
}
/// The session's one writer to TeXpresso's stdin: callers queue lines and go on, and a
/// TeXpresso that has stopped reading stops the session instead of holding them.
async fn write_lines(
    mut stdin: ChildStdin,
    mut queued: mpsc::UnboundedReceiver<Vec<u8>>,
    session: std::sync::Weak<Session>,
) {
    while let Some(lines) = queued.recv().await {
        let write = async {
            stdin.write_all(&lines).await?;
            stdin.flush().await
        };
        let written = match tokio::time::timeout(UNREAD, write).await {
            Ok(written) => written.map_err(|err| err.to_string()),
            Err(_) => Err("viewer stopped reading commands".to_owned()),
        };
        if let Err(err) = written {
            if let Some(session) = session.upgrade() {
                session.stop(Some(format!(
                    "Couldn't send changes to TeXpresso: {err}. Start TeXpresso again."
                )));
            }
            break;
        }
    }
}
async fn read_output(reader: impl AsyncRead + Unpin, session: Arc<Session>, protocol: bool) {
    let mut reader = tokio::io::BufReader::with_capacity(8192, reader);
    // The line read so far, cut at MAX_MESSAGE: one longer is no message.
    let mut pending = Vec::new();
    fn keep(pending: &mut Vec<u8>, bytes: &[u8]) {
        let room = MAX_MESSAGE.saturating_sub(pending.len());
        pending.extend_from_slice(&bytes[..bytes.len().min(room)]);
    }
    loop {
        let chunk = match reader.fill_buf().await {
            Ok([]) | Err(_) => break,
            Ok(chunk) => chunk,
        };
        let count = chunk.len();
        if !protocol {
            let mut state = lock(&session.state);
            let end = state.stderr.base + state.stderr.bytes.len() as u64;
            state.stderr.append(end, chunk);
            (session.sink)(LiveEvent::Log);
        } else {
            let mut rest = chunk;
            while let Some(end) = memchr::memchr(b'\n', rest) {
                keep(&mut pending, &rest[..end]);
                if let Ok(message) = serde_json::from_slice::<Value>(&pending) {
                    apply_message(&session, &message);
                }
                pending.clear();
                rest = &rest[end + 1..];
            }
            keep(&mut pending, rest);
        }
        reader.consume(count);
    }
}
fn apply_message(session: &Session, message: &Value) {
    if message[0] == "reset-sync" {
        let files = lock(&session.files);
        let texts = files.texts.iter();
        let messages: Vec<_> = texts.map(|(p, t)| json!(["open", p, t.string()])).collect();
        session.send(&messages);
        return;
    }
    let mut guard = lock(&session.state);
    let state = &mut *guard;
    let verb = message[0].as_str().unwrap_or_default();
    // A patched build's first word is that it sends pages.
    state.spoken = true;
    let number = |index: usize| message[index].as_u64();
    let event = match verb {
        "live" => {
            state.live = number(1).map(|version| version as u32);
            return;
        }
        // [page, index, path, ..]: one page, complete at a path in the session's folder.
        "page" => {
            let folder = session.pdf.as_deref().and_then(Path::parent);
            let path = message[2].as_str().filter(|path| {
                folder.is_some_and(|folder| Path::new(path).parent() == Some(folder))
            });
            let (Some(page), Some(path)) = (number(1), path) else {
                return;
            };
            LiveEvent::Page {
                page: page as u32,
                path: path.to_owned(),
            }
        }
        // [pdf, path, pages], and from a patched build [.., run, changed, ..]: the whole
        // document written to the path it was given.
        "pdf" => {
            let Some(pdf) = &session.pdf else {
                return;
            };
            let changed = message[4].as_array().map(|ranges| {
                let page = |range: &Value, at: usize| range[at].as_u64().unwrap_or(0) as u32;
                ranges.iter().map(|r| [page(r, 0), page(r, 1)]).collect()
            });
            LiveEvent::Document {
                path: pdf.to_string_lossy().into_owned(),
                pages: number(2).unwrap_or(0) as u32,
                run: message[3].as_str().map(str::to_owned),
                changed,
            }
        }
        // [done, pages, run]
        "done" => match message[2].as_str() {
            Some(run) => LiveEvent::Done(run.to_owned()),
            None => return,
        },
        // Upstream sends [truncate, buffer, end] and [append, buffer, byte-offset, text].
        "truncate" | "append" => {
            let output = match message[1].as_str() {
                Some("out") => &mut state.output,
                Some("log") => &mut state.log,
                _ => return,
            };
            match (verb, message[2].as_u64(), message[3].as_str()) {
                ("truncate", Some(end), _) => output.truncate(end),
                ("append", Some(offset), Some(text)) => output.append(offset, text.as_bytes()),
                _ => return,
            }
            state.protocol_seen = true;
            LiveEvent::Log
        }
        _ => return,
    };
    (session.sink)(event);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_deltas_reconstruct_text() {
        let pairs = [
            ("é😀tail", "ê😃tail"),
            ("é", ""),
            ("", "你好"),
            ("αtestβ", "αβ"),
            ("abc", "abc"),
        ];
        for padding in [0, 1, 63, 64, 65, 127, 128] {
            for (old, new) in pairs {
                let old = format!("{}{old}{}", "é".repeat(padding), "😀".repeat(padding));
                let new = format!("{}{new}{}", "é".repeat(padding), "😀".repeat(padding));
                let (start, remove, inserted) = delta(&old, &new);
                assert_eq!(
                    format!("{}{inserted}{}", &old[..start], &old[start + remove..]),
                    new
                );
            }
        }
    }
    #[test]
    fn bounded_output_keeps_offsets_after_backtracking() {
        let mut output = Output::default();
        output.append(0, &vec![b'x'; MAX_OUTPUT + 10]);
        assert_eq!(output.base, 10);
        output.append(12, b"ok");
        assert_eq!(output.text(), "xxok");
        output.truncate(0);
        output.append(0, "é".as_bytes());
        assert_eq!(output.text(), "é");
    }

    #[test]
    fn edits_in_utf16_units_change_the_same_bytes_as_in_a_plain_string() {
        // What the editor has: UTF-16 units. What TeXpresso takes: bytes. Counted
        // byte by byte, as decoding each character took most of the test's time: a
        // character starts at each byte that doesn't continue one, and is two units
        // where it takes four bytes.
        let bytes_at = |text: &str, units: usize| {
            let mut seen = 0;
            for (at, &byte) in text.as_bytes().iter().enumerate() {
                if byte & 0xC0 != 0x80 {
                    if seen == units {
                        return Some(at);
                    }
                    seen += 1 + usize::from(byte >= 0xF0);
                }
            }
            (seen == units).then_some(text.len())
        };
        let utf16_len = |text: &str| text.encode_utf16().count();
        let mut plain = "aé😀b\n".repeat(900);
        let mut text = Text::new(&plain);
        let mut seed = 7u64;
        let mut next = |below: usize| {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (seed >> 33) as usize % below.max(1)
        };
        let mut units = utf16_len(&plain);
        for round in 0..4000 {
            let start = next(units + 1);
            let remove = match round % 7 {
                0 => next(5000),
                1 => next(3),
                _ => 0,
            }
            .min(units - start);
            let inserted = [
                "x",
                "é",
                "😀",
                "",
                "\\section{Ünïcode 😀}\n",
                &"y".repeat(next(4000)),
            ][next(6)]
            .to_owned();
            let fits = bytes_at(&plain, start).zip(bytes_at(&plain, start + remove));
            let changed = text.edit(start, remove, &inserted);
            assert_eq!(changed, fits.map(|(from, to)| (from, to - from)), "{round}");
            if let Some((from, to)) = fits {
                plain.replace_range(from..to, &inserted);
                units = units - remove + utf16_len(&inserted);
            }
            assert_eq!(text.0.len_bytes(), plain.len());
            assert_eq!(text.byte_offset(start), bytes_at(&plain, start));
        }
        assert_eq!(text.string(), plain);
        let units = utf16_len(&plain);
        assert_eq!(text.edit(units + 1, 0, "x"), None);
        assert_eq!(text.edit(units, 1, ""), None);
        assert_eq!(text.edit(0, units + 1, ""), None);
        assert_eq!(text.string(), plain);
        let mut pair = Text::new("a😀b");
        assert_eq!(pair.edit(2, 0, "x"), None);
        assert_eq!(pair.edit(1, 1, ""), None);
        assert_eq!(pair.byte_offset(2), None);
        assert_eq!(pair.edit(1, 2, "é"), Some((1, 4)));
        assert_eq!(pair.string(), "aéb");
        let mut empty = Text::new("");
        assert_eq!(empty.edit(0, 0, "é"), Some((0, 0)));
        assert_eq!(empty.edit(1, 0, "x"), Some((2, 0)));
        assert_eq!(empty.string(), "éx");
    }

    /// A session of `root` that runs nothing.
    fn idle(root: PathBuf) -> Arc<Session> {
        Arc::new(Session {
            root,
            pdf: None,
            state: Mutex::default(),
            files: Mutex::default(),
            lines: mpsc::unbounded_channel().0,
            sink: Box::new(|_| {}),
        })
    }

    #[tokio::test]
    async fn output_is_read_a_line_at_a_time_and_an_overlong_line_is_no_message() {
        let session = idle(PathBuf::new());
        // Over many reads, the long line's end among them.
        let long = format!(r#"["append","out",3,"{}"]"#, "x".repeat(MAX_MESSAGE));
        let text = format!(
            "[\"append\",\"out\",0,\"rea\"]\n{long}\n[\"append\",\"out\",3,\"dy\"]\n[\"append\",\"log\",0,\"cut"
        );
        read_output(text.as_bytes(), Arc::clone(&session), true).await;
        // The last line never ended.
        let status = session.status();
        assert_eq!((status.output.as_str(), status.log.as_str()), ("ready", ""));
    }

    /// Through a stub TeXpresso, a shell script.
    #[cfg(unix)]
    mod stub {
        use super::*;

        fn setup() -> (tempfile::TempDir, PathBuf, String) {
            use std::os::unix::fs::PermissionsExt;
            let tmp = tempfile::tempdir().unwrap();
            let root = tmp.path().join("project");
            let bin = tmp.path().join("bin");
            fs::create_dir(&root).unwrap();
            fs::create_dir(&bin).unwrap();
            fs::write(root.join("main.tex"), "disk text").unwrap();
            let commands = tmp.path().join("commands");
            let child_pid = tmp.path().join("engine.pid");
            let stub = bin.join("texpresso");
            fs::write(&stub, format!(
                "#!/bin/sh\n/bin/sleep 300 &\necho $! > '{}'\nprintf '[\"append\",\"out\",0,\"ready\"]\\n'\nprintf '[\"pdf\",\"%s\",1]\\n' \"$TEXPRESSO_PDF_OUTPUT\"\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> '{}'\n  case \"$line\" in *EXIT_CLEAN*) exit 0;; *EXIT_STUB*) exit 7;;\n    *TEX_ERROR*) printf '[\"append\",\"log\",0,\"! Undefined control sequence.\"]\\n';; esac\ndone\n",
                child_pid.display(), commands.display()
            )).unwrap();
            fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
            (tmp, root, bin.to_string_lossy().into_owned())
        }
        const SOON: Duration = Duration::from_secs(3);
        async fn until(mut check: impl FnMut() -> bool) {
            tokio::time::timeout(SOON, async {
                while !check() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .expect("stub made progress");
        }
        fn commands(tmp: &tempfile::TempDir) -> Vec<Value> {
            fs::read_to_string(tmp.path().join("commands"))
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
        type Events = mpsc::UnboundedReceiver<LiveEvent>;
        /// A sink, and what it is sent.
        fn sink() -> (Sink, Events) {
            let (tx, rx) = mpsc::unbounded_channel();
            (Box::new(move |event| drop(tx.send(event))), rx)
        }
        /// The next event `wanted` takes, those before it passed over.
        async fn next(events: &mut Events, wanted: impl Fn(&LiveEvent) -> bool) -> LiveEvent {
            let next = async {
                loop {
                    let event = events.recv().await.expect("the session's events");
                    if wanted(&event) {
                        return event;
                    }
                }
            };
            tokio::time::timeout(SOON, next).await.expect("an event")
        }
        fn document(event: &LiveEvent) -> bool {
            matches!(event, LiveEvent::Document { .. })
        }
        /// Any event but the log's.
        fn shown(event: &LiveEvent) -> bool {
            *event != LiveEvent::Log
        }
        /// The project session numbered 1, a host's first.
        const OWNER: u64 = 1;
        /// A preview of `root` for `owner`, with `files` open and `pane` showing it.
        fn start(
            manager: &Manager,
            owner: u64,
            root: &Path,
            path_env: &str,
            files: &[FileBuffer],
            pane: Option<&Pane>,
        ) -> (Status, Events) {
            let (sink, events) = sink();
            let status = manager.start(owner, root, files, path_env, pane, sink);
            (status.unwrap(), events)
        }
        /// The user's Start, in the host's pane.
        fn begin(manager: &Manager, owner: u64, root: &Path, path_env: &str) -> Status {
            start(manager, owner, root, path_env, &[], Some(&Pane::default())).0
        }
        /// The status code of a refusal.
        fn refused<T>(result: Result<T, CoreError>) -> u16 {
            match result {
                Ok(_) => panic!("accepted"),
                Err(error) => error.status,
            }
        }
        /// `text` with a change TeXpresso was sent made to it.
        fn apply(text: &mut String, change: &Value) {
            let start = change[2].as_u64().unwrap() as usize;
            let end = start + change[3].as_u64().unwrap() as usize;
            text.replace_range(start..end, change[4].as_str().unwrap());
        }
        fn main_buffer(text: &str) -> Vec<FileBuffer> {
            vec![FileBuffer {
                path: "main.tex".into(),
                text: text.into(),
            }]
        }

        #[tokio::test]
        async fn the_vfs_has_the_editors_texts_and_each_whole_text_goes_as_a_change() {
            use std::os::unix::fs::PermissionsExt;
            let (tmp, root, path_env) = setup();
            let manager = Manager::default();
            // A main file named texpresso-live.tex builds this; live preview leaves it.
            fs::create_dir_all(root.join(BUILD_DIR)).unwrap();
            let normal = root.join(BUILD_DIR).join("texpresso-live.pdf");
            fs::write(&normal, "normal build").unwrap();
            let pane = Some(&Pane::default());
            let (first, mut events) =
                start(&manager, OWNER, &root, &path_env, &main_buffer("abc"), pane);
            assert!(first.running);
            // The session's own, outside the project: never a build's output.
            let LiveEvent::Document { path, .. } = next(&mut events, document).await else {
                unreachable!()
            };
            let pdf = PathBuf::from(path);
            assert!(
                pdf.ends_with("live.pdf") && !pdf.starts_with(dunce::canonicalize(&root).unwrap())
            );
            // In a shared temporary folder, for its owner alone.
            let folder = pdf.parent().unwrap().to_owned();
            let mode = fs::metadata(&folder).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);
            assert_eq!(fs::read(&normal).unwrap(), b"normal build");
            until(|| !commands(&tmp).is_empty()).await;
            let main = dunce::canonicalize(root.join("main.tex")).unwrap();
            assert_eq!(commands(&tmp)[0], json!(["open", main, "abc"]));
            // TeXpresso's copy, rebuilt from the changes it is sent; the same text again
            // sends none, and the disk keeps its own.
            let changes = || -> Vec<Value> {
                let sent = commands(&tmp).into_iter();
                sent.filter(|c| c[0] == "change").collect()
            };
            let mut text = String::from("abc");
            for edit in ["abXc", "aXc", "aXc", "aXcd"] {
                let sent = changes().len();
                manager.update(OWNER, "main.tex", edit).unwrap();
                if text != edit {
                    until(|| changes().len() > sent).await;
                    apply(&mut text, &changes().pop().unwrap());
                }
                assert_eq!(text, edit);
            }
            assert_eq!(changes().len(), 3);
            assert_eq!(fs::read_to_string(&main).unwrap(), "disk text");
            for (path, text) in [
                ("../escape.tex", "bad"),
                ("build/out.tex", "bad"),
                ("main.tex", "NUL\0"),
            ] {
                assert_eq!(refused(manager.update(OWNER, path, text)), 400);
            }
            manager.rescan(OWNER).unwrap();
            until(|| commands(&tmp).iter().any(|c| c[0] == "rescan")).await;
            assert!(!manager.stop_request(OWNER).running);
            assert!(!folder.exists());
            assert_eq!(refused(manager.status(OWNER)), 404);
            begin(&manager, OWNER, &root, &path_env);
            manager.kill_all();
            assert!(!manager.status(OWNER).unwrap().running);
        }

        /// The owner's preview before a start, of this project or another, is stopped.
        #[tokio::test]
        async fn a_start_stops_the_owners_preview_before_it() {
            let (_tmp, root, path_env) = setup();
            let (_other_tmp, other_root, _) = setup();
            let manager = Manager::default();
            begin(&manager, OWNER, &other_root, &path_env);
            let before = manager.owned(OWNER).unwrap();
            assert!(begin(&manager, OWNER, &root, &path_env).running);
            assert!(!before.running());
        }

        #[tokio::test]
        async fn an_exit_keeps_the_output_says_why_and_stops_the_engine_group() {
            let (tmp, root, path_env) = setup();
            let manager = Manager::default();
            let (_, mut events) = start(&manager, OWNER, &root, &path_env, &[], None);
            until(|| {
                fs::read_to_string(tmp.path().join("engine.pid")).is_ok()
                    && manager.status(OWNER).unwrap().output == "ready"
            })
            .await;
            let child_pid: i32 = fs::read_to_string(tmp.path().join("engine.pid"))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            manager.update(OWNER, "main.tex", "EXIT_STUB").unwrap();
            let ended = next(&mut events, |e| matches!(e, LiveEvent::Ended(_))).await;
            let LiveEvent::Ended(Some(error)) = ended else {
                panic!("{ended:?}")
            };
            assert!(error.contains("exited"), "{error}");
            let status = manager.status(OWNER).unwrap();
            assert!(!status.running && status.output == "ready");
            until(|| unsafe { libc::kill(child_pid, 0) == -1 }).await;
        }

        /// Without a pane TeXpresso shows the document in its own window: the session makes no
        /// folder for one, offers none, and tells TeXpresso no view or caret. The log still
        /// follows TeX.
        #[tokio::test]
        async fn in_texpressos_own_window_only_the_log_comes_and_no_view_or_caret_is_sent() {
            let (tmp, root, path_env) = setup();
            let manager = Manager::default();
            let files = main_buffer("abc");
            let (_, mut events) = start(&manager, OWNER, &root, &path_env, &files, None);
            assert!(manager.owned(OWNER).unwrap().pdf.is_none());
            manager.view(OWNER, 0, 1).unwrap();
            manager.caret(OWNER, "main.tex", 1).unwrap();
            until(|| manager.status(OWNER).unwrap().output == "ready").await;
            manager.update(OWNER, "main.tex", "TEX_ERROR").unwrap();
            until(|| manager.status(OWNER).unwrap().log.contains("! Undefined")).await;
            manager.update(OWNER, "main.tex", "EXIT_CLEAN").unwrap();
            // Its stub printed a document all the same, with no path to write it to.
            let mut seen = vec![next(&mut events, |_| true).await];
            while !matches!(seen.last(), Some(LiveEvent::Ended(_))) {
                seen.push(next(&mut events, |_| true).await);
            }
            assert_eq!(seen.pop(), Some(LiveEvent::Ended(None)));
            assert!(!seen.is_empty() && seen.iter().all(|e| *e == LiveEvent::Log));
            let sent = commands(&tmp);
            assert!(
                sent.iter().all(|c| c[0] != "view" && c[0] != "caret"),
                "{sent:?}"
            );
        }

        #[tokio::test]
        async fn the_log_follows_backtracking_and_has_the_programs_own_output_once_it_fails() {
            let (_tmp, root, path_env) = setup();
            let manager = Manager::default();
            begin(&manager, OWNER, &root, &path_env);
            let session = manager.owned(OWNER).unwrap();
            // Backtracking drops TeX's log, and the process's historical stderr is
            // not put in its place.
            let diagnostic = "Undefined control sequence";
            lock(&session.state).stderr.append(0, diagnostic.as_bytes());
            apply_message(&session, &json!(["append", "log", 0, diagnostic]));
            assert!(session.status().log.contains(diagnostic));
            apply_message(&session, &json!(["truncate", "log", 0]));
            assert!(!session.status().log.contains(diagnostic));

            session.stop(Some("TeXpresso exited".into()));
            let status = manager.status(OWNER).unwrap();
            assert!(!status.running && status.error.is_some());
            // Ended with an error, the log has that stderr after all.
            assert!(status.log.contains(diagnostic));
        }

        /// A stub that speaks as a build with Underleaf's patch does: it says so first, writes
        /// "the document", answers each change with page 1 in a file of its own, and a request
        /// for a finishing pass with a new document.
        fn setup_live() -> (tempfile::TempDir, PathBuf, String) {
            let (tmp, root, path_env) = setup();
            let stub = tmp.path().join("bin/texpresso");
            fs::write(&stub, format!(
                concat!(
                    "#!/bin/sh\ndir=${{TEXPRESSO_PDF_OUTPUT%/*}}\nn=0\n",
                    "printf '[\"live\",1]\\n[\"pdf\",\"%s\",3,\"partial\",[[0,2]],0]\\n' \"$TEXPRESSO_PDF_OUTPUT\"\n",
                    "while IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> '{}'\n",
                    "  case \"$line\" in\n",
                    "    '[\"change\",'*) n=$((n + 1))\n",
                    "      printf '[\"page\",1,\"%s/page-1-%s.pdf\",0]\\n' \"$dir\" \"$n\";;\n",
                    "    *rerun-once*) printf '[\"pdf\",\"%s\",4,\"complete\",[[1,1],[3,3]],0]\\n[\"done\",4,\"complete\"]\\n' \"$TEXPRESSO_PDF_OUTPUT\";;\n",
                    "  esac\ndone\n"
                ),
                tmp.path().join("commands").display()
            )).unwrap();
            (tmp, root, path_env)
        }

        #[tokio::test]
        async fn a_keystroke_goes_as_bytes_at_once_and_one_that_does_not_fit_is_refused() {
            let (tmp, root, path_env) = setup_live();
            let manager = Manager::default();
            let pane = Pane {
                view: Some((2, 3)),
                caret: Some(("main.tex".into(), 4)),
            };
            let files = main_buffer("aé😀b");
            start(&manager, OWNER, &root, &path_env, &files, Some(&pane));
            let path = dunce::canonicalize(root.join("main.tex")).unwrap();
            // Four units in: after a, é and the pair, seven bytes in.
            manager.edit(OWNER, "main.tex", 4, 0, "X").unwrap();
            manager.edit(OWNER, "main.tex", 1, 3, "").unwrap();
            manager.view(OWNER, 5, 4).unwrap();
            manager.caret(OWNER, "main.tex", 2).unwrap();
            until(|| commands(&tmp).len() >= 7).await;
            let sent = commands(&tmp);
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
            // No finishing passes of upstream's kind, which start the document over.
            assert!(!sent.iter().any(|c| c[0] == "rerun"));

            // The copy is "aXb" now: nothing below is in it, and nothing is sent or changed.
            for (file, start, remove) in
                [("main.tex", 4, 0), ("main.tex", 2, 2), ("other.tex", 0, 0)]
            {
                assert_eq!(refused(manager.edit(OWNER, file, start, remove, "no")), 412);
            }
            assert_eq!(refused(manager.caret(OWNER, "main.tex", 9)), 412);
            assert_eq!(refused(manager.edit(OWNER, "main.tex", 0, 0, "\0")), 400);
            assert_eq!(refused(manager.edit(OWNER + 1, "main.tex", 0, 0, "x")), 404);
            // The whole text puts the copy right, sent as the change from what TeXpresso has.
            manager.update(OWNER, "main.tex", "aXb😀").unwrap();
            manager.edit(OWNER, "main.tex", 5, 0, "!").unwrap();
            until(|| commands(&tmp).len() >= 9).await;
            assert_eq!(
                commands(&tmp)[7..],
                [
                    json!(["change", path, 3, 0, "😀"]),
                    json!(["change", path, 7, 0, "!"]),
                ]
            );
            // A session that has ended takes an edit as nothing, and refuses none.
            manager.stop(&root).unwrap();
            manager.edit(OWNER, "main.tex", 0, 0, "x").unwrap();
        }

        #[tokio::test]
        async fn pages_and_documents_come_as_typeset_and_the_end_after_them() {
            let (_tmp, root, path_env) = setup_live();
            let manager = Manager::default();
            let pane = Some(&Pane::default());
            let files = main_buffer("abc");
            let (_, mut events) = start(&manager, OWNER, &root, &path_env, &files, pane);
            let session = manager.owned(OWNER).unwrap();
            // The build says what it speaks, then the first document.
            let first = next(&mut events, document).await;
            assert_eq!(lock(&session.state).live, Some(1));
            let LiveEvent::Document {
                path,
                pages: 3,
                run,
                changed,
            } = first
            else {
                panic!("{first:?}")
            };
            assert_eq!(
                (run.as_deref(), changed),
                (Some("partial"), Some(vec![[0, 2]]))
            );
            assert!(manager.live_pdf(OWNER).is_err(), "no SyncTeX yet");
            // Each edit's page as it comes, from the session's folder.
            let folder = PathBuf::from(&path).parent().unwrap().to_owned();
            for n in 1..=2 {
                manager.edit(OWNER, "main.tex", 3, 0, "d").unwrap();
                let page = next(&mut events, shown).await;
                let path = folder.join(format!("page-1-{n}.pdf"));
                let path = path.to_string_lossy().into_owned();
                assert_eq!(page, LiveEvent::Page { page: 1, path });
            }
            // A page file from outside the session's folder is nobody's page.
            apply_message(&session, &json!(["page", 0, "/etc/passwd", 0]));
            // A finishing pass: the document, then the run's end.
            session.send(&[json!(["rerun-once"])]);
            let whole = LiveEvent::Document {
                path,
                pages: 4,
                run: Some("complete".into()),
                changed: Some(vec![[1, 1], [3, 3]]),
            };
            assert_eq!(next(&mut events, shown).await, whole);
            let done = next(&mut events, shown).await;
            assert_eq!(done, LiveEvent::Done("complete".into()));
            manager.stop(&root).unwrap();
            assert_eq!(next(&mut events, shown).await, LiveEvent::Ended(None));
        }

        #[tokio::test]
        async fn a_build_that_only_writes_the_document_is_sent_nothing_it_does_not_know() {
            let (tmp, root, path_env) = setup();
            let manager = Manager::default();
            let pane = Some(&Pane::default());
            let files = main_buffer("abc");
            let (_, mut events) = start(&manager, OWNER, &root, &path_env, &files, pane);
            // No word of pages before the document: the build is an older one.
            let first = next(&mut events, document).await;
            let live = lock(&manager.owned(OWNER).unwrap().state).live;
            assert!(live.is_none());
            assert!(matches!(
                first,
                LiveEvent::Document {
                    pages: 1,
                    run: None,
                    changed: None,
                    ..
                }
            ));
            manager.edit(OWNER, "main.tex", 3, 0, "d").unwrap();
            manager.view(OWNER, 0, 1).unwrap();
            manager.caret(OWNER, "main.tex", 1).unwrap();
            until(|| commands(&tmp).iter().any(|c| c[0] == "change")).await;
            manager.rescan(OWNER).unwrap();
            until(|| commands(&tmp).iter().any(|c| c[0] == "rescan")).await;
            let verbs: Vec<_> = commands(&tmp)
                .iter()
                .map(|c| c[0].as_str().unwrap().to_owned())
                .collect();
            assert_eq!(verbs, ["open", "change", "rescan"]);
        }
    }
}
