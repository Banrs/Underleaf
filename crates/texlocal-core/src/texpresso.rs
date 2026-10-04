//! Optional persistent TeXpresso viewer. Author buffers stay in its VFS; the
//! ordinary latexmk build and PDF continue to use saved project files.
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
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

use crate::{paths, settings, CoreError, BUILD_DIR};

const MAX_FILE: usize = 8 * 1024 * 1024;
const MAX_FILES: usize = 256;
const MAX_TOTAL: usize = 64 * 1024 * 1024;
const MAX_OUTPUT: usize = 128 * 1024;
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
const LEASE: Duration = Duration::from_secs(120);
const MISSING: &str = "TeXpresso was not found. Install it and put texpresso on PATH, or set TEXLOCAL_TEXPRESSO to its absolute executable path, then restart Underleaf.";

#[derive(Debug, Deserialize)]
pub struct FileBuffer {
    pub path: String,
    pub text: String,
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
    stderr: Output,
    error: Option<String>,
    revision: u64,
}
struct Input {
    stdin: ChildStdin,
    files: HashMap<PathBuf, String>,
}
struct Session {
    executable: PathBuf,
    main: String,
    state: Mutex<State>,
    input: tokio::sync::Mutex<Input>,
    revision: Arc<AtomicU64>,
}
impl Session {
    fn bump(&self, state: &mut State) {
        state.revision = self.revision.fetch_add(1, Ordering::Relaxed) + 1;
    }
    fn stop(&self, error: Option<String>) {
        let mut state = self.state.lock().unwrap();
        if let Some(pid) = state.pid.take() {
            // The viewer starts an engine: stopping just its parent leaks it.
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
            state.error = error;
            self.bump(&mut state);
            if let Ok(mut input) = self.input.try_lock() {
                input.files.clear();
            }
        }
    }
    fn status(&self) -> Status {
        let mut state = self.state.lock().unwrap();
        state.last_used = Instant::now();
        let mut log = state.log.text();
        log.push_str(&state.stderr.text());
        if log.len() > MAX_OUTPUT {
            let mut start = log.len() - MAX_OUTPUT;
            while !log.is_char_boundary(start) {
                start += 1;
            }
            log.drain(..start);
        }
        Status {
            available: executable_file(&self.executable),
            running: state.pid.is_some(),
            executable: Some(self.executable.to_string_lossy().into_owned()),
            output: state.output.text(),
            log,
            error: state.error.clone(),
            revision: state.revision,
        }
    }
    async fn send(&self, messages: &[Value]) {
        let mut input = self.input.lock().await;
        if let Err(err) = write_messages(&mut input.stdin, messages).await {
            self.stop(Some(format!(
                "Couldn't send changes to TeXpresso: {err}. Start Live again."
            )));
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.stop(None);
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
        for session in self.sessions.lock().unwrap().values() {
            session.stop(None);
        }
    }
    pub async fn stop_request(&self, root: &Path) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        self.stop(root)
    }
    pub fn stop(&self, root: &Path) -> Result<Status, CoreError> {
        let root = fs::canonicalize(root)?;
        let session = self.sessions.lock().unwrap().get(&root).cloned();
        if let Some(session) = session {
            session.stop(None);
            Ok(session.status())
        } else {
            Ok(self.idle(Some(&crate::compile::tex_path(None))))
        }
    }
    fn idle(&self, path_env: Option<&str>) -> Status {
        let executable = discover(path_env.unwrap_or_default());
        Status {
            available: executable.is_some(),
            running: false,
            executable: executable.map(|p| p.to_string_lossy().into_owned()),
            log: String::new(),
            output: String::new(),
            error: None,
            revision: self.revision.load(Ordering::Relaxed),
        }
    }
    pub fn status(&self, root: &Path, path_env: &str) -> Result<Status, CoreError> {
        let root = fs::canonicalize(root)?;
        let session = self.sessions.lock().unwrap().get(&root).cloned();
        if let Some(session) = session {
            if settings::read_settings(&root).main_file != session.main {
                session.stop(Some("The main file changed. Start Live again.".into()));
            }
            Ok(session.status())
        } else {
            Ok(self.idle(Some(path_env)))
        }
    }
    pub async fn start(
        &self,
        root: &Path,
        files: &[FileBuffer],
        path_env: &str,
    ) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = fs::canonicalize(root)?;
        let main = settings::read_settings(&root).main_file;
        let main_path = validate_buffer(&root, &main, "")?;
        if !main_path.is_file() {
            return Err(CoreError::bad_request("The main file does not exist."));
        }
        let mut buffers = HashMap::new();
        for file in files {
            let path = validate_buffer(&root, &file.path, &file.text)?;
            if buffers.insert(path, file.text.clone()).is_some() {
                return Err(CoreError::bad_request(
                    "Live buffers contain duplicate paths.",
                ));
            }
        }
        validate_total(&buffers)?;
        let Some(executable) = discover(path_env) else {
            let mut status = self.status(&root, path_env)?;
            status.available = false;
            status.error = Some(MISSING.into());
            return Ok(status);
        };
        let build = paths::safe_path(&root, BUILD_DIR)?;
        fs::create_dir_all(&build)?;
        let build = fs::canonicalize(build)?;
        self.stop(&root)?;
        let mut command = std::process::Command::new(&executable);
        command
            .args(["-json", "-texlive", "-I"])
            .arg(build)
            .arg(&main_path)
            .current_dir(&root)
            .env("PATH", path_env)
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut command = tokio::process::Command::from(command);
        command.kill_on_drop(true);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(err) => {
                let mut status = self.status(&root, path_env)?;
                status.error = Some(format!("Couldn't start TeXpresso: {err}. Check TEXLOCAL_TEXPRESSO and its dependencies."));
                return Ok(status);
            }
        };
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let session = Arc::new(Session {
            executable,
            main,
            input: tokio::sync::Mutex::new(Input {
                stdin: child.stdin.take().unwrap(),
                files: buffers,
            }),
            revision: Arc::clone(&self.revision),
            state: Mutex::new(State {
                pid: child.id(),
                last_used: Instant::now(),
                output: Output::default(),
                log: Output::default(),
                stderr: Output::default(),
                error: None,
                revision: self.revision.fetch_add(1, Ordering::Relaxed) + 1,
            }),
        });
        {
            let mut sessions = self.sessions.lock().unwrap();
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
                            session.stop(Some(format!("TeXpresso exited ({}). Check the live log and start Live again.",
                                result.map(|s| s.to_string()).unwrap_or_else(|e| e.to_string()))));
                        }
                        break;
                    }
                    _ = tokio::time::sleep(Duration::from_secs(5)) => {
                        let Some(session) = weak.upgrade() else { break; };
                        let expired = session.state.lock().unwrap().last_used.elapsed() >= LEASE;
                        if expired { session.stop(Some("The Live session expired. Start Live again.".into())); }
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
    pub async fn update(
        &self,
        root: &Path,
        path: &str,
        text: &str,
        path_env: &str,
    ) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = fs::canonicalize(root)?;
        let path = validate_buffer(&root, path, text)?;
        let status = self.status(&root, path_env)?;
        if !status.running {
            return Ok(status);
        }
        let session = self.sessions.lock().unwrap().get(&root).cloned().unwrap();
        let mut input = session.input.lock().await;
        let total = input
            .files
            .iter()
            .filter(|(p, _)| *p != &path)
            .map(|(_, t)| t.len())
            .sum::<usize>()
            + text.len();
        if total > MAX_TOTAL || (!input.files.contains_key(&path) && input.files.len() >= MAX_FILES)
        {
            return Err(CoreError::bad_request(
                "Too many live buffers (limit 256 files / 64 MB).",
            ));
        }
        let message = match input.files.get(&path) {
            Some(previous) if previous == text => return Ok(session.status()),
            Some(previous) => {
                let (offset, remove, inserted) = delta(previous, text);
                json!(["change", path, offset, remove, inserted])
            }
            None => json!(["open", path, text]),
        };
        if let Err(err) = write_messages(&mut input.stdin, &[message]).await {
            session.stop(Some(format!(
                "Couldn't send changes to TeXpresso: {err}. Start Live again."
            )));
        } else {
            input.files.insert(path, text.to_string());
            session.bump(&mut session.state.lock().unwrap());
        }
        Ok(session.status())
    }
    pub async fn rescan(&self, root: &Path, path_env: &str) -> Result<Status, CoreError> {
        let _request = self.requests.lock().await;
        let root = fs::canonicalize(root)?;
        let status = self.status(&root, path_env)?;
        if status.running {
            let session = self.sessions.lock().unwrap().get(&root).cloned().unwrap();
            session.send(&[json!(["rescan"])]).await;
            return Ok(session.status());
        }
        Ok(status)
    }
}

