//! LaTeX builds by latexmk: finding TeX, killing a tool with all it starts, one build per
//! project that a newer one or a Stop ends, time and output limits, and telling this build's
//! outputs from an earlier one's.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use serde::Serialize;
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};
use tokio::sync::OwnedMutexGuard;

use crate::error::CoreError;
use crate::logparse::{LogItem, latexmk_errors, parse_blg, parse_log};
use crate::paths::safe_rel_file;
use crate::settings::{main_base_name, read_settings};
use crate::{BUILD_DIR, lock, lossy_string, tail};

const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
pub(crate) const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
/// The most of a tool's stdout, and of its stderr, kept.
const PIPE_KEPT: u64 = 1_000_000;
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

/// What `dir` holds; nothing if it can't be read.
fn children(dir: impl AsRef<Path>) -> impl Iterator<Item = PathBuf> {
    fs::read_dir(dir).into_iter().flatten().filter_map(|entry| Some(entry.ok()?.path()))
}

/// PATH for spawned TeX tools: the folder the user chose first, then the
/// user's PATH, then where TeX's installers put it. Built per use — a couple
/// of read_dirs — so a TeX install performed while the app runs is found
/// without a restart.
pub(crate) fn tex_path(chosen: Option<&Path>) -> String {
    let user = std::env::var_os("PATH").unwrap_or_default();
    let chosen = chosen.map(Path::to_path_buf).into_iter();
    join_path(chosen.chain(absolute_dirs(&user)).chain(usual_tex_dirs()))
}

/// MiKTeX's folders for one user and for all, or MacTeX's link and Homebrew's;
/// then TeX Live's bin folders, newest year first.
fn usual_tex_dirs() -> Vec<PathBuf> {
    let (mut dirs, texlive): (Vec<_>, PathBuf) = if cfg!(windows) {
        let under = |var, dir| Some(PathBuf::from(std::env::var_os(var)?).join(dir));
        let mut texlive = std::env::var_os("SystemDrive").unwrap_or_else(|| "C:".into());
        texlive.push(r"\texlive");
        let miktex = [
            under("LOCALAPPDATA", r"Programs\MiKTeX\miktex\bin\x64"),
            under("ProgramFiles", r"MiKTeX\miktex\bin\x64"),
        ];
        (miktex.into_iter().flatten().collect(), texlive.into())
    } else {
        let usual = ["/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin"];
        (usual.map(PathBuf::from).into(), "/usr/local/texlive".into())
    };
    let mut years: Vec<_> = children(texlive)
        .filter(|year| {
            let name = year.file_name().and_then(OsStr::to_str);
            name.is_some_and(|name| name.len() == 4 && name.bytes().all(|b| b.is_ascii_digit()))
        })
        .collect();
    years.sort_unstable_by(|a, b| b.cmp(a));
    dirs.extend(years.iter().flat_map(|year| children(year.join("bin"))));
    dirs
}

/// Folders as a PATH, in the platform's form. A folder whose name holds the
/// separator can't be one of them, and is left out.
pub(crate) fn join_path(dirs: impl IntoIterator<Item = PathBuf>) -> String {
    let dirs = dirs.into_iter().filter(|dir| std::env::join_paths([dir]).is_ok());
    std::env::join_paths(dirs).map(|path| path.to_string_lossy().into_owned()).unwrap_or_default()
}

/// A PATH's absolute folders: an empty or relative entry would be looked up
/// from the project, where a latexmk of its own could stand.
fn absolute_dirs(path: &OsStr) -> impl Iterator<Item = PathBuf> + '_ {
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

/// A tool and every process it starts, the engines latexmk or TeXpresso runs
/// among them, which stopping the tool alone would leak: a process group of
/// its own on Unix, a Job Object on Windows. Kept apart from the child, so a
/// Stop or quit kills the tree from any thread while another awaits the tool.
#[derive(Clone)]
pub(crate) struct Tree {
    #[cfg(unix)]
    group: i32,
    /// A job that ends every process in it when it is killed, or when its
    /// last handle closes: as the last owner of its tree here lets go, or the
    /// app quits or crashes.
    #[cfg(windows)]
    job: Arc<std::os::windows::io::OwnedHandle>,
}

