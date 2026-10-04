//! LaTeX compilation via latexmk: augmented PATH discovery, process-group
//! kill, per-project supersede and stop, timeout and output caps, and the
//! stale-output guard.

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
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

/// What `dir` holds; nothing if it can't be read.
fn children(dir: impl AsRef<Path>) -> impl Iterator<Item = PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
}

/// Year/architecture-specific TeX Live bin dirs, newest year first.
fn texlive_bins() -> impl Iterator<Item = PathBuf> {
    let mut years: Vec<_> = children("/usr/local/texlive")
        .filter(|year| {
            year.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.len() == 4 && name.bytes().all(|b| b.is_ascii_digit()))
        })
        .map(|year| year.join("bin"))
        .collect();
    years.sort_unstable_by(|a, b| b.cmp(a));
    years.into_iter().flat_map(children)
}

/// PATH for spawned TeX tools: the folder the user chose first, then the
/// user's PATH, then the discovered TeX dirs. Built per use — a couple of
/// read_dirs — so a TeX install performed while the app runs is found without
/// a restart.
pub fn tex_path(chosen: Option<&Path>) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(dir) = chosen {
        parts.push(dir.to_string_lossy().into_owned());
    }
    if let Ok(cur) = std::env::var("PATH") {
        if !cur.is_empty() {
            parts.push(cur);
        }
    }
    parts
        .extend(["/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin"].map(str::to_string));
    parts.extend(texlive_bins().map(|p| p.to_string_lossy().into_owned()));
    parts.join(":")
}

pub fn has_latexmk(dir: &Path) -> bool {
    dir.join("latexmk").is_file()
}

pub fn latexmk_dir(path_env: &str) -> Option<PathBuf> {
    std::env::split_paths(path_env).find(|dir| has_latexmk(dir))
}

/// The TeX programs folder `dir` names: `dir` itself, or the bin folder of a
/// TeX Live root picked in its place.
pub fn tex_bin_dir(dir: &Path) -> Option<PathBuf> {
    std::iter::once(dir.to_path_buf())
        .chain(children(dir.join("bin")))
        .find(|c| has_latexmk(c))
}

// ---------- process plumbing ----------

/// Kill the process group, including the engines latexmk started.
fn kill_pid_tree(pid: u32) {
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
}

fn base_command(
    program: &str,
    cwd: Option<&Path>,
    path_env: &str,
) -> std::io::Result<tokio::process::Command> {
    // A full path avoids std's fork fallback, which can crash a child of the
    // multithreaded Mac app before exec.
    let program = std::env::split_paths(path_env)
        .map(|dir| dir.join(program))
        .find(|path| path.is_file())
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("{program} is not on the PATH"),
            )
        })?;
    let mut std_cmd = std::process::Command::new(program);
    // TeX Live's engines read texmf.cnf's variables from the environment
    // first. Unwrapped, the log keeps each message and path on one line;
    // wrapped at the default 79 columns, words and paths split mid-way.
    std_cmd.env("PATH", path_env).env("max_print_line", "10000");
    if let Some(dir) = cwd {
        std_cmd.current_dir(dir);
    }
    std_cmd.process_group(0);
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
    let mut capped = (&mut reader).take(MAX_OUTPUT as u64);
    if capped.read_to_end(kept).await.is_ok() {
        let _ = tokio::io::copy(&mut reader, &mut tokio::io::sink()).await;
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
    let Ok(mut child) =
        base_command(program, cwd, path_env).and_then(|mut cmd| cmd.args(args).spawn())
    else {
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
                        kill_pid_tree(pid);
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
    /// The TeXpresso program live preview would run, and the folder chosen for it.
    pub texpresso: Option<String>,
    pub texpresso_dir: Option<String>,
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
        texpresso: None,
        texpresso_dir: None,
    }
}

/// latexmk's own version line, falling back to the first nonempty line.
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

#[derive(Default)]
struct RunningEntry {
    gate: Arc<ProjectGate>,
    latest: Option<Arc<()>>,
    pid: Option<u32>,
    stopped: bool,
}

type Registry = HashMap<PathBuf, RunningEntry>;
type ProjectGate = tokio::sync::Mutex<()>;

/// One compile per project, supersede-kill semantics, and kill-all on quit.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<Registry>,
    pub path_env: Option<String>,
    pub timeout: Option<Duration>,
}

/// Keeps the project's gate alive through waiting, running, and cancellation.
/// Dropping a live child kills its whole tree before releasing the gate.
struct Registration<'a> {
    manager: &'a CompileManager,
    root: &'a Path,
    gate: Arc<ProjectGate>,
    request: Arc<()>,
    gate_guard: Option<OwnedMutexGuard<()>>,
    child: Option<tokio::process::Child>,
}

