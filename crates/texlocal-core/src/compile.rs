//! LaTeX compilation via latexmk: augmented PATH discovery, process-group
//! kill, per-project supersede and stop, timeout and output caps, and the
//! stale-output guard.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{Duration, Instant, SystemTime};

use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::sync::OwnedMutexGuard;

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

/// Synchronous kill, at quit and when a run is dropped. On Windows it waits for
/// taskkill, so a quitting app leaves no console helper behind.
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

/// `program` by its full path on `path_env`: std forks to spawn a bare name,
/// and a forked child of a multithreaded process can crash before its exec.
#[cfg(unix)]
fn program_path(program: &str, path_env: &str) -> std::io::Result<PathBuf> {
    std::env::split_paths(path_env)
        .map(|dir| dir.join(program))
        .find(|path| path.is_file())
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("{program} is not on the PATH"),
            )
        })
}

/// Windows has no fork: CreateProcess searches the child's PATH itself.
#[cfg(windows)]
fn program_path(program: &str, _path_env: &str) -> std::io::Result<PathBuf> {
    Ok(PathBuf::from(program))
}

fn base_command(
    program: &str,
    cwd: Option<&Path>,
    path_env: &str,
) -> std::io::Result<tokio::process::Command> {
    let mut std_cmd = std::process::Command::new(program_path(program, path_env)?);
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
    Ok(cmd)
}

/// Keep bounded output while draining to EOF, so a full pipe cannot block the
/// child. The caller keeps what was read if it ends the drain early.
async fn read_capped<R: tokio::io::AsyncRead + Unpin>(mut reader: R, kept: &mut Vec<u8>) {
    let mut chunk = [0u8; 8192];
    loop {
        match reader.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if kept.len() < MAX_OUTPUT {
                    let take = n.min(MAX_OUTPUT - kept.len());
                    kept.extend_from_slice(&chunk[..take]);
                }
            }
        }
    }
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
    let Ok(mut cmd) = base_command(program, cwd, path_env) else {
        return (-1, String::new());
    };
    cmd.args(args);
    let Ok(mut child) = cmd.spawn() else {
        return (-1, String::new());
    };
    let (code, stdout, ..) = drive(&mut child, timeout).await;
    (code, stdout)
}

/// Collect capped output while the child runs. On timeout, kill its process
/// tree before reaping; the final value reports whether it timed out.
async fn drive(
    child: &mut tokio::process::Child,
    timeout: Duration,
) -> (i32, String, String, bool) {
    let pid = child.id();
    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (status, timed_out) = {
        let readers = async {
            tokio::join!(read_capped(stdout, &mut out), read_capped(stderr, &mut err),);
        };
        let wait = async {
            match tokio::time::timeout(timeout, child.wait()).await {
                Ok(status) => (status.ok(), false),
                Err(_) => {
                    if let Some(pid) = pid {
                        terminate_pid_tree(pid).await;
                    }
                    let _ = child.start_kill();
                    (child.wait().await.ok(), true)
                }
            }
        };
        tokio::pin!(readers, wait);
        tokio::select! {
            status = &mut wait => {
                // A descendant or unrelated inherited pipe can outlive the child.
                // Drain its buffered output briefly, then drop both read futures.
                let _ = tokio::time::timeout(DRAIN_GRACE, readers).await;
                status
            }
            _ = &mut readers => wait.await,
        }
    };
    (
        status.and_then(|s| s.code()).unwrap_or(-1),
        crate::lossy_string(out),
        crate::lossy_string(err),
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
/// `pdf`: the successful build's PDF, or one a failed build wrote while
/// compiling past errors. `stopped`: Stop, a newer build
/// of the same project, or quitting ended it.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompileResult {
    pub ok: bool,
    pub stopped: bool,
    pub duration_ms: u64,
    pub pdf: Option<String>,
    /// True only when this completed latexmk run wrote the PDF it returns.
    pub pdf_changed: bool,
    pub errors: Vec<LogItem>,
    pub warnings: Vec<LogItem>,
    pub log: String,
}

struct RunningEntry {
    token: u64,
    pid: Option<u32>,
    stopped: bool,
}

type Registry = HashMap<PathBuf, RunningEntry>;
type ProjectGate = tokio::sync::Mutex<()>;

/// One compile per project, supersede-kill semantics, and kill-all on quit.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<Registry>,
    // A cancelled replacement can leave the registry while its predecessor
    // still owns the build directory. Weak entries let the next request find
    // that predecessor's gate without retaining idle mutexes.
    gates: Mutex<HashMap<PathBuf, Weak<ProjectGate>>>,
    next_token: AtomicU64,
    pub path_env: Option<String>,
    pub timeout: Option<Duration>,
}

