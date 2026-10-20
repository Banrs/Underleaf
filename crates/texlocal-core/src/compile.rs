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
/// A log that loops on `\message` until the timeout can reach gigabytes.
const LOG_READ_MAX: u64 = 16 * 1024 * 1024;
const OUTPUTS: [&str; 5] = ["log", "pdf", "blg", "aux", "fdb_latexmk"];

/// `pdf`: the PDF a good build, or a failed one compiling past errors, wrote.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompileResult {
    pub ok: bool,
    pub stopped: bool,
    pub duration_ms: u64,
    pub pdf: Option<String>,
    pub pdf_changed: bool,
    pub errors: Vec<LogItem>,
    pub warnings: Vec<LogItem>,
    pub bad_boxes: Vec<LogItem>,
    pub log: String,
}

#[derive(Default)]
struct Running {
    stopped: bool,
    /// None once reaped, when its group's number may be another's.
    tree: Option<Tree>,
    /// latexmk's record, until a good run ends. After a fatal TeX error it
    /// holds the truncated .aux's state, which fails every later run.
    record: Option<PathBuf>,
}

#[derive(Default)]
pub struct CompileManager {
    running: Mutex<HashMap<PathBuf, Running>>,
    /// A build asked for after quitting began would start an engine nothing kills.
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
    outputs: HashMap<&'static str, PathBuf>,
    before: HashMap<&'static str, Stamp>,
    request_started: Instant,
}

impl CompileRun {
    fn output(&self, ext: &str) -> &Path {
        &self.outputs[ext]
    }

    /// By stamp: a file's length and time to the nanosecond, whatever the volume's clock.
    fn wrote(&self, ext: &str) -> bool {
        std::fs::metadata(self.output(ext))
            .is_ok_and(|meta| self.before.get(ext) != Some(&Stamp::of(&meta)))
    }

    fn read(&self, ext: &str, allow_existing: bool) -> Option<String> {
        (allow_existing || self.wrote(ext))
            .then(|| read_tail(self.output(ext), LOG_READ_MAX).ok())
            .flatten()
            .map(crate::lossy_string)
    }

    /// The .aux and .pdf a killed run wrote are cut short: the next run would fail on the .aux.
    fn discard_cut_short(&self) {
        for ext in ["aux", "pdf"] {
            if self.wrote(ext) {
                let _ = std::fs::remove_file(self.output(ext));
            }
        }
    }
}

/// Named after -norc turns off the automatic ones; a relative home would be the project's.
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
        let running = lock(&self.running);
        self.shutdown.store(true, Ordering::Release);
        for entry in running.values() {
            if let Some(tree) = &entry.tree {
                tree.kill();
            }
        }
    }

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

    pub fn clean(root: &Path) -> Result<(), CoreError> {
        match std::fs::remove_dir_all(root.join(BUILD_DIR)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

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

        // None is made here: one made before the stop check could ghost a project renamed meanwhile.
        let outdir_arg = format!("-outdir={BUILD_DIR}");
        let auxdir_arg = format!("-auxdir={BUILD_DIR}");
        let mut args = vec![if shell_escape {
            "-shell-escape"
        } else {
            "-norc"
        }];
        // A project's own latexmkrc runs Perl on every build, so only a trusted project's is read.
        let user_rc = (!shell_escape)
            .then(|| user_latexmkrc(|key| std::env::var_os(key)))
            .flatten();
        // latexmk obeys an rc file where it comes in the arguments, so the user's goes first
        // and can't move the PDF out of the build folder or swap the engine.
        if let Some(rc) = &user_rc {
            args.extend(["-r", rc]);
        }
        args.extend([
            settings.engine.flag(),
            "-interaction=batchmode",
            "-file-line-error",
            "-synctex=1",
            // Past errors as Overleaf compiles, unless the project stops on the first.
            if settings.stop_on_first_error {
                "-halt-on-error"
            } else {
                "-f"
            },
            &outdir_arg,
            &auxdir_arg,
        ]);
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
    // A no-op build keeps the PDF and its log; an old log after a new PDF is the last build's.
    let unchanged = ok && !run.wrote("pdf") && !run.wrote("log");
    let engine_log = run.read("log", unchanged);
    let (mut items, bad_boxes) = parse_log(engine_log.as_deref().unwrap_or(&output), &run.main_rel);
    if let Some(blg) = run.read("blg", unchanged) {
        items.extend(parse_blg(&blg));
    }
    let (mut errors, warnings): (Vec<_>, Vec<_>) = items
        .into_iter()
        .partition(|item| item.kind == Severity::Error);

    let wrote_pdf = matches!(end, End::Exited(_)) && run.wrote("pdf");
    match end {
        End::TimedOut => errors.push(LogItem::error(format!(
            "The build was stopped after {} minutes without finishing. The Build Log shows how far it got.",
            COMPILE_TIMEOUT.as_secs() / 60
        ))),
        End::Unstarted(err) => {
            errors = vec![LogItem::error(format!("Couldn't start latexmk: {err}"))];
        }
        // A failure always names a cause: latexmk's summary of the failed step, else the exit.
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
        pdf: (ok || wrote_pdf).then(|| run.output("pdf").to_string_lossy().into_owned()),
        pdf_changed: wrote_pdf,
        errors,
        warnings,
        bad_boxes,
        log,
    }
}

fn joined_log(engine_log: Option<&str>, output: String) -> String {
    let log = match engine_log {
        Some(engine_log) => format!("{}\n\n{output}", crate::tail(engine_log, LOG_TAIL)),
        None => output,
    };
    crate::tail(&log, LOG_TAIL).to_owned()
}

/// From a line's start when it cuts: a cut line would parse as garbage.
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
