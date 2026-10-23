//! Optional persistent TeXpresso viewer. Author buffers stay in its VFS; the ordinary
//! latexmk build and PDF continue to use saved project files.
//!
//! A build with Underleaf's patch (tools/texpresso) writes the pages the client says it
//! shows as one-page PDFs when retypeset, and the whole document when a run ends. Where TeX
//! runs inside the app (`inprocess`), the engine it links speaks the same over pipes.
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use ropey::Rope;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::paths::{self, Project};
use crate::process::{self, Tree};
use crate::tex::{find_tool, program_at};
use crate::{CoreError, lock, settings, tail};

const MAX_OUTPUT: usize = 128 * 1024;
/// TeX's log is kept whole for its errors' files, which only its start opens.
const MAX_LOG: usize = 16 * 1024 * 1024;
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

#[derive(Debug)]
pub struct FileBuffer {
    pub path: String,
    pub text: String,
}

/// A client that shows the document itself: the pages it shows (from 0) and its caret (a
/// path, and UTF-16 units in), so a patched build has those pages first and a snapshot ready.
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveEvent {
    Page {
        page: u32,
        path: String,
    },
    /// The whole document, complete on disk, its SyncTeX beside it. `run`: how the run ended
    /// (`complete`, `stopped`, or `partial` while still typeset). `changed`: first/last page
    /// ranges that differ from before. Both None from a build that doesn't say.
    Document {
        path: String,
        pages: u32,
        run: Option<String>,
        changed: Option<Vec<[u32; 2]>>,
    },
    Done(String),
    /// TeXpresso has read every change sent before the mark of this number.
    Synced(u64),
    Log,
    Ended(Option<String>),
}

pub type Sink = Box<dyn Fn(LiveEvent) + Send + Sync>;