impl Registration<'_> {
    /// Stop marked it, a newer request replaced it, or kill_all cleared it.
    fn stopped(&self, running: &Registry) -> bool {
        let entry = &running[self.root];
        entry.stopped
            || !entry
                .latest
                .as_ref()
                .is_some_and(|r| Arc::ptr_eq(r, &self.request))
    }
}

impl Drop for Registration<'_> {
    fn drop(&mut self) {
        let mut running = self.manager.running();
        let entry = running.get_mut(self.root).expect("registered project");
        if entry
            .latest
            .as_ref()
            .is_some_and(|r| Arc::ptr_eq(r, &self.request))
        {
            entry.latest = None;
        }
        if let Some(pid) = self.child.as_ref().and_then(tokio::process::Child::id) {
            kill_pid_tree(pid);
        }
        if self.gate_guard.is_some() {
            entry.pid = None;
        }
        self.child = None;
        // On cancellation, Tokio reaps the killed child after this guard releases.
        self.gate_guard = None;
        // Only the registry and this registration still own the idle gate.
        if Arc::strong_count(&self.gate) == 2 {
            running.remove(self.root);
        }
    }
}

#[derive(PartialEq)]
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
    let home = dir("HOME")?;
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
    /// The registry holds plain data that no panic leaves half-written, so a
    /// poisoned lock is still usable — and kill_all runs at quit, from
    /// `tl_close` too, where a panic would abort the host.
    fn running(&self) -> MutexGuard<'_, Registry> {
        self.running.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn kill_all(&self) {
        let mut running = self.running();
        for entry in running.values_mut() {
            entry.latest = None;
            if let Some(pid) = entry.pid {
                kill_pid_tree(pid);
            }
        }
    }

    /// Stop a project's build, and say whether one was running. Its entry
    /// stays, so the run and a successor waiting on it settle as usual, and
    /// the run reports itself stopped; one that hasn't started latexmk yet
    /// doesn't start it.
    pub fn stop(&self, root: &Path) -> bool {
        let mut running = self.running();
        let Some(entry) = running.get_mut(root).filter(|entry| entry.latest.is_some()) else {
            return false;
        };
        entry.stopped = true;
        if let Some(pid) = entry.pid {
            kill_pid_tree(pid);
        }
        true
    }

    fn register<'a>(&'a self, root: &'a Path) -> Registration<'a> {
        let mut running = self.running();
        let entry = running.entry(root.to_path_buf()).or_default();
        let request = Arc::new(());
        entry.latest = Some(Arc::clone(&request));
        entry.stopped = false;
        // The PID belongs to the gate's active owner, even when the latest
        // request is still waiting or an intervening request was cancelled.
        if let Some(pid) = entry.pid {
            kill_pid_tree(pid);
        }
        Registration {
            manager: self,
            root,
            gate: Arc::clone(&entry.gate),
            request,
            gate_guard: None,
            child: None,
        }
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

        let outdir_arg = format!("-outdir={BUILD_DIR}");
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
            &outdir_arg,
            if shell_escape {
                "-shell-escape"
            } else {
                "-norc"
            },
        ]);
        // A latexmkrc is Perl that runs on every build, so a project's own is
        // honoured only in a project trusted with shell escape. -norc turns
        // off every automatic rc file, and the user's own is named again.
        let user_rc = (!shell_escape)
            .then(|| user_latexmkrc(|key| std::env::var_os(key)))
            .flatten();
        if let Some(rc) = &user_rc {
            args.extend(["-r", rc]);
        }
        args.push(&main_arg);

        let mut registration = self.register(root);

        // The gate keeps a successor off the build directory until its
        // predecessor settles, even if an intermediate request is cancelled.
        // Cancelling the active future can only signal the tree, not await reap.
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

        let path_env = self
            .path_env
            .as_deref()
            .map_or_else(|| Cow::Owned(tex_path(tex_dir)), Cow::Borrowed);
        let spawned = {
            // Hold the registry lock across synchronous spawn + PID publication.
            // A successor or Stop therefore sees either no child or the actual
            // PID, never an unkillable gap between the two.
            let mut running = self.running();
            if registration.stopped(&running) {
                None
            } else {
                Some(
                    base_command("latexmk", Some(root), &path_env)
                        .and_then(|mut cmd| cmd.args(&args).spawn())
                        .inspect(|child| running.get_mut(root).unwrap().pid = child.id()),
                )
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
    if let Some(blg) = run.read("blg", unchanged) {
        items.extend(parse_blg(&blg));
    }
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
    fn the_version_names_latexmk() {
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
