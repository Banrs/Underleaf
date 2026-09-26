//! LaTeX compilation via latexmk: augmented PATH discovery, process-group
//! kill, per-project supersede and stop, timeout and output caps, and the
//! stale-output guard.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::sync::Notify;

use crate::error::CoreError;
use crate::logparse::{latexmk_errors, parse_blg, parse_log, LogItem};
use crate::paths::safe_rel_file;
use crate::settings::{main_base_name, read_settings};
use crate::BUILD_DIR;

const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: usize = 1_000_000;
/// How long a finished child's pipes are read before giving up on them.
const DRAIN_GRACE: Duration = Duration::from_secs(2);
const LOG_TAIL: usize = 200_000;
/// How much of the log file is parsed. A real document's log is a few MB at
/// most; one that loops on `\message` until the timeout can reach gigabytes.
const LOG_READ_MAX: u64 = 16 * 1024 * 1024;

pub(crate) fn engine_flags(engine: &str) -> Option<&'static [&'static str]> {
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

#[cfg(windows)]
fn taskkill(pid: u32) -> std::process::Command {
    use std::os::windows::process::CommandExt;
    let mut command = std::process::Command::new("taskkill");
    command
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .creation_flags(0x0800_0000);
    command
}

/// Synchronous shutdown kill. On Windows this waits for taskkill because the
/// app process is about to exit and cannot leave a console helper behind.
fn kill_pid_tree(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
    #[cfg(windows)]
    let _ = taskkill(pid).status();
}

/// Async equivalent used while the application remains live. Waiting for the
/// Windows helper is load-bearing: otherwise a replacement compile can start
/// while descendants of the previous latexmk still own and write build files.
async fn terminate_pid_tree(pid: u32) {
    #[cfg(unix)]
    kill_pid_tree(pid);
    #[cfg(windows)]
    let _ = tokio::process::Command::from(taskkill(pid)).status().await;
}

fn base_command(program: &str, cwd: Option<&Path>, path_env: &str) -> tokio::process::Command {
    let mut std_cmd = std::process::Command::new(program);
    // TeX Live's engines read texmf.cnf's variables from the environment
    // first. Unwrapped, the log keeps each message and path on one line;
    // wrapped at the default 79 columns, words and paths split mid-way.
    std_cmd.env("PATH", path_env).env("max_print_line", "10000");
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

/// Spawn, collect capped output, and kill the whole tree on timeout: the
/// exit code (-1 for none) and stdout.
pub(crate) async fn run(
    program: &str,
    args: &[&str],
    cwd: Option<&Path>,
    timeout: Duration,
    path_env: &str,
) -> (i32, String) {
    let mut cmd = base_command(program, cwd, path_env);
    cmd.args(args);
    let Ok(mut child) = cmd.spawn() else {
        return (-1, String::new());
    };
    let (code, stdout, ..) = drive(&mut child, timeout).await;
    (code, stdout)
}

/// Drive a spawned child to completion: stream both pipes into capped buffers,
/// and if it outlives the timeout, kill its whole process tree before reaping
/// it. Both callers share this so a change to the timeout or kill path cannot
/// reach one of them and miss the other. The last value says whether the
/// timeout ended it.
async fn drive(
    child: &mut tokio::process::Child,
    timeout: Duration,
) -> (i32, String, String, bool) {
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

    let (status, timed_out) = tokio::select! {
        status = child.wait() => (status.ok(), false),
        _ = tokio::time::sleep_until(deadline) => {
            if let Some(pid) = pid { terminate_pid_tree(pid).await; }
            let _ = child.start_kill();
            (child.wait().await.ok(), true)
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
        timed_out,
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
    let (code, stdout) = run("latexmk", &["-version"], None, PROBE_TIMEOUT, path_env).await;
    let available = code == 0;
    TexStatus {
        available,
        version: available.then(|| version_line(&stdout)),
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

/// A build's outcome. `ok`: latexmk finished cleanly and the PDF exists.
/// `pdf`: set whenever this build wrote the PDF, errors or not, since a build
/// carries on past errors as Overleaf's does. `stopped`: Stop, a newer build
/// of the same project, or quitting ended it.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompileResult {
    pub ok: bool,
    pub stopped: bool,
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
    stopped: bool,
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

    /// Stop marked it, a newer run replaced it, or kill_all cleared it.
    fn stopped(&self, running: &Registry) -> bool {
        running
            .get(self.root)
            .is_none_or(|entry| entry.token != self.token || entry.stopped)
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

/// How a build's latexmk ended.
#[derive(Clone, Copy, PartialEq)]
enum End {
    Exited(i32),
    TimedOut,
    Stopped,
}

/// What finish() needs to know about one compile run.
struct CompileRun<'a> {
    main_rel: &'a str,
    base: String,
    outdir: PathBuf,
    /// The modification times of the outputs finish() reads, before the run.
    before: HashMap<&'static str, SystemTime>,
    started_at: SystemTime,
    request_started: Instant,
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
}

impl CompileRun<'_> {
    fn output(&self, ext: &str) -> PathBuf {
        self.outdir.join(format!("{}.{ext}", self.base))
    }

    /// Whether this run wrote an output: its time changed, or is past the
    /// start, for a clock too coarse to tell the two writes apart.
    fn wrote(&self, ext: &str) -> bool {
        modified(&self.output(ext))
            .is_some_and(|time| self.before.get(ext) != Some(&time) || time >= self.started_at)
    }

    /// An output this run wrote, as text, if it did.
    fn read(&self, ext: &str) -> Option<String> {
        self.wrote(ext)
            .then(|| read_tail(&self.output(ext), LOG_READ_MAX).ok())
            .flatten()
            .map(crate::lossy_string)
    }
}

/// The user's own latexmkrc, found where latexmk looks for it, so that it can
/// be named after -norc turns off the automatic ones. A relative home would
/// find the project's own rc instead, so only absolute paths count.
fn user_latexmkrc(var: impl Fn(&str) -> Option<OsString>) -> Option<String> {
    let dir = |key| var(key).map(PathBuf::from).filter(|p| p.is_absolute());
    let home = dir("HOME").or_else(|| dir("USERPROFILE"))?;
    let config = dir("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"));
    [
        config.join("latexmk").join("latexmkrc"),
        home.join(".latexmkrc"),
    ]
    .into_iter()
    .find(|rc| rc.is_file())
    .map(|rc| rc.to_string_lossy().into_owned())
}

impl CompileManager {
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

    /// Stop a project's build, and say whether one was running. Its entry
    /// stays, so the run and a successor waiting on it settle as usual, and
    /// the run reports itself stopped; one that hasn't started latexmk yet
    /// doesn't start it.
    pub async fn stop(&self, root: &Path) -> bool {
        let Some(pid) = self.running().get_mut(root).map(|entry| {
            entry.stopped = true;
            entry.pid
        }) else {
            return false;
        };
        if let Some(pid) = pid {
            terminate_pid_tree(pid).await;
        }
        true
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
                stopped: false,
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

    /// A run stopped before latexmk started.
    fn stopped_early(start: Instant) -> CompileResult {
        CompileResult {
            ok: false,
            stopped: true,
            duration_ms: start.elapsed().as_millis() as u64,
            pdf: None,
            errors: Vec::new(),
            warnings: Vec::new(),
            log: "The build was stopped before it started.".to_string(),
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
            // By default, past errors as Overleaf compiles: TeX carries on
            // and latexmk finishes its passes (-f), so the PDF shows all that
            // compiled and the log every error.
            if settings.stop_on_first_error {
                "-halt-on-error"
            } else {
                "-f"
            },
        ]);
        let outdir_arg = format!("-outdir={BUILD_DIR}");
        args.push(&outdir_arg);
        // A latexmkrc is Perl that runs on every build, so a project's own is
        // honoured only in a project trusted with shell escape. -norc turns
        // off every automatic rc file, and the user's own is named again.
        let user_rc = (!shell_escape)
            .then(|| user_latexmkrc(|key| std::env::var_os(key)))
            .flatten();
        if shell_escape {
            args.push("-shell-escape");
        } else {
            args.push("-norc");
        }
        if let Some(rc) = &user_rc {
            args.extend(["-r", rc]);
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

        if registration.stopped(&self.running()) {
            return Ok(Self::stopped_early(request_started));
        }

        // Capture output times after the predecessor has stopped, otherwise
        // its final writes can be mistaken for output from this generation.
        let mut run = CompileRun {
            main_rel: &main_rel,
            base: main_base_name(&main_rel),
            outdir,
            before: HashMap::new(),
            started_at: SystemTime::now(),
            request_started,
        };
        run.before = ["log", "pdf", "blg"]
            .into_iter()
            .filter_map(|ext| Some((ext, modified(&run.output(ext))?)))
            .collect();

        let mut cmd = base_command("latexmk", Some(root), &self.path(tex_dir));
        cmd.args(&args);
        let spawned = {
            // Hold the registry lock across synchronous spawn + PID publication.
            // A successor or Stop therefore sees either no child or the actual
            // PID, never an unkillable gap between the two.
            let mut running = self.running();
            match running.get_mut(root) {
                Some(entry) if entry.token == registration.token && !entry.stopped => {
                    Some(cmd.spawn().inspect(|child| entry.pid = child.id()))
                }
                _ => None,
            }
        };

        let child = match spawned {
            None => return Ok(Self::stopped_early(request_started)),
            Some(Err(err)) => {
                let mut result = finish(&run, End::Exited(-1), err.to_string());
                result.errors = vec![LogItem::error(format!("Couldn't start latexmk: {err}"))];
                return Ok(result);
            }
            Some(Ok(child)) => registration.child.insert(child),
        };
        let timeout = self.timeout.unwrap_or(COMPILE_TIMEOUT);
        let (code, mut output, stderr, timed_out) = drive(child, timeout).await;
        registration.settled = true;
        output.push_str(&stderr);
        let end = if registration.stopped(&self.running()) {
            End::Stopped
        } else if timed_out {
            End::TimedOut
        } else {
            End::Exited(code)
        };
        Ok(finish(&run, end, output))
    }
}

fn finish(run: &CompileRun, end: End, output: String) -> CompileResult {
    let engine_log = run.read("log");
    let mut items = parse_log(engine_log.as_deref().unwrap_or(&output), run.main_rel);
    // bibtex and biber report into a log of their own.
    items.extend(run.read("blg").map_or_else(Vec::new, |blg| parse_blg(&blg)));
    let (mut errors, warnings): (Vec<_>, Vec<_>) =
        items.into_iter().partition(|item| item.kind == "error");

    let ok = end == End::Exited(0) && run.output("pdf").exists();
    // Not from a build cut short, which may have left it half-written.
    let wrote_pdf = matches!(end, End::Exited(_)) && run.wrote("pdf");
    match end {
        End::TimedOut => errors.push(LogItem::error(format!(
            "The build was stopped after {} minutes. Something in the document may be repeating forever.",
            COMPILE_TIMEOUT.as_secs() / 60
        ))),
        // A failure always names a cause: latexmk's own summary of the step
        // that failed (bibtex, biber, makeindex), else how it ended.
        End::Exited(code) if !ok && errors.is_empty() => {
            errors = latexmk_errors(&output);
            if errors.is_empty() {
                errors.push(LogItem::error(match code {
                    0 => "The build made no PDF. See the Build Log.".to_string(),
                    code => format!("latexmk stopped with exit code {code}. See the Build Log."),
                }));
            }
        }
        _ => {}
    }
    if !ok {
        // latexmk's record of the run. After a fatal TeX error it holds the
        // truncated .aux's state, so bibtex fails on it ("no \citation") and
        // every later run stops at "gave an error in previous invocation",
        // even with -g and the source fixed. Without it the next run starts
        // afresh.
        let _ = std::fs::remove_file(run.output("fdb_latexmk"));
    }

    // The engine's log, then latexmk's account of the passes it ran.
    let log = match engine_log {
        Some(engine_log) => format!("{engine_log}\n\n{output}"),
        None => output,
    };
    CompileResult {
        ok,
        stopped: end == End::Stopped,
        duration_ms: run.request_started.elapsed().as_millis() as u64,
        // Never a PDF this run didn't write: the UI keeps its old preview
        // visible but does not reload it as fresh output.
        pdf: (ok || wrote_pdf).then(|| format!("{BUILD_DIR}/{}.pdf", run.base)),
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
    use super::{read_tail, user_latexmkrc, version_line};
    use std::ffi::OsString;
    use std::path::Path;

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

    #[test]
    fn the_users_own_latexmkrc_is_found_where_latexmk_looks() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let env = |home: &Path| {
            let home = OsString::from(home);
            move |key: &str| (key == "HOME").then(|| home.clone())
        };
        assert_eq!(user_latexmkrc(env(home)), None);
        std::fs::write(home.join(".latexmkrc"), "").unwrap();
        let rc = |path: &Path| Some(path.to_string_lossy().into_owned());
        assert_eq!(user_latexmkrc(env(home)), rc(&home.join(".latexmkrc")));
        let config = home.join(".config/latexmk/latexmkrc");
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        std::fs::write(&config, "").unwrap();
        assert_eq!(user_latexmkrc(env(home)), rc(&config));
        // A relative home would be the project's own folder.
        assert_eq!(user_latexmkrc(env(Path::new("."))), None);
    }
}
