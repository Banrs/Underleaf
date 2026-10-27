use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::paths::{self, Project};
use crate::process::{self, Tree};
use crate::tex::{find_tool, program_at};
use crate::{CoreError, lock, settings, sys, tail};

const MAX_OUTPUT: usize = 128 * 1024;
const MAX_LOG: usize = 16 * 1024 * 1024;
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
const UNREAD: Duration = Duration::from_secs(60);
const NOT_RUNNING: &str = "Live Preview isn't running.";
const UNPATCHED: &str = "This TeXpresso doesn't have Underleaf's patch, or has an older one. Build it with tools/texpresso/build.sh.";
const LIVE_VERSION: u64 = 2;
const UNFIT: &str = "The edit doesn't fit the text TeXpresso has. Send the whole text.";

#[derive(Debug)]
pub struct FileBuffer {
    pub path: String,
    pub text: String,
}

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
    Document {
        path: String,
        pages: u32,
        run: String,
        changed: Vec<[u32; 2]>,
    },
    Done(String),
    Synced(u64),
    Log,
    Ended(Option<String>),
}

pub type Sink = Box<dyn Fn(LiveEvent) + Send + Sync>;

pub(crate) trait Preview: Send + Sync {
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
    fn mark(&self, owner: u64, mark: u64) -> Result<(), CoreError>;
    fn tex_log(&self, owner: u64) -> Option<String>;
    fn status(&self, owner: u64) -> Result<Status, CoreError>;
    fn stop_request(&self, owner: u64) -> Status;
    fn stop(&self, root: &Path) -> Result<(), CoreError>;
}

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
    fn text(&self) -> String {
        let start = self.bytes.len().saturating_sub(MAX_OUTPUT);
        String::from_utf8_lossy(&self.bytes[start..]).into_owned()
    }
}

fn byte_offset(text: &str, units: usize) -> Option<usize> {
    let mut counted = 0;
    for (at, char) in text.char_indices() {
        if counted >= units {
            return (counted == units).then_some(at);
        }
        counted += char.len_utf16();
    }
    (counted == units).then_some(text.len())
}

fn splice(
    text: &mut String,
    start: usize,
    remove: usize,
    inserted: &str,
) -> Option<(usize, usize)> {
    let offset = byte_offset(text, start)?;
    let removed = byte_offset(&text[offset..], remove)?;
    text.replace_range(offset..offset + removed, inserted);
    Some((offset, removed))
}

struct Link {
    lines: mpsc::UnboundedSender<Vec<u8>>,
    tree: Tree,
}

#[derive(Default)]
struct State {
    link: Option<Link>,
    output: Output,
    log: Output,
    live: bool,
    protocol_seen: bool,
    stderr: Output,
    error: Option<String>,
}

struct Session {
    root: PathBuf,
    pdf: PathBuf,
    state: Mutex<State>,
    files: Mutex<HashMap<String, String>>,
    sink: Sink,
}