/// A compile's entry in the registry, and the child it spawned. Dropping it,
/// on every exit path, removes the entry if it is still this run's, drops the
/// child, then releases the project's gate. A run dropped before its
/// child settled (the compile future was cancelled) kills the tree first,
/// while latexmk still lives: kill_on_drop reaches only latexmk, and Windows'
/// taskkill /T finds the engine only under a living parent.
struct Registration<'a> {
    manager: &'a CompileManager,
    root: &'a Path,
    token: u64,
    gate: Arc<ProjectGate>,
    gate_guard: Option<OwnedMutexGuard<()>>,
    child: Option<tokio::process::Child>,
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
            running.remove(self.root);
        }
        drop(running);
        // A newer request may already have replaced this registry entry, but
        // its kill can itself be cancelled before it reaches this child.
        if let Some(pid) = self.child.as_ref().and_then(tokio::process::Child::id) {
            kill_pid_tree(pid);
        }
        self.child = None;
        // On cancellation, Tokio reaps the killed child after this guard releases.
        self.gate_guard = None;
    }
}

#[derive(Clone, Copy, PartialEq)]
enum End {
    Exited(i32),
    TimedOut,
    Stopped,
}

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

    /// A fresh output, or an existing one for a successful no-op build.
    fn read(&self, ext: &str, allow_existing: bool) -> Option<String> {
        (allow_existing || self.wrote(ext))
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

    fn register<'a>(&'a self, root: &'a Path) -> (Registration<'a>, Option<u32>) {
        let token = self.next_token.fetch_add(1, Ordering::Relaxed);
        let gate = {
            let mut gates = self.gates.lock().unwrap_or_else(PoisonError::into_inner);
            gates.retain(|_, gate| gate.strong_count() != 0);
            if let Some(gate) = gates.get(root).and_then(Weak::upgrade) {
                gate
            } else {
                let gate = Arc::new(ProjectGate::new(()));
                gates.insert(root.to_path_buf(), Arc::downgrade(&gate));
                gate
            }
        };
        let previous_pid = self
            .running()
            .insert(
                root.to_path_buf(),
                RunningEntry {
                    token,
                    pid: None,
                    stopped: false,
                },
            )
            .and_then(|entry| entry.pid);
        let registration = Registration {
            manager: self,
            root,
            token,
            gate,
            gate_guard: None,
            child: None,
        };
        (registration, previous_pid)
    }

    fn stopped_early(start: Instant) -> CompileResult {
        CompileResult {
            ok: false,
            stopped: true,
            duration_ms: start.elapsed().as_millis() as u64,
            pdf: None,
            pdf_changed: false,
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

        let (mut registration, previous_pid) = self.register(root);

        // The gate keeps a successor off the build directory until its
        // predecessor settles, even if an intermediate request is cancelled.
        // Cancelling the active future can only signal the tree, not await reap.
        if let Some(pid) = previous_pid {
            terminate_pid_tree(pid).await;
        }
        registration.gate_guard = Some(Arc::clone(&registration.gate).lock_owned().await);

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
        if let Ok(cmd) = &mut cmd {
            cmd.args(&args);
        }
        let spawned = {
            // Hold the registry lock across synchronous spawn + PID publication.
            // A successor or Stop therefore sees either no child or the actual
            // PID, never an unkillable gap between the two.
            let mut running = self.running();
            match running.get_mut(root) {
                Some(entry) if entry.token == registration.token && !entry.stopped => Some(
                    cmd.and_then(|mut cmd| cmd.spawn())
                        .inspect(|child| entry.pid = child.id()),
                ),
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
        registration.child = None;
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
    let ok = end == End::Exited(0) && run.output("pdf").exists();
    // With incremental latexmk, a clean no-op keeps both the PDF and its log.
    // Keep the warnings from that log; after a newly written PDF, an old log
    // still belongs to the previous build and must not be shown.
    let unchanged = ok && !run.wrote("pdf") && !run.wrote("log");
    let engine_log = run.read("log", unchanged);
    let mut items = parse_log(engine_log.as_deref().unwrap_or(&output), run.main_rel);
    items.extend(
        run.read("blg", unchanged)
            .map_or_else(Vec::new, |blg| parse_blg(&blg)),
    );
    let (mut errors, warnings): (Vec<_>, Vec<_>) =
        items.into_iter().partition(|item| item.kind == "error");

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
        // A failed run can only advertise a PDF it actually wrote.
        pdf: (ok || wrote_pdf).then(|| format!("{BUILD_DIR}/{}.pdf", run.base)),
        pdf_changed: wrote_pdf,
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
    s[s.ceil_char_boundary(s.len() - max)..].to_string()
}

#[cfg(test)]
mod tests {
    use super::{read_tail, tail, user_latexmkrc, version_line};
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
    fn a_long_log_keeps_its_last_whole_characters() {
        assert_eq!(tail("short".into(), 10), "short");
        assert_eq!(tail("aébc".into(), 3), "bc");
        assert_eq!(tail("aébc".into(), 4), "ébc");
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
        let config = home.join(".config").join("latexmk").join("latexmkrc");
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        std::fs::write(&config, "").unwrap();
        assert_eq!(user_latexmkrc(env(home)), rc(&config));
        // A relative home would be the project's own folder.
        assert_eq!(user_latexmkrc(env(Path::new("."))), None);
    }
}
