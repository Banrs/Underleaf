//! LaTeX compilation via latexmk, ported from server/compile.js: augmented
//! PATH discovery, process-group kill, per-project supersede, timeout and
//! output caps, and the stale-log guard.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;

use crate::error::CoreError;
use crate::logparse::{parse_log, LogItem};
use crate::paths::safe_rel_file;
use crate::settings::{main_base_name, read_settings};
use crate::BUILD_DIR;

pub const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
// Cap what we hold from a child; a runaway document can print for the whole
// timeout window.
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

/// Kill a whole process tree. latexmk drives pdflatex/biber as children of its
/// own; killing just latexmk leaves those running. On unix the child was
/// spawned in its own process group, so one signal reaches the tree; Windows
/// has no process groups in this sense, so taskkill /T is the best effort.
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
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .spawn();
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
        // Without this every latexmk/synctex spawn flashes a console window;
        // Electron suppressed it implicitly.
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
    pub code: i32, // -1 for spawn failure or signal death
    pub stdout: String,
}

/// Spawn, collect capped output, and kill the whole tree on timeout.
/// (compile.js `run`)
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
        // The spawn error itself is not surfaced: callers act on the -1 code,
        // exactly as the JS `run` did.
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
            if let Some(pid) = pid { kill_pid_tree(pid); }
            let _ = child.start_kill();
            child.wait().await.ok()
        }
    };
    // stderr is drained but discarded: no caller reads it, and leaving the pipe
    // unread would stall a child that filled its buffer.
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
}

/// One compile per project, supersede-kill semantics, and kill-all on quit —
/// the state that lived in compile.js's module-level `running` map, made
/// explicit so the core stays global-free.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<HashMap<PathBuf, RunningEntry>>,
    next_token: AtomicU64,
    /// Test hook; None uses the discovered TeX PATH.
    pub path_env: Option<String>,
    /// Test hook; None uses COMPILE_TIMEOUT.
    pub timeout: Option<Duration>,
}

impl CompileManager {
    pub fn new() -> Self {
        Self::default()
    }

    fn path(&self) -> &str {
        self.path_env.as_deref().unwrap_or_else(|| tex_path())
    }

    /// Called on app quit: compiles run in their own process groups, so
    /// nothing signals them when the parent exits unless we do it here.
    pub fn kill_all(&self) {
        let mut running = self.running.lock().unwrap();
        for entry in running.values() {
            if let Some(pid) = entry.pid {
                kill_pid_tree(pid);
            }
        }
        running.clear();
    }

    pub async fn compile(
        &self,
        root: &Path,
        overrides: &CompileOverrides,
    ) -> Result<CompileResult, CoreError> {
        let settings = read_settings(root);
        let engine = overrides.engine.clone().unwrap_or(settings.engine);
        let main_file = overrides.main_file.clone().unwrap_or(settings.main_file);
        let shell_escape = overrides.shell_escape.unwrap_or(settings.shell_escape);

        let flags = engine_flags(&engine)
            .ok_or_else(|| CoreError::bad_request(format!("Unknown engine: {engine}")))?;
        // Re-validate rather than trusting the stored value: .texlocal.json is
        // a plain file the user can edit, and this string is about to become
        // an argv element.
        let main_rel = safe_rel_file(root, &main_file)?;
        if !root.join(&main_rel).exists() {
            return Err(CoreError::bad_request(format!(
                "Main file not found: {main_rel}"
            )));
        }
        // "./" so latexmk reads it as a path no matter what it contains.
        let main_arg = format!("./{main_rel}");

        let outdir = root.join(BUILD_DIR);
        std::fs::create_dir_all(&outdir)?;

        let mut args: Vec<&str> = flags.to_vec();
        // batchmode skips console echoing (a bit faster); errors still land in
        // the .log file, which is what we parse.
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
        let started_at = SystemTime::now();
        let start_instant = std::time::Instant::now();
        // What the log looked like before this run, so finish() can tell
        // whether latexmk replaced it.
        let log_before =
            std::fs::metadata(outdir.join(format!("{}.log", main_base_name(&main_rel))))
                .and_then(|m| m.modified())
                .ok();

        let mut cmd = base_command("latexmk", Some(root), self.path());
        cmd.args(&args);
        let spawned = cmd.spawn();

        let mut child = match spawned {
            Ok(c) => c,
            Err(err) => {
                return Ok(self.finish(
                    root,
                    &main_rel,
                    log_before,
                    started_at,
                    start_instant,
                    -1,
                    err.to_string(),
                ));
            }
        };
        let pid = child.id();

        // One compile per project: kill any in-flight run first.
        if let Some(prev) = self
            .running
            .lock()
            .unwrap()
            .insert(root.to_path_buf(), RunningEntry { token, pid })
        {
            if let Some(prev_pid) = prev.pid {
                kill_pid_tree(prev_pid);
            }
        }

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
                if let Some(pid) = pid { kill_pid_tree(pid); }
                let _ = child.start_kill();
                child.wait().await.ok()
            }
        };
        let code = status.and_then(|s| s.code()).unwrap_or(-1);
        let mut output = out_task.await.unwrap_or_default();
        output.push_str(&err_task.await.unwrap_or_default());

        {
            let mut running = self.running.lock().unwrap();
            if running.get(root).map(|e| e.token) == Some(token) {
                running.remove(root);
            }
        }

        Ok(self.finish(
            root,
            &main_rel,
            log_before,
            started_at,
            start_instant,
            code,
            output,
        ))
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

        // Parse the .log file (batchmode sends errors there, not to stdout) —
        // but only if this run wrote it; a stale log would report last run's
        // errors.
        //
        // Freshness is decided by whether the file changed, not by comparing
        // its timestamp to the wall clock: Linux stamps files from a coarse
        // clock that lags the fine-grained one by up to a jiffy, so a log
        // written just after the run began can carry an mtime just before it,
        // and a real failure's errors would silently vanish from the log pane.
        // The wall-clock test stays as a fallback for the case where the log
        // is rewritten byte-identically within one timestamp tick.
        let mut log = fallback_output;
        if let Ok(meta) = std::fs::metadata(&log_path) {
            let modified = meta.modified().ok();
            let rewritten = modified != log_before;
            let after_start = modified.map(|m| m >= started_at).unwrap_or(false);
            if rewritten || after_start {
                if let Ok(bytes) = std::fs::read(&log_path) {
                    log = String::from_utf8_lossy(&bytes).into_owned();
                }
            }
        }

        let issues = parse_log(&log, main_rel);
        let pdf_exists = outdir.join(format!("{base}.pdf")).exists();
        let (errors, warnings): (Vec<_>, Vec<_>) =
            issues.into_iter().partition(|i| i.kind == "error");

        CompileResult {
            ok: code == 0 && pdf_exists,
            duration_ms: start_instant.elapsed().as_millis() as u64,
            pdf: pdf_exists.then(|| format!("{BUILD_DIR}/{base}.pdf")),
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