pub(crate) trait Preview: Send + Sync {
    /// A preview of `project` for the session `owner`, in place of any the owner had. A
    /// patched build writes the document for the `pane` instead of opening a window; upstream
    /// opens its window all the same.
    fn start(
        &self,
        owner: u64,
        project: &Project,
        files: &[FileBuffer],
        path_env: &str,
        pane: &Pane,
        sink: Sink,
    ) -> Result<Status, CoreError>;
    fn update(&self, owner: u64, rel: &str, text: &str) -> Result<(), CoreError>;
    /// A keystroke: `remove` UTF-16 units at `start` replaced by `text`. It waits for nothing.
    /// An edit that doesn't fit the session's copy is refused with status 412 and changes
    /// nothing: `update` with the whole text then puts both right.
    fn edit(
        &self,
        owner: u64,
        rel: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<(), CoreError>;
    fn view(&self, owner: u64, first: u32, last: u32) -> Result<(), CoreError>;
    fn caret(&self, owner: u64, rel: &str, offset: usize) -> Result<(), CoreError>;
    fn rescan(&self, owner: u64) -> Result<(), CoreError>;
    /// Numbers the changes sent before it, for `LiveEvent::Synced`.
    fn mark(&self, owner: u64, mark: u64) -> Result<(), CoreError>;
    /// TeX's log, whole: None once its start was dropped.
    fn tex_log(&self, owner: u64) -> Option<String>;
    fn status(&self, owner: u64) -> Result<Status, CoreError>;
    fn stop_request(&self, owner: u64) -> Status;
    fn stop(&self, root: &Path) -> Result<(), CoreError>;
}

/// A buffer TeXpresso writes by byte offset, of which the last `max` bytes are kept.
struct Output {
    base: u64,
    bytes: Vec<u8>,
    max: usize,
}

impl Default for Output {
    fn default() -> Self {
        Self {
            base: 0,
            bytes: Vec::new(),
            max: MAX_OUTPUT,
        }
    }
}

impl Output {
    fn end(&self) -> u64 {
        self.base + self.bytes.len() as u64
    }
    fn truncate(&mut self, end: u64) {
        if end < self.base {
            self.base = end;
            self.bytes.clear();
        } else {
            self.bytes.truncate((end - self.base) as usize);
        }
    }
    fn append(&mut self, offset: u64, text: &[u8]) {
        self.truncate(offset);
        if offset > self.end() {
            self.bytes.clear();
            self.base = offset;
        }
        self.bytes.extend_from_slice(text);
        let excess = self.bytes.len().saturating_sub(self.max);
        self.bytes.drain(..excess);
        self.base += excess as u64;
    }
    /// The last `MAX_OUTPUT` bytes, to show.
    fn text(&self) -> String {
        let start = self.bytes.len().saturating_sub(MAX_OUTPUT);
        String::from_utf8_lossy(&self.bytes[start..]).into_owned()
    }
}

/// The char `units` UTF-16 units into `text`, unless that is inside a character.
fn char_at(text: &Rope, units: usize) -> Option<usize> {
    let at = text.try_utf16_cu_to_char(units).ok()?;
    (text.char_to_utf16_cu(at) == units).then_some(at)
}

fn byte_offset(text: &Rope, units: usize) -> Option<usize> {
    Some(text.char_to_byte(char_at(text, units)?))
}

/// Replaces `remove` UTF-16 units at `start` with `inserted`; the byte offset and length
/// it replaced, as TeXpresso counts them.
fn splice(text: &mut Rope, start: usize, remove: usize, inserted: &str) -> Option<(usize, usize)> {
    let from = char_at(text, start)?;
    let to = char_at(text, start.checked_add(remove)?)?;
    let offset = text.char_to_byte(from);
    let removed = text.char_to_byte(to) - offset;
    text.remove(from..to);
    text.insert(from, inserted);
    Some((offset, removed))
}

/// A running session's way to TeXpresso: dropping it closes TeXpresso's input, which ends it.
struct Link {
    lines: mpsc::UnboundedSender<Vec<u8>>,
    /// The program's and its engine's processes; none for the engine inside the app.
    tree: Option<Tree>,
}

#[derive(Default)]
struct State {
    link: Option<Link>,
    output: Output,
    log: Output,
    protocol_seen: bool,
    stderr: Output,
    error: Option<String>,
}

struct Session {
    root: PathBuf,
    pdf: PathBuf,
    state: Mutex<State>,
    files: Mutex<HashMap<String, Rope>>,
    sink: Sink,
}

impl Session {
    fn running(&self) -> bool {
        lock(&self.state).link.is_some()
    }
    fn stop(&self, error: Option<String>) {
        let mut state = lock(&self.state);
        if let Some(link) = state.link.take() {
            // The viewer starts an engine: stopping just its parent leaks it.
            if let Some(tree) = link.tree {
                tree.kill();
            }
            remove_pdf_folder(&self.pdf);
            state.error.clone_from(&error);
            if let Ok(mut files) = self.files.try_lock() {
                files.clear();
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
        Status {
            running: state.link.is_some(),
            output: state.output.text(),
            log: tail(&log, MAX_OUTPUT).to_owned(),
            error: state.error.clone(),
        }
    }
    fn send(&self, messages: &[Value]) {
        let mut lines = Vec::new();
        for message in messages {
            serde_json::to_writer(&mut lines, message).expect("JSON values serialize");
            lines.push(b'\n');
        }
        if let Some(link) = &lock(&self.state).link {
            let _ = link.lines.send(lines);
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop(None);
    }
}

fn remove_pdf_folder(pdf: &Path) {
    if let Some(folder) = pdf.parent() {
        let _ = fs::remove_dir_all(folder);
    }
}

#[derive(Default)]
pub struct Manager {
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
    fn owned(&self, owner: u64) -> Result<Arc<Session>, CoreError> {
        lock(&self.sessions)
            .get(&owner)
            .cloned()
            .ok_or_else(|| CoreError::not_found(NOT_RUNNING))
    }
    pub fn live_pdf(&self, owner: u64) -> Result<PathBuf, CoreError> {
        let pdf = self.owned(owner)?.pdf.clone();
        if !pdf.with_extension("synctex").is_file() {
            return Err(CoreError::not_found(
                "TeXpresso hasn't written a document to sync with yet",
            ));
        }
        Ok(pdf)
    }
}

impl Manager {
    /// The build folder and where the session's pages go, once the owner's last preview has
    /// stopped.
    fn prepare(&self, owner: u64, project: &Project) -> Result<(PathBuf, PathBuf), CoreError> {
        fs::create_dir_all(&project.build)?;
        let build = dunce::canonicalize(&project.build)?;
        if let Some(previous) = lock(&self.sessions).get(&owner) {
            previous.stop(None);
        }
        // The session's own folder, for its owner alone; the session removes it as it stops.
        let mut folder = tempfile::Builder::new();
        folder.prefix("texlocal-texpresso-");
        #[cfg(unix)]
        folder.permissions(std::os::unix::fs::PermissionsExt::from_mode(0o700));
        let pdf = dunce::canonicalize(folder.tempdir()?.keep())?.join("live.pdf");
        Ok((build, pdf))
    }

    /// The owner's running session, and the lines it sends TeXpresso.
    fn open(
        &self,
        owner: u64,
        root: PathBuf,
        pdf: PathBuf,
        buffers: HashMap<String, Rope>,
        sink: Sink,
        tree: Option<Tree>,
    ) -> (Arc<Session>, mpsc::UnboundedReceiver<Vec<u8>>) {
        let (lines, queued) = mpsc::unbounded_channel();
        let session = Arc::new(Session {
            root,
            pdf,
            files: Mutex::new(buffers),
            sink,
            state: Mutex::new(State {
                link: Some(Link { lines, tree }),
                log: Output {
                    max: MAX_LOG,
                    ..Output::default()
                },
                ..State::default()
            }),
        });
        let mut sessions = lock(&self.sessions);
        // Under the map's lock, so `kill_all` stops it either way.
        if self.shutdown.load(Ordering::Acquire) {
            session.stop(None);
        }
        sessions.insert(owner, Arc::clone(&session));
        (session, queued)
    }
}

impl Preview for Manager {
    fn start(
        &self,
        owner: u64,
        project: &Project,
        files: &[FileBuffer],
        path_env: &str,
        pane: &Pane,
        sink: Sink,
    ) -> Result<Status, CoreError> {
        let root = dunce::canonicalize(&project.root)?;
        let main = settings::read_settings(&project.settings).main_file;
        let main = paths::safe_path(&root, &main)?;
        if !main.is_file() {
            return Err(CoreError::bad_request("The main file does not exist."));
        }
        let mut buffers = HashMap::new();
        let mut opening = Vec::new();
        for file in files {
            opening.push(json!(["open", root.join(&file.path), file.text]));
            buffers.insert(file.path.clone(), Rope::from_str(&file.text));
        }
        // TeXpresso's idle reruns stay off: each restarts TeX from nothing after a pause in
        // typing and shows no page until it is over.
        let view = pane
            .view
            .map(|(first, last)| json!(["view", first, last.max(first)]));
        let caret = pane.caret.as_ref().and_then(|(rel, units)| {
            let offset = byte_offset(buffers.get(rel)?, *units)?;
            Some(json!(["caret", root.join(rel), offset]))
        });
        opening.extend(view.into_iter().chain(caret));
        let failed = |error: String| {
            Ok(Status {
                error: Some(error),
                ..Status::default()
            })
        };
        #[cfg(unix)]
        if crate::inprocess::IN_PROCESS {
            let engine = match crate::inprocess::engine() {
                Ok(engine) => engine,
                Err(err) => return failed(err.message),
            };
            let (build, pdf) = self.prepare(owner, project)?;
            // The engine runs one session at a time.
            for (_, other) in lock(&self.sessions).iter().filter(|(o, _)| **o != owner) {
                let why = "Live Preview stopped here as another project’s started: this device runs one at a time.";
                other.stop(Some(why.into()));
            }
            let (session, queued) = self.open(owner, root, pdf.clone(), buffers, sink, None);
            let args = ["texpresso", "-json", "-I"].map(std::ffi::OsString::from);
            let args = args.into_iter();
            let args = args.chain([build.into(), main.into()]).collect();
            let weak = Arc::downgrade(&session);
            tokio::spawn(live_in_app(engine, args, pdf, queued, weak));
            session.send(&opening);
            return Ok(session.status());
        }
        let Some(executable) = discover(path_env) else {
            return failed(MISSING.into());
        };
        let (build, pdf) = self.prepare(owner, project)?;
        let mut command = process::tool(&executable, path_env);
        command
            .args(["-json", "-texlive", "-I"])
            .arg(&build)
            .arg(&main)
            .current_dir(&root)
            .stdin(Stdio::piped())
            .env("TEXPRESSO_PDF_OUTPUT", &pdf);
        // A Mac app runs with signals ignored or blocked that a child inherits across exec.
        // TeXpresso stops a stale TeX worker with SIGTERM, and ignored it never ends.
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
                remove_pdf_folder(&pdf);
                return failed(format!(
                    "Couldn't start TeXpresso: {err}. Check TEXLOCAL_TEXPRESSO and its dependencies."
                ));
            }
        };
        let (session, queued) = self.open(owner, root, pdf, buffers, sink, Some(tree));
        let (stdin, stdout, stderr) =
            (child.stdin.take(), child.stdout.take(), child.stderr.take());
        let weak = Arc::downgrade(&session);
        tokio::spawn(write_lines(stdin.unwrap(), queued, weak.clone()));
        tokio::spawn(read_output(stdout.unwrap(), Arc::clone(&session), true));
        tokio::spawn(read_output(stderr.unwrap(), Arc::clone(&session), false));
        let exit = async move {
            match child.wait().await {
                Ok(status) if status.success() => None,
                result => Some(result.map_or_else(|e| e.to_string(), |s| s.to_string())),
            }
        };
        tokio::spawn(stop_on_exit(exit, weak));
        session.send(&opening);
        Ok(session.status())
    }
    fn update(&self, owner: u64, rel: &str, text: &str) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        if !session.running() {
            return Ok(());
        }
        let mut files = lock(&session.files);
        let path = session.root.join(rel);
        let message = match files.get(rel).map(|old| delta(&String::from(old), text)) {
            Some((_, 0, "")) => return Ok(()),
            Some((offset, remove, inserted)) => json!(["change", path, offset, remove, inserted]),
            None => json!(["open", path, text]),
        };
        session.send(&[message]);
        files.insert(rel.to_owned(), Rope::from_str(text));
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
        let mut files = lock(&session.files);
        if !session.running() {
            return Ok(());
        }
        let held = files.get_mut(rel);
        let (offset, removed) = held
            .and_then(|held| splice(held, start, remove, text))
            .ok_or_else(|| CoreError::unfit(UNFIT))?;
        session.send(&[json!([
            "change",
            session.root.join(rel),
            offset,
            removed,
            text
        ])]);
        Ok(())
    }
    fn view(&self, owner: u64, first: u32, last: u32) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        session.send(&[json!(["view", first, last.max(first)])]);
        Ok(())
    }
    fn caret(&self, owner: u64, rel: &str, offset: usize) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        let offset = (lock(&session.files).get(rel))
            .and_then(|text| byte_offset(text, offset))
            .ok_or_else(|| CoreError::unfit(UNFIT))?;
        session.send(&[json!(["caret", session.root.join(rel), offset])]);
        Ok(())
    }
    fn rescan(&self, owner: u64) -> Result<(), CoreError> {
        let session = self.owned(owner)?;
        if session.running() {
            session.send(&[json!(["rescan"])]);
        }
        Ok(())
    }
    fn mark(&self, owner: u64, mark: u64) -> Result<(), CoreError> {
        self.owned(owner)?.send(&[json!(["mark", mark])]);
        Ok(())
    }
    fn tex_log(&self, owner: u64) -> Option<String> {
        let session = self.owned(owner).ok()?;
        let log = &lock(&session.state).log;
        (log.base == 0).then(|| String::from_utf8_lossy(&log.bytes).into_owned())
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

fn common<T: PartialEq>(a: impl Iterator<Item = T>, b: impl Iterator<Item = T>) -> usize {
    a.zip(b).take_while(|(a, b)| a == b).count()
}

/// The change from one whole text to the next, in bytes. Both boundaries must be UTF-8
/// boundaries even when differing characters share leading or trailing bytes.
pub(crate) fn delta<'a>(old: &str, new: &'a str) -> (usize, usize, &'a str) {
    let (a, b) = (old.as_bytes(), new.as_bytes());
    let mut start = common(a.iter(), b.iter());
    while !old.is_char_boundary(start) || !new.is_char_boundary(start) {
        start -= 1;
    }
    let mut suffix = common(a[start..].iter().rev(), b[start..].iter().rev());
    while !old.is_char_boundary(old.len() - suffix) || !new.is_char_boundary(new.len() - suffix) {
        suffix -= 1;
    }
    (
        start,
        old.len() - start - suffix,
        &new[start..new.len() - suffix],
    )
}