impl Session {
    fn running(&self) -> bool {
        lock(&self.state).link.is_some()
    }
    fn stop(&self, error: Option<String>) {
        let link = {
            let mut state = lock(&self.state);
            let link = state.link.take();
            if link.is_some() {
                state.error.clone_from(&error);
            }
            link
        };
        let Some(link) = link else { return };
        link.tree.kill();
        remove_pdf_folder(&self.pdf);
        lock(&self.files).clear();
        (self.sink)(LiveEvent::Ended(error));
    }
    fn status(&self) -> Status {
        let state = lock(&self.state);
        let mut log = state.log.text();
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
    pub fn live_text(&self, owner: u64, rel: &str) -> Option<String> {
        lock(&self.owned(owner).ok()?.files).get(rel).cloned()
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
    fn prepare(&self, owner: u64, project: &Project) -> Result<(PathBuf, PathBuf), CoreError> {
        fs::create_dir_all(&project.build)?;
        let build = std::fs::canonicalize(&project.build)?;
        if let Some(previous) = lock(&self.sessions).get(&owner) {
            previous.stop(None);
        }
        let mut folder = tempfile::Builder::new();
        folder.prefix("texlocal-texpresso-");
        folder.permissions(sys::permissions(0o700));
        let pdf = std::fs::canonicalize(folder.tempdir()?.keep())?.join("live.pdf");
        Ok((build, pdf))
    }

    fn open(
        &self,
        owner: u64,
        root: PathBuf,
        pdf: PathBuf,
        buffers: HashMap<String, String>,
        sink: Sink,
        tree: Tree,
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
        if self.shutdown.load(Ordering::Acquire) {
            session.stop(None);
        }
        sessions.insert(owner, Arc::clone(&session));
        (session, queued)
    }
}

fn opening(
    root: &Path,
    files: &[FileBuffer],
    pane: &Pane,
) -> (HashMap<String, String>, Vec<Value>) {
    let mut buffers = HashMap::new();
    let mut opening = Vec::new();
    for file in files {
        opening.push(json!(["open", root.join(&file.path), file.text]));
        buffers.insert(file.path.clone(), file.text.clone());
    }
    let view = pane
        .view
        .map(|(first, last)| json!(["view", first, last.max(first)]));
    let caret = pane.caret.as_ref().and_then(|(rel, units)| {
        let offset = byte_offset(buffers.get(rel)?, *units)?;
        Some(json!(["caret", root.join(rel), offset]))
    });
    opening.extend(view.into_iter().chain(caret));
    (buffers, opening)
}

fn command(
    executable: &Path,
    path_env: &str,
    build: &Path,
    main: &Path,
    root: &Path,
    pdf: &Path,
) -> tokio::process::Command {
    let mut command = process::tool(executable, path_env);
    command
        .args(["-json", "-texlive", "-I"])
        .arg(build)
        .arg(main)
        .current_dir(root)
        .stdin(Stdio::piped())
        .env("TEXPRESSO_PDF_OUTPUT", pdf);
    sys::default_signals(&mut command);
    command
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
        let root = std::fs::canonicalize(&project.root)?;
        let main = settings::read_settings(&project.settings).main_file;
        let main = paths::safe_path(&root, &main)?;
        if !main.is_file() {
            return Err(CoreError::bad_request("The main file does not exist."));
        }
        let (buffers, opening) = opening(&root, files, pane);
        let failed = |error: String| {
            Ok(Status {
                error: Some(error),
                ..Status::default()
            })
        };
        let Some(executable) = discover(path_env) else {
            return failed(sys::NO_TEXPRESSO.into());
        };
        let (build, pdf) = self.prepare(owner, project)?;
        let mut command = command(&executable, path_env, &build, &main, &root, &pdf);
        let (mut child, tree) = match Tree::spawn(&mut command) {
            Ok(spawned) => spawned,
            Err(err) => {
                remove_pdf_folder(&pdf);
                return failed(format!(
                    "Couldn't start TeXpresso: {err}. Check TEXLOCAL_TEXPRESSO and its dependencies."
                ));
            }
        };
        let (session, queued) = self.open(owner, root, pdf, buffers, sink, tree.clone());
        let (stdin, stdout, stderr) =
            (child.stdin.take(), child.stdout.take(), child.stderr.take());
        let weak = Arc::downgrade(&session);
        tokio::spawn(write_lines(stdin.unwrap(), queued, weak.clone()));
        tokio::spawn(read_output(stdout.unwrap(), Arc::clone(&session), true));
        tokio::spawn(read_output(stderr.unwrap(), Arc::clone(&session), false));
        let exit = async move {
            match tree.ended(&mut child).await {
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
        let message = match files.get(rel).map(|old| delta(old, text)) {
            Some((_, 0, "")) => return Ok(()),
            Some((offset, remove, inserted)) => json!(["change", path, offset, remove, inserted]),
            None => json!(["open", path, text]),
        };
        session.send(&[message]);
        files.insert(rel.to_owned(), text.to_owned());
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
        let root = std::fs::canonicalize(root)?;
        for session in lock(&self.sessions).values().filter(|s| s.root == root) {
            session.stop(None);
        }
        Ok(())
    }
}

pub(crate) fn discover(path_env: &str) -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("TEXLOCAL_TEXPRESSO").filter(|p| !p.is_empty()) {
        return program_at(Path::new(&override_path));
    }
    find_tool("texpresso", path_env).and_then(|p| std::fs::canonicalize(p).ok())
}

fn common<T: PartialEq>(a: impl Iterator<Item = T>, b: impl Iterator<Item = T>) -> usize {
    a.zip(b).take_while(|(a, b)| a == b).count()
}

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
            while let Some(end) = rest.iter().position(|&byte| byte == b'\n') {
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
            drop(state);
            (session.sink)(LiveEvent::Log);
        }
        reader.consume(count);
    }
}

fn apply_message(session: &Session, message: &Value) {
    let verb = message[0].as_str().unwrap_or_default();
    let number = |index: usize| message[index].as_u64().map(|n| n as u32);
    let live = {
        let mut state = lock(&session.state);
        if !state.live && verb == "live" && message[1] == LIVE_VERSION {
            (state.live, state.protocol_seen) = (true, true);
            return;
        }
        state.live
    };
    if !live {
        return session.stop(Some(UNPATCHED.into()));
    }
    let event = match verb {
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
            let (Some(run), Some(ranges)) = (message[3].as_str(), message[4].as_array()) else {
                return;
            };
            let page = |range: &Value, at: usize| range[at].as_u64().unwrap_or(0) as u32;
            LiveEvent::Document {
                path: session.pdf.to_string_lossy().into_owned(),
                pages: number(2).unwrap_or(0),
                run: run.to_owned(),
                changed: ranges.iter().map(|r| [page(r, 0), page(r, 1)]).collect(),
            }
        }
        "done" => match message[1].as_str() {
            Some(run) => LiveEvent::Done(run.to_owned()),
            None => return,
        },
        "synced" => match message[1].as_u64() {
            Some(mark) => LiveEvent::Synced(mark),
            None => return,
        },
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
