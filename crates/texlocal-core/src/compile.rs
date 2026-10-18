//! LaTeX compilation via latexmk: augmented PATH discovery, process-group
//! kill, per-project supersede and stop, timeout and output caps, and the
//! stale-output guard.

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use serde::Serialize;
use tokio::io::AsyncReadExt;
use tokio::sync::OwnedMutexGuard;

use crate::error::CoreError;
use crate::logparse::{LogItem, latexmk_errors, parse_blg, parse_log};
use crate::paths::safe_rel_file;
use crate::settings::{main_base_name, read_settings};
use crate::{BUILD_DIR, lock};

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

fn texlive_root() -> PathBuf {
    if cfg!(windows) {
        let mut root = std::env::var_os("SystemDrive").unwrap_or_else(|| "C:".into());
        root.push(r"\texlive");
        root.into()
    } else {
        PathBuf::from("/usr/local/texlive")
    }
}

/// Year/architecture-specific TeX Live bin dirs, newest year first.
fn texlive_bins() -> impl Iterator<Item = PathBuf> {
    let mut years: Vec<_> = children(texlive_root())
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
    let user = std::env::var_os("PATH").unwrap_or_default();
    join_path(
        chosen
            .map(Path::to_path_buf)
            .into_iter()
            .chain(absolute_dirs(&user))
            .chain(usual_tex_dirs())
            .chain(texlive_bins()),
    )
}

/// Where TeX's installers put its programs, besides TeX Live's years: MacTeX's
/// link and Homebrew's folders, or MiKTeX's for one user and for all.
fn usual_tex_dirs() -> Vec<PathBuf> {
    if cfg!(windows) {
        let under = |var, dir| Some(PathBuf::from(std::env::var_os(var)?).join(dir));
        [
            under("LOCALAPPDATA", r"Programs\MiKTeX\miktex\bin\x64"),
            under("ProgramFiles", r"MiKTeX\miktex\bin\x64"),
        ]
        .into_iter()
        .flatten()
        .collect()
    } else {
        ["/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin"]
            .map(PathBuf::from)
            .into()
    }
}

/// Folders as a PATH, in the platform's form. A folder whose name holds the
/// separator can't be one of them, and is left out.
pub(crate) fn join_path(dirs: impl IntoIterator<Item = PathBuf>) -> String {
    let dirs = dirs
        .into_iter()
        .filter(|dir| std::env::join_paths([dir]).is_ok());
    std::env::join_paths(dirs)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// A PATH's absolute folders: an empty or relative entry would be looked up
/// from the project, where a latexmk of its own could stand.
fn absolute_dirs(path: &std::ffi::OsStr) -> impl Iterator<Item = PathBuf> + '_ {
    std::env::split_paths(path).filter(|dir| dir.is_absolute())
}

/// `program` as a shell finds it in `path_env`'s folders: a file it may run,
/// by any of Windows' program extensions (.exe, .bat …) there.
pub(crate) fn find_tool(program: &str, path_env: &str) -> Option<PathBuf> {
    // The PATHs built here hold absolute folders only: none is found from
    // the folder given for relative ones.
    which::which_in(program, Some(path_env), Path::new("/")).ok()
}

/// The program at the absolute `path`, by any of Windows' program extensions.
pub(crate) fn program_at(path: &Path) -> Option<PathBuf> {
    path.is_absolute().then(|| which::which(path).ok())?
}

/// The TeX programs folder `dir` names: `dir` itself, or the bin folder of a
/// TeX Live root picked in its place.
pub(crate) fn tex_bin_dir(dir: &Path) -> Option<PathBuf> {
    std::iter::once(dir.to_path_buf())
        .chain(children(dir.join("bin")))
        .find(|c| program_at(&c.join("latexmk")).is_some())
}

// ---------- process plumbing ----------

/// A tool and every process it starts, the engines latexmk or TeXpresso runs
/// among them, which stopping the tool alone would leak: a process group of
/// its own on Unix, a Job Object on Windows. Kept apart from the child, so a
/// Stop or quit kills the tree from any thread while another awaits the tool.
#[derive(Clone)]
pub(crate) struct Tree {
    #[cfg(unix)]
    group: i32,
    #[cfg(windows)]
    job: Arc<job::Job>,
}