/// Stops the session when TeXpresso exits, saying why (`exit`'s status) unless it exited
/// cleanly; also when the runtime drops this task first.
async fn stop_on_exit(exit: impl Future<Output = Option<String>>, session: Weak<Session>) {
    struct Stop(Weak<Session>, Option<String>);
    impl Drop for Stop {
        fn drop(&mut self) {
            if let Some(session) = self.0.upgrade() {
                session.stop(self.1.take());
            }
        }
    }
    let mut stop = Stop(session, None);
    stop.1 = (exit.await).map(|status| {
        format!("TeXpresso exited ({status}). Check its log and start TeXpresso again.")
    });
}

/// Live Preview by the engine inside the app, which runs one session at a time: a start
/// waits until the last session has ended.
#[cfg(unix)]
async fn live_in_app(
    engine: &'static crate::inprocess::Engine,
    args: Vec<std::ffi::OsString>,
    pdf: PathBuf,
    queued: mpsc::UnboundedReceiver<Vec<u8>>,
    session: Weak<Session>,
) {
    use tokio::net::unix::pipe;
    static ONE: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);
    let Ok(one) = ONE.acquire().await else {
        return;
    };
    let Some(running) = session.upgrade().filter(|session| session.running()) else {
        return;
    };
    let Some((live, [commands, messages, log])) = engine.live_start(&args, &pdf) else {
        return running.stop(Some("TeXpresso couldn’t start.".into()));
    };
    let pipes = (|| {
        Ok::<_, std::io::Error>((
            pipe::Sender::from_owned_fd(commands)?,
            pipe::Receiver::from_owned_fd(messages)?,
            pipe::Receiver::from_owned_fd(log)?,
        ))
    })();
    match pipes {
        Ok((commands, messages, log)) => {
            tokio::spawn(write_lines(commands, queued, session.clone()));
            tokio::spawn(read_output(messages, Arc::clone(&running), true));
            tokio::spawn(read_output(log, running, false));
        }
        // The pipes are closed, which ends the session.
        Err(err) => running.stop(Some(format!("TeXpresso couldn’t start: {err}."))),
    }
    let exit = async move {
        let wait = tokio::task::spawn_blocking(move || {
            let status = engine.wait(live);
            drop(one);
            status
        });
        match wait.await {
            Ok(0) => None,
            Ok(status) => Some(format!("exit status {status}")),
            Err(err) => Some(err.to_string()),
        }
    };
    stop_on_exit(exit, session).await;
}

