//! LaTeX compilation via latexmk: augmented PATH discovery, process-group
//! kill, per-project supersede, timeout and output caps, and the stale-log
//! guard.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, SystemTime};

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
/// How long a finished child's pipes are read before giving up on them.
const DRAIN_GRACE: Duration = Duration::from_secs(2);
const LOG_TAIL: usize = 200_000;
/// How much of the log file is parsed. A real document's log is a few MB at
/// most; one that loops on `\message` until the timeout can reach gigabytes.
const LOG_READ_MAX: u64 = 16 * 1024 * 1024;

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
    years.sort_unstable_by(|a, b| b.cmp(a));
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

/// latexmk's file name, as the PATH search that spawns it looks for it.
const LATEXMK: &str = if cfg!(windows) {
    "latexmk.exe"
} else {
    "latexmk"
};

/// PATH for spawned TeX tools: the folder the user chose first, then the
/// user's PATH, then the discovered TeX dirs. Built per use — a couple of
/// read_dirs — so a TeX install performed while the app runs is found without
/// a restart.
pub fn tex_path(chosen: Option<&Path>) -> String {
    let delim = if cfg!(windows) { ";" } else { ":" };
    let mut parts: Vec<String> = Vec::new();
    if let Some(dir) = chosen {
        parts.push(dir.to_string_lossy().into_owned());
    }
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
}

pub fn has_latexmk(dir: &Path) -> bool {
    dir.join(LATEXMK).is_file()
}

/// The PATH entry latexmk is spawned from, if any.
pub fn latexmk_dir(path_env: &str) -> Option<PathBuf> {
    std::env::split_paths(path_env).find(|dir| has_latexmk(dir))
}

/// The TeX programs folder `dir` names: `dir` itself, or the bin folder of a
/// TeX Live or MiKTeX root picked in its place.
pub fn tex_bin_dir(dir: &Path) -> Option<PathBuf> {
    let mut candidates = vec![
        dir.to_path_buf(),
        dir.join("miktex").join("bin").join("x64"),
    ];
    if let Ok(rd) = std::fs::read_dir(dir.join("bin")) {
        candidates.extend(rd.filter_map(|e| e.ok()).map(|e| e.path()));
    }
    candidates.into_iter().find(|c| has_latexmk(c))
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

/// Drain a child stream to EOF into `kept`, keeping at most `cap` bytes.
/// Draining past the cap matters: stopping reads would block the child on a
/// full pipe. The buffer is shared so that what was read survives the task
/// being cancelled (see `drive`).
async fn read_capped<R: tokio::io::AsyncRead + Unpin>(
    mut reader: R,
    cap: usize,
    kept: Arc<Mutex<Vec<u8>>>,
) {
    let mut chunk = [0u8; 8192];
    loop {
        match reader.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let mut kept = kept.lock().unwrap_or_else(PoisonError::into_inner);
                if kept.len() < cap {
                    let take = n.min(cap - kept.len());
                    kept.extend_from_slice(&chunk[..take]);
                }
            }
        }
    }
}

fn take_text(buffer: &Mutex<Vec<u8>>) -> String {
    let bytes = std::mem::take(&mut *buffer.lock().unwrap_or_else(PoisonError::into_inner));
    crate::lossy_string(bytes)
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
    let (code, stdout, _stderr) = drive(&mut child, timeout).await;
    RunOutput { code, stdout }
}