impl Tree {
    pub(crate) fn spawn(command: &mut Command) -> std::io::Result<(Child, Self)> {
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
            let handle = child.raw_handle().expect("a child just spawned has its handle");
            // Joined as it starts, long before it has loaded, let alone run a
            // program of its own.
            match job_of(handle) {
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
        // SAFETY: the handle is open while self is.
        #[cfg(windows)]
        unsafe {
            use std::os::windows::io::AsRawHandle;
            windows_sys::Win32::System::JobObjects::TerminateJobObject(self.job.as_raw_handle(), 1);
        }
    }
}

/// A new job holding `process`, which takes every process it starts.
#[cfg(windows)]
fn job_of(
    process: std::os::windows::io::RawHandle,
) -> std::io::Result<std::os::windows::io::OwnedHandle> {
    use std::io::Error;
    use std::os::windows::io::FromRawHandle;
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject,
    };
    // SAFETY: no name and no attributes make an unnamed job with the default
    // security; the handle is owned from here.
    let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    if handle.is_null() {
        return Err(Error::last_os_error());
    }
    let job = unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(handle) };
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: the limits are of the class named, at their own size, and both
    // handles are open.
    let joined = unsafe {
        SetInformationJobObject(
            handle,
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        ) != 0
            && AssignProcessToJobObject(handle, process) != 0
    };
    // The error is read before closing the job could change it.
    if joined { Ok(job) } else { Err(Error::last_os_error()) }
}

fn base_command(program: &str, cwd: Option<&Path>, path_env: &str) -> std::io::Result<Command> {
    // A full path avoids std's fork fallback, which can crash a child of the
    // multithreaded Mac app before exec.
    let missing = || std::io::Error::other(format!("{program} is not on the PATH"));
    let program = find_tool(program, path_env).ok_or_else(missing)?;
    let mut cmd = Command::new(program);
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

/// Keeps bounded output while reading to EOF, so a full pipe cannot block the
/// child. The caller keeps what was read if it ends the read early.
async fn read_capped(mut reader: impl tokio::io::AsyncRead + Unpin, kept: &mut Vec<u8>) {
    let mut capped = (&mut reader).take(PIPE_KEPT);
    if capped.read_to_end(kept).await.is_ok() {
        let _ = tokio::io::copy(&mut reader, &mut tokio::io::sink()).await;
    }
}

/// Runs a tool to its end, or kills its whole tree at `timeout`: the exit code
/// (-1 for none) and its stdout.
pub(crate) async fn run(
    program: &str,
    args: &[&str],
    cwd: Option<&Path>,
    timeout: Duration,
    path_env: &str,
) -> (i32, String) {
    match base_command(program, cwd, path_env).and_then(|mut cmd| Tree::spawn(cmd.args(args))) {
        Ok((mut child, tree)) => {
            let (code, stdout, ..) = drive(&mut child, &tree, timeout).await;
            (code, stdout)
        }
        Err(_) => (-1, String::new()),
    }
}

/// Collects capped output while the child runs, its tree killed before it is
/// reaped on timeout: the exit code, stdout, stderr and whether it timed out.
async fn drive(child: &mut Child, tree: &Tree, timeout: Duration) -> (i32, String, String, bool) {
    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (status, timed_out) = {
        let readers = async {
            tokio::join!(read_capped(stdout, &mut out), read_capped(stderr, &mut err));
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
            // A descendant or an unrelated process can hold the pipes past the
            // child: their buffered output is read briefly, then let go.
            ended = &mut wait => {
                let _ = tokio::time::timeout(DRAIN_GRACE, readers).await;
                ended
            }
            () = &mut readers => wait.await,
        }
    };
    let code = status.and_then(|s| s.code()).unwrap_or(-1);
    (code, lossy_string(out), lossy_string(err), timed_out)
}

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
    if code != 0 {
        return TexStatus::default();
    }
    let latexmk = find_tool("latexmk", path_env);
    TexStatus {
        available: true,
        version: Some(version_line(&stdout)),
        found: latexmk.and_then(|path| Some(path.parent()?.to_string_lossy().into_owned())),
        ..TexStatus::default()
    }
}

