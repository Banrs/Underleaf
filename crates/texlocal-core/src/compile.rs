//! Building a project with latexmk: one build at a time per project, a newer
//! request superseding the one running, Stop and quit, the timeout, and the
//! stale-output guard. The process and TeX discovery it stands on are in
//! `process` and `tex`.

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::sync::OwnedMutexGuard;

use crate::atomic::Stamp;
use crate::error::CoreError;
use crate::logparse::{LogItem, Severity, latexmk_errors, parse_blg, parse_log};
use crate::paths::safe_rel_file;
use crate::process::{self, drive};
use crate::settings::{main_base_name, read_settings};
use crate::{BUILD_DIR, lock};

// Where these were before compile.rs was split; the code that reaches TeX
// discovery and the process tree through here has yet to move to the modules.
pub(crate) use crate::process::Tree;
pub use crate::tex::{TexStatus, tex_available, tex_path};
pub(crate) use crate::tex::{find_tool, join_path, program_at, tex_bin_dir};

const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
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
    /// Which request is the project's current one: each request and each Stop
    /// moves it on, and a request holding another number has been replaced
    /// or stopped.
    epoch: u64,
    /// The requests alive, waiting for the gate or running.
    busy: usize,
    /// The active run's tree, for a request that replaces it to kill.
    tree: Option<Tree>,
    /// The active run's latexmk record, until a good run ends. It is removed
    /// where the run ends if it did not end ok, and by a Stop, to remove it
    /// where it is: a rename moves the folder before the run can remove it
    /// itself. After a fatal TeX error it holds the truncated .aux's state, so
    /// bibtex fails on it ("no \citation") and every later run stops at "gave
    /// an error in previous invocation", even with -g and the source fixed.
    /// Without it the next run starts afresh.
    record: Option<PathBuf>,
}

type Registry = HashMap<PathBuf, RunningEntry>;
type ProjectGate = tokio::sync::Mutex<()>;

/// One compile per project, supersede-kill semantics, and kill-all on quit.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<Registry>,
    /// Set by `kill_all`, for good: a build asked for after quitting began
    /// (a queued one, an automatic one) would start an engine nothing kills.
    shutdown: AtomicBool,
    pub path_env: Option<String>,
}

/// Keeps the project's gate alive through waiting, running, and cancellation.
/// Dropping a live child kills its whole tree, and a run that did not end ok
/// loses latexmk's record, before the gate is released.
struct Registration<'a> {
    manager: &'a CompileManager,
    root: &'a Path,
    gate: Arc<ProjectGate>,
    epoch: u64,
    gate_guard: Option<OwnedMutexGuard<()>>,
    child: Option<(tokio::process::Child, Tree)>,
}

impl Registration<'_> {
    /// Stop ended it, a newer request replaced it, or the app is quitting.
    /// Asked with the registry locked, as `kill_all` sets the latch.
    fn stopped(&self, running: &Registry) -> bool {
        self.manager.shutdown.load(Ordering::Acquire) || running[self.root].epoch != self.epoch
    }
}

impl Drop for Registration<'_> {
    fn drop(&mut self) {
        let mut running = lock(&self.manager.running);
        let entry = running.get_mut(self.root).expect("registered project");
        entry.busy -= 1;
        // Not once it is reaped, when its group's number may be another's.
        if let Some((child, tree)) = &self.child
            && child.id().is_some()
        {
            tree.kill();
        }
        if self.gate_guard.is_some() {
            entry.tree = None;
            if let Some(record) = entry.record.take() {
                let _ = std::fs::remove_file(record);
            }
        }
        self.child = None;
        // On cancellation, Tokio reaps the killed child after this guard releases.
        self.gate_guard = None;
        forget_idle(&mut running, self.root, &self.gate);
    }
}

