//! LaTeX compilation via latexmk, ported from server/compile.js: augmented
//! PATH discovery, process-group kill, per-project supersede, timeout and
//! output caps, and the stale-log guard.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::sync::Notify;

use crate::error::CoreError;
use crate::logparse::{parse_log, LogItem};
use crate::paths::safe_rel_file;
use crate::settings::{main_base_name, read_settings};
use crate::BUILD_DIR;

pub const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: usize = 1_000_000;
const LOG_TAIL: usize = 200_000;

fn engine_flags(engine: &str) -> Option<&'static [&'static str]> {
    match engine {
        "pdflatex" => Some(&["-pdf"]),
        "xelatex" => Some(&["-xelatex"]),
        "lualatex" => Some(&["-lualatex"]),
        _ => None,
    }
}

// ---------- TeX PATH discovery ----------

fn four_digit_years(dir: &Path) -> Vec<String> {
    let mut years: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.len() == 4 && n.bytes().all(|b| b.is_ascii_digit()))
                .collect()
        })
        .unwrap_or_default();
    years.sort();
    years.reverse();
    years
}

/// Year/architecture-specific TeX Live bin dirs, newest year first.
fn texlive_bins() -> Vec<PathBuf> {
    if cfg!(windows) {
        let root = Path::new(r"C:\texlive");
        four_digit_years(root)
            .into_iter()
            .flat_map(|year| {
                [
                    root.join(&year).join("bin").join("windows"),
                    root.join(&year).join("bin").join("win32"),
                ]
            })
            .collect()
    } else {
        let root = Path::new("/usr/local/texlive");
        four_digit_years(root)
            .into_iter()
            .flat_map(|year| {
                let bin = root.join(&year).join("bin");
                std::fs::read_dir(&bin)
                    .map(|rd| {
                        rd.filter_map(|e| e.ok())
                            .map(|e| e.path())
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default()
            })
            .collect()
    }
}

fn tex_dirs() -> Vec<PathBuf> {
    if cfg!(windows) {
        let mut dirs = texlive_bins();
        if let Ok(lad) = std::env::var("LOCALAPPDATA") {
            dirs.push(PathBuf::from(lad).join(r"Programs\MiKTeX\miktex\bin\x64"));
        }
        dirs.push(PathBuf::from(r"C:\Program Files\MiKTeX\miktex\bin\x64"));
        dirs
    } else {
        let mut dirs = vec![
            PathBuf::from("/Library/TeX/texbin"),
            PathBuf::from("/usr/local/bin"),
            PathBuf::from("/opt/homebrew/bin"),
        ];
        dirs.extend(texlive_bins());
        dirs
    }
}

/// PATH for spawned TeX tools: the user's PATH first (it always wins), then
/// the discovered TeX dirs. Frozen on first use, as the JS module-load freeze
/// was — a TeX install performed while the app runs needs a restart.
pub fn tex_path() -> &'static str {
    static TEX_PATH: OnceLock<String> = OnceLock::new();
    TEX_PATH.get_or_init(|| {
        let delim = if cfg!(windows) { ";" } else { ":" };
        let mut parts: Vec<String> = Vec::new();
        if let Ok(cur) = std::env::var("PATH") {
            if !cur.is_empty() {
                parts.push(cur);
            }
        }
        parts.extend(
            tex_dirs()
                .into_iter()
                .map(|p| p.to_string_lossy().into_owned()),
        );
        parts.join(delim)
    })
}

// ---------- process plumbing ----------

/// Synchronous shutdown kill. On Windows this waits for taskkill because the
/// app process is about to exit and cannot leave a console helper behind.
pub(crate) fn kill_pid_tree(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .creation_flags(0x0800_0000)
            .status();
    }
}

/// Async equivalent used while the application remains live. Waiting for the
/// Windows helper is load-bearing: otherwise a replacement compile can start
/// while descendants of the previous latexmk still own and write build files.
async fn terminate_pid_tree(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let mut command = std::process::Command::new("taskkill");
        command
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .creation_flags(0x0800_0000);
        let _ = tokio::process::Command::from(command).status().await;
    }
}

fn base_command(program: &str, cwd: Option<&Path>, path_env: &str) -> tokio::process::Command {
    let mut std_cmd = std::process::Command::new(program);
    std_cmd.env("PATH", path_env);
    if let Some(dir) = cwd {
        std_cmd.current_dir(dir);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        std_cmd.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        std_cmd.creation_flags(0x0800_0000);
    }
    let mut cmd = tokio::process::Command::from(std_cmd);
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    cmd
}

/// Drain a child stream to EOF, keeping at most `cap` bytes. Draining past the
/// cap matters: stopping reads would block the child on a full pipe.
async fn read_capped<R: tokio::io::AsyncRead + Unpin>(mut reader: R, cap: usize) -> String {
    let mut kept: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match reader.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if kept.len() < cap {
                    let take = n.min(cap - kept.len());
                    kept.extend_from_slice(&chunk[..take]);
                }
            }
        }
    }
    String::from_utf8_lossy(&kept).into_owned()
}

pub(crate) struct RunOutput {
    pub code: i32,
    pub stdout: String,
}

