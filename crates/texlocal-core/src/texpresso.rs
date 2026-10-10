//! Optional persistent TeXpresso viewer. Author buffers stay in its VFS; the
//! ordinary latexmk build and PDF continue to use saved project files.
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::ChildStdin;

use crate::{lock, paths, settings, tail, CoreError, BUILD_DIR, SETTINGS_FILE};

const MAX_FILE: usize = 8 * 1024 * 1024;
const MAX_FILES: usize = 256;
const MAX_TOTAL: usize = 64 * 1024 * 1024;
const MAX_OUTPUT: usize = 128 * 1024;
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
const LEASE: Duration = Duration::from_secs(120);
const MISSING: &str = "TeXpresso wasn't found. Choose the folder it's in, in Settings, or install it in /opt/homebrew/bin or /usr/local/bin.";
const REPLACED: &str =
    "Another window started TeXpresso for this project. Start TeXpresso again to preview here.";
const TOO_MANY: &str = "Too many files for TeXpresso (limit 256 files / 64 MB).";

#[derive(Debug, Deserialize)]
pub struct FileBuffer {
    pub path: String,
    pub text: String,
}

/// `Status`'s document fields alone (`Manager::pdf_state`).
#[derive(Debug, Clone, Serialize)]
pub struct PdfState {
    pub running: bool,
    pub pdf: Option<String>,
    #[serde(rename = "pdfVersion")]
    pub pdf_version: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub available: bool,
    pub running: bool,
    pub executable: Option<String>,
    pub log: String,
    pub output: String,
    pub error: Option<String>,
    pub revision: u64,
    pub session: Option<String>,
    /// The whole document as TeXpresso last wrote it, when its build writes one
    /// (TEXPRESSO_PDF_OUTPUT), and how many times it has.
    pub pdf: Option<String>,
    #[serde(rename = "pdfVersion")]
    pub pdf_version: u64,
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

struct State {
    pid: Option<u32>,
    last_used: Instant,
    output: Output,
    log: Output,
    protocol_seen: bool,
    stderr: Output,
    error: Option<String>,
    revision: u64,
    pdf_version: u64,
    /// The settings file as last seen, by `settings_stamp`.
    settings: Stamp,
}
struct Input {
    stdin: ChildStdin,
    files: HashMap<PathBuf, String>,
    /// Where the paths clients send lead, found once: a session's files
    /// don't move under it, as a rename or delete stops it.
    paths: HashMap<String, PathBuf>,
}
struct Session {
    token: String,
    executable: PathBuf,
    main: String,
    /// Where a patched build writes the document, when the client shows it.
    pdf: Option<PathBuf>,
    state: Mutex<State>,
    input: tokio::sync::Mutex<Input>,
    revision: Arc<AtomicU64>,
}
impl Session {
    /// Where the document is, once TeXpresso has written it.
    fn written_pdf(&self, state: &State) -> Option<&Path> {
        self.pdf.as_deref().filter(|_| state.pdf_version > 0)
    }
    fn bump(&self, state: &mut State) {
        state.revision = self.revision.fetch_add(1, Ordering::Relaxed) + 1;
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
        lock(&self.state).pid.is_some()
    }
    fn stop(&self, error: Option<String>) {
        let mut state = lock(&self.state);
        if let Some(pid) = state.pid.take() {
            // The viewer starts an engine: stopping just its parent leaks it.
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
            remove_pdf_folder(self.pdf.as_deref());
            state.error = error;
            self.bump(&mut state);
            if let Ok(mut input) = self.input.try_lock() {
                input.files.clear();
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
            available: executable_file(&self.executable),
            running: state.pid.is_some(),
            executable: Some(self.executable.to_string_lossy().into_owned()),
            output: state.output.text(),
            log,
            error: state.error.clone(),
            revision: state.revision,
            session: Some(self.token.clone()),
            pdf: self
                .written_pdf(&state)
                .map(|pdf| pdf.to_string_lossy().into_owned()),
            pdf_version: state.pdf_version,
        }
    }
    async fn send(&self, messages: &[Value]) {
        let mut input = self.input.lock().await;
        if let Err(err) = write_messages(&mut input.stdin, messages).await {
            self.stop(Some(unsent(err)));
        }
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
        let root = fs::canonicalize(root)?;
        let Some(session) = self.session(&root, token)? else {
            return Ok(self.idle(path_env));
        };
        session.stop(None);
        // Explicit Stop ends ownership too; internal host invalidation
        // uses stop(root), retaining identity for a conditional restart.
        lock(&self.sessions).remove(&root);
        Ok(session.status())
    }
    /// The session's document alone, for a client waiting on it after an edit: no log, and
    /// no settings read, so it can ask often.
    pub fn pdf_state(&self, root: &Path, token: &str) -> Result<PdfState, CoreError> {
        let session = self.owned(&fs::canonicalize(root)?, token)?;
        let mut state = lock(&session.state);
        state.last_used = Instant::now();
        Ok(PdfState {
            running: state.pid.is_some(),
            pdf: session
                .written_pdf(&state)
                .map(|pdf| pdf.to_string_lossy().into_owned()),
            pdf_version: state.pdf_version,
        })
    }
    /// The live document the client's session last wrote, which has its SyncTeX beside it.
    pub fn live_pdf(&self, root: &Path, token: &str) -> Result<PathBuf, CoreError> {
        let session = self.owned(&fs::canonicalize(root)?, token)?;
        let state = lock(&session.state);
        session
            .written_pdf(&state)
            .filter(|pdf| pdf.with_extension("synctex").is_file())
            .map(Path::to_path_buf)
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
    /// The project's session; with a token, only while that client still owns it.
    fn session(&self, root: &Path, token: Option<&str>) -> Result<Option<Arc<Session>>, CoreError> {
        match token {
            Some(token) => self.owned(root, token).map(Some),
            None => Ok(lock(&self.sessions).get(root).cloned()),
        }
    }
    pub fn stop(&self, root: &Path) -> Result<(), CoreError> {
        let root = fs::canonicalize(root)?;
        let session = lock(&self.sessions).get(&root).cloned();
        if let Some(session) = session {
            session.stop(None);
        }
        Ok(())
    }
    fn idle(&self, path_env: &str) -> Status {
        let executable = discover(path_env);
        Status {
            available: executable.is_some(),
            running: false,
            executable: executable.map(|p| p.to_string_lossy().into_owned()),
            log: String::new(),
            output: String::new(),
            error: None,
            revision: self.revision.load(Ordering::Relaxed),
            session: None,
            pdf: None,
            pdf_version: 0,
        }
    }
    /// Inspection does not acquire ownership or renew the viewer's lease.
    pub fn status(
        &self,
        root: &Path,
        token: Option<&str>,
        path_env: &str,
    ) -> Result<Status, CoreError> {
        let root = fs::canonicalize(root)?;
        let Some(session) = self.session(&root, token)? else {
            return Ok(self.idle(path_env));
        };
        if token.is_some() {
            session.renew(&root);
        }
        Ok(session.status())
    }
    pub async fn start(
        &self,
        root: &Path,
        files: &[FileBuffer],
        expected: Option<&str>,
        path_env: &str,
        pdf: bool,
    ) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = fs::canonicalize(root)?;
        // Automatic restart may only replace the same owner; an explicit user
        // Start omits the expectation to deliberately take over the project.
        if let Some(token) = expected {
            self.owned(&root, token)?;
        }
        let stamp = settings_stamp(&root);
        let main = settings::read_settings(&root).main_file;
        let (mut buffers, mut paths) = (HashMap::new(), HashMap::new());
        let main_path = validate_buffer(&root, &main, "", &paths)?;
        if !main_path.is_file() {
            return Err(CoreError::bad_request("The main file does not exist."));
        }
        for file in files {
            let path = validate_buffer(&root, &file.path, &file.text, &paths)?;
            paths.insert(file.path.clone(), path.clone());
            if buffers.insert(path, file.text.clone()).is_some() {
                return Err(CoreError::bad_request(
                    "Files sent to TeXpresso repeat a path.",
                ));
            }
        }
        check_limits(
            buffers.len(),
            buffers.values().map(String::len).sum::<usize>(),
        )?;
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
        let build = fs::canonicalize(build)?;
        self.stop(&root)?;
        let mut token = [0u8; 16];
        getrandom::fill(&mut token).map_err(|err| CoreError::internal(err.to_string()))?;
        let token: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
        // For a client that shows it, a build with Underleaf's patch writes the
        // document here instead of opening its own window; upstream opens one.
        // The session's own folder: no build output or other session shares it.
        let pdf = match pdf {
            true => {
                let folder = std::env::temp_dir().join(format!("texlocal-texpresso-{token}"));
                fs::DirBuilder::new().mode(0o700).create(&folder)?;
                Some(fs::canonicalize(folder)?.join("live.pdf"))
            }
            false => None,
        };
        let mut command = std::process::Command::new(&executable);
        command
            .args(["-json", "-texlive", "-I"])
            .arg(&build)
            .arg(&main_path)
            .current_dir(&root)
            .env("PATH", path_env)
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(pdf) = &pdf {
            command.env("TEXPRESSO_PDF_OUTPUT", pdf);
        }
        // A Mac app runs with signals ignored or blocked that a child inherits across exec.
        // TeXpresso stops a stale TeX worker with SIGTERM, and ignored it never ends: the
        // snapshot waiting on it never resumes, and live preview stops at the first edit.
        // SAFETY: only async-signal-safe calls, between fork and exec.
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
        let mut command = tokio::process::Command::from(command);
        command.kill_on_drop(true);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(err) => {
                remove_pdf_folder(pdf.as_deref());
                return failed(format!(
                "Couldn't start TeXpresso: {err}. Check TEXLOCAL_TEXPRESSO and its dependencies."
            ));
            }
        };
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let session = Arc::new(Session {
            token,
            executable,
            main,
            pdf,
            input: tokio::sync::Mutex::new(Input {
                stdin: child.stdin.take().unwrap(),
                files: buffers,
                paths,
            }),
            revision: Arc::clone(&self.revision),
            state: Mutex::new(State {
                pid: child.id(),
                last_used: Instant::now(),
                output: Output::default(),
                log: Output::default(),
                protocol_seen: false,
                stderr: Output::default(),
                error: None,
                revision: self.revision.fetch_add(1, Ordering::Relaxed) + 1,
                pdf_version: 0,
                settings: stamp,
            }),
        });
        {
            let mut sessions = lock(&self.sessions);
            if self.shutdown.load(Ordering::Acquire) {
                session.stop(None);
            }
            sessions.insert(root, Arc::clone(&session));
        }
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
        let mut messages = vec![json!(["rerun", true])];
        {
            let input = session.input.lock().await;
            messages.extend(
                input
                    .files
                    .iter()
                    .map(|(path, text)| json!(["open", path, text])),
            );
        }
        session.send(&messages).await;
        Ok(session.status())
    }
    /// An edit, sent as the change from the buffer TeXpresso has, which takes
    /// it in place: once per keystroke, so no copy of the whole buffer.
    pub async fn update(
        &self,
        root: &Path,
        rel: &str,
        text: &str,
        token: &str,
    ) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = fs::canonicalize(root)?;
        let session = self.owned(&root, token)?;
        if !session.renew(&root) {
            return Ok(session.status());
        }
        let mut input = session.input.lock().await;
        let input = &mut *input;
        let path = validate_buffer(&root, rel, text, &input.paths)?;
        let others = input.files.iter().filter(|(p, _)| *p != &path);
        check_limits(
            others.clone().count() + 1,
            others.map(|(_, t)| t.len()).sum::<usize>() + text.len(),
        )?;
        let previous = input.files.get_mut(&path);
        let change = previous.as_deref().map(|previous| delta(previous, text));
        let message = match change {
            Some((_, 0, "")) => return Ok(session.status()),
            Some((offset, remove, inserted)) => json!(["change", path, offset, remove, inserted]),
            None => json!(["open", path, text]),
        };
        if let Err(err) = write_messages(&mut input.stdin, &[message]).await {
            session.stop(Some(unsent(err)));
        } else {
            match (previous, change) {
                (Some(previous), Some((offset, remove, inserted))) => {
                    previous.replace_range(offset..offset + remove, inserted)
                }
                _ => {
                    input.paths.insert(rel.to_owned(), path.clone());
                    input.files.insert(path, text.to_owned());
                }
            }
            session.bump(&mut lock(&session.state));
        }
        Ok(session.status())
    }
    pub async fn rescan(&self, root: &Path, token: &str) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = fs::canonicalize(root)?;
        let session = self.owned(&root, token)?;
        if session.renew(&root) {
            session.send(&[json!(["rescan"])]).await;
        }
        Ok(session.status())
    }
}