/// Drive a spawned child to completion: stream both pipes into capped buffers,
/// and if it outlives the timeout, kill its whole process tree before reaping
/// it. Both callers share this so a change to the timeout or kill path cannot
/// reach one of them and miss the other.
async fn drive(child: &mut tokio::process::Child, timeout: Duration) -> (i32, String, String) {
    let pid = child.id();
    let deadline = tokio::time::Instant::now() + timeout;
    let out_buf = Arc::new(Mutex::new(Vec::new()));
    let err_buf = Arc::new(Mutex::new(Vec::new()));
    let mut out_task = tokio::spawn(read_capped(
        child.stdout.take().expect("stdout piped"),
        MAX_OUTPUT,
        out_buf.clone(),
    ));
    let mut err_task = tokio::spawn(read_capped(
        child.stderr.take().expect("stderr piped"),
        MAX_OUTPUT,
        err_buf.clone(),
    ));

    let status = tokio::select! {
        status = child.wait() => status.ok(),
        _ = tokio::time::sleep_until(deadline) => {
            if let Some(pid) = pid { terminate_pid_tree(pid).await; }
            let _ = child.start_kill();
            child.wait().await.ok()
        }
    };
    // Once the child is gone, everything it wrote is already in the pipes, so
    // a short grace reads it all. Waiting longer only waits on a process that
    // holds the pipes open without writing: a descendant that outlived it (a
    // shell-escape `&`, a latexmkrc previewer), or — where pipes can't be
    // created close-on-exec atomically, as on macOS — a process spawned
    // elsewhere at that instant that inherited them. When the grace runs out
    // the readers stop, and what they read by then is kept.
    let drain_until = tokio::time::Instant::now() + DRAIN_GRACE;
    if tokio::time::timeout_at(drain_until, async {
        let _ = (&mut out_task).await;
        let _ = (&mut err_task).await;
    })
    .await
    .is_err()
    {
        out_task.abort();
        err_task.abort();
    }
    (
        status.and_then(|s| s.code()).unwrap_or(-1),
        take_text(&out_buf),
        take_text(&err_buf),
    )
}

// ---------- availability ----------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TexStatus {
    pub available: bool,
    pub version: Option<String>,
    /// The TeX folder the user chose; None finds TeX automatically.
    pub tex_dir: Option<String>,
    /// The folder the working latexmk runs from.
    pub found: Option<String>,
}

pub async fn tex_available(path_env: &str) -> TexStatus {
    let out = run("latexmk", &["-version"], None, PROBE_TIMEOUT, path_env).await;
    let available = out.code == 0;
    TexStatus {
        available,
        version: available.then(|| version_line(&out.stdout)),
        tex_dir: None,
        found: available
            .then(|| latexmk_dir(path_env))
            .flatten()
            .map(|dir| dir.to_string_lossy().into_owned()),
    }
}

/// latexmk's own version line. TeX Live's latexmk on Windows first reports
/// the console code pages it changed, so the first line is not it.
fn version_line(stdout: &str) -> String {
    let mut lines = stdout.lines().map(str::trim).filter(|l| !l.is_empty());
    let first = lines.clone().next().unwrap_or("");
    lines
        .find(|l| l.starts_with("Latexmk"))
        .unwrap_or(first)
        .to_string()
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

type Registry = HashMap<PathBuf, RunningEntry>;

/// One compile per project, supersede-kill semantics, and kill-all on quit.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<Registry>,
    next_token: AtomicU64,
    pub path_env: Option<String>,
    pub timeout: Option<Duration>,
}

/// A compile's entry in the registry, and the child it spawned. Dropping it,
/// on every exit path, removes the entry if it is still this run's, drops the
/// child, then wakes the successor waiting on it. A run dropped before its
/// child settled (the compile future was cancelled) kills the tree first,
/// while latexmk still lives: kill_on_drop reaches only latexmk, and Windows'
/// taskkill /T finds the engine only under a living parent.
struct Registration<'a> {
    manager: &'a CompileManager,
    root: &'a Path,
    token: u64,
    done: Arc<Notify>,
    child: Option<tokio::process::Child>,
    settled: bool,
}

impl Registration<'_> {
    fn is_current(&self, running: &Registry) -> bool {
        running.get(self.root).map(|entry| entry.token) == Some(self.token)
    }
}