/// The session's one writer to TeXpresso's stdin: a TeXpresso that has stopped reading
/// stops the session instead of holding the queued lines.
async fn write_lines(
    mut stdin: impl AsyncWrite + Unpin,
    mut queued: mpsc::UnboundedReceiver<Vec<u8>>,
    session: Weak<Session>,
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
        if let Some(session) = session.upgrade() {
            session.stop(Some(format!(
                "Couldn't send changes to TeXpresso: {error}. Start TeXpresso again."
            )));
        }
        break;
    }
}

async fn read_output(reader: impl AsyncRead + Unpin, session: Arc<Session>, protocol: bool) {
    let mut reader = tokio::io::BufReader::with_capacity(8192, reader);
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
        if protocol {
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
        } else {
            let mut state = lock(&session.state);
            let end = state.stderr.end();
            state.stderr.append(end, chunk);
            (session.sink)(LiveEvent::Log);
        }
        reader.consume(count);
    }
}

fn apply_message(session: &Session, message: &Value) {
    let verb = message[0].as_str().unwrap_or_default();
    let number = |index: usize| message[index].as_u64().map(|n| n as u32);
    let event = match verb {
        "reset-sync" => {
            let files = lock(&session.files);
            let messages: Vec<_> = (files.iter())
                .map(|(rel, text)| json!(["open", session.root.join(rel), String::from(text)]))
                .collect();
            session.send(&messages);
            return;
        }
        "page" => {
            let folder = session.pdf.parent();
            let path = (message[2].as_str()).filter(|path| Path::new(path).parent() == folder);
            let (Some(page), Some(path)) = (number(1), path) else {
                return;
            };
            LiveEvent::Page {
                page,
                path: path.to_owned(),
            }
        }
        "pdf" => {
            let changed = message[4].as_array().map(|ranges| {
                let page = |range: &Value, at: usize| range[at].as_u64().unwrap_or(0) as u32;
                ranges.iter().map(|r| [page(r, 0), page(r, 1)]).collect()
            });
            LiveEvent::Document {
                path: session.pdf.to_string_lossy().into_owned(),
                pages: number(2).unwrap_or(0),
                run: message[3].as_str().map(str::to_owned),
                changed,
            }
        }
        "done" => match message[2].as_str() {
            Some(run) => LiveEvent::Done(run.to_owned()),
            None => return,
        },
        "synced" => match message[1].as_u64() {
            Some(mark) => LiveEvent::Synced(mark),
            None => return,
        },
        // Upstream sends [truncate, buffer, end] and [append, buffer, byte-offset, text].
        "truncate" | "append" => {
            let mut state = lock(&session.state);
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
        let long = "aé😀b\n".repeat(900);
        let cases = [
            ("a😀b", 1, 2, "é", Some((1, 4))),
            ("", 0, 0, "é", Some((0, 0))),
            (long.as_str(), 6 * 800 + 2, 2, "x", Some((9 * 800 + 3, 4))),
            ("a😀b", 2, 0, "x", None),
            ("a😀b", 1, 1, "", None),
            ("a😀b", 5, 0, "x", None),
            ("a😀b", 0, 5, "", None),
        ];
        for (before, start, remove, inserted, changed) in cases {
            let mut text = Rope::from_str(before);
            assert_eq!(splice(&mut text, start, remove, inserted), changed);
            let mut after = before.to_owned();
            if let Some((from, removed)) = changed {
                after.replace_range(from..from + removed, inserted);
            }
            assert_eq!(String::from(&text), after);
        }
        assert_eq!(byte_offset(&Rope::from_str("a😀b"), 2), None);
        let long = Rope::from_str(&long);
        assert_eq!(byte_offset(&long, 6 * 800 + 4), Some(9 * 800 + 7));
    }

    #[tokio::test]
    async fn output_is_read_a_line_at_a_time_and_an_overlong_line_is_no_message() {
        let session = Arc::new(Session {
            root: PathBuf::new(),
            pdf: PathBuf::new(),
            state: Mutex::default(),
            files: Mutex::default(),
            sink: Box::new(|_| {}),
        });
        let long = format!(r#"["append","out",3,"{}"]"#, "x".repeat(MAX_MESSAGE));
        let text = format!(
            "[\"append\",\"out\",0,\"rea\"]\n{long}\n[\"append\",\"out\",3,\"dy\"]\n[\"append\",\"log\",0,\"cut"
        );
        read_output(text.as_bytes(), Arc::clone(&session), true).await;
        let status = session.status();
        assert_eq!((status.output.as_str(), status.log.as_str()), ("ready", ""));
    }

    #[cfg(unix)]
    mod stub {
        use super::*;

        const OWNER: u64 = 1;
        const SOON: Duration = Duration::from_secs(3);

        /// TeXpresso as a build with Underleaf's patch speaks, beside an engine it starts. It
        /// writes each command it is sent to `commands` in the folder above its own, and
        /// answers a few as TeXpresso would.
        const STUB: &str = r#"#!/bin/sh
here=${0%/bin/texpresso}
/bin/sleep 300 &
echo $! > "$here/engine.pid"
pages=${TEXPRESSO_PDF_OUTPUT%/*}
n=0
printf '["append","out",0,"ready"]\n["pdf","%s",3,"partial",[[0,2]],0]\n' "$TEXPRESSO_PDF_OUTPUT"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$here/commands"
  case "$line" in
    *EXIT_CLEAN*) exit 0;;
    *EXIT_STUB*) exit 7;;
    *TEX_ERROR*) printf '["append","log",0,"! Undefined control sequence."]\n';;
    '["mark",'*) printf '["synced",%s\n' "${line#*,}";;
    '["change",'*) n=$((n + 1))
      printf '["page",1,"%s/page-1-%s.pdf",0]\n' "$pages" "$n";;
    *rerun-once*)
      printf '["pdf","%s",4,"complete",[[1,1],[3,3]],0]\n' "$TEXPRESSO_PDF_OUTPUT"
      printf '["done",4,"complete"]\n';;
  esac
done
"#;

        fn setup() -> (tempfile::TempDir, PathBuf, String) {
            use std::os::unix::fs::PermissionsExt;
            let tmp = tempfile::tempdir().unwrap();
            let (bin, root) = (tmp.path().join("bin"), tmp.path().join("project"));
            fs::create_dir(&bin).unwrap();
            fs::create_dir(&root).unwrap();
            fs::write(root.join("main.tex"), "disk text").unwrap();
            fs::write(bin.join("texpresso"), STUB).unwrap();
            let executable = fs::Permissions::from_mode(0o755);
            fs::set_permissions(bin.join("texpresso"), executable).unwrap();
            (tmp, root, bin.to_string_lossy().into_owned())
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

        fn commands(tmp: &tempfile::TempDir) -> Vec<Value> {
            fs::read_to_string(tmp.path().join("commands"))
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }

        type Events = mpsc::UnboundedReceiver<LiveEvent>;

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

        fn shown(event: &LiveEvent) -> bool {
            *event != LiveEvent::Log
        }

        /// A start for `OWNER`, with `main.tex` open in the editor at `text` if given.
        fn start(
            manager: &Manager,
            root: &Path,
            path_env: &str,
            text: Option<&str>,
            pane: &Pane,
        ) -> (Status, Events) {
            let (tx, events) = mpsc::unbounded_channel();
            let sink = Box::new(move |event| drop(tx.send(event)));
            let files: Vec<_> = (text.into_iter())
                .map(|text| FileBuffer {
                    path: "main.tex".into(),
                    text: text.into(),
                })
                .collect();
            let project = Project::in_folder(root);
            let status = manager.start(OWNER, &project, &files, path_env, pane, sink);
            (status.unwrap(), events)
        }

        fn begin(manager: &Manager, root: &Path, path_env: &str) -> Status {
            start(manager, root, path_env, None, &Pane::default()).0
        }

        #[tokio::test]
        async fn the_vfs_has_the_editors_texts_and_each_whole_text_goes_as_a_change() {
            use std::os::unix::fs::PermissionsExt;
            let (tmp, root, path_env) = setup();
            let manager = Manager::default();
            fs::create_dir_all(root.join("build")).unwrap();
            let normal = root.join("build/texpresso-live.pdf");
            fs::write(&normal, "normal build").unwrap();
            let (first, mut events) =
                start(&manager, &root, &path_env, Some("abc"), &Pane::default());
            assert!(first.running);
            let LiveEvent::Document { path, .. } = next(&mut events, document).await else {
                unreachable!()
            };
            let pdf = PathBuf::from(path);
            assert!(
                pdf.ends_with("live.pdf") && !pdf.starts_with(dunce::canonicalize(&root).unwrap())
            );
            let folder = pdf.parent().unwrap().to_owned();
            let mode = fs::metadata(&folder).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);
            assert_eq!(fs::read(&normal).unwrap(), b"normal build");
            until(|| !commands(&tmp).is_empty()).await;
            let main = dunce::canonicalize(root.join("main.tex")).unwrap();
            assert_eq!(commands(&tmp)[0], json!(["open", main, "abc"]));
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
                    let change = changes().pop().unwrap();
                    let start = change[2].as_u64().unwrap() as usize;
                    let end = start + change[3].as_u64().unwrap() as usize;
                    text.replace_range(start..end, change[4].as_str().unwrap());
                }
                assert_eq!(text, edit);
            }
            assert_eq!(changes().len(), 3);
            assert_eq!(fs::read_to_string(&main).unwrap(), "disk text");
            manager.rescan(OWNER).unwrap();
            until(|| commands(&tmp).iter().any(|c| c[0] == "rescan")).await;
            assert!(!manager.stop_request(OWNER).running);
            assert!(!folder.exists());
            assert_eq!(manager.status(OWNER).unwrap_err().status, 404);
            begin(&manager, &root, &path_env);
            manager.kill_all();
            assert!(!manager.status(OWNER).unwrap().running);
        }

        #[tokio::test]
        async fn a_start_stops_the_owners_preview_before_it() {
            let (_tmp, root, path_env) = setup();
            let (_other_tmp, other_root, _) = setup();
            let manager = Manager::default();
            begin(&manager, &other_root, &path_env);
            let before = manager.owned(OWNER).unwrap();
            assert!(begin(&manager, &root, &path_env).running);
            assert!(!before.running());
        }

        #[tokio::test]
        async fn an_exit_keeps_the_output_says_why_and_stops_the_engine_group() {
            let (tmp, root, path_env) = setup();
            let manager = Manager::default();
            let (_, mut events) = start(&manager, &root, &path_env, None, &Pane::default());
            let engine = || fs::read_to_string(tmp.path().join("engine.pid"));
            until(|| engine().is_ok() && manager.status(OWNER).unwrap().output == "ready").await;
            let engine: i32 = engine().unwrap().trim().parse().unwrap();
            manager.update(OWNER, "main.tex", "EXIT_STUB").unwrap();
            let ended = next(&mut events, |e| matches!(e, LiveEvent::Ended(_))).await;
            let LiveEvent::Ended(Some(error)) = ended else {
                panic!("{ended:?}")
            };
            assert!(error.contains("exited"), "{error}");
            let status = manager.status(OWNER).unwrap();
            assert!(!status.running && status.output == "ready");
            until(|| unsafe { libc::kill(engine, 0) == -1 }).await;
        }

        #[tokio::test]
        async fn the_log_follows_backtracking_and_has_the_programs_own_output_once_it_fails() {
            let (_tmp, root, path_env) = setup();
            let manager = Manager::default();
            begin(&manager, &root, &path_env);
            let session = manager.owned(OWNER).unwrap();
            // Backtracking drops TeX's log, and the process's historical stderr is
            // not put in its place.
            let diagnostic = "Undefined control sequence";
            lock(&session.state).stderr.append(0, diagnostic.as_bytes());
            apply_message(&session, &json!(["append", "log", 0, diagnostic]));
            assert!(session.status().log.contains(diagnostic));
            assert_eq!(manager.tex_log(OWNER).as_deref(), Some(diagnostic));
            apply_message(&session, &json!(["truncate", "log", 0]));
            assert!(!session.status().log.contains(diagnostic));

            session.stop(Some("TeXpresso exited".into()));
            let status = manager.status(OWNER).unwrap();
            assert!(!status.running && status.error.is_some());
            assert!(status.log.contains(diagnostic));
        }

        #[tokio::test]
        async fn a_keystroke_goes_as_bytes_at_once_and_one_that_does_not_fit_is_refused() {
            let (tmp, root, path_env) = setup();
            let manager = Manager::default();
            let pane = Pane {
                view: Some((2, 3)),
                caret: Some(("main.tex".into(), 4)),
            };
            start(&manager, &root, &path_env, Some("aé😀b"), &pane);
            let path = dunce::canonicalize(root.join("main.tex")).unwrap();
            manager.edit(OWNER, "main.tex", 4, 0, "X").unwrap();
            manager.view(OWNER, 5, 4).unwrap();
            manager.caret(OWNER, "main.tex", 2).unwrap();
            until(|| commands(&tmp).len() >= 6).await;
            let sent = commands(&tmp);
            assert_eq!(
                sent[1..],
                [
                    json!(["view", 2, 3]),
                    json!(["caret", path, 7]),
                    json!(["change", path, 7, 0, "X"]),
                    json!(["view", 5, 5]),
                    json!(["caret", path, 3]),
                ]
            );
            assert!(!sent.iter().any(|c| c[0] == "rerun"));

            let refused = manager.edit(OWNER, "other.tex", 0, 0, "no");
            assert_eq!(refused.unwrap_err().status, 412);
            let refused = manager.edit(OWNER + 1, "main.tex", 0, 0, "x");
            assert_eq!(refused.unwrap_err().status, 404);
            manager.update(OWNER, "main.tex", "aXb").unwrap();
            manager.edit(OWNER, "main.tex", 3, 0, "!").unwrap();
            until(|| commands(&tmp).len() >= 8).await;
            assert_eq!(
                commands(&tmp)[6..],
                [
                    json!(["change", path, 1, 6, ""]),
                    json!(["change", path, 3, 0, "!"]),
                ]
            );
            manager.stop(&root).unwrap();
            manager.edit(OWNER, "main.tex", 0, 0, "x").unwrap();
        }

        #[tokio::test]
        async fn pages_and_documents_come_as_typeset_and_the_end_after_them() {
            let (_tmp, root, path_env) = setup();
            let manager = Manager::default();
            let (_, mut events) = start(&manager, &root, &path_env, Some("abc"), &Pane::default());
            let session = manager.owned(OWNER).unwrap();
            let first = next(&mut events, document).await;
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
            let folder = PathBuf::from(&path).parent().unwrap().to_owned();
            for n in 1..=2 {
                manager.edit(OWNER, "main.tex", 3, 0, "d").unwrap();
                let page = next(&mut events, shown).await;
                let path = folder.join(format!("page-1-{n}.pdf"));
                let path = path.to_string_lossy().into_owned();
                assert_eq!(page, LiveEvent::Page { page: 1, path });
            }
            apply_message(&session, &json!(["page", 0, "/etc/passwd", 0]));
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
            manager.mark(OWNER, 3).unwrap();
            assert_eq!(next(&mut events, shown).await, LiveEvent::Synced(3));
            manager.stop(&root).unwrap();
            assert_eq!(next(&mut events, shown).await, LiveEvent::Ended(None));
        }
    }
}
