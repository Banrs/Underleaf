use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use schemars::JsonSchema;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use texlocal_latex::diff::delta;
use texlocal_latex::message::Message;
use texlocal_latex::utf16::byte_offset;

use crate::messages;
use crate::paths::{self, Project};
use crate::process::{self, Processes, Tree};
use crate::tex::{find_tool, program_at};
use crate::{CoreError, lock, settings, sys, tail};

const MAX_OUTPUT: usize = 128 * 1024;
const MAX_LOG: usize = 16 * 1024 * 1024;
const MAX_MESSAGE: usize = 64 * 1024 * 1024;
const UNREAD: Duration = Duration::from_secs(60);
const LIVE_VERSION: u64 = 3;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveEvent {
    Page {
        page: u32,
        pdf: String,
    },
    Document {
        path: String,
        pages: u32,
        run: String,
        changed: Vec<PageRange>,
    },
    Done(String),
    Synced(u64),
    Log,
    Ended(Option<Message>),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
pub struct PageRange {
    pub first: u32,
    pub last: u32,
}

pub type Sink = Box<dyn Fn(LiveEvent) + Send + Sync>;

pub trait Preview: Send + Sync {
    fn available(&self, path_env: &str) -> bool;
    fn start(
        &self,
        project: &Project,
        files: &[FileBuffer],
        path_env: &str,
        pane: &Pane,
        sink: Sink,
    ) -> Result<Arc<dyn LiveRun>, CoreError>;
}

pub trait LiveRun: Send + Sync {
    fn update(&self, rel: &str, text: &str);
    fn edit(&self, rel: &str, start: usize, remove: usize, text: &str) -> bool;
    fn view(&self, first: u32, last: u32);
    fn caret(&self, rel: &str, offset: usize);
    fn rescan(&self);
    fn mark(&self, mark: u64);
    fn log(&self) -> String;
    fn tex_log(&self) -> Option<String>;
    fn text(&self, rel: &str) -> Option<String>;
    fn pdf(&self) -> Result<PathBuf, CoreError>;
    fn stop(&self);
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
    error: Option<Message>,
}

struct Session {
    root: PathBuf,
    pdf: PathBuf,
    state: Mutex<State>,
    files: Mutex<HashMap<String, String>>,
    sink: Sink,
}

impl Session {
    fn new(
        root: PathBuf,
        pdf: PathBuf,
        files: HashMap<String, String>,
        sink: Sink,
        tree: Tree,
    ) -> (Arc<Self>, mpsc::UnboundedReceiver<Vec<u8>>) {
        let (lines, queued) = mpsc::unbounded_channel();
        let session = Arc::new(Self {
            root,
            pdf,
            files: Mutex::new(files),
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
        (session, queued)
    }
    fn running(&self) -> bool {
        lock(&self.state).link.is_some()
    }
    fn end(&self, error: Option<Message>) {
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

impl LiveRun for Session {
    fn update(&self, rel: &str, text: &str) {
        let mut files = lock(&self.files);
        if !self.running() {
            return;
        }
        let path = self.root.join(rel);
        let message = match files.get(rel).map(|old| delta(old, text)) {
            Some((_, 0, "")) => return,
            Some((offset, remove, inserted)) => json!(["change", path, offset, remove, inserted]),
            None => json!(["open", path, text]),
        };
        self.send(&[message]);
        files.insert(rel.to_owned(), text.to_owned());
    }
    fn edit(&self, rel: &str, start: usize, remove: usize, text: &str) -> bool {
        let mut files = lock(&self.files);
        if !self.running() {
            return true;
        }
        let spliced = files
            .get_mut(rel)
            .and_then(|held| splice(held, start, remove, text));
        let Some((offset, removed)) = spliced else {
            return false;
        };
        let path = self.root.join(rel);
        self.send(&[json!(["change", path, offset, removed, text])]);
        true
    }
    fn view(&self, first: u32, last: u32) {
        self.send(&[json!(["view", first, last.max(first)])]);
    }
    fn caret(&self, rel: &str, offset: usize) {
        let offset = (lock(&self.files).get(rel)).and_then(|text| byte_offset(text, offset));
        if let Some(offset) = offset {
            self.send(&[json!(["caret", self.root.join(rel), offset])]);
        }
    }
    fn rescan(&self) {
        self.send(&[json!(["rescan"])]);
    }
    fn mark(&self, mark: u64) {
        self.send(&[json!(["mark", mark])]);
    }
    fn log(&self) -> String {
        let state = lock(&self.state);
        let mut log = state.log.text();
        if !state.protocol_seen || state.error.is_some() {
            log.push_str(tail(&state.stderr.text(), 16 * 1024));
        }
        let texts = [tail(&log, MAX_OUTPUT), &state.output.text()];
        let texts: Vec<&str> = texts.into_iter().filter(|text| !text.is_empty()).collect();
        texts.join("\n\n")
    }
    fn tex_log(&self) -> Option<String> {
        let log = &lock(&self.state).log;
        (log.base == 0).then(|| String::from_utf8_lossy(&log.bytes).into_owned())
    }
    fn text(&self, rel: &str) -> Option<String> {
        lock(&self.files).get(rel).cloned()
    }
    fn pdf(&self) -> Result<PathBuf, CoreError> {
        if !self.pdf.with_extension("synctex").is_file() {
            return Err(CoreError::not_found(messages::texpresso_unsynced()));
        }
        Ok(self.pdf.clone())
    }
    fn stop(&self) {
        self.end(None);
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.end(None);
    }
}

fn remove_pdf_folder(pdf: &Path) {
    if let Some(folder) = pdf.parent() {
        let _ = fs::remove_dir_all(folder);
    }
}

#[derive(Default)]
pub struct Manager {
    processes: Arc<Processes>,
    sessions: Mutex<Vec<Weak<Session>>>,
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.stop_all();
    }
}

impl Manager {
    pub(crate) fn new(processes: Arc<Processes>) -> Self {
        Self {
            processes,
            sessions: Mutex::default(),
        }
    }

    pub fn stop_all(&self) {
        for session in lock(&self.sessions).iter().filter_map(Weak::upgrade) {
            session.end(None);
        }
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
    command
}

impl Preview for Manager {
    fn available(&self, path_env: &str) -> bool {
        discover(path_env).is_some()
    }
    fn start(
        &self,
        project: &Project,
        files: &[FileBuffer],
        path_env: &str,
        pane: &Pane,
        sink: Sink,
    ) -> Result<Arc<dyn LiveRun>, CoreError> {
        let root = fs::canonicalize(&project.root)?;
        let main = settings::read_settings(&project.settings).main_file;
        let main = paths::safe_path(&root, &main)?;
        if !main.is_file() {
            return Err(CoreError::bad_request(messages::live_no_main()));
        }
        let none = || CoreError::not_found(messages::no_texpresso());
        let executable = discover(path_env).ok_or_else(none)?;
        fs::create_dir_all(&project.build)?;
        let build = fs::canonicalize(&project.build)?;
        let mut folder = tempfile::Builder::new();
        folder.prefix("texlocal-texpresso-");
        sys::private(&mut folder);
        let pdf = fs::canonicalize(folder.tempdir()?.keep())?.join("live.pdf");
        let mut command = command(&executable, path_env, &build, &main, &root, &pdf);
        let (mut child, tree) = self.processes.spawn(None, &mut command).map_err(|err| {
            remove_pdf_folder(&pdf);
            CoreError::internal(messages::texpresso_unstarted(err))
        })?;
        let (buffers, opening) = opening(&root, files, pane);
        let (session, queued) = Session::new(root, pdf, buffers, sink, tree.clone());
        let mut sessions = lock(&self.sessions);
        sessions.retain(|session| session.strong_count() > 0);
        sessions.push(Arc::downgrade(&session));
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
        Ok(session)
    }
}

pub(crate) fn discover(path_env: &str) -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("TEXLOCAL_TEXPRESSO").filter(|p| !p.is_empty()) {
        return program_at(Path::new(&override_path));
    }
    find_tool("texpresso", path_env).and_then(|p| fs::canonicalize(p).ok())
}

async fn stop_on_exit(exit: impl Future<Output = Option<String>>, session: Weak<Session>) {
    struct Stop(Weak<Session>, Option<Message>);
    impl Drop for Stop {
        fn drop(&mut self) {
            if let Some(session) = self.0.upgrade() {
                session.end(self.1.take());
            }
        }
    }
    let mut stop = Stop(session, None);
    stop.1 = (exit.await).map(messages::texpresso_exited);
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
            Ok(Err(err)) => messages::io_error(err),
            Err(_) => messages::viewer_stopped(),
        };
        if let Some(session) = session.upgrade() {
            session.end(Some(messages::texpresso_unsent(error)));
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
                    apply_message(&session, message);
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

fn apply_message(session: &Session, mut message: Value) {
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
        return session.end(Some(messages::live_unpatched()));
    }
    let event = match verb {
        "page" => match (number(1), message[2].take()) {
            (Some(page), Value::String(pdf)) => LiveEvent::Page { page, pdf },
            _ => return,
        },
        "pdf" => {
            let (Some(run), Some(ranges)) = (message[3].as_str(), message[4].as_array()) else {
                return;
            };
            let page = |range: &Value, at: usize| range[at].as_u64().unwrap_or(0) as u32;
            LiveEvent::Document {
                path: session.pdf.to_string_lossy().into_owned(),
                pages: number(2).unwrap_or(0),
                run: run.to_owned(),
                changed: ranges
                    .iter()
                    .map(|r| PageRange {
                        first: page(r, 0),
                        last: page(r, 1),
                    })
                    .collect(),
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

#[cfg(test)]
mod tests {
    use std::sync::mpsc::{Receiver, channel};

    use super::*;
    use crate::settings::AppSettings;
    use crate::tex::tool_paths;

    fn heard(events: &Receiver<LiveEvent>, quiet: Duration) -> Vec<LiveEvent> {
        std::iter::from_fn(|| events.recv_timeout(quiet).ok()).collect()
    }

    fn typesets(events: &[LiveEvent]) -> usize {
        events
            .iter()
            .filter(|e| matches!(e, LiveEvent::Done(_)))
            .count()
    }

    async fn typed(run: &dyn LiveRun, at: usize, keys: &str) {
        for (i, key) in keys.char_indices() {
            assert!(run.edit("main.tex", at + i, 0, &key.to_string()));
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "needs TeX and TeXpresso"]
    async fn typing_typesets_the_view_then_the_rest_once_it_settles() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("p");
        fs::create_dir(&root).unwrap();
        let para = "A sentence that fills a line of the page. ".repeat(60);
        let section = |n: usize| {
            let next = n % 8 + 1;
            format!(
                "\\section{{Part {n}}}\\label{{s{n}}}\n{para}\n\n{para}\n\nSee page~\\pageref{{s{next}}}.\n"
            )
        };
        let sections: String = (1..=8).map(section).collect();
        let text = format!(
            "\\documentclass{{article}}\n\\begin{{document}}\n\\tableofcontents\n{sections}\\end{{document}}\n"
        );
        fs::write(root.join("main.tex"), &text).unwrap();
        let project = Project {
            build: root.join("build"),
            root,
            settings: dir.path().join("settings.json"),
            ui: dir.path().join("ui.json"),
            history: dir.path().join("history"),
        };
        let (tx, events) = channel();
        let sink: Sink = Box::new(move |event| drop(tx.send(event)));
        let manager = Manager::default();
        let files = [FileBuffer {
            path: "main.tex".into(),
            text: text.clone(),
        }];
        let pane = Pane {
            view: Some((0, 0)),
            caret: None,
        };
        let path = tool_paths(&AppSettings::default()).1;
        let run = manager.start(&project, &files, &path, &pane, sink).unwrap();
        let mut started = std::iter::from_fn(|| events.recv_timeout(Duration::from_secs(120)).ok());
        assert!(started.any(|event| matches!(event, LiveEvent::Done(_))));
        heard(&events, Duration::from_secs(5));

        typed(&*run, text.find("A sentence").unwrap(), "abcdefgh").await;
        let typing: Vec<_> = events.try_iter().collect();
        assert_eq!(typesets(&typing), 0, "only the page in view while typing");
        let settling = heard(&events, Duration::from_secs(5));
        let pages = (typing.iter().chain(&settling))
            .take_while(|e| !matches!(e, LiveEvent::Done(_)))
            .filter_map(|e| match e {
                LiveEvent::Page { page, .. } => Some(*page),
                _ => None,
            });
        let pages: Vec<u32> = pages.collect();
        assert!(
            !pages.is_empty() && pages.iter().all(|&page| page == 0),
            "{pages:?}"
        );
        assert!(
            (1..=3).contains(&typesets(&settling)),
            "the rest once, then at most two passes"
        );

        let last = text.rfind("A sentence").unwrap();
        run.caret("main.tex", last);
        let moved = heard(&events, Duration::from_secs(3));
        assert_eq!(typesets(&moved), 0, "a caret move alone typesets nothing");

        typed(&*run, text.find("{Part 1}").unwrap() + 5, "xy").await;
        let retitled = typesets(&heard(&events, Duration::from_secs(6)));
        assert!(
            (2..=3).contains(&retitled),
            "the run and at most two passes"
        );
        run.stop();
    }
}