fn executable_file(path: &Path) -> bool {
    path.is_absolute()
        && fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}
fn discover(path_env: &str) -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("TEXLOCAL_TEXPRESSO").filter(|p| !p.is_empty()) {
        let path = PathBuf::from(override_path);
        return executable_file(&path).then_some(path);
    }
    std::env::split_paths(path_env)
        .map(|p| p.join("texpresso"))
        .find(|p| executable_file(p))
        .and_then(|p| fs::canonicalize(p).ok())
}
fn canonical_file(root: &Path, path: &str) -> Result<PathBuf, CoreError> {
    let path = paths::safe_write_path(root, path)?;
    if path.exists() {
        return Ok(fs::canonicalize(path)?);
    }
    let mut parent = path.as_path();
    while !parent.exists() {
        parent = parent.parent().unwrap();
    }
    Ok(fs::canonicalize(parent)?.join(path.strip_prefix(parent).unwrap()))
}
fn validate_buffer(root: &Path, path: &str, text: &str) -> Result<PathBuf, CoreError> {
    if text.len() > MAX_FILE {
        return Err(CoreError::bad_request(
            "Live buffers are limited to 8 MB per file.",
        ));
    }
    if path.len() > 4096 || path.contains('\0') || text.contains('\0') {
        return Err(CoreError::bad_request("Invalid live buffer path or text."));
    }
    let path = canonical_file(root, path)?;
    if path.is_dir() {
        return Err(CoreError::bad_request("Live buffers must name files."));
    }
    Ok(path)
}
fn validate_total(files: &HashMap<PathBuf, String>) -> Result<(), CoreError> {
    if files.len() > MAX_FILES || files.values().map(String::len).sum::<usize>() > MAX_TOTAL {
        return Err(CoreError::bad_request(
            "Too many live buffers (limit 256 files / 64 MB).",
        ));
    }
    Ok(())
}
// Both boundaries must be UTF-8 boundaries even when differing codepoints
// share leading or trailing bytes.
fn delta<'a>(old: &str, new: &'a str) -> (usize, usize, &'a str) {
    let mut start = old
        .bytes()
        .zip(new.bytes())
        .take_while(|(a, b)| a == b)
        .count();
    while !old.is_char_boundary(start) || !new.is_char_boundary(start) {
        start -= 1;
    }
    let mut suffix = old.as_bytes()[start..]
        .iter()
        .rev()
        .zip(new.as_bytes()[start..].iter().rev())
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
            let mut state = session.state.lock().unwrap();
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
    let (Some(verb), Some(name)) = (message[0].as_str(), message[1].as_str()) else {
        return;
    };
    let mut state = session.state.lock().unwrap();
    let output = match name {
        "out" => &mut state.output,
        "log" => &mut state.log,
        _ => return,
    };
    match verb {
        "truncate" => {
            if let Some(end) = message[2].as_u64() {
                output.truncate(end);
            } else {
                return;
            }
        }
        "append" => {
            // Upstream sends [append, buffer, byte-offset, text].
            let (Some(offset), Some(text)) = (message[2].as_u64(), message[3].as_str()) else {
                return;
            };
            output.append(offset, text.as_bytes());
        }
        _ => return,
    }
    session.bump(&mut state);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_deltas_reconstruct_text() {
        for (old, new) in [
            ("é😀tail", "ê😃tail"),
            ("é", ""),
            ("", "你好"),
            ("αtestβ", "αβ"),
            ("abc", "abc"),
        ] {
            let (start, remove, inserted) = delta(old, new);
            assert_eq!(
                format!("{}{inserted}{}", &old[..start], &old[start + remove..]),
                new
            );
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
}