/// Spawn, collect capped output, and kill the whole tree on timeout.
pub(crate) async fn run(
    program: &str,
    args: &[&str],
    cwd: Option<&Path>,
    timeout: Duration,
    path_env: &str,
) -> RunOutput {
    let mut cmd = base_command(program, cwd, path_env);
    cmd.args(args);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => {
            return RunOutput {
                code: -1,
                stdout: String::new(),
            }
        }
    };
    let pid = child.id();
    let out_task = tokio::spawn(read_capped(
        child.stdout.take().expect("stdout piped"),
        MAX_OUTPUT,
    ));
    let err_task = tokio::spawn(read_capped(
        child.stderr.take().expect("stderr piped"),
        MAX_OUTPUT,
    ));

    let status = tokio::select! {
        status = child.wait() => status.ok(),
        _ = tokio::time::sleep(timeout) => {
            if let Some(pid) = pid { terminate_pid_tree(pid).await; }
            let _ = child.start_kill();
            child.wait().await.ok()
        }
    };
    let _ = err_task.await;
    RunOutput {
        code: status.and_then(|s| s.code()).unwrap_or(-1),
        stdout: out_task.await.unwrap_or_default(),
    }
}

// ---------- availability ----------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TexStatus {
    pub available: bool,
    pub version: Option<String>,
}

pub async fn tex_available(path_env: Option<&str>) -> TexStatus {
    let path = path_env.unwrap_or_else(|| tex_path());
    let out = run("latexmk", &["-version"], None, PROBE_TIMEOUT, path).await;
    TexStatus {
        available: out.code == 0,
        version: (out.code == 0).then(|| {
            out.stdout
                .split('\n')
                .next()
                .unwrap_or("")
                .trim()
                .to_string()
        }),
    }
}

// ---------- compile ----------

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompileOverrides {
    pub engine: Option<String>,
    pub main_file: Option<String>,
    pub shell_escape: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompileResult {
    pub ok: bool,
    pub duration_ms: u64,
    pub pdf: Option<String>,
    pub errors: Vec<LogItem>,
    pub warnings: Vec<LogItem>,
    pub log: String,
}

struct RunningEntry {
    token: u64,
    pid: Option<u32>,
    done: Arc<Notify>,
}

struct CompletionGuard(Arc<Notify>);

impl Drop for CompletionGuard {
    fn drop(&mut self) {
        // notify_one stores a permit when the successor has not begun waiting
        // yet, so a very fast completion cannot be missed.
        self.0.notify_one();
    }
}

/// One compile per project, supersede-kill semantics, and kill-all on quit.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<HashMap<PathBuf, RunningEntry>>,
    next_token: AtomicU64,
    pub path_env: Option<String>,
    pub timeout: Option<Duration>,
}

impl CompileManager {
    pub fn new() -> Self {
        Self::default()
    }

    fn path(&self) -> &str {
        self.path_env.as_deref().unwrap_or_else(|| tex_path())
    }

    pub fn kill_all(&self) {
        let mut running = self.running.lock().unwrap();
        for entry in running.values() {
            if let Some(pid) = entry.pid {
                kill_pid_tree(pid);
            }
        }
        running.clear();
    }

    fn clear_if_current(&self, root: &Path, token: u64) {
        let mut running = self.running.lock().unwrap();
        if running.get(root).map(|entry| entry.token) == Some(token) {
            running.remove(root);
        }
    }

    fn superseded(start: std::time::Instant) -> CompileResult {
        CompileResult {
            ok: false,
            duration_ms: start.elapsed().as_millis() as u64,
            pdf: None,
            errors: Vec::new(),
            warnings: Vec::new(),
            log: "Compile superseded by a newer request".to_string(),
        }
    }