impl Tree {
    pub(crate) fn spawn(
        command: &mut tokio::process::Command,
    ) -> std::io::Result<(tokio::process::Child, Self)> {
        #[cfg(unix)]
        {
            let child = command.process_group(0).spawn()?;
            let group = child.id().expect("a child just spawned has its pid") as i32;
            Ok((child, Self { group }))
        }
        #[cfg(windows)]
        {
            // A console of its own that is never shown, which its engines
            // share: a console program a windowed app starts would open a
            // window for each pass.
            command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
            let mut child = command.spawn()?;
            let handle = child
                .raw_handle()
                .expect("a child just spawned has its handle");
            // Joined as it starts, long before it has loaded, let alone run a
            // program of its own.
            match job::Job::of(handle) {
                Ok(job) => Ok((child, Self { job: Arc::new(job) })),
                Err(err) => {
                    let _ = child.start_kill();
                    Err(err)
                }
            }
        }
    }

    pub(crate) fn kill(&self) {
        // SAFETY: a plain system call, on the group the tool leads.
        #[cfg(unix)]
        unsafe {
            libc::killpg(self.group, libc::SIGKILL);
        }
        #[cfg(windows)]
        self.job.kill();
    }
}

/// A Job Object that ends every process in it when it is killed, or when its
/// last handle closes: as the last owner of its tree here lets go, or the app
/// quits or crashes.
#[cfg(windows)]
mod job {
    use std::io;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle};

    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject,
    };

    pub(crate) struct Job(OwnedHandle);

    impl Job {
        /// A new job holding `process`, which takes every process it starts.
        pub(crate) fn of(process: RawHandle) -> io::Result<Self> {
            // SAFETY: no name and no attributes make an unnamed job with the
            // default security; the handle is owned from here.
            let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
            if handle.is_null() {
                return Err(io::Error::last_os_error());
            }
            let job = Self(unsafe { OwnedHandle::from_raw_handle(handle) });
            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            // SAFETY: the limits are of the class named, at their own size,
            // and both handles are open.
            let joined = unsafe {
                SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    (&raw const limits).cast(),
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                ) != 0
                    && AssignProcessToJobObject(handle, process) != 0
            };
            if joined {
                Ok(job)
            } else {
                Err(io::Error::last_os_error())
            }
        }

        pub(crate) fn kill(&self) {
            // SAFETY: the handle is open while self is.
            unsafe { TerminateJobObject(self.0.as_raw_handle(), 1) };
        }
    }
}

fn base_command(
    program: &str,
    cwd: Option<&Path>,
    path_env: &str,
) -> std::io::Result<tokio::process::Command> {
    // A full path avoids std's fork fallback, which can crash a child of the
    // multithreaded Mac app before exec.
    let program = find_tool(program, path_env).ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("{program} is not on the PATH"),
        )
    })?;
    let mut cmd = tokio::process::Command::new(program);
    // TeX Live's engines read texmf.cnf's variables from the environment
    // first. Unwrapped, the log keeps each message and path on one line;
    // wrapped at the default 79 columns, words and paths split mid-way.
    cmd.env("PATH", path_env)
        .env("max_print_line", "10000")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
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
    let Ok((mut child, tree)) =
        base_command(program, cwd, path_env).and_then(|mut cmd| Tree::spawn(cmd.args(args)))
    else {
        return (-1, String::new());
    };
    let (code, stdout, ..) = drive(&mut child, &tree, timeout).await;
    (code, stdout)
}

/// Collect capped output while the child runs. On timeout, kill its process
/// tree before reaping; the final value reports whether it timed out.
async fn drive(
    child: &mut tokio::process::Child,
    tree: &Tree,
    timeout: Duration,
) -> (i32, String, String, bool) {
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
                    tree.kill();
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
            () = &mut readers => wait.await,
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

#[derive(Debug, Clone, Default, Serialize)]
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
        found: available
            .then(|| find_tool("latexmk", path_env))
            .flatten()
            .and_then(|latexmk| {
                latexmk
                    .parent()
                    .map(|dir| dir.to_string_lossy().into_owned())
            }),
        ..TexStatus::default()
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

/// A build's outcome. `ok`: latexmk finished cleanly and the PDF exists.
/// `pdf`: the successful build's PDF, or one a failed build wrote while
/// compiling past errors, as an absolute path. `stopped`: Stop, a newer build
/// of the same project, or quitting ended it.
#[derive(Debug, Default, Serialize)]
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
    tree: Option<Tree>,
    /// The active run's latexmk record, for a Stop to remove where it is: a
    /// rename moves the folder before the run can remove it itself.
    record: Option<PathBuf>,
    stopped: bool,
}