/// latexmk's own version line, falling back to the first nonempty line.
fn version_line(stdout: &str) -> String {
    let mut lines = stdout.lines().map(str::trim).filter(|l| !l.is_empty());
    let first = lines.clone().next().unwrap_or("");
    let line = lines.find(|l| l.starts_with("Latexmk")).unwrap_or(first);
    line.to_string()
}

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

type Gate = tokio::sync::Mutex<()>;

/// A project's builds: the gate they pass one at a time, and what its holder runs.
#[derive(Default)]
struct Entry {
    gate: Arc<Gate>,
    /// The latest request, until it ends or is stopped.
    latest: Option<u64>,
    tree: Option<Tree>,
    /// latexmk's record of a run that has started and not ended well. After
    /// a fatal TeX error it holds the truncated .aux's state, so bibtex fails
    /// on it ("no \citation") and every later run stops at "gave an error in
    /// previous invocation", even with -g and the source fixed. Removed, the
    /// next run starts afresh. A Stop removes it where it is: a rename moves
    /// the folder before the run could.
    record: Option<PathBuf>,
}

impl Entry {
    /// Ends the latest request, and the run, if there is either; whether there was.
    fn stop(&mut self) -> bool {
        if let Some(tree) = &self.tree {
            tree.kill();
        }
        if let Some(record) = self.record.take() {
            let _ = fs::remove_file(record);
        }
        self.latest.take().is_some() || self.tree.is_some()
    }
}

/// One build per project, a newer one or Stop ending the one before, and
/// kill-all on quit.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<HashMap<PathBuf, Entry>>,
    pub path_env: Option<String>,
}

/// A request's hold on its project, through waiting, running and cancellation.
/// Dropped, it kills a live child's whole tree and removes the record of a run
/// that didn't end well, before the gate lets the next build in.
struct Registration<'a> {
    manager: &'a CompileManager,
    root: &'a Path,
    id: u64,
    gate: Arc<Gate>,
    guard: Option<OwnedMutexGuard<()>>,
    child: Option<Child>,
}

impl Registration<'_> {
    /// A Stop, a newer request or quitting ended it.
    fn stopped(&self, running: &HashMap<PathBuf, Entry>) -> bool {
        running[self.root].latest != Some(self.id)
    }
}

impl Drop for Registration<'_> {
    fn drop(&mut self) {
        let mut running = lock(&self.manager.running);
        let entry = running.get_mut(self.root).expect("registered project");
        if entry.latest == Some(self.id) {
            entry.latest = None;
        }
        if self.guard.is_some() {
            let child = self.child.take();
            // Not once it is reaped, when its group's number may be another's.
            if let Some(tree) = entry.tree.take()
                && child.as_ref().is_some_and(|child| child.id().is_some())
            {
                tree.kill();
            }
            // On cancellation, Tokio reaps the killed child after the gate opens.
            drop(child);
            if let Some(record) = entry.record.take() {
                let _ = fs::remove_file(record);
            }
            self.guard = None;
        }
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
    fs::metadata(path).and_then(|meta| meta.modified()).ok()
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
        let fresh = allow_existing || self.wrote(ext);
        fresh.then(|| read_tail(&self.output(ext), LOG_READ_MAX).ok())?.map(lossy_string)
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
    [config.join("latexmk").join("latexmkrc"), home.join(".latexmkrc")]
        .into_iter()
        .find(|rc| rc.is_file())
        .map(|rc| rc.to_string_lossy().into_owned())
}