    pub async fn compile(
        &self,
        root: &Path,
        overrides: &CompileOverrides,
    ) -> Result<CompileResult, CoreError> {
        let request_started = std::time::Instant::now();
        let settings = read_settings(root);
        let engine = overrides.engine.clone().unwrap_or(settings.engine);
        let main_file = overrides.main_file.clone().unwrap_or(settings.main_file);
        let shell_escape = overrides.shell_escape.unwrap_or(settings.shell_escape);

        let flags = engine_flags(&engine)
            .ok_or_else(|| CoreError::bad_request(format!("Unknown engine: {engine}")))?;
        let main_rel = safe_rel_file(root, &main_file)?;
        if !root.join(&main_rel).exists() {
            return Err(CoreError::bad_request(format!(
                "Main file not found: {main_rel}"
            )));
        }
        let main_arg = format!("./{main_rel}");

        let outdir = root.join(BUILD_DIR);
        std::fs::create_dir_all(&outdir)?;

        let mut args: Vec<&str> = flags.to_vec();
        args.extend([
            "-interaction=batchmode",
            "-file-line-error",
            "-synctex=1",
            "-halt-on-error",
        ]);
        let outdir_arg = format!("-outdir={BUILD_DIR}");
        args.push(&outdir_arg);
        if shell_escape {
            args.push("-shell-escape");
        }
        args.push(&main_arg);

        let token = self.next_token.fetch_add(1, Ordering::Relaxed);
        let done = Arc::new(Notify::new());
        let _completion = CompletionGuard(Arc::clone(&done));
        let previous = self.running.lock().unwrap().insert(
            root.to_path_buf(),
            RunningEntry {
                token,
                pid: None,
                done,
            },
        );

        // A replacement must not touch the same build directory until the
        // predecessor has fully settled: process tree gone, child reaped, and
        // stdout/stderr pipes drained. The completion chain also covers the
        // PID-not-yet-recorded window and chains correctly through a third run.
        if let Some(previous) = previous {
            if let Some(pid) = previous.pid {
                terminate_pid_tree(pid).await;
            }
            previous.done.notified().await;
        }

        if self.running.lock().unwrap().get(root).map(|entry| entry.token) != Some(token) {
            return Ok(Self::superseded(request_started));
        }

        // Capture log identity after the predecessor has stopped, otherwise its
        // final write can be mistaken for output from this generation.
        let started_at = SystemTime::now();
        let log_before =
            std::fs::metadata(outdir.join(format!("{}.log", main_base_name(&main_rel))))
                .and_then(|meta| meta.modified())
                .ok();

        let mut cmd = base_command("latexmk", Some(root), self.path());
        cmd.args(&args);
        let spawn_result = {
            // Hold the registry lock across synchronous spawn + PID publication.
            // A successor therefore sees either no child or the actual PID,
            // never an unkillable gap between the two.
            let mut running = self.running.lock().unwrap();
            if running.get(root).map(|entry| entry.token) != Some(token) {
                None
            } else {
                match cmd.spawn() {
                    Ok(child) => {
                        running.get_mut(root).expect("token checked").pid = child.id();
                        Some(Ok(child))
                    }
                    Err(err) => Some(Err(err)),
                }
            }
        };

        let mut child = match spawn_result {
            None => return Ok(Self::superseded(request_started)),
            Some(Err(err)) => {
                let result = self.finish(
                    root,
                    &main_rel,
                    log_before,
                    started_at,
                    request_started,
                    -1,
                    err.to_string(),
                );
                self.clear_if_current(root, token);
                return Ok(result);
            }
            Some(Ok(child)) => child,
        };
        let pid = child.id();

        let out_task = tokio::spawn(read_capped(
            child.stdout.take().expect("stdout piped"),
            MAX_OUTPUT,
        ));
        let err_task = tokio::spawn(read_capped(
            child.stderr.take().expect("stderr piped"),
            MAX_OUTPUT,
        ));

        let timeout = self.timeout.unwrap_or(COMPILE_TIMEOUT);
        let status = tokio::select! {
            status = child.wait() => status.ok(),
            _ = tokio::time::sleep(timeout) => {
                if let Some(pid) = pid { terminate_pid_tree(pid).await; }
                let _ = child.start_kill();
                child.wait().await.ok()
            }
        };
        let code = status.and_then(|s| s.code()).unwrap_or(-1);
        let mut output = out_task.await.unwrap_or_default();
        output.push_str(&err_task.await.unwrap_or_default());

        let result = self.finish(
            root,
            &main_rel,
            log_before,
            started_at,
            request_started,
            code,
            output,
        );
        self.clear_if_current(root, token);
        Ok(result)
    }

    #[allow(clippy::too_many_arguments)]
    fn finish(
        &self,
        root: &Path,
        main_rel: &str,
        log_before: Option<SystemTime>,
        started_at: SystemTime,
        start_instant: std::time::Instant,
        code: i32,
        fallback_output: String,
    ) -> CompileResult {
        let base = main_base_name(main_rel);
        let outdir = root.join(BUILD_DIR);
        let log_path = outdir.join(format!("{base}.log"));

        let mut log = fallback_output;
        if let Ok(meta) = std::fs::metadata(&log_path) {
            let modified = meta.modified().ok();
            let rewritten = modified != log_before;
            let after_start = modified.map(|mtime| mtime >= started_at).unwrap_or(false);
            if rewritten || after_start {
                if let Ok(bytes) = std::fs::read(&log_path) {
                    log = String::from_utf8_lossy(&bytes).into_owned();
                }
            }
        }

        let issues = parse_log(&log, main_rel);
        let pdf_exists = outdir.join(format!("{base}.pdf")).exists();
        let ok = code == 0 && pdf_exists;
        let (errors, warnings): (Vec<_>, Vec<_>) =
            issues.into_iter().partition(|item| item.kind == "error");

        CompileResult {
            ok,
            duration_ms: start_instant.elapsed().as_millis() as u64,
            // Never advertise a pre-existing PDF for a failed run. The UI keeps
            // its old preview visible but does not reload it as fresh output.
            pdf: ok.then(|| format!("{BUILD_DIR}/{base}.pdf")),
            errors,
            warnings,
            log: tail(&log, LOG_TAIL).to_string(),
        }
    }
}

/// The last `max` bytes of `s`, moved forward to a char boundary.
fn tail(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut start = s.len() - max;
    while !s.is_char_boundary(start) {
        start += 1;
    }
    &s[start..]
}