impl RunningEntry {
    fn latest_is(&self, request: &Arc<()>) -> bool {
        self.latest
            .as_ref()
            .is_some_and(|r| Arc::ptr_eq(r, request))
    }
}

type Registry = HashMap<PathBuf, RunningEntry>;
type ProjectGate = tokio::sync::Mutex<()>;

/// One compile per project, supersede-kill semantics, and kill-all on quit.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<Registry>,
    pub path_env: Option<String>,
}

/// Keeps the project's gate alive through waiting, running, and cancellation.
/// Dropping a live child kills its whole tree, and a run that did not end ok
/// loses latexmk's record, before the gate is released.
struct Registration<'a> {
    manager: &'a CompileManager,
    root: &'a Path,
    gate: Arc<ProjectGate>,
    request: Arc<()>,
    gate_guard: Option<OwnedMutexGuard<()>>,
    child: Option<(tokio::process::Child, Tree)>,
    /// latexmk's record of a run that has started and not yet ended ok. After
    /// a fatal TeX error it holds the truncated .aux's state, so bibtex fails
    /// on it ("no \citation") and every later run stops at "gave an error in
    /// previous invocation", even with -g and the source fixed. Without it the
    /// next run starts afresh.
    record: Option<PathBuf>,
}

impl Registration<'_> {
    /// Stop marked it, a newer request replaced it, or kill_all cleared it.
    fn stopped(&self, running: &Registry) -> bool {
        let entry = &running[self.root];
        entry.stopped || !entry.latest_is(&self.request)
    }
}

impl Drop for Registration<'_> {
    fn drop(&mut self) {
        let mut running = lock(&self.manager.running);
        let entry = running.get_mut(self.root).expect("registered project");
        if entry.latest_is(&self.request) {
            entry.latest = None;
        }
        // Not once it is reaped, when its group's number may be another's.
        if let Some((child, tree)) = &self.child
            && child.id().is_some()
        {
            tree.kill();
        }
        if self.gate_guard.is_some() {
            entry.tree = None;
            entry.record = None;
        }
        self.child = None;
        if let Some(record) = self.record.take() {
            let _ = std::fs::remove_file(record);
        }
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
    Unstarted(String),
}