pub(crate) fn executable_file(path: &Path) -> bool {
    path.is_absolute()
        && fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}
/// TEXLOCAL_TEXPRESSO, for development, else `texpresso` on the path.
pub(crate) fn discover(path_env: &str) -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("TEXLOCAL_TEXPRESSO").filter(|p| !p.is_empty()) {
        let path = PathBuf::from(override_path);
        return executable_file(&path).then_some(path);
    }
    std::env::split_paths(path_env)
        .map(|p| p.join("texpresso"))
        .find(|p| executable_file(p))
        .and_then(|p| fs::canonicalize(p).ok())
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
        return Err(CoreError::bad_request(
            "TeXpresso takes files of up to 8 MB.",
        ));
    }
    if path.len() > 4096 || path.contains('\0') || text.contains('\0') {
        return Err(CoreError::bad_request(
            "A file sent to TeXpresso has an invalid path or text.",
        ));
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
/// The settings file's identity, size and date, or None while it is
/// missing: every write the app makes replaces it, so a changed main file
/// shows here for one stat, where reading and parsing it would take more.
type Stamp = Option<(u64, i64, i64, u64)>;
fn settings_stamp(root: &Path) -> Stamp {
    let meta = fs::metadata(root.join(SETTINGS_FILE)).ok()?;
    Some((meta.ino(), meta.mtime(), meta.mtime_nsec(), meta.len()))
}
fn check_limits(files: usize, bytes: usize) -> Result<(), CoreError> {
    if files > MAX_FILES || bytes > MAX_TOTAL {
        return Err(CoreError::bad_request(TOO_MANY));
    }
    Ok(())
}
fn unsent(err: std::io::Error) -> String {
    format!("Couldn't send changes to TeXpresso: {err}. Start TeXpresso again.")
}
// Both boundaries must be UTF-8 boundaries even when differing codepoints
// share leading or trailing bytes.
fn delta<'a>(old: &str, new: &'a str) -> (usize, usize, &'a str) {
    let (a, b) = (old.as_bytes(), new.as_bytes());
    let mut start = a.iter().zip(b).take_while(|(a, b)| a == b).count();
    while !old.is_char_boundary(start) || !new.is_char_boundary(start) {
        start -= 1;
    }
    let mut suffix = a[start..]
        .iter()
        .rev()
        .zip(b[start..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    while !old.is_char_boundary(old.len() - suffix) || !new.is_char_boundary(new.len() - suffix) {
        suffix -= 1;
    }
    (
        start,
        old.len() - start - suffix,
        &new[start..new.len() - suffix],
    )
}
async fn write_messages(stdin: &mut ChildStdin, messages: &[Value]) -> std::io::Result<()> {
    let operation = async {
        for message in messages {
            let mut bytes = serde_json::to_vec(message)?;
            bytes.push(b'\n');
            stdin.write_all(&bytes).await?;
        }
        stdin.flush().await
    };
    tokio::time::timeout(Duration::from_secs(5), operation)
        .await
        .unwrap_or_else(|_| {
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "viewer stopped reading commands",
            ))
        })
}
async fn read_output(mut reader: impl AsyncRead + Unpin, session: Arc<Session>, protocol: bool) {
    let mut chunk = [0; 8192];
    let mut pending = Vec::new();
    loop {
        let count = match reader.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if !protocol {
            let mut state = lock(&session.state);
            let end = state.stderr.base + state.stderr.bytes.len() as u64;
            state.stderr.append(end, &chunk[..count]);
            session.bump(&mut state);
            continue;
        }
        for byte in &chunk[..count] {
            if *byte == b'\n' {
                if let Ok(message) = serde_json::from_slice::<Value>(&pending) {
                    if message[0] == "reset-sync" {
                        let mut input = session.input.lock().await;
                        let messages: Vec<_> = input
                            .files
                            .iter()
                            .map(|(p, t)| json!(["open", p, t]))
                            .collect();
                        let _ = write_messages(&mut input.stdin, &messages).await;
                    } else {
                        apply_message(&session, &message);
                    }
                }
                pending.clear();
            } else if pending.len() < MAX_MESSAGE {
                pending.push(*byte);
            }
        }
    }
}
fn apply_message(session: &Session, message: &Value) {
    let mut guard = lock(&session.state);
    let state = &mut *guard;
    // [pdf, path, pages]: the document written to the path it was given.
    if message[0] == "pdf" {
        if session.pdf.is_some() {
            state.pdf_version += 1;
            session.bump(state);
        }
        return;
    }
    let output = match message[1].as_str() {
        Some("out") => &mut state.output,
        Some("log") => &mut state.log,
        _ => return,
    };
    // Upstream sends [truncate, buffer, end] and [append, buffer, byte-offset, text].
    match (
        message[0].as_str(),
        message[2].as_u64(),
        message[3].as_str(),
    ) {
        (Some("truncate"), Some(end), _) => output.truncate(end),
        (Some("append"), Some(offset), Some(text)) => output.append(offset, text.as_bytes()),
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

    fn setup() -> (tempfile::TempDir, PathBuf, String) {
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
    async fn until(mut check: impl FnMut() -> bool) {
        tokio::time::timeout(Duration::from_secs(3), async {
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
    #[tokio::test]
    async fn persistent_vfs_protocol_validates_paths_and_reconstructs_unicode() {
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
        let first = manager
            .start(
                &root,
                &[FileBuffer {
                    path: "main.tex".into(),
                    text: original.into(),
                }],
                None,
                &path_env,
                true,
            )
            .await
            .unwrap();
        assert!(first.running && first.available);
        let token = first.session.as_deref().unwrap();
        let live = || manager.status(&root, None, &path_env).unwrap();
        until(|| live().pdf_version == 1).await;
        // The session's own, outside the project: never a build's output.
        let pdf = PathBuf::from(live().pdf.unwrap());
        assert!(pdf.ends_with("live.pdf") && !pdf.starts_with(fs::canonicalize(&root).unwrap()));
        assert_eq!(
            fs::read(root.join(BUILD_DIR).join("texpresso-live.pdf")).unwrap(),
            b"normal build"
        );
        until(|| commands(&tmp).len() >= 2).await;
        let sent = commands(&tmp);
        assert!(sent.iter().any(|c| c == &json!(["rerun", true])));
        let opened = sent.iter().find(|c| c[0] == "open").unwrap();
        assert_eq!(
            opened[1],
            fs::canonicalize(root.join("main.tex"))
                .unwrap()
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(opened[2], original);
        let second = manager
            .update(&root, "main.tex", updated, token)
            .await
            .unwrap();
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
        assert!(manager
            .update(&root, "../escape.tex", "bad", token)
            .await
            .is_err());
        assert!(manager
            .update(&root, "build/out.tex", "bad", token)
            .await
            .is_err());
        assert!(manager
            .update(&root, "main.tex", &"x".repeat(MAX_FILE + 1), token,)
            .await
            .is_err());
        manager.rescan(&root, token).await.unwrap();
        until(|| commands(&tmp).iter().any(|c| c[0] == "rescan")).await;
        assert!(
            !manager
                .stop_request(&root, Some(token), &path_env)
                .await
                .unwrap()
                .running
        );
        assert_eq!(
            manager
                .start(&root, &[], Some(token), &path_env, false)
                .await
                .unwrap_err()
                .status,
            409
        );
        let restarted = manager
            .start(&root, &[], None, &path_env, false)
            .await
            .unwrap();
        assert!(restarted.running && restarted.revision > second.revision);
        manager
            .update(
                &root,
                "main.tex",
                "EXIT_CLEAN",
                restarted.session.as_deref().unwrap(),
            )
            .await
            .unwrap();
        until(|| !manager.status(&root, None, &path_env).unwrap().running).await;
        assert!(manager
            .status(&root, None, &path_env)
            .unwrap()
            .error
            .is_none());
        manager
            .start(&root, &[], None, &path_env, false)
            .await
            .unwrap();
        manager.kill_all();
        assert!(!manager.status(&root, None, &path_env).unwrap().running);
    }
    #[tokio::test]
    async fn the_live_pdf_folder_goes_with_its_session() {
        let (_tmp, root, path_env) = setup();
        let manager = Manager::default();
        let live = manager
            .start(&root, &[], None, &path_env, true)
            .await
            .unwrap();
        until(|| manager.status(&root, None, &path_env).unwrap().pdf_version == 1).await;
        let pdf = PathBuf::from(manager.status(&root, None, &path_env).unwrap().pdf.unwrap());
        let folder = pdf.parent().unwrap().to_owned();
        // In a shared temporary folder, for its owner alone.
        let mode = fs::metadata(&folder).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
        manager
            .stop_request(&root, live.session.as_deref(), &path_env)
            .await
            .unwrap();
        assert!(!folder.exists());
    }
    #[tokio::test]
    async fn edits_follow_one_another_and_a_new_main_file_stops_the_session() {
        let (tmp, root, path_env) = setup();
        let manager = Manager::default();
        let buffer = |text: &str| {
            vec![FileBuffer {
                path: "main.tex".into(),
                text: text.into(),
            }]
        };
        let started = manager
            .start(&root, &buffer("abc"), None, &path_env, false)
            .await
            .unwrap();
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
            manager
                .update(&root, "main.tex", edit, token)
                .await
                .unwrap();
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
            .update(&root, "main.tex", "abc", token)
            .await
            .unwrap();
        assert!(!status.running);
        assert!(status.error.unwrap().contains("main file changed"));
    }

    #[tokio::test]
    async fn unexpected_exit_retains_output_and_stops_engine_group() {
        let (tmp, root, path_env) = setup();
        let manager = Manager::default();
        let owner = manager
            .start(&root, &[], None, &path_env, false)
            .await
            .unwrap();
        until(|| {
            fs::read_to_string(tmp.path().join("engine.pid")).is_ok()
                && manager.status(&root, None, &path_env).unwrap().output == "ready"
        })
        .await;
        let child_pid: i32 = fs::read_to_string(tmp.path().join("engine.pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        manager
            .update(
                &root,
                "main.tex",
                "EXIT_STUB",
                owner.session.as_deref().unwrap(),
            )
            .await
            .unwrap();
        until(|| !manager.status(&root, None, &path_env).unwrap().running).await;
        let status = manager.status(&root, None, &path_env).unwrap();
        assert_eq!(status.output, "ready");
        // Not asked for, the stub's document isn't offered.
        assert!(status.pdf.is_none() && status.pdf_version == 0);
        assert!(status.error.unwrap().contains("exited"));
        // Killed descendants can remain zombies briefly while init reaps them.
        until(|| {
            (unsafe { libc::kill(child_pid, 0) == -1 })
                || fs::read_to_string(format!("/proc/{child_pid}/stat"))
                    .is_ok_and(|stat| stat.contains(") Z "))
        })
        .await;
    }
    #[tokio::test]
    async fn abandoned_session_lease_expires_without_polling() {
        let (_tmp, root, path_env) = setup();
        let manager = Manager::default();
        manager
            .start(&root, &[], None, &path_env, false)
            .await
            .unwrap();
        let session = manager
            .sessions
            .lock()
            .unwrap()
            .get(&fs::canonicalize(&root).unwrap())
            .cloned()
            .unwrap();
        session.state.lock().unwrap().last_used = Instant::now() - LEASE;
        tokio::time::sleep(Duration::from_millis(5100)).await;
        let status = manager.status(&root, None, &path_env).unwrap();
        assert!(!status.running);
        assert!(status.error.unwrap().contains("expired"));
    }
    #[tokio::test]
    async fn backtracked_tex_log_excludes_historical_process_stderr() {
        let (_tmp, root, path_env) = setup();
        let manager = Manager::default();
        manager
            .start(&root, &[], None, &path_env, false)
            .await
            .unwrap();
        let session = manager
            .sessions
            .lock()
            .unwrap()
            .get(&fs::canonicalize(&root).unwrap())
            .cloned()
            .unwrap();
        let diagnostic = "Undefined control sequence";
        session
            .state
            .lock()
            .unwrap()
            .stderr
            .append(0, diagnostic.as_bytes());
        apply_message(&session, &json!(["append", "log", 0, diagnostic]));
        assert!(session.status().log.contains(diagnostic));
        apply_message(&session, &json!(["truncate", "log", 0]));
        assert!(!session.status().log.contains(diagnostic));
        session.stop(Some("TeXpresso exited".into()));
        assert!(session.status().log.contains(diagnostic));
    }
    #[tokio::test]
    async fn replacement_rejects_queued_stale_edits_cleanup_and_lease_renewal() {
        let (_tmp, root, path_env) = setup();
        let manager = Arc::new(Manager::default());
        assert!(!manager.status(&root, None, &path_env).unwrap().running);
        let old = manager
            .start(&root, &[], None, &path_env, false)
            .await
            .unwrap()
            .session
            .unwrap();
        // B's Start reaches the queue before A's delayed edit.
        let blocked = manager.requests.lock().await;
        let replacement = tokio::spawn({
            let (manager, root, path_env) = (Arc::clone(&manager), root.clone(), path_env.clone());
            async move {
                manager
                    .start(
                        &root,
                        &[FileBuffer {
                            path: "main.tex".into(),
                            text: "owner B".into(),
                        }],
                        None,
                        &path_env,
                        false,
                    )
                    .await
                    .unwrap()
            }
        });
        tokio::task::yield_now().await;
        let stale_edit = tokio::spawn({
            let (manager, root, old) = (Arc::clone(&manager), root.clone(), old.clone());
            async move { manager.update(&root, "main.tex", "stale A", &old).await }
        });
        drop(blocked);
        let current = replacement.await.unwrap().session.unwrap();
        assert_ne!(old, current);
        assert_eq!(stale_edit.await.unwrap().unwrap_err().status, 409);
        let session = manager
            .owned(&fs::canonicalize(&root).unwrap(), &current)
            .unwrap();
        let before = Instant::now() - Duration::from_secs(60);
        session.state.lock().unwrap().last_used = before;
        assert_eq!(
            manager
                .status(&root, Some(&old), &path_env)
                .unwrap_err()
                .status,
            409
        );
        assert_eq!(manager.rescan(&root, &old).await.unwrap_err().status, 409);
        assert_eq!(
            manager
                .stop_request(&root, Some(&old), &path_env)
                .await
                .unwrap_err()
                .status,
            409
        );
        // An idle tab can inspect B, but neither inspection nor A extends its lease.
        assert_eq!(
            manager
                .status(&root, None, &path_env)
                .unwrap()
                .session
                .as_deref(),
            Some(current.as_str())
        );
        assert_eq!(session.state.lock().unwrap().last_used, before);
        assert!(
            manager
                .status(&root, Some(&current), &path_env)
                .unwrap()
                .running
        );
        assert!(session.state.lock().unwrap().last_used > before);
        assert_eq!(
            session.input.lock().await.files[&fs::canonicalize(root.join("main.tex")).unwrap()],
            "owner B"
        );
        assert_eq!(
            manager
                .start(&root, &[], Some(&old), &path_env, false)
                .await
                .unwrap_err()
                .status,
            409
        );
        manager.stop(&root).unwrap();
        assert!(!manager.status(&root, None, &path_env).unwrap().running);
        let restarted = manager
            .start(&root, &[], Some(&current), &path_env, false)
            .await
            .unwrap();
        assert!(restarted.running);
        assert_ne!(restarted.session.as_deref(), Some(current.as_str()));
        // Deliberately selected global Stop remains available to an inspecting tab.
        assert!(
            !manager
                .stop_request(&root, None, &path_env)
                .await
                .unwrap()
                .running
        );
        assert_eq!(
            manager
                .start(&root, &[], restarted.session.as_deref(), &path_env, false)
                .await
                .unwrap_err()
                .status,
            409
        );
    }
}