impl Drop for Registration<'_> {
    fn drop(&mut self) {
        let mut running = self.manager.running();
        if self.is_current(&running) {
            let pid = running.remove(self.root).and_then(|entry| entry.pid);
            if let Some(pid) = pid.filter(|_| !self.settled) {
                kill_pid_tree(pid);
            }
        }
        drop(running);
        self.child = None;
        // notify_one stores a permit when the successor has not begun waiting
        // yet, so a very fast completion cannot be missed.
        self.done.notify_one();
    }
}

/// What finish() needs to know about one compile run.
struct CompileRun<'a> {
    main_rel: &'a str,
    base: String,
    outdir: PathBuf,
    log_path: PathBuf,
    log_before: Option<SystemTime>,
    started_at: SystemTime,
    request_started: Instant,
}

impl CompileManager {
    pub fn new() -> Self {
        Self::default()
    }

    fn path(&self, tex_dir: Option<&Path>) -> String {
        self.path_env.clone().unwrap_or_else(|| tex_path(tex_dir))
    }

    /// The registry holds plain data that no panic leaves half-written, so a
    /// poisoned lock is still usable — and kill_all runs at quit, from
    /// `tl_close` too, where a panic would abort the host.
    fn running(&self) -> MutexGuard<'_, Registry> {
        self.running.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn kill_all(&self) {
        let mut running = self.running();
        for entry in running.values() {
            if let Some(pid) = entry.pid {
                kill_pid_tree(pid);
            }
        }
        running.clear();
    }

    fn register<'a>(&'a self, root: &'a Path) -> (Registration<'a>, Option<RunningEntry>) {
        let token = self.next_token.fetch_add(1, Ordering::Relaxed);
        let done = Arc::new(Notify::new());
        let previous = self.running().insert(
            root.to_path_buf(),
            RunningEntry {
                token,
                pid: None,
                done: Arc::clone(&done),
            },
        );
        let registration = Registration {
            manager: self,
            root,
            token,
            done,
            child: None,
            settled: false,
        };
        (registration, previous)
    }

    fn superseded(start: Instant) -> CompileResult {
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
        tex_dir: Option<&Path>,
    ) -> Result<CompileResult, CoreError> {
        let request_started = Instant::now();
        let settings = read_settings(root);
        let engine = overrides
            .engine
            .as_deref()
            .unwrap_or(settings.engine.as_str());
        let main_file = overrides
            .main_file
            .as_deref()
            .unwrap_or(settings.main_file.as_str());
        let shell_escape = overrides.shell_escape.unwrap_or(settings.shell_escape);

        let flags = engine_flags(engine)
            .ok_or_else(|| CoreError::bad_request(format!("Unknown engine: {engine}")))?;
        let main_rel = safe_rel_file(root, main_file)?;
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
            // Always run. Without -g, latexmk declines to retry a document
            // whose last run failed until a source file changes, so a compile
            // after installing TeX or a missing package reports the stale error.
            "-g",
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

        let (mut registration, previous) = self.register(root);

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

        if !registration.is_current(&self.running()) {
            return Ok(Self::superseded(request_started));
        }

        // Capture log identity after the predecessor has stopped, otherwise its
        // final write can be mistaken for output from this generation.
        let base = main_base_name(&main_rel);
        let log_path = outdir.join(format!("{base}.log"));
        let log_before = std::fs::metadata(&log_path)
            .and_then(|meta| meta.modified())
            .ok();
        let run = CompileRun {
            main_rel: &main_rel,
            base,
            outdir,
            log_path,
            log_before,
            started_at: SystemTime::now(),
            request_started,
        };

        let mut cmd = base_command("latexmk", Some(root), &self.path(tex_dir));
        cmd.args(&args);
        let spawned = {
            // Hold the registry lock across synchronous spawn + PID publication.
            // A successor therefore sees either no child or the actual PID,
            // never an unkillable gap between the two.
            let mut running = self.running();
            match running.get_mut(root) {
                Some(entry) if entry.token == registration.token => {
                    Some(cmd.spawn().inspect(|child| entry.pid = child.id()))
                }
                _ => None,
            }
        };

        let child = match spawned {
            None => return Ok(Self::superseded(request_started)),
            Some(Err(err)) => return Ok(finish(&run, -1, err.to_string())),
            Some(Ok(child)) => registration.child.insert(child),
        };
        let timeout = self.timeout.unwrap_or(COMPILE_TIMEOUT);
        let (code, mut output, stderr) = drive(child, timeout).await;
        registration.settled = true;
        output.push_str(&stderr);
        Ok(finish(&run, code, output))
    }
}