struct CompileRun {
    main_rel: String,
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

impl CompileRun {
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
/// find the project's own rc instead, so only absolute paths count. On
/// Windows, without HOME, latexmk's home is the user's profile folder.
fn user_latexmkrc(var: impl Fn(&str) -> Option<OsString>) -> Option<String> {
    let dir = |key| var(key).map(PathBuf::from).filter(|p| p.is_absolute());
    let home = dir("HOME").or_else(|| dir("USERPROFILE").filter(|_| cfg!(windows)))?;
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
    pub fn kill_all(&self) {
        let mut running = lock(&self.running);
        for entry in running.values_mut() {
            entry.latest = None;
            if let Some(tree) = &entry.tree {
                tree.kill();
            }
        }
    }

    /// Stop a project's build, and say whether one was running. Its entry
    /// stays, so the run and a successor waiting on it settle as usual, and
    /// the run reports itself stopped; one that hasn't started latexmk yet
    /// doesn't start it.
    pub fn stop(&self, root: &Path) -> bool {
        let mut running = lock(&self.running);
        let Some(entry) = running.get_mut(root).filter(|entry| entry.latest.is_some()) else {
            return false;
        };
        entry.stopped = true;
        if let Some(tree) = &entry.tree {
            tree.kill();
        }
        if let Some(record) = entry.record.take() {
            let _ = std::fs::remove_file(record);
        }
        true
    }

    /// Removes the project's build folder, with a running build stopped and settled first. A
    /// folder that isn't there is already clean.
    pub async fn clean(&self, root: &Path) -> Result<(), CoreError> {
        self.stop(root);
        let gate = Arc::clone(
            &lock(&self.running)
                .entry(root.to_path_buf())
                .or_default()
                .gate,
        );
        let _idle = gate.lock().await;
        match std::fs::remove_dir_all(root.join(BUILD_DIR)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    fn register<'a>(&'a self, root: &'a Path) -> Registration<'a> {
        let mut running = lock(&self.running);
        let entry = running.entry(root.to_path_buf()).or_default();
        let request = Arc::new(());
        entry.latest = Some(Arc::clone(&request));
        entry.stopped = false;
        // The tree belongs to the gate's active owner, even when the latest
        // request is still waiting or an intervening request was cancelled.
        if let Some(tree) = &entry.tree {
            tree.kill();
        }
        Registration {
            manager: self,
            root,
            gate: Arc::clone(&entry.gate),
            request,
            gate_guard: None,
            child: None,
            record: None,
        }
    }

    fn stopped_early(start: Instant) -> CompileResult {
        CompileResult {
            stopped: true,
            duration_ms: start.elapsed().as_millis() as u64,
            log: "The build was stopped before it started.".to_string(),
            ..CompileResult::default()
        }
    }

    /// Build with the project's settings, as they are when the build is asked for.
    pub async fn compile(
        &self,
        root: &Path,
        tex_dir: Option<&Path>,
    ) -> Result<CompileResult, CoreError> {
        let request_started = Instant::now();
        let settings = read_settings(root);
        let (engine, shell_escape) = (settings.engine.as_str(), settings.shell_escape);

        let flags = engine_flags(engine)
            .ok_or_else(|| CoreError::bad_request(format!("Unknown engine: {engine}")))?;
        let main_rel = safe_rel_file(root, &settings.main_file)?;
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

        if registration.stopped(&lock(&self.running)) {
            return Ok(Self::stopped_early(request_started));
        }

        // Capture output times after the predecessor has stopped, otherwise
        // its final writes can be mistaken for output from this generation.
        let mut run = CompileRun {
            base: main_base_name(&main_rel),
            main_rel,
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
            // Hold the registry lock across synchronous spawn + tree publication.
            // A successor or Stop therefore sees either no child or its tree,
            // never an unkillable gap between the two.
            let mut running = lock(&self.running);
            if registration.stopped(&running) {
                return Ok(Self::stopped_early(request_started));
            }
            running.get_mut(root).unwrap().record = Some(run.output("fdb_latexmk"));
            base_command("latexmk", Some(root), &path_env)
                .and_then(|mut cmd| Tree::spawn(cmd.args(&args)))
                .inspect(|(_, tree)| {
                    running.get_mut(root).unwrap().tree = Some(tree.clone());
                })
        };
        // Kept only if the run ends ok: a cancelled one drops it with the gate.
        registration.record = Some(run.output("fdb_latexmk"));
        let (end, output) = match spawned {
            Err(err) => (End::Unstarted(err.to_string()), err.to_string()),
            Ok(spawned) => {
                let (child, tree) = registration.child.insert(spawned);
                let (code, mut output, stderr, timed_out) =
                    drive(child, tree, COMPILE_TIMEOUT).await;
                registration.child = None;
                output.push_str(&stderr);
                let mut running = lock(&self.running);
                // Reaped: a Stop from here on must not signal its group, whose
                // number may already be another process's.
                running.get_mut(root).expect("registered project").tree = None;
                let end = if registration.stopped(&running) {
                    End::Stopped
                } else if timed_out {
                    End::TimedOut
                } else {
                    End::Exited(code)
                };
                if end == End::Exited(0) {
                    // A good run's record is kept, whatever stops it from here.
                    running.get_mut(root).expect("registered project").record = None;
                }
                (end, output)
            }
        };
        // Reading and parsing the logs blocks, so not on a runtime worker. It
        // only reads: a build cancelled meanwhile, its gate released, leaves
        // it nothing to change under the next build.
        let result = tokio::task::spawn_blocking(move || finish(&run, &end, output))
            .await
            .map_err(|err| CoreError::internal(err.to_string()))?;
        if result.ok {
            registration.record = None;
        }
        Ok(result)
    }
}

fn finish(run: &CompileRun, end: &End, output: String) -> CompileResult {
    let ok = *end == End::Exited(0) && run.output("pdf").exists();
    // With incremental latexmk, a clean no-op keeps both the PDF and its log.
    // Keep the warnings from that log; after a newly written PDF, an old log
    // still belongs to the previous build and must not be shown.
    let unchanged = ok && !run.wrote("pdf") && !run.wrote("log");
    let engine_log = run.read("log", unchanged);
    let mut items = parse_log(engine_log.as_deref().unwrap_or(&output), &run.main_rel);
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
        End::Unstarted(err) => {
            errors = vec![LogItem::error(format!("Couldn't start latexmk: {err}"))];
        }
        // A failure always names a cause: latexmk's own summary of the step
        // that failed (bibtex, biber, makeindex), else how it ended.
        &End::Exited(code) if !ok && errors.is_empty() => {
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
    let log = joined_log(engine_log.as_deref(), output);
    CompileResult {
        ok,
        stopped: *end == End::Stopped,
        duration_ms: run.request_started.elapsed().as_millis() as u64,
        // A failed run can only advertise a PDF it actually wrote.
        pdf: (ok || wrote_pdf).then(|| run.output("pdf").to_string_lossy().into_owned()),
        pdf_changed: wrote_pdf,
        errors,
        warnings,
        log,
    }
}

/// The end of the engine's log, then latexmk's account of the passes it ran,
/// that the result shows: the log is cut to its part before it is copied.
fn joined_log(engine_log: Option<&str>, output: String) -> String {
    let log = match engine_log {
        Some(engine_log) => format!("{}\n\n{output}", crate::tail(engine_log, LOG_TAIL)),
        None => output,
    };
    if log.len() > LOG_TAIL {
        crate::tail(&log, LOG_TAIL).to_owned()
    } else {
        log
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

#[cfg(test)]
mod tests {
    use super::{LOG_TAIL, absolute_dirs, joined_log, read_tail, user_latexmkrc, version_line};
    use crate::tail;
    use std::ffi::OsString;
    use std::path::Path;

    #[tokio::test]
    async fn cleaning_removes_the_build_folder_and_a_missing_one_is_clean() {
        let dir = tempfile::tempdir().unwrap();
        let manager = super::CompileManager::default();
        manager.clean(dir.path()).await.unwrap();
        std::fs::create_dir_all(dir.path().join("build/sub")).unwrap();
        std::fs::write(dir.path().join("build/main.aux"), "x").unwrap();
        std::fs::write(dir.path().join("main.tex"), "x").unwrap();
        manager.clean(dir.path()).await.unwrap();
        assert!(!dir.path().join("build").exists());
        assert!(dir.path().join("main.tex").exists());
    }

    #[test]
    fn a_long_log_is_read_from_its_last_whole_line_and_character() {
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
        // The log shown keeps its last whole characters.
        assert_eq!(tail("short", 10), "short");
        assert_eq!(tail("aébc", 3), "bc");
        assert_eq!(tail("aébc", 4), "ébc");
    }

    #[test]
    fn the_shown_log_is_the_end_of_both_logs_joined() {
        let long = "é".repeat(LOG_TAIL);
        for (engine, output) in [
            (None, "latexmk".to_string()),
            (Some("short"), "latexmk".to_string()),
            (Some(long.as_str()), "latexmk".to_string()),
            (Some(long.as_str()), "x".repeat(LOG_TAIL - 1)),
            (Some("engine"), long.clone()),
        ] {
            let whole = match engine {
                Some(engine) => format!("{engine}\n\n{output}"),
                None => output.clone(),
            };
            assert_eq!(joined_log(engine, output), tail(&whole, LOG_TAIL));
        }
    }

    #[test]
    fn tools_are_found_only_in_absolute_folders_of_the_path() {
        let base = std::env::temp_dir();
        let (first, last) = (base.join("bin"), base.join("tex").join("bin"));
        let path = std::env::join_paths([&first, Path::new(""), Path::new("."), &last]).unwrap();
        let dirs: Vec<_> = absolute_dirs(&path).collect();
        assert_eq!(dirs, [first, last]);
    }

    #[tokio::test]
    async fn killing_a_tree_ends_the_tool() {
        let mut command = tokio::process::Command::new(if cfg!(windows) { "cmd" } else { "sh" });
        if cfg!(windows) {
            command.args(["/C", "ping -n 30 127.0.0.1 > NUL"]);
        } else {
            command.args(["-c", "sleep 30; true"]);
        }
        let (mut child, tree) = super::Tree::spawn(&mut command).unwrap();
        tree.kill();
        let ended = tokio::time::timeout(std::time::Duration::from_secs(5), child.wait());
        assert!(!ended.await.unwrap().unwrap().success());
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
        // Without HOME, Windows' latexmk looks in the user's profile.
        let profile = OsString::from(home);
        let windows = move |key: &str| (key == "USERPROFILE").then(|| profile.clone());
        let found = user_latexmkrc(windows);
        assert_eq!(found, rc(&config).filter(|_| cfg!(windows)));
    }
}
