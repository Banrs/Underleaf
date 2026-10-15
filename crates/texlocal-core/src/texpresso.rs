//! Optional persistent TeXpresso viewer. Author buffers stay in its VFS; the
//! ordinary latexmk build and PDF continue to use saved project files.
//!
//! A build with Underleaf's patch (tools/texpresso) shows nothing itself: it writes the
//! pages the client says it is showing as one-page PDFs the moment they are typeset again,
//! and the whole document when a run has ended. `Manager::wait` hands those to the client
//! as they come; `Manager::edit` takes a keystroke without waiting for anything.
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ropey::Rope;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt};
use tokio::process::ChildStdin;
use tokio::sync::mpsc;

use crate::atomic::Stamp;
use crate::compile::{Tree, find_tool, program_at};
use crate::{BUILD_DIR, CoreError, SETTINGS_FILE, lock, paths, settings, tail};

const MAX_FILE: usize = 8 * 1024 * 1024;
const MAX_FILES: usize = 256;
const MAX_TOTAL: usize = 64 * 1024 * 1024;
const MAX_OUTPUT: usize = 128 * 1024;
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
const LEASE: Duration = Duration::from_secs(120);
/// How long TeXpresso may leave what it was sent unread before the session is given up:
/// it reads nothing while it makes its TeX formats, five seconds and more the first time.
const UNREAD: Duration = Duration::from_secs(60);
/// The longest `wait` waits, well inside the lease it renews.
const MAX_WAIT: Duration = Duration::from_secs(60);
const MISSING: &str = if cfg!(windows) {
    "TeXpresso wasn't found. Choose the folder it's in, in Settings."
} else {
    "TeXpresso wasn't found. Choose the folder it's in, in Settings, or install it in /opt/homebrew/bin or /usr/local/bin."
};
const REPLACED: &str =
    "Another window started TeXpresso for this project. Start TeXpresso again to preview here.";
const TOO_MANY: &str = "Too many files for TeXpresso (limit 256 files / 64 MB).";
const TOO_LARGE: &str = "TeXpresso takes files of up to 8 MB.";
const UNFIT: &str = "The edit doesn't fit the text TeXpresso has. Send the whole text.";
const INVALID: &str = "A file sent to TeXpresso has an invalid path or text.";

#[derive(Debug, Deserialize)]
pub struct FileBuffer {
    pub path: String,
    pub text: String,
}

/// A place in a file, in UTF-16 units as the editors count.
#[derive(Debug, Deserialize)]
pub struct Caret {
    pub path: String,
    pub offset: usize,
}

/// The client's pane: the pages it shows there, from 0, and where its caret is, for a
/// build with Underleaf's patch to have those pages first and a snapshot ready where the
/// first key will land.
#[derive(Debug, Default)]
pub struct Pane {
    pub view: Option<(u32, u32)>,
    pub caret: Option<Caret>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub available: bool,
    pub running: bool,
    pub log: String,
    pub output: String,
    pub error: Option<String>,
    pub revision: u64,
    pub session: Option<String>,
}

/// A page typeset again, alone in a PDF that is complete on disk.
#[derive(Debug, Clone, Serialize)]
pub struct PageUpdate {
    /// From 0.
    pub page: u32,
    pub path: String,
    /// Rises with every event of the session: a later page or document has a higher one.
    pub serial: u64,
    /// The last edit (`Manager::edit`'s number) the page shows.
    pub edit: u64,
}

/// The whole document, complete on disk, its SyncTeX beside it.
#[derive(Debug, Clone, Serialize)]
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
    pub edit: u64,
}

/// A run of TeX that is over.
#[derive(Debug, Clone, Serialize)]
pub struct RunEnd {
    pub pages: u32,
    /// `complete` or `stopped`, as `Document::run`.
    pub run: String,
}

/// `Manager::update`'s answer: the edit's number, 0 when the text is as TeXpresso has it,
/// and the session's status unless the client asked for the number alone.
#[derive(Debug, Serialize)]
pub struct Updated {
    pub edit: u64,
    #[serde(flatten)]
    pub status: Option<Status>,
}