impl CompileManager {
    pub(crate) fn kill_all(&self) {
        lock(&self.running).values_mut().for_each(|entry| {
            entry.stop();
        });
    }

    /// Stops a project's build, and says whether one was asked for or running.
    /// The run and a successor waiting on it settle as usual, the run saying it
    /// was stopped; one that hasn't started latexmk yet doesn't start it.
    pub(crate) fn stop(&self, root: &Path) -> bool {
        lock(&self.running).get_mut(root).is_some_and(Entry::stop)
    }

    /// Removes the project's build folder, with a running build stopped and
    /// settled first. A folder that isn't there is already clean.
    pub(crate) async fn clean(&self, root: &Path) -> Result<(), CoreError> {
        self.stop(root);
        let gate = Arc::clone(&lock(&self.running).entry(root.into()).or_default().gate);
        let _idle = gate.lock().await;
        match fs::remove_dir_all(root.join(BUILD_DIR)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    fn register<'a>(&'a self, root: &'a Path) -> Registration<'a> {
        static REQUESTS: AtomicU64 = AtomicU64::new(0);
        let id = REQUESTS.fetch_add(1, Ordering::Relaxed);
        let mut running = lock(&self.running);
        let entry = running.entry(root.into()).or_default();
        // The tree is the gate holder's, even while the latest request waits
        // or one between them was cancelled.
        entry.stop();
        entry.latest = Some(id);
        Registration {
            manager: self,
            root,
            id,
            gate: Arc::clone(&entry.gate),
            guard: None,
            child: None,
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
        let engine = &settings.engine;
        let flags = engine_flags(engine)
            .ok_or_else(|| CoreError::bad_request(format!("Unknown engine: {engine}")))?;
        let main_rel = safe_rel_file(root, &settings.main_file)?;
        if !root.join(&main_rel).exists() {
            let missing = format!("Main file not found: {main_rel}");
            return Err(CoreError::bad_request(missing));
        }
        let outdir = root.join(BUILD_DIR);
        fs::create_dir_all(&outdir)?;

        // A latexmkrc is Perl that runs on every build, so a project's own is
        // honoured only in a project trusted with shell escape. -norc turns
        // off every automatic rc file, and the user's own is named again.
        let shell_escape = settings.shell_escape;
        let user_rc =
            (!shell_escape).then(|| user_latexmkrc(|key| std::env::var_os(key))).flatten();
        let (outdir_arg, main_arg) = (format!("-outdir={BUILD_DIR}"), format!("./{main_rel}"));
        let mut args = flags.to_vec();
        args.extend([
            "-interaction=batchmode",
            "-file-line-error",
            "-synctex=1",
            // By default, past errors as Overleaf compiles: TeX carries on
            // and latexmk finishes its passes (-f), so the PDF shows all that
            // compiled and the log every error.
            if settings.stop_on_first_error { "-halt-on-error" } else { "-f" },
            &outdir_arg,
            if shell_escape { "-shell-escape" } else { "-norc" },
        ]);
        if let Some(rc) = &user_rc {
            args.extend(["-r", rc]);
        }
        args.push(&main_arg);

        let mut registration = self.register(root);
        // The gate keeps a successor off the build folder until its
        // predecessor settles, even if a request between them is cancelled.
        registration.guard = Some(Arc::clone(&registration.gate).lock_owned().await);

        // Times taken once the predecessor has stopped: its last writes
        // aren't this build's output.
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
        let path_env = match &self.path_env {
            Some(path_env) => path_env.clone(),
            None => tex_path(tex_dir),
        };
        let spawned = {
            // Spawned and its tree published under the registry's lock: a
            // successor or Stop sees no child or its tree, never an
            // unkillable gap between the two.
            let mut running = lock(&self.running);
            if registration.stopped(&running) {
                return Ok(CompileResult {
                    stopped: true,
                    duration_ms: request_started.elapsed().as_millis() as u64,
                    log: "The build was stopped before it started.".to_string(),
                    ..CompileResult::default()
                });
            }
            let entry = running.get_mut(root).expect("registered project");
            entry.record = Some(run.output("fdb_latexmk"));
            let spawned = base_command("latexmk", Some(root), &path_env)
                .and_then(|mut cmd| Tree::spawn(cmd.args(&args)));
            if let Ok((_, tree)) = &spawned {
                entry.tree = Some(tree.clone());
            }
            spawned
        };
        let (end, output) = match spawned {
            Err(err) => (End::Unstarted(err.to_string()), err.to_string()),
            Ok((child, tree)) => {
                let child = registration.child.insert(child);
                let (code, mut output, stderr, timed_out) =
                    drive(child, &tree, COMPILE_TIMEOUT).await;
                registration.child = None;
                output.push_str(&stderr);
                let mut running = lock(&self.running);
                let end = if registration.stopped(&running) {
                    End::Stopped
                } else if timed_out {
                    End::TimedOut
                } else {
                    End::Exited(code)
                };
                let entry = running.get_mut(root).expect("registered project");
                // Reaped: a Stop from here on must not signal its group, whose
                // number may already be another process's.
                entry.tree = None;
                // A good run's record is kept, whatever stops it from here.
                if end == End::Exited(0) && run.output("pdf").exists() {
                    entry.record = None;
                }
                (end, output)
            }
        };
        // Reading and parsing the logs blocks, so not on a runtime worker. It
        // only reads: a build cancelled meanwhile, its gate released, leaves
        // it nothing to change under the next build.
        tokio::task::spawn_blocking(move || finish(&run, &end, output))
            .await
            .map_err(|err| CoreError::internal(err.to_string()))
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
    items.extend(run.read("blg", unchanged).iter().flat_map(|blg| parse_blg(blg)));
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
    CompileResult {
        ok,
        stopped: *end == End::Stopped,
        duration_ms: run.request_started.elapsed().as_millis() as u64,
        // A failed run can only advertise a PDF it actually wrote.
        pdf: (ok || wrote_pdf).then(|| run.output("pdf").to_string_lossy().into_owned()),
        pdf_changed: wrote_pdf,
        errors,
        warnings,
        log: joined_log(engine_log.as_deref(), &output),
    }
}

/// The last `LOG_TAIL` bytes of the engine's log and latexmk's account of the
/// passes it ran, joined: only what is shown is copied, once.
fn joined_log(engine_log: Option<&str>, output: &str) -> String {
    let parts = match engine_log {
        Some(log) => [log, "\n\n", output],
        None => ["", "", output],
    };
    let mut room = LOG_TAIL;
    let mut kept = Vec::new();
    for part in parts.into_iter().rev() {
        let end = tail(part, room);
        room -= end.len();
        kept.push(end);
        if end.len() < part.len() {
            break;
        }
    }
    kept.into_iter().rev().collect()
}

/// A file's last `max` bytes, starting at a line when it had to cut: errors
/// sit at the end of a log, and a cut line would parse as garbage.
fn read_tail(path: &Path, max: u64) -> std::io::Result<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = fs::File::open(path)?;
    let len = file.metadata()?.len();
    let cut = len > max;
    if cut {
        file.seek(SeekFrom::Start(len - max))?;
    }
    let mut bytes = Vec::with_capacity(len.min(max) as usize);
    file.take(max).read_to_end(&mut bytes)?;
    if cut {
        let start = memchr::memchr(b'\n', &bytes).map_or(0, |i| i + 1);
        bytes.drain(..start);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cleaning_removes_the_build_folder_and_a_missing_one_is_clean() {
        let dir = tempfile::tempdir().unwrap();
        let manager = CompileManager::default();
        manager.clean(dir.path()).await.unwrap();
        fs::create_dir_all(dir.path().join("build/sub")).unwrap();
        fs::write(dir.path().join("main.tex"), "x").unwrap();
        manager.clean(dir.path()).await.unwrap();
        assert!(!dir.path().join("build").exists() && dir.path().join("main.tex").exists());
    }

    #[test]
    fn a_long_log_is_read_from_its_last_whole_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("main.log");
        fs::write(&path, "first line\nsecond line\n./main.tex:3: Boom.\n").unwrap();
        assert_eq!(read_tail(&path, 30).unwrap(), b"./main.tex:3: Boom.\n");
        assert_eq!(read_tail(&path, 1000).unwrap(), fs::read(&path).unwrap());
    }

    #[test]
    fn the_shown_log_is_the_end_of_both_logs_joined() {
        let long = "é".repeat(LOG_TAIL);
        for (engine, output) in [
            (None, "latexmk".to_string()),
            (None, long.clone() + "x"),
            (Some("short"), "latexmk".to_string()),
            (Some(long.as_str()), "latexmk".to_string()),
            (Some(long.as_str()), "x".repeat(LOG_TAIL - 1)),
            (Some(long.as_str()), "x".repeat(LOG_TAIL - 3)),
            (Some("engine"), long.clone()),
        ] {
            let whole = match engine {
                Some(engine) => format!("{engine}\n\n{output}"),
                None => output.clone(),
            };
            assert_eq!(joined_log(engine, &output), tail(&whole, LOG_TAIL));
        }
    }

    #[test]
    fn tools_are_found_only_in_absolute_folders_of_the_path() {
        let base = std::env::temp_dir();
        let (first, last) = (base.join("bin"), base.join("tex").join("bin"));
        let path = std::env::join_paths([&first, Path::new(""), Path::new("."), &last]).unwrap();
        assert_eq!(absolute_dirs(&path).collect::<Vec<_>>(), [first, last]);
    }

    #[tokio::test]
    async fn killing_a_tree_ends_the_tool() {
        let mut command = Command::new(if cfg!(windows) { "cmd" } else { "sh" });
        if cfg!(windows) {
            command.args(["/C", "ping -n 30 127.0.0.1 > NUL"]);
        } else {
            command.args(["-c", "sleep 30; true"]);
        }
        let (mut child, tree) = Tree::spawn(&mut command).unwrap();
        tree.kill();
        let ended = tokio::time::timeout(Duration::from_secs(5), child.wait());
        assert!(!ended.await.unwrap().unwrap().success());
    }

    #[test]
    fn the_version_names_latexmk() {
        let line = "Latexmk, John Collins, 1 Jan 2025. Version 4.86";
        assert_eq!(version_line(&format!("\nbanner\n{line}\n")), line);
        assert_eq!(version_line("something else\n"), "something else");
    }

    #[test]
    fn the_users_own_latexmkrc_is_found_where_latexmk_looks() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let env = |key: &'static str, home: &Path| {
            let home = OsString::from(home);
            move |var: &str| (var == key).then(|| home.clone())
        };
        let rc = |path: PathBuf| Some(path.to_string_lossy().into_owned());
        assert_eq!(user_latexmkrc(env("HOME", home)), None);
        fs::write(home.join(".latexmkrc"), "").unwrap();
        assert_eq!(user_latexmkrc(env("HOME", home)), rc(home.join(".latexmkrc")));
        let config = home.join(".config").join("latexmk").join("latexmkrc");
        fs::create_dir_all(config.parent().unwrap()).unwrap();
        fs::write(&config, "").unwrap();
        assert_eq!(user_latexmkrc(env("HOME", home)), rc(config.clone()));
        // A relative home would be the project's own folder.
        assert_eq!(user_latexmkrc(env("HOME", Path::new("."))), None);
        // Without HOME, Windows' latexmk looks in the user's profile.
        let found = user_latexmkrc(env("USERPROFILE", home));
        assert_eq!(found, rc(config).filter(|_| cfg!(windows)));
    }
}