fn finish(run: &CompileRun, code: i32, fallback_output: String) -> CompileResult {
    let mut log = fallback_output;
    if let Ok(meta) = std::fs::metadata(&run.log_path) {
        let modified = meta.modified().ok();
        let rewritten = modified != run.log_before;
        let after_start = modified.is_some_and(|mtime| mtime >= run.started_at);
        if rewritten || after_start {
            if let Ok(bytes) = read_tail(&run.log_path, LOG_READ_MAX) {
                log = crate::lossy_string(bytes);
            }
        }
    }

    let (errors, warnings): (Vec<_>, Vec<_>) = parse_log(&log, run.main_rel)
        .into_iter()
        .partition(|item| item.kind == "error");
    let ok = code == 0 && run.outdir.join(format!("{}.pdf", run.base)).exists();

    CompileResult {
        ok,
        duration_ms: run.request_started.elapsed().as_millis() as u64,
        // Never advertise a pre-existing PDF for a failed run. The UI keeps
        // its old preview visible but does not reload it as fresh output.
        pdf: ok.then(|| format!("{BUILD_DIR}/{}.pdf", run.base)),
        errors,
        warnings,
        log: tail(log, LOG_TAIL),
    }
}

/// A file's last `max` bytes, starting at a line when it had to cut: errors
/// sit at the end of a log, and a cut line would parse as garbage.
fn read_tail(path: &Path, max: u64) -> std::io::Result<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path)?;
    let len = file.metadata()?.len();
    let cut = len > max;
    if cut {
        file.seek(SeekFrom::Start(len - max))?;
    }
    let mut bytes = Vec::with_capacity(len.min(max) as usize);
    file.take(max).read_to_end(&mut bytes)?;
    if cut {
        let start = bytes.iter().position(|&b| b == b'\n').map_or(0, |i| i + 1);
        bytes.drain(..start);
    }
    Ok(bytes)
}

/// The last `max` bytes of `s`, moved forward to a char boundary. A log
/// that fits, the usual case, is returned without a copy.
fn tail(s: String, max: usize) -> String {
    if s.len() <= max {
        return s;
    }
    let mut start = s.len() - max;
    while !s.is_char_boundary(start) {
        start += 1;
    }
    s[start..].to_string()
}

#[cfg(test)]
mod tests {
    use super::{read_tail, version_line};

    #[test]
    fn a_long_log_is_read_from_its_last_whole_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("main.log");
        std::fs::write(&path, "first line\nsecond line\n./main.tex:3: Boom.\n").unwrap();
        assert_eq!(
            read_tail(&path, 30).unwrap(),
            b"./main.tex:3: Boom.\n".to_vec()
        );
        assert_eq!(
            read_tail(&path, 1000).unwrap(),
            std::fs::read(&path).unwrap()
        );
    }

    #[test]
    fn the_version_skips_windows_code_page_notices() {
        let windows = "Initial Win CP for (console input, console output, system): (CP437, CP437, CP1252)\r\n\
                       I changed them all to CP1252\r\n\
                       Latexmk, John Collins, 9 March 2026. Version 4.88\r\n";
        assert_eq!(
            version_line(windows),
            "Latexmk, John Collins, 9 March 2026. Version 4.88"
        );
        assert_eq!(
            version_line("Latexmk, John Collins, 1 Jan 2025. Version 4.86\n"),
            "Latexmk, John Collins, 1 Jan 2025. Version 4.86"
        );
        assert_eq!(version_line("something else\n"), "something else");
    }
}