/// What is new for a client since the `seq` it last had (`Manager::wait`).
#[derive(Debug, Clone, Serialize)]
pub struct Events {
    pub seq: u64,
    pub running: bool,
    pub error: Option<String>,
    /// 1 from a build that sends pages as they change; None from one that only writes the
    /// whole document, known once the first document has come.
    pub live: Option<u32>,
    /// `Status::revision`: when it has risen, the log or output may have changed.
    pub revision: u64,
    /// The last edit whose effect on the pages in view has been sent, changed or not.
    pub synced: u64,
    /// The document, when a new one was written; it comes before `pages`.
    pub pdf: Option<Document>,
    /// The latest of each page written since `pdf`, lowest page first.
    pub pages: Vec<PageUpdate>,
    pub done: Option<RunEnd>,
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
    fn bytes(&self) -> usize {
        self.0.len_bytes()
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

/// The events a client hasn't had yet, each with the `seq` it came at.
#[derive(Default)]
struct Feed {
    seq: u64,
    pages: BTreeMap<u32, PageUpdate>,
    document: Option<Document>,
    done: Option<(u64, RunEnd)>,
    synced: u64,
}

struct State {
    tree: Option<Tree>,
    last_used: Instant,
    output: Output,
    log: Output,
    protocol_seen: bool,
    stderr: Output,
    error: Option<String>,
    revision: u64,
    pdf_version: u64,
    /// The settings file as last seen, by `settings_stamp`.
    settings: Option<Stamp>,
    /// Whether TeXpresso has said anything, and the page protocol it said it speaks.
    spoken: bool,
    live: Option<u32>,
    feed: Feed,
    /// Edits sent, each followed by its number for TeXpresso to say what shows it.
    edits: u64,
}
#[derive(Default)]
struct Files {
    texts: HashMap<PathBuf, Text>,
    /// Where the paths clients send lead, found once: a session's files
    /// don't move under it, as a rename or delete stops it.
    paths: HashMap<String, PathBuf>,
    bytes: usize,
}
struct Session {
    token: String,
    executable: PathBuf,
    main: String,
    /// Where a patched build writes the document, in a folder of the session's own.
    pdf: PathBuf,
    state: Mutex<State>,
    /// Never held across a wait: a keystroke takes it on the editor's own thread.
    files: Mutex<Files>,
    /// Lines for TeXpresso's stdin, written in order by the session's writer.
    lines: mpsc::UnboundedSender<Vec<u8>>,
    changed: tokio::sync::Notify,
    revision: Arc<AtomicU64>,
}
impl Session {
    fn bump(&self, state: &mut State) {
        state.revision = self.revision.fetch_add(1, Ordering::Relaxed) + 1;
    }
    /// Something a waiting client is told at once. Its number.
    fn event(&self, state: &mut State) -> u64 {
        self.bump(state);
        state.feed.seq += 1;
        self.changed.notify_waiters();
        state.feed.seq
    }
    /// For its owner: renew the lease, and stop if the main file has changed
    /// since the start. Whether it still runs.
    fn renew(&self, root: &Path) -> bool {
        let stamp = settings_stamp(root);
        let seen = {
            let mut state = lock(&self.state);
            state.last_used = Instant::now();
            std::mem::replace(&mut state.settings, stamp)
        };
        if seen != stamp && settings::read_settings(root).main_file != self.main {
            self.stop(Some("The main file changed. Start TeXpresso again.".into()));
        }
        lock(&self.state).tree.is_some()
    }
    fn stop(&self, error: Option<String>) {
        let mut state = lock(&self.state);
        if let Some(tree) = state.tree.take() {
            // The viewer starts an engine: stopping just its parent leaks it.
            tree.kill();
            remove_pdf_folder(&self.pdf);
            state.error = error;
            self.event(&mut state);
            if let Ok(mut files) = self.files.try_lock() {
                files.texts.clear();
                files.bytes = 0;
            }
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
            log = tail(&log, MAX_OUTPUT).to_owned();
        }
        Status {
            available: program_at(&self.executable).is_some(),
            running: state.tree.is_some(),
            output: state.output.text(),
            log,
            error: state.error.clone(),
            revision: state.revision,
            session: Some(self.token.clone()),
        }
    }
    fn events(&self, state: &State, after: u64) -> Events {
        let feed = &state.feed;
        let new = |serial: u64| serial > after;
        Events {
            seq: feed.seq,
            running: state.tree.is_some(),
            error: state.error.clone(),
            live: state.live,
            revision: state.revision,
            synced: feed.synced,
            pdf: feed.document.clone().filter(|d| new(d.serial)),
            pages: feed
                .pages
                .values()
                .filter(|p| new(p.serial))
                .cloned()
                .collect(),
            done: feed
                .done
                .as_ref()
                .filter(|(serial, _)| new(*serial))
                .map(|(_, end)| end.clone()),
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
    /// The number of a new edit, with the message that has a build that sends pages say
    /// when they show it.
    fn mark(&self, messages: &mut Vec<Value>) -> u64 {
        let mut state = lock(&self.state);
        state.edits += 1;
        if self.sends_pages(&state) {
            messages.push(json!(["mark", state.edits]));
        }
        state.edits
    }
    /// Whether to send what only a build that sends pages knows: it has said it is one,
    /// or nothing at all yet. Another would only report a command it doesn't know.
    fn sends_pages(&self, state: &State) -> bool {
        state.live.is_some() || !state.spoken
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.stop(None);
        remove_pdf_folder(&self.pdf);
    }
}
fn remove_pdf_folder(pdf: &Path) {
    if let Some(folder) = pdf.parent() {
        let _ = fs::remove_dir_all(folder);
    }
}

#[derive(Default)]
pub struct Manager {
    sessions: Mutex<HashMap<PathBuf, Arc<Session>>>,
    requests: tokio::sync::Mutex<()>,
    revision: Arc<AtomicU64>,
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
    /// None is reserved for an explicitly requested global Stop. Automatic
    /// cleanup always supplies the owner's token.
    pub async fn stop_request(
        &self,
        root: &Path,
        token: Option<&str>,
        path_env: &str,
    ) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = dunce::canonicalize(root)?;
        let Some(session) = self.session(&root, token)? else {
            return Ok(self.idle(path_env));
        };
        session.stop(None);
        // Explicit Stop ends ownership too; internal host invalidation
        // uses stop(root), retaining identity for a conditional restart.
        lock(&self.sessions).remove(&root);
        Ok(session.status())
    }
    /// The live document the client's session last wrote, which has its SyncTeX beside it.
    pub fn live_pdf(&self, root: &Path, token: &str) -> Result<PathBuf, CoreError> {
        let session = self.owned(&dunce::canonicalize(root)?, token)?;
        let state = lock(&session.state);
        Some(&session.pdf)
            .filter(|pdf| state.pdf_version > 0 && pdf.with_extension("synctex").is_file())
            .cloned()
            .ok_or_else(|| {
                CoreError::not_found("TeXpresso hasn't written a document to sync with yet")
            })
    }
    fn owned(&self, root: &Path, token: &str) -> Result<Arc<Session>, CoreError> {
        lock(&self.sessions)
            .get(root)
            .filter(|session| session.token == token)
            .cloned()
            .ok_or_else(|| CoreError::conflict(REPLACED))
    }
    /// The session a token is for, without the disk: its token is its owner's alone.
    fn held(&self, token: &str) -> Result<Arc<Session>, CoreError> {
        lock(&self.sessions)
            .values()
            .find(|session| session.token == token)
            .cloned()
            .ok_or_else(|| CoreError::conflict(REPLACED))
    }
    /// The project's session; with a token, only while that client still owns it.
    fn session(&self, root: &Path, token: Option<&str>) -> Result<Option<Arc<Session>>, CoreError> {
        match token {
            Some(token) => self.owned(root, token).map(Some),
            None => Ok(lock(&self.sessions).get(root).cloned()),
        }
    }
    pub fn stop(&self, root: &Path) -> Result<(), CoreError> {
        let root = dunce::canonicalize(root)?;
        let session = lock(&self.sessions).get(&root).cloned();
        if let Some(session) = session {
            session.stop(None);
        }
        Ok(())
    }
    fn idle(&self, path_env: &str) -> Status {
        Status {
            available: discover(path_env).is_some(),
            running: false,
            log: String::new(),
            output: String::new(),
            error: None,
            revision: self.revision.load(Ordering::Relaxed),
            session: None,
        }
    }
    /// Inspection does not acquire ownership or renew the viewer's lease. The
    /// PATH is built only when no session answers: a client polls this while
    /// its session runs, and the PATH reads the app's settings and TeX's folders.
    pub fn status<P: AsRef<str>>(
        &self,
        root: &Path,
        token: Option<&str>,
        path_env: impl FnOnce() -> P,
    ) -> Result<Status, CoreError> {
        let root = dunce::canonicalize(root)?;
        let Some(session) = self.session(&root, token)? else {
            return Ok(self.idle(path_env().as_ref()));
        };
        if token.is_some() {
            session.renew(&root);
        }
        Ok(session.status())
    }
    /// A build with Underleaf's patch writes the document for the client's `pane`;
    /// upstream opens its own window all the same.
    pub async fn start(
        &self,
        root: &Path,
        files: &[FileBuffer],
        expected: Option<&str>,
        path_env: &str,
        pane: &Pane,
    ) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = dunce::canonicalize(root)?;
        // Automatic restart may only replace the same owner; an explicit user
        // Start omits the expectation to deliberately take over the project.
        if let Some(token) = expected {
            self.owned(&root, token)?;
        }
        let stamp = settings_stamp(&root);
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
            buffers.bytes += file.text.len();
            if buffers.texts.insert(path, Text::new(&file.text)).is_some() {
                return Err(CoreError::bad_request(
                    "Files sent to TeXpresso repeat a path.",
                ));
            }
        }
        check_limits(buffers.texts.len(), buffers.bytes)?;
        let failed = |error: String| {
            Ok(Status {
                error: Some(error),
                ..self.idle(path_env)
            })
        };
        let Some(executable) = discover(path_env) else {
            return failed(MISSING.into());
        };
        let build = paths::safe_path(&root, BUILD_DIR)?;
        fs::create_dir_all(&build)?;
        let build = dunce::canonicalize(build)?;
        self.stop(&root)?;
        let token = crate::random_hex(16)?;
        // The session's own folder, for its owner alone: no build output or
        // other session shares it. The session removes it as it stops.
        let folder = tempfile::Builder::new()
            .prefix("texlocal-texpresso-")
            .tempdir()?
            .keep();
        let pdf = dunce::canonicalize(folder)?.join("live.pdf");
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
        command.env("TEXPRESSO_PDF_OUTPUT", &pdf);
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
                libc::sigemptyset(&mut none);
                libc::sigprocmask(libc::SIG_SETMASK, &none, std::ptr::null_mut());
                Ok(())
            });
        }
        let (mut child, tree) = match Tree::spawn(&mut command) {
            Ok(spawned) => spawned,
            Err(err) => {
                remove_pdf_folder(&pdf);
                return failed(format!(
                    "Couldn't start TeXpresso: {err}. Check TEXLOCAL_TEXPRESSO and its dependencies."
                ));
            }
        };
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let (lines, queued) = mpsc::unbounded_channel();
        // Where the caret is in bytes, as TeXpresso counts, from the text just sent.
        let caret = pane.caret.as_ref().and_then(|caret| {
            let path = buffers.paths.get(&caret.path)?;
            let offset = buffers.texts.get(path)?.byte_offset(caret.offset)?;
            Some(json!(["caret", path, offset]))
        });
        let session = Arc::new(Session {
            token,
            executable,
            main,
            pdf,
            files: Mutex::new(buffers),
            lines,
            changed: tokio::sync::Notify::new(),
            revision: Arc::clone(&self.revision),
            state: Mutex::new(State {
                tree: Some(tree),
                last_used: Instant::now(),
                output: Output::default(),
                log: Output::default(),
                protocol_seen: false,
                stderr: Output::default(),
                error: None,
                revision: self.revision.fetch_add(1, Ordering::Relaxed) + 1,
                pdf_version: 0,
                settings: stamp,
                spoken: false,
                live: None,
                feed: Feed::default(),
                edits: 0,
            }),
        });
        {
            let mut sessions = lock(&self.sessions);
            if self.shutdown.load(Ordering::Acquire) {
                session.stop(None);
            }
            sessions.insert(root, Arc::clone(&session));
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
            loop {
                tokio::select! {
                    result = child.wait() => {
                        if let Some(session) = weak.upgrade() {
                            let error = match result {
                                Ok(status) if status.success() => None,
                                result => Some(format!("TeXpresso exited ({}). Check its log and start TeXpresso again.",
                                    result.map(|s| s.to_string()).unwrap_or_else(|e| e.to_string()))),
                            };
                            session.stop(error);
                        }
                        break;
                    }
                    _ = tokio::time::sleep(Duration::from_secs(5)) => {
                        let Some(session) = weak.upgrade() else { break; };
                        let expired = lock(&session.state).last_used.elapsed() >= LEASE;
                        if expired { session.stop(Some("The TeXpresso session expired. Start TeXpresso again.".into())); }
                    }
                }
            }
        });
        // TeXpresso's idle reruns stay off: each starts TeX again from nothing after a pause
        // in typing and shows no page until it is over. A build that sends pages makes its
        // finishing passes beside the document.
        if let Some((first, last)) = pane.view {
            opened.push(json!(["view", first, last.max(first)]));
        }
        opened.extend(caret);
        session.send(&opened);
        Ok(session.status())
    }
    /// The whole text of a file: sent as the change from the buffer TeXpresso has, or
    /// whole when it has none. It is also what repairs a copy `edit` refused to change.
    /// `brief` leaves the status, and the log in it, out of the answer.
    pub async fn update(
        &self,
        root: &Path,
        rel: &str,
        text: &str,
        token: &str,
        brief: bool,
    ) -> Result<Updated, CoreError> {
        let _request = self.requests.lock().await;
        let root = dunce::canonicalize(root)?;
        let session = self.owned(&root, token)?;
        let updated = |edit| Updated {
            edit,
            status: (!brief).then(|| session.status()),
        };
        if !session.renew(&root) {
            return Ok(updated(0));
        }
        let edit = {
            let mut files = lock(&session.files);
            let files = &mut *files;
            let path = validate_buffer(&root, rel, text, &files.paths)?;
            let previous = files.texts.get(&path).map(Text::string);
            let held = previous.as_ref().map_or(0, String::len);
            check_limits(
                files.texts.len() + usize::from(previous.is_none()),
                files.bytes - held + text.len(),
            )?;
            let message = match previous.as_deref().map(|previous| delta(previous, text)) {
                Some((_, 0, "")) => None,
                Some((offset, remove, inserted)) => {
                    Some(json!(["change", path, offset, remove, inserted]))
                }
                None => Some(json!(["open", path, text])),
            };
            match message {
                Some(message) => {
                    let mut messages = vec![message];
                    let edit = session.mark(&mut messages);
                    session.send(&messages);
                    files.paths.insert(rel.to_owned(), path.clone());
                    files.bytes = files.bytes - held + text.len();
                    files.texts.insert(path, Text::new(text));
                    edit
                }
                None => 0,
            }
        };
        if edit > 0 {
            session.bump(&mut lock(&session.state));
        }
        Ok(updated(edit))
    }
    /// A keystroke, as the editor has it: `remove` UTF-16 units at `start` of a file the
    /// session has, replaced by `text`. It waits for nothing (no disk, no TeXpresso), so
    /// the editor can call it where the edit is made. Its number, which `Events::synced`
    /// reaches when the pages in view show it; 0 for a session that has ended. An edit
    /// that doesn't fit the session's copy is refused with status 412 and changes nothing:
    /// `update` with the whole text then puts both right.
    pub fn edit(
        &self,
        token: &str,
        rel: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<u64, CoreError> {
        let session = self.held(token)?;
        if text.contains('\0') {
            return Err(CoreError::bad_request(INVALID));
        }
        let mut files = lock(&session.files);
        let files = &mut *files;
        {
            let mut state = lock(&session.state);
            state.last_used = Instant::now();
            if state.tree.is_none() {
                return Ok(0);
            }
        }
        let unfit = || CoreError::unfit(UNFIT);
        let path = files.paths.get(rel).ok_or_else(unfit)?;
        let held = files.texts.get_mut(path).ok_or_else(unfit)?;
        if held.bytes() + text.len() > MAX_FILE {
            return Err(CoreError::bad_request(TOO_LARGE));
        }
        if files.bytes + text.len() > MAX_TOTAL {
            return Err(CoreError::bad_request(TOO_MANY));
        }
        let before = held.bytes();
        let (offset, removed) = held.edit(start, remove, text).ok_or_else(unfit)?;
        files.bytes = files.bytes - before + held.bytes();
        let mut messages = vec![json!(["change", path, offset, removed, text])];
        let edit = session.mark(&mut messages);
        session.send(&messages);
        Ok(edit)
    }
    /// The pages the client shows, from 0: a patched build typesets as far as the last of
    /// them first, and sends each as it changes.
    pub fn view(&self, token: &str, first: u32, last: u32) -> Result<(), CoreError> {
        let session = self.held(token)?;
        if session.sends_pages(&lock(&session.state)) {
            session.send(&[json!(["view", first, last.max(first)])]);
        }
        Ok(())
    }
    /// Where the client's caret has settled: a patched build takes a snapshot there, so
    /// the first key typed there is answered as quickly as the ones after it. Refused as
    /// `edit` is for a file or place the session's copy doesn't have.
    pub fn caret(&self, token: &str, rel: &str, offset: usize) -> Result<(), CoreError> {
        let session = self.held(token)?;
        let files = lock(&session.files);
        let unfit = || CoreError::unfit(UNFIT);
        let path = files.paths.get(rel).ok_or_else(unfit)?;
        let text = files.texts.get(path).ok_or_else(unfit)?;
        let offset = text.byte_offset(offset).ok_or_else(unfit)?;
        if session.sends_pages(&lock(&session.state)) {
            session.send(&[json!(["caret", path, offset])]);
        }
        Ok(())
    }
    /// Waits until the session has something a client at `after` hasn't had (`Events`),
    /// it ends, or `timeout` passes, and answers with what is new; other calls go on
    /// meanwhile. `after` is the `seq` of the last answer, 0 at first.
    pub async fn wait(
        &self,
        root: &Path,
        token: &str,
        after: u64,
        timeout: Duration,
    ) -> Result<Events, CoreError> {
        let root = dunce::canonicalize(root)?;
        let session = self.owned(&root, token)?;
        session.renew(&root);
        let deadline = tokio::time::Instant::now() + timeout.min(MAX_WAIT);
        loop {
            let changed = session.changed.notified();
            tokio::pin!(changed);
            // Listening before the look: an event in between isn't missed.
            changed.as_mut().enable();
            {
                let mut state = lock(&session.state);
                state.last_used = Instant::now();
                // A `seq` from another session is no place in this one's events.
                let after = if after > state.feed.seq { 0 } else { after };
                if state.feed.seq > after
                    || state.tree.is_none()
                    || tokio::time::Instant::now() >= deadline
                {
                    return Ok(session.events(&state, after));
                }
            }
            let _ = tokio::time::timeout_at(deadline, changed).await;
        }
    }
    pub async fn rescan(&self, root: &Path, token: &str) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = dunce::canonicalize(root)?;
        let session = self.owned(&root, token)?;
        if session.renew(&root) {
            session.send(&[json!(["rescan"])]);
        }
        Ok(session.status())
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
    fs::metadata(root.join(SETTINGS_FILE))
        .ok()
        .map(|meta| Stamp::of(&meta))
}
fn check_limits(files: usize, bytes: usize) -> Result<(), CoreError> {
    if files > MAX_FILES || bytes > MAX_TOTAL {
        return Err(CoreError::bad_request(TOO_MANY));
    }
    Ok(())
}
/// How many items two runs share at their start.
fn common<T: PartialEq>(a: impl Iterator<Item = T>, b: impl Iterator<Item = T>) -> usize {
    a.zip(b).take_while(|(a, b)| a == b).count()
}
/// Compared a block at a time, which compiles to one memcmp each: byte by
/// byte, the whole of a large file would be a loop of single compares.
const BLOCK: usize = 256;
fn common_prefix(a: &[u8], b: &[u8]) -> usize {
    let blocks = common(
        a.as_chunks::<BLOCK>().0.iter(),
        b.as_chunks::<BLOCK>().0.iter(),
    );
    let start = blocks * BLOCK;
    start + common(a[start..].iter(), b[start..].iter())
}
fn common_suffix(a: &[u8], b: &[u8]) -> usize {
    let blocks = common(
        a.as_rchunks::<BLOCK>().1.iter().rev(),
        b.as_rchunks::<BLOCK>().1.iter().rev(),
    );
    let end = blocks * BLOCK;
    let (a, b) = (&a[..a.len() - end], &b[..b.len() - end]);
    end + common(a.iter().rev(), b.iter().rev())
}
// Both boundaries must be UTF-8 boundaries even when differing codepoints
// share leading or trailing bytes.
fn delta<'a>(old: &str, new: &'a str) -> (usize, usize, &'a str) {
    let (a, b) = (old.as_bytes(), new.as_bytes());
    let mut start = common_prefix(a, b);
    while !old.is_char_boundary(start) || !new.is_char_boundary(start) {
        start -= 1;
    }
    let mut suffix = common_suffix(&a[start..], &b[start..]);
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
        let written = tokio::time::timeout(UNREAD, write)
            .await
            .unwrap_or_else(|_| {
                Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "viewer stopped reading commands",
                ))
            });
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
            session.bump(&mut state);
        } else {
            let mut rest = chunk;
            while let Some(end) = memchr::memchr(b'\n', rest) {
                keep(&mut pending, &rest[..end]);
                if let Ok(message) = serde_json::from_slice::<Value>(&pending) {
                    receive(&session, &message);
                }
                pending.clear();
                rest = &rest[end + 1..];
            }
            keep(&mut pending, rest);
        }
        reader.consume(count);
    }
}
fn receive(session: &Session, message: &Value) {
    if message[0] == "reset-sync" {
        let files = lock(&session.files);
        let messages: Vec<_> = files
            .texts
            .iter()
            .map(|(p, t)| json!(["open", p, t.string()]))
            .collect();
        session.send(&messages);
    } else {
        apply_message(session, message);
    }
}
fn apply_message(session: &Session, message: &Value) {
    let mut guard = lock(&session.state);
    let state = &mut *guard;
    let verb = message[0].as_str().unwrap_or_default();
    // A patched build's first word is that it sends pages.
    state.spoken = true;
    let number = |index: usize| message[index].as_u64();
    match verb {
        "live" => {
            state.live = number(1).map(|version| version as u32);
            session.event(state);
            return;
        }
        // [page, index, path, mark]: one page, complete at a path in the session's folder.
        "page" => {
            let folder = session.pdf.parent();
            let path = message[2].as_str().filter(|path| {
                folder.is_some_and(|folder| Path::new(path).parent() == Some(folder))
            });
            if let (Some(page), Some(path)) = (number(1), path) {
                let update = PageUpdate {
                    page: page as u32,
                    path: path.to_owned(),
                    serial: session.event(state),
                    edit: number(3).unwrap_or(0),
                };
                state.feed.pages.insert(update.page, update);
            }
            return;
        }
        // [pdf, path, pages], and from a patched build [.., run, changed, mark]: the whole
        // document written to the path it was given.
        "pdf" => {
            state.pdf_version += 1;
            let changed = message[4].as_array().map(|ranges| {
                let page = |range: &Value, at: usize| range[at].as_u64().unwrap_or(0) as u32;
                ranges.iter().map(|r| [page(r, 0), page(r, 1)]).collect()
            });
            let document = Document {
                path: session.pdf.to_string_lossy().into_owned(),
                version: state.pdf_version,
                serial: session.event(state),
                pages: number(2).unwrap_or(0) as u32,
                run: message[3].as_str().map(str::to_owned),
                changed,
                edit: number(5).unwrap_or(0),
            };
            // The pages written before it are in it, and their own files are going.
            state.feed.pages.clear();
            state.feed.document = Some(document);
            return;
        }
        "done" => {
            if let (Some(pages), Some(run)) = (number(1), message[2].as_str()) {
                let end = RunEnd {
                    pages: pages as u32,
                    run: run.to_owned(),
                };
                state.feed.done = Some((session.event(state), end));
            }
            return;
        }
        "synced" => {
            if let Some(edit) = number(1) {
                state.feed.synced = edit;
                session.event(state);
            }
            return;
        }
        _ => {}
    }
    let output = match message[1].as_str() {
        Some("out") => &mut state.output,
        Some("log") => &mut state.log,
        _ => return,
    };
    // Upstream sends [truncate, buffer, end] and [append, buffer, byte-offset, text].
    match (verb, message[2].as_u64(), message[3].as_str()) {
        ("truncate", Some(end), _) => output.truncate(end),
        ("append", Some(offset), Some(text)) => output.append(offset, text.as_bytes()),
        _ => return,
    }
    state.protocol_seen = true;
    session.bump(state);
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

    #[tokio::test]
    async fn output_is_read_a_line_at_a_time_and_an_overlong_line_is_no_message() {
        let session = Arc::new(Session {
            token: "token".into(),
            executable: PathBuf::new(),
            main: "main.tex".into(),
            pdf: PathBuf::new(),
            state: Mutex::new(State {
                tree: None,
                last_used: Instant::now(),
                output: Output::default(),
                log: Output::default(),
                protocol_seen: false,
                stderr: Output::default(),
                error: None,
                revision: 0,
                pdf_version: 0,
                settings: None,
                spoken: false,
                live: None,
                feed: Feed::default(),
                edits: 0,
            }),
            files: Mutex::default(),
            lines: mpsc::unbounded_channel().0,
            changed: tokio::sync::Notify::new(),
            revision: Arc::default(),
        });
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

    #[cfg(unix)]
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
            "#!/bin/sh\n/bin/sleep 300 &\necho $! > '{}'\nprintf '[\"append\",\"out\",0,\"ready\"]\\n'\nprintf '[\"pdf\",\"%s\",1]\\n' \"$TEXPRESSO_PDF_OUTPUT\"\nwhile IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> '{}'\n  case \"$line\" in *EXIT_CLEAN*) exit 0;; *EXIT_STUB*) exit 7;; esac\ndone\n",
            child_pid.display(), commands.display()
        )).unwrap();
        fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
        (tmp, root, bin.to_string_lossy().into_owned())
    }
    #[cfg(unix)]
    const SOON: Duration = Duration::from_secs(3);
    #[cfg(unix)]
    async fn until(mut check: impl FnMut() -> bool) {
        tokio::time::timeout(SOON, async {
            while !check() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("stub made progress");
    }
    #[cfg(unix)]
    fn commands(tmp: &tempfile::TempDir) -> Vec<Value> {
        fs::read_to_string(tmp.path().join("commands"))
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
    /// The first document the session hands its client.
    #[cfg(unix)]
    async fn first_document(manager: &Manager, root: &Path, token: &str) -> Document {
        let mut events = manager.wait(root, token, 0, SOON).await.unwrap();
        while events.pdf.is_none() {
            events = manager.wait(root, token, events.seq, SOON).await.unwrap();
        }
        events.pdf.unwrap()
    }
    /// A session on `root` with `files` open.
    #[cfg(unix)]
    async fn begin(manager: &Manager, root: &Path, path_env: &str, files: &[FileBuffer]) -> Status {
        let pane = Pane::default();
        manager
            .start(root, files, None, path_env, &pane)
            .await
            .unwrap()
    }
    /// Starts again, claiming to be the owner `token`.
    #[cfg(unix)]
    async fn restart(
        manager: &Manager,
        root: &Path,
        path_env: &str,
        token: &str,
    ) -> Result<Status, CoreError> {
        manager
            .start(root, &[], Some(token), path_env, &Pane::default())
            .await
    }
    /// The status code of a refusal.
    #[cfg(unix)]
    fn refused<T>(result: Result<T, CoreError>) -> u16 {
        match result {
            Ok(_) => panic!("accepted"),
            Err(error) => error.status,
        }
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn persistent_vfs_protocol_validates_paths_and_reconstructs_unicode() {
        use std::os::unix::fs::PermissionsExt;
        let (tmp, root, path_env) = setup();
        let manager = Manager::default();
        let original = "prefix é😀 suffix";
        let updated = "prefix ê😃 suffix";
        // A main file named texpresso-live.tex builds this; live preview leaves it.
        fs::create_dir_all(root.join(BUILD_DIR)).unwrap();
        fs::write(
            root.join(BUILD_DIR).join("texpresso-live.pdf"),
            "normal build",
        )
        .unwrap();
        let first = begin(&manager, &root, &path_env, &main_buffer(original)).await;
        assert!(first.running && first.available);
        let token = first.session.as_deref().unwrap();
        // The session's own, outside the project: never a build's output.
        let pdf = PathBuf::from(first_document(&manager, &root, token).await.path);
        assert!(pdf.ends_with("live.pdf") && !pdf.starts_with(dunce::canonicalize(&root).unwrap()));
        // In a shared temporary folder, for its owner alone.
        let folder = pdf.parent().unwrap().to_owned();
        let mode = fs::metadata(&folder).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
        assert_eq!(
            fs::read(root.join(BUILD_DIR).join("texpresso-live.pdf")).unwrap(),
            b"normal build"
        );
        until(|| !commands(&tmp).is_empty()).await;
        let sent = commands(&tmp);
        let opened = sent.iter().find(|c| c[0] == "open").unwrap();
        assert_eq!(
            opened[1],
            dunce::canonicalize(root.join("main.tex"))
                .unwrap()
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(opened[2], original);
        let second = manager
            .update(&root, "main.tex", updated, token, false)
            .await
            .unwrap();
        assert_eq!(second.edit, 1);
        let second = second.status.unwrap();
        assert!(second.running && second.revision > first.revision);
        until(|| commands(&tmp).iter().any(|c| c[0] == "change")).await;
        let sent = commands(&tmp);
        let changed = sent.iter().find(|c| c[0] == "change").unwrap();
        let start = changed[2].as_u64().unwrap() as usize;
        let remove = changed[3].as_u64().unwrap() as usize;
        assert_eq!(
            format!(
                "{}{}{}",
                &original[..start],
                changed[4].as_str().unwrap(),
                &original[start + remove..]
            ),
            updated
        );
        assert_eq!(
            fs::read_to_string(root.join("main.tex")).unwrap(),
            "disk text"
        );
        assert!(
            manager
                .update(&root, "../escape.tex", "bad", token, false)
                .await
                .is_err()
        );
        assert!(
            manager
                .update(&root, "build/out.tex", "bad", token, false)
                .await
                .is_err()
        );
        assert!(
            manager
                .update(&root, "main.tex", &"x".repeat(MAX_FILE + 1), token, true)
                .await
                .is_err()
        );
        manager.rescan(&root, token).await.unwrap();
        until(|| commands(&tmp).iter().any(|c| c[0] == "rescan")).await;
        assert!(
            !manager
                .stop_request(&root, Some(token), &path_env)
                .await
                .unwrap()
                .running
        );
        assert!(!folder.exists());
        assert_eq!(
            refused(restart(&manager, &root, &path_env, token).await),
            409
        );
        let restarted = begin(&manager, &root, &path_env, &[]).await;
        assert!(restarted.running && restarted.revision > second.revision);
        manager
            .update(
                &root,
                "main.tex",
                "EXIT_CLEAN",
                restarted.session.as_deref().unwrap(),
                true,
            )
            .await
            .unwrap();
        until(|| !manager.status(&root, None, || &path_env).unwrap().running).await;
        assert!(
            manager
                .status(&root, None, || &path_env)
                .unwrap()
                .error
                .is_none()
        );
        begin(&manager, &root, &path_env, &[]).await;
        manager.kill_all();
        assert!(!manager.status(&root, None, || &path_env).unwrap().running);
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn edits_follow_one_another_and_a_new_main_file_stops_the_session() {
        let (tmp, root, path_env) = setup();
        let manager = Manager::default();
        let started = begin(&manager, &root, &path_env, &main_buffer("abc")).await;
        let token = started.session.as_deref().unwrap();
        let changes = || -> Vec<Value> {
            let sent = commands(&tmp).into_iter();
            sent.filter(|c| c[0] == "change").collect()
        };
        // TeXpresso's copy, rebuilt from the changes it is sent; the same
        // text again sends none.
        let mut text = String::from("abc");
        for edit in ["abXc", "aXc", "aXc", "aXcd"] {
            let sent = changes().len();
            let updated = manager
                .update(&root, "main.tex", edit, token, true)
                .await
                .unwrap();
            assert!(updated.status.is_none() && (updated.edit > 0) == (text != edit));
            if text != edit {
                until(|| changes().len() > sent).await;
                let change = changes().pop().unwrap();
                let start = change[2].as_u64().unwrap() as usize;
                let end = start + change[3].as_u64().unwrap() as usize;
                text.replace_range(start..end, change[4].as_str().unwrap());
            }
            assert_eq!(text, edit);
        }
        assert_eq!(changes().len(), 3);

        fs::write(root.join("other.tex"), "").unwrap();
        crate::settings::write_settings(&root, &json!({ "mainFile": "other.tex" })).unwrap();
        let status = manager
            .update(&root, "main.tex", "abc", token, false)
            .await
            .unwrap()
            .status
            .unwrap();
        assert!(!status.running);
        assert!(status.error.unwrap().contains("main file changed"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unexpected_exit_retains_output_and_stops_engine_group() {
        let (tmp, root, path_env) = setup();
        let manager = Manager::default();
        let owner = begin(&manager, &root, &path_env, &[]).await;
        until(|| {
            fs::read_to_string(tmp.path().join("engine.pid")).is_ok()
                && manager.status(&root, None, || &path_env).unwrap().output == "ready"
        })
        .await;
        let child_pid: i32 = fs::read_to_string(tmp.path().join("engine.pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let token = owner.session.as_deref().unwrap();
        manager
            .update(&root, "main.tex", "EXIT_STUB", token, false)
            .await
            .unwrap();
        until(|| !manager.status(&root, None, || &path_env).unwrap().running).await;
        let status = manager.status(&root, None, || &path_env).unwrap();
        assert_eq!(status.output, "ready");
        let events = manager.wait(&root, token, 0, Duration::ZERO).await.unwrap();
        assert!(!events.running);
        assert!(status.error.unwrap().contains("exited"));
        // Killed descendants can remain zombies briefly while init reaps them.
        until(|| {
            (unsafe { libc::kill(child_pid, 0) == -1 })
                || fs::read_to_string(format!("/proc/{child_pid}/stat"))
                    .is_ok_and(|stat| stat.contains(") Z "))
        })
        .await;
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn the_log_follows_backtracking_and_an_abandoned_lease_ends_the_session_unpolled() {
        let (_tmp, root, path_env) = setup();
        let manager = Manager::default();
        let started = begin(&manager, &root, &path_env, &[]).await;
        let session = manager.held(&started.session.unwrap()).unwrap();
        // Backtracking drops TeX's log, and the process's historical stderr is
        // not put in its place.
        let diagnostic = "Undefined control sequence";
        let stderr = diagnostic.as_bytes();
        session.state.lock().unwrap().stderr.append(0, stderr);
        apply_message(&session, &json!(["append", "log", 0, diagnostic]));
        assert!(session.status().log.contains(diagnostic));
        apply_message(&session, &json!(["truncate", "log", 0]));
        assert!(!session.status().log.contains(diagnostic));

        session.state.lock().unwrap().last_used = Instant::now() - LEASE;
        // The session looks at its lease every five seconds of tokio's clock, which
        // goes straight to its next look once nothing else has work.
        tokio::time::pause();
        tokio::time::sleep(Duration::from_millis(5100)).await;
        let status = manager.status(&root, None, || &path_env).unwrap();
        assert!(!status.running);
        assert!(status.error.unwrap().contains("expired"));
        // Ended, the log has that stderr after all.
        assert!(session.status().log.contains(diagnostic));
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn replacement_rejects_queued_stale_edits_cleanup_and_lease_renewal() {
        let (_tmp, root, path_env) = setup();
        let manager = Arc::new(Manager::default());
        assert!(!manager.status(&root, None, || &path_env).unwrap().running);
        let old = begin(&manager, &root, &path_env, &[])
            .await
            .session
            .unwrap();
        // B's Start reaches the queue before A's delayed edit.
        let blocked = manager.requests.lock().await;
        let replacement = tokio::spawn({
            let (manager, root, path_env) = (Arc::clone(&manager), root.clone(), path_env.clone());
            async move { begin(&manager, &root, &path_env, &main_buffer("owner B")).await }
        });
        tokio::task::yield_now().await;
        let stale_edit = tokio::spawn({
            let (manager, root, old) = (Arc::clone(&manager), root.clone(), old.clone());
            async move {
                manager
                    .update(&root, "main.tex", "stale A", &old, false)
                    .await
            }
        });
        drop(blocked);
        let current = replacement.await.unwrap().session.unwrap();
        assert_ne!(old, current);
        assert_eq!(refused(stale_edit.await.unwrap()), 409);
        let session = manager
            .owned(&dunce::canonicalize(&root).unwrap(), &current)
            .unwrap();
        let before = Instant::now() - Duration::from_secs(60);
        session.state.lock().unwrap().last_used = before;
        let stale = Some(old.as_str());
        assert_eq!(refused(manager.status(&root, stale, || &path_env)), 409);
        assert_eq!(refused(manager.rescan(&root, &old).await), 409);
        assert_eq!(
            refused(manager.stop_request(&root, stale, &path_env).await),
            409
        );
        // An idle tab can inspect B, but neither inspection nor A extends its lease.
        let inspected = manager.status(&root, None, || &path_env).unwrap();
        assert_eq!(inspected.session.as_deref(), Some(current.as_str()));
        assert_eq!(session.state.lock().unwrap().last_used, before);
        let owned = manager.status(&root, Some(&current), || &path_env);
        assert!(owned.unwrap().running);
        assert!(session.state.lock().unwrap().last_used > before);
        let main = dunce::canonicalize(root.join("main.tex")).unwrap();
        assert_eq!(
            session.files.lock().unwrap().texts[&main].string(),
            "owner B"
        );
        assert_eq!(
            refused(restart(&manager, &root, &path_env, &old).await),
            409
        );
        manager.stop(&root).unwrap();
        assert!(!manager.status(&root, None, || &path_env).unwrap().running);
        let restarted = restart(&manager, &root, &path_env, &current).await.unwrap();
        assert!(restarted.running);
        assert_ne!(restarted.session.as_deref(), Some(current.as_str()));
        // Deliberately selected global Stop remains available to an inspecting tab.
        let stopped = manager.stop_request(&root, None, &path_env).await;
        assert!(!stopped.unwrap().running);
        let token = restarted.session.as_deref().unwrap();
        assert_eq!(
            refused(restart(&manager, &root, &path_env, token).await),
            409
        );
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
            assert_eq!(text.bytes(), plain.len());
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

    /// A stub that speaks as a build with Underleaf's patch does: it says so first, writes
    /// "the document", answers each numbered edit with page 1 and that the view shows it,
    /// and a request for a finishing pass with a new document.
    #[cfg(unix)]
    fn setup_live() -> (tempfile::TempDir, PathBuf, String) {
        let (tmp, root, path_env) = setup();
        let stub = tmp.path().join("bin/texpresso");
        fs::write(&stub, format!(
            concat!(
                "#!/bin/sh\ndir=${{TEXPRESSO_PDF_OUTPUT%/*}}\n",
                "printf '[\"live\",1]\\n[\"pdf\",\"%s\",3,\"partial\",[[0,2]],0]\\n' \"$TEXPRESSO_PDF_OUTPUT\"\n",
                "while IFS= read -r line; do\n  printf '%s\\n' \"$line\" >> '{}'\n",
                "  case \"$line\" in\n",
                "    '[\"mark\",'*) n=${{line#*,}}; n=${{n%]}}\n",
                "      printf '[\"page\",1,\"%s/page-1-%s.pdf\",%s]\\n[\"synced\",%s]\\n' \"$dir\" \"$n\" \"$n\" \"$n\";;\n",
                "    *rerun-once*) printf '[\"pdf\",\"%s\",4,\"complete\",[[1,1],[3,3]],9]\\n[\"done\",4,\"complete\"]\\n' \"$TEXPRESSO_PDF_OUTPUT\";;\n",
                "  esac\ndone\n"
            ),
            tmp.path().join("commands").display()
        )).unwrap();
        (tmp, root, path_env)
    }
    #[cfg(unix)]
    fn main_buffer(text: &str) -> Vec<FileBuffer> {
        vec![FileBuffer {
            path: "main.tex".into(),
            text: text.into(),
        }]
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_keystroke_goes_as_bytes_at_once_and_one_that_does_not_fit_is_refused() {
        let (tmp, root, path_env) = setup_live();
        let manager = Manager::default();
        let pane = Pane {
            view: Some((2, 3)),
            caret: Some(Caret {
                path: "main.tex".into(),
                offset: 4,
            }),
        };
        let started = manager
            .start(&root, &main_buffer("aé😀b"), None, &path_env, &pane)
            .await
            .unwrap();
        let token = started.session.as_deref().unwrap();
        let path = dunce::canonicalize(root.join("main.tex")).unwrap();
        // Four units in: after a, é and the pair, seven bytes in.
        assert_eq!(manager.edit(token, "main.tex", 4, 0, "X").unwrap(), 1);
        assert_eq!(manager.edit(token, "main.tex", 1, 3, "").unwrap(), 2);
        manager.view(token, 5, 4).unwrap();
        manager.caret(token, "main.tex", 2).unwrap();
        until(|| commands(&tmp).len() >= 9).await;
        let sent = commands(&tmp);
        assert_eq!(
            sent[1..],
            [
                json!(["view", 2, 3]),
                json!(["caret", path, 7]),
                json!(["change", path, 7, 0, "X"]),
                json!(["mark", 1]),
                json!(["change", path, 1, 6, ""]),
                json!(["mark", 2]),
                json!(["view", 5, 5]),
                json!(["caret", path, 2]),
            ]
        );
        // No finishing passes of upstream's kind, which start the document over.
        assert!(!sent.iter().any(|c| c[0] == "rerun"));

        // The copy is "aXb" now: nothing below is in it, and nothing is sent or changed.
        for (file, start, remove) in [("main.tex", 4, 0), ("main.tex", 2, 2), ("other.tex", 0, 0)] {
            assert_eq!(
                manager
                    .edit(token, file, start, remove, "no")
                    .unwrap_err()
                    .status,
                412
            );
        }
        assert_eq!(manager.caret(token, "main.tex", 9).unwrap_err().status, 412);
        assert_eq!(
            manager
                .edit(token, "main.tex", 0, 0, "\0")
                .unwrap_err()
                .status,
            400
        );
        assert_eq!(
            manager
                .edit("stale", "main.tex", 0, 0, "x")
                .unwrap_err()
                .status,
            409
        );
        // The whole text puts the copy right, sent as the change from what TeXpresso has.
        let repaired = manager
            .update(&root, "main.tex", "aXb😀", token, true)
            .await
            .unwrap();
        assert_eq!(repaired.edit, 3);
        assert_eq!(manager.edit(token, "main.tex", 5, 0, "!").unwrap(), 4);
        until(|| commands(&tmp).len() >= 13).await;
        assert_eq!(
            commands(&tmp)[9..],
            [
                json!(["change", path, 3, 0, "😀"]),
                json!(["mark", 3]),
                json!(["change", path, 7, 0, "!"]),
                json!(["mark", 4]),
            ]
        );
        // A session that has ended takes no edit, and says so with no number.
        manager.stop(&root).unwrap();
        assert_eq!(manager.edit(token, "main.tex", 0, 0, "x").unwrap(), 0);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn waiting_hands_over_the_latest_of_each_page_and_ends_with_the_session() {
        let (_tmp, root, path_env) = setup_live();
        let manager = Arc::new(Manager::default());
        let started = begin(&manager, &root, &path_env, &main_buffer("abc")).await;
        let token = started.session.clone().unwrap();
        let wait = |after: u64, timeout: Duration| {
            let (manager, root, token) = (Arc::clone(&manager), root.clone(), token.clone());
            async move { manager.wait(&root, &token, after, timeout).await.unwrap() }
        };
        // The build says what it speaks, then the first document.
        let mut events = wait(0, SOON).await;
        while events.pdf.is_none() {
            events = wait(events.seq, SOON).await;
        }
        let first = wait(0, SOON).await;
        assert_eq!(first.live, Some(1));
        let document = first.pdf.unwrap();
        assert_eq!((document.version, document.pages), (1, 3));
        assert_eq!(document.run.as_deref(), Some("partial"));
        assert_eq!(document.changed, Some(vec![[0, 2]]));
        assert!(first.pages.is_empty() && first.done.is_none() && first.running);

        // Nothing new: the wait lasts its time, and other calls go on meanwhile.
        let began = Instant::now();
        let waiting = tokio::spawn(wait(first.seq, Duration::from_secs(20)));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!waiting.is_finished());
        assert_eq!(manager.edit(&token, "main.tex", 3, 0, "d").unwrap(), 1);
        assert_eq!(manager.edit(&token, "main.tex", 4, 0, "e").unwrap(), 2);
        let mut events = waiting.await.unwrap();
        assert!(began.elapsed() < SOON && events.seq > first.seq);
        while events.synced < 2 {
            events = wait(events.seq, SOON).await;
        }
        // Two edits wrote page 1 twice: a client that was away has only the later.
        let all = wait(0, SOON).await;
        assert_eq!(all.pages.len(), 1);
        let page = &all.pages[0];
        let folder = PathBuf::from(&document.path).parent().unwrap().to_owned();
        assert_eq!((page.page, page.edit), (1, 2));
        assert_eq!(PathBuf::from(&page.path), folder.join("page-1-2.pdf"));
        assert!(page.serial > document.serial && all.pdf.unwrap().serial == document.serial);
        // And one that has seen it is told nothing twice.
        let quiet = wait(all.seq, Duration::from_millis(60)).await;
        assert!(quiet.pages.is_empty() && quiet.pdf.is_none() && quiet.seq == all.seq);
        assert_eq!(quiet.synced, 2);

        // A new document takes the place of the pages before it: the stub writes one when
        // asked for a finishing pass, as upstream's build does.
        manager.held(&token).unwrap().send(&[json!(["rerun-once"])]);
        let mut events = wait(all.seq, SOON).await;
        while events.done.is_none() {
            events = wait(all.seq, SOON).await;
        }
        let document = events.pdf.unwrap();
        assert_eq!((document.version, document.pages, document.edit), (2, 4, 9));
        assert_eq!(document.run.as_deref(), Some("complete"));
        assert_eq!(document.changed, Some(vec![[1, 1], [3, 3]]));
        assert!(events.pages.is_empty());
        let done = events.done.unwrap();
        assert_eq!((done.pages, done.run.as_str()), (4, "complete"));

        // A page file from outside the session's folder is nobody's page.
        let session = manager.held(&token).unwrap();
        apply_message(&session, &json!(["page", 0, "/etc/passwd", 1]));
        assert!(wait(events.seq, Duration::ZERO).await.pages.is_empty());

        // Stopping answers the wait at once.
        let waiting = tokio::spawn(wait(events.seq, Duration::from_secs(20)));
        tokio::time::sleep(Duration::from_millis(30)).await;
        let began = Instant::now();
        manager.stop(&root).unwrap();
        let ended = waiting.await.unwrap();
        assert!(!ended.running && began.elapsed() < Duration::from_secs(1));
        assert!(!wait(ended.seq, Duration::from_secs(20)).await.running);
        assert_eq!(
            manager
                .wait(&root, "stale", 0, Duration::ZERO)
                .await
                .unwrap_err()
                .status,
            409
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_build_that_only_writes_the_document_is_sent_nothing_it_does_not_know() {
        let (tmp, root, path_env) = setup();
        let manager = Manager::default();
        let started = begin(&manager, &root, &path_env, &main_buffer("abc")).await;
        let token = started.session.as_deref().unwrap();
        let mut events = manager.wait(&root, token, 0, SOON).await.unwrap();
        while events.pdf.is_none() {
            events = manager.wait(&root, token, events.seq, SOON).await.unwrap();
        }
        // No word of pages before the document: the build is an older one.
        let document = events.pdf.unwrap();
        assert_eq!(
            (events.live, document.version, document.pages),
            (None, 1, 1)
        );
        assert!(document.run.is_none() && document.changed.is_none());
        assert_eq!(manager.edit(token, "main.tex", 3, 0, "d").unwrap(), 1);
        manager.view(token, 0, 1).unwrap();
        manager.caret(token, "main.tex", 1).unwrap();
        until(|| commands(&tmp).iter().any(|c| c[0] == "change")).await;
        manager.rescan(&root, token).await.unwrap();
        until(|| commands(&tmp).iter().any(|c| c[0] == "rescan")).await;
        let verbs: Vec<_> = commands(&tmp)
            .iter()
            .map(|c| c[0].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(verbs, ["open", "change", "rescan"]);
    }
}
