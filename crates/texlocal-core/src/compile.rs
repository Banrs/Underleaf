//! Building a project with latexmk: Stop and quit, the timeout, and the
//! stale-output guard. A session runs one build at a time.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::error::CoreError;
use crate::logparse::{LogItem, Severity, latexmk_errors, parse_blg, parse_log};
use crate::paths::safe_rel_file;
use crate::process::{self, Tree, drive};
use crate::settings::read_settings;
use crate::stamp::Stamp;
use crate::{BUILD_DIR, lock};

const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
const LOG_TAIL: usize = 200_000;
/// How much of the log file is parsed. A real document's log is a few MB at
/// most; one that loops on `\message` until the timeout can reach gigabytes.
const LOG_READ_MAX: u64 = 16 * 1024 * 1024;
/// The outputs a build reads, or removes: the engine's log and PDF, bibtex's
/// or biber's log, the .aux a killed run cuts short, and latexmk's record.
const OUTPUTS: [&str; 5] = ["log", "pdf", "blg", "aux", "fdb_latexmk"];

/// A build's outcome. `ok`: latexmk finished cleanly and the PDF exists.
/// `pdf`: the successful build's PDF, or one a failed build wrote while
/// compiling past errors, as an absolute path. `stopped`: Stop or quitting
/// ended it.
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
struct Running {
    stopped: bool,
    /// None until latexmk starts, and once it is reaped, when its group's
    /// number may be another's.
    tree: Option<Tree>,
    /// latexmk's record, until a good run ends. After a fatal TeX error it
    /// holds the truncated .aux's state, so every later run stops at "gave an
    /// error in previous invocation". A Stop removes it where it is, as a
    /// rename moves the folder before the run ends.
    record: Option<PathBuf>,
}

/// The builds running, by project root, for Stop and quitting.
#[derive(Default)]
pub struct CompileManager {
    running: Mutex<HashMap<PathBuf, Running>>,
    /// Set for good: a build asked for after quitting began would start an
    /// engine nothing kills.
    shutdown: AtomicBool,
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
    /// Each of `OUTPUTS`, where this build writes it.
    outputs: HashMap<&'static str, PathBuf>,
    /// The outputs as they were before the run: it wrote one if its stamp has
    /// changed.
    before: HashMap<&'static str, Stamp>,
    request_started: Instant,
}

impl CompileRun {
    fn output(&self, ext: &str) -> &Path {
        &self.outputs[ext]
    }

    /// Whether this run wrote an output. Its stamp (a file's length and
    /// time to the nanosecond) tells, whatever the volume's clock.
    fn wrote(&self, ext: &str) -> bool {
        std::fs::metadata(self.output(ext))
            .is_ok_and(|meta| self.before.get(ext) != Some(&Stamp::of(&meta)))
    }

    /// A fresh output, or an existing one for a successful no-op build.
    fn read(&self, ext: &str, allow_existing: bool) -> Option<String> {
        (allow_existing || self.wrote(ext))
            .then(|| read_tail(self.output(ext), LOG_READ_MAX).ok())
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

    /// Whether a build was running.
    pub fn stop(&self, root: &Path) -> bool {
        let mut running = lock(&self.running);
        let Some(entry) = running.get_mut(root) else {
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

    /// The session cleans only once its build has ended.
    pub fn clean(root: &Path) -> Result<(), CoreError> {
        match std::fs::remove_dir_all(root.join(BUILD_DIR)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    /// Build with the project's settings, as they are when the build is asked
    /// for, running TeX's tools from `path_env`.
    pub async fn compile(&self, root: &Path, path_env: &str) -> Result<CompileResult, CoreError> {
        let request_started = Instant::now();
        let settings = read_settings(root);
        let shell_escape = settings.shell_escape;
        let main_rel = safe_rel_file(&settings.main_file)?;
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
        let mut args = vec![settings.engine.flag()];
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
        let outputs: HashMap<_, _> = OUTPUTS
            .into_iter()
            .map(|ext| Ok((ext, settings.output(root, ext)?)))
            .collect::<Result<_, CoreError>>()?;

        let run = CompileRun {
            main_rel,
            before: (outputs.iter())
                .filter_map(|(&ext, path)| Some((ext, Stamp::of(&std::fs::metadata(path).ok()?))))
                .collect(),
            outputs,
            request_started,
        };
        let spawned = {
            // Spawned and published under the lock, so Stop and quitting see
            // either no child or its tree.
            let mut running = lock(&self.running);
            if self.shutdown.load(Ordering::Acquire) {
                return Ok(CompileResult {
                    stopped: true,
                    duration_ms: request_started.elapsed().as_millis() as u64,
                    log: "The build was stopped before it started.".to_string(),
                    ..CompileResult::default()
                });
            }
            let entry = running.entry(root.to_path_buf()).or_default();
            entry.record = Some(run.output("fdb_latexmk").to_path_buf());
            process::command("latexmk", Some(root), path_env)
                .and_then(|mut cmd| Tree::spawn(cmd.args(&args)))
                .inspect(|(_, tree)| entry.tree = Some(tree.clone()))
        };
        let (end, output) = match spawned {
            Err(err) => (End::Unstarted(err.to_string()), err.to_string()),
            Ok((mut child, tree)) => {
                let (code, mut output, stderr, timed_out) =
                    drive(&mut child, &tree, COMPILE_TIMEOUT).await;
                output.push_str(&stderr);
                let end = if timed_out {
                    End::TimedOut
                } else {
                    End::Exited(code)
                };
                (end, output)
            }
        };
        let entry = lock(&self.running).remove(root).unwrap_or_default();
        let end = if entry.stopped || self.shutdown.load(Ordering::Acquire) {
            End::Stopped
        } else {
            end
        };
        if let Some(record) = entry.record
            && (end != End::Exited(0) || !run.output("pdf").exists())
        {
            let _ = std::fs::remove_file(record);
        }
        // Reading and parsing the logs blocks, so not on a runtime worker.
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
    crate::tail(&log, LOG_TAIL).to_owned()
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

#[cfg(all(test, unix))]
mod stubs;

#[cfg(test)]
mod tests {
    use super::{LOG_TAIL, joined_log, read_tail, user_latexmkrc};
    use crate::tail;
    use std::ffi::OsString;
    use std::path::Path;

    #[test]
    fn cleaning_removes_the_build_folder_and_a_missing_one_is_clean() {
        let dir = tempfile::tempdir().unwrap();
        let clean = super::CompileManager::clean;
        clean(dir.path()).unwrap();
        std::fs::create_dir_all(dir.path().join("build/sub")).unwrap();
        std::fs::write(dir.path().join("build/main.aux"), "x").unwrap();
        std::fs::write(dir.path().join("main.tex"), "x").unwrap();
        clean(dir.path()).unwrap();
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