/// Drops a project's entry when only the registry and `gate` still own its
/// gate: nobody is waiting, running or cleaning.
fn forget_idle(running: &mut Registry, root: &Path, gate: &Arc<ProjectGate>) {
    if Arc::strong_count(gate) == 2 {
        running.remove(root);
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
    /// The outputs finish() reads, as they were before the run: it wrote one
    /// if its stamp has changed.
    before: HashMap<&'static str, Stamp>,
    request_started: Instant,
}

fn stamp(path: &Path) -> Option<Stamp> {
    std::fs::metadata(path).ok().map(|meta| Stamp::of(&meta))
}

impl CompileRun {
    fn output(&self, ext: &str) -> PathBuf {
        self.outdir.join(format!("{}.{ext}", self.base))
    }

    /// Whether this run wrote an output. Its stamp (a file's length and
    /// time to the nanosecond) tells, whatever the volume's clock.
    fn wrote(&self, ext: &str) -> bool {
        stamp(&self.output(ext)).is_some_and(|now| self.before.get(ext) != Some(&now))
    }

    /// A fresh output, or an existing one for a successful no-op build.
    fn read(&self, ext: &str, allow_existing: bool) -> Option<String> {
        (allow_existing || self.wrote(ext))
            .then(|| read_tail(&self.output(ext), LOG_READ_MAX).ok())
            .flatten()
            .map(crate::lossy_string)
    }

    /// Removes the .aux and .pdf this run wrote, once it is killed: they are
    /// cut short. The next run would read the .aux and fail on a file the
    /// user cannot fix ("File ended while scanning"), and the project would
    /// open on a PDF with pages missing. Outputs it never touched are the
    /// previous build's, and whole.
    fn discard_cut_short(&self) {
        for ext in ["aux", "pdf"] {
            if self.wrote(ext) {
                let _ = std::fs::remove_file(self.output(ext));
            }
        }
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
    /// Quitting: ends every build, and any asked for after it.
    pub fn kill_all(&self) {
        let running = lock(&self.running);
        self.shutdown.store(true, Ordering::Release);
        for entry in running.values() {
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
        let Some(entry) = running.get_mut(root).filter(|entry| entry.busy > 0) else {
            return false;
        };
        entry.epoch += 1;
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
        let cleaned = {
            let _idle = gate.lock().await;
            std::fs::remove_dir_all(root.join(BUILD_DIR))
        };
        forget_idle(&mut lock(&self.running), root, &gate);
        match cleaned {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    fn register<'a>(&'a self, root: &'a Path) -> Registration<'a> {
        let mut running = lock(&self.running);
        let entry = running.entry(root.to_path_buf()).or_default();
        entry.epoch += 1;
        entry.busy += 1;
        // The tree belongs to the gate's active owner, even when the latest
        // request is still waiting or an intervening request was cancelled.
        if let Some(tree) = &entry.tree {
            tree.kill();
        }
        Registration {
            manager: self,
            root,
            gate: Arc::clone(&entry.gate),
            epoch: entry.epoch,
            gate_guard: None,
            child: None,
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

        // latexmk makes the folder itself, so none is made here: one made
        // before the stop check below could be a ghost of a project renamed
        // meanwhile.
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

        // Capture the outputs' stamps after the predecessor has stopped,
        // otherwise its final writes can be mistaken for output from this run.
        let mut run = CompileRun {
            base: main_base_name(&main_rel),
            main_rel,
            outdir: root.join(BUILD_DIR),
            before: HashMap::new(),
            request_started,
        };
        run.before = ["log", "pdf", "blg", "aux"]
            .into_iter()
            .filter_map(|ext| Some((ext, stamp(&run.output(ext))?)))
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
            let entry = running.get_mut(root).expect("registered project");
            entry.record = Some(run.output("fdb_latexmk"));
            process::command("latexmk", Some(root), &path_env)
                .and_then(|mut cmd| Tree::spawn(cmd.args(&args)))
                .inspect(|(_, tree)| entry.tree = Some(tree.clone()))
        };
        let (end, output) = match spawned {
            Err(err) => (End::Unstarted(err.to_string()), err.to_string()),
            Ok(spawned) => {
                let (child, tree) = registration.child.insert(spawned);
                let (code, mut output, stderr, timed_out) =
                    drive(child, tree, COMPILE_TIMEOUT).await;
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
                if end == End::Exited(0) && run.output("pdf").exists() {
                    // A good run's record is kept, whatever stops it from here.
                    entry.record = None;
                }
                (end, output)
            }
        };
        // Reading and parsing the logs blocks, so not on a runtime worker. It
        // only reads and clears what a killed run left: a build cancelled
        // meanwhile, its gate released, leaves it nothing to change under the
        // next build.
        tokio::task::spawn_blocking(move || finish(&run, &end, output))
            .await
            .map_err(|err| CoreError::internal(err.to_string()))
    }
}

fn finish(run: &CompileRun, end: &End, output: String) -> CompileResult {
    if matches!(end, End::Stopped | End::TimedOut) {
        run.discard_cut_short();
    }
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
    let (mut errors, warnings): (Vec<_>, Vec<_>) = items
        .into_iter()
        .partition(|item| item.kind == Severity::Error);

    // Not from a build cut short, which may have left it half-written.
    let wrote_pdf = matches!(end, End::Exited(_)) && run.wrote("pdf");
    match end {
        End::TimedOut => errors.push(LogItem::error(format!(
            "The build was stopped after {} minutes without finishing. The Build Log shows how far it got.",
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
    use super::{LOG_TAIL, joined_log, read_tail, user_latexmkrc};
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
        // Nothing of the project is kept: it never built, and may be renamed.
        assert!(crate::lock(&manager.running).is_empty());
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
