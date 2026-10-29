use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::logparse::{
    LogItem, Severity, latexmk_errors, parse_blg, parse_log, point_to_shell_escape,
};
use tokio::process::Child;

use crate::error::CoreError;
use crate::lock;
use crate::messages;
use crate::paths::{Project, safe_rel_file};
use crate::process::{self, Tree, drive};
use crate::settings::{granted, read_settings};
use crate::stamp::Stamp;
use crate::sys;

const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
const LOG_TAIL: usize = 200_000;
const LOG_READ_MAX: u64 = 16 * 1024 * 1024;
const STAMPED: [&str; 4] = ["log", "pdf", "blg", "aux"];
const GLOSSARY_RULES: &str = "\
    sub tl_rule { my ($from, $to) = @_; \
        add_cus_dep($from, $to, 0, 'tl_'.$to) unless grep { /^$from $to / } @cus_dep_list } \
    sub tl_gls { my ($name, $dir) = fileparse($_[0]); system('makeglossaries', '-d', $dir, $name) } \
    sub tl_acr { tl_gls(@_) } \
    sub tl_nls { system('makeindex', '-s', 'nomencl.ist', '-t', $_[0].'.nlg', \
        '-o', $_[0].'.nls', $_[0].'.nlo') } \
    sub tl_glstex { my ($name, $dir) = fileparse($_[0]); \
        my $failed = system('bib2gls', '--group', $_[0]); \
        rename($name.'.glstex', $_[0].'.glstex') if $dir; \
        if (open(my $log, $_[0].'.glg')) { while (my $line = readline($log)) { \
            rdb_ensure_file($rule, $1) if $line =~ /^Reading (.*\\.bib)\\s$/ } } \
        $failed } \
    tl_rule('glo', 'gls'); tl_rule('acn', 'acr'); tl_rule('nlo', 'nls'); tl_rule('aux', 'glstex');";

#[derive(Debug, Default, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CompileResult {
    pub ok: bool,
    pub stopped: bool,
    pub duration_ms: u64,
    pub pdf: Option<String>,
    #[serde(skip)]
    pub pdf_changed: bool,
    #[serde(skip)]
    pub errors: Vec<LogItem>,
    #[serde(skip)]
    pub warnings: Vec<LogItem>,
    pub bad_boxes: Vec<LogItem>,
    pub log: String,
}

#[derive(Default)]
struct Running {
    stopped: bool,
    tree: Option<Tree>,
}

#[derive(Default)]
pub struct CompileManager {
    running: Mutex<HashMap<PathBuf, Running>>,
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
    root: PathBuf,
    main_rel: String,
    pdf: PathBuf,
    before: HashMap<&'static str, Stamp>,
    request_started: Instant,
}

pub struct Started {
    run: CompileRun,
    spawned: Option<std::io::Result<(Child, Tree)>>,
}

impl CompileRun {
    fn output(&self, ext: &str) -> PathBuf {
        self.pdf.with_extension(ext)
    }

    fn wrote(&self, ext: &str) -> bool {
        std::fs::metadata(self.output(ext))
            .is_ok_and(|meta| self.before.get(ext) != Some(&Stamp::of(&meta)))
    }

    fn read(&self, ext: &str, allow_existing: bool) -> Option<String> {
        (allow_existing || self.wrote(ext))
            .then(|| read_tail(std::fs::File::open(self.output(ext)).ok()?, LOG_READ_MAX).ok())
            .flatten()
            .map(crate::lossy_string)
    }

    fn discard_cut_short(&self) {
        for ext in ["aux", "pdf"] {
            if self.wrote(ext) {
                let _ = std::fs::remove_file(self.output(ext));
            }
        }
    }
}

impl CompileManager {
    pub fn kill_all(&self) {
        let running = lock(&self.running);
        self.shutdown.store(true, Ordering::Release);
        for entry in running.values() {
            entry.halt();
        }
    }

    pub fn stop(&self, root: &Path) {
        if let Some(entry) = lock(&self.running).get_mut(root) {
            entry.stopped = true;
            entry.halt();
        }
    }

    pub fn clean(build: &Path) -> Result<(), CoreError> {
        match std::fs::remove_dir_all(build) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    pub fn start(&self, project: &Project, path_env: &str) -> Result<Started, CoreError> {
        let request_started = Instant::now();
        let root = &project.root;
        let (settings, trusted) = (read_settings(&project.settings), granted(project));
        let main_rel = safe_rel_file(&settings.main_file)?;
        if !root.join(&main_rel).exists() {
            return Err(CoreError::bad_request(messages::main_file_missing(
                main_rel,
            )));
        }
        let pdf = settings.output(&project.build, "pdf")?;
        let before = STAMPED.into_iter().filter_map(|ext| {
            let meta = std::fs::metadata(pdf.with_extension(ext)).ok()?;
            Some((ext, Stamp::of(&meta)))
        });
        let run = CompileRun {
            root: root.clone(),
            before: before.collect(),
            main_rel,
            pdf,
            request_started,
        };
        let command = process::command("latexmk", Some(root), path_env).map(|mut command| {
            if trusted {
                command.arg("-shell-escape");
            } else {
                command.arg("-norc");
                if let Some(rc) = sys::latexmkrc(|key| std::env::var_os(key)) {
                    command.arg("-r").arg(rc);
                }
            }
            command.args([
                settings.engine.flag(),
                "-interaction=batchmode",
                "-file-line-error",
                "-synctex=1",
                if settings.stop_on_first_error {
                    "-halt-on-error"
                } else {
                    "-f"
                },
            ]);
            command.arg("-e").arg(GLOSSARY_RULES);
            for option in ["-outdir=", "-auxdir="] {
                let mut arg = OsString::from(option);
                arg.push(&project.build);
                command.arg(arg);
            }
            command.arg(format!("./{}", run.main_rel));
            command
        });
        let mut running = lock(&self.running);
        let spawned = (!self.shutdown.load(Ordering::Acquire)).then(|| {
            let entry = running.entry(root.clone()).or_default();
            let spawned = command.and_then(|mut command| Tree::spawn(&mut command));
            spawned.inspect(|(_, tree)| entry.tree = Some(tree.clone()))
        });
        Ok(Started { run, spawned })
    }

    pub async fn wait(&self, started: Started, auto: bool) -> Result<CompileResult, CoreError> {
        let Started { run, spawned } = started;
        let Some(spawned) = spawned else {
            return Ok(stopped_before_start(&run));
        };
        let (end, output) = match spawned {
            Err(err) => (End::Unstarted(err.to_string()), err.to_string()),
            Ok((mut child, tree)) => {
                let (code, output, timed_out) =
                    drive(&mut child, &tree, auto.then_some(COMPILE_TIMEOUT)).await;
                let end = if timed_out {
                    End::TimedOut
                } else {
                    End::Exited(code)
                };
                (end, output)
            }
        };
        let entry = lock(&self.running).remove(&run.root).unwrap_or_default();
        let end = if entry.stopped || self.shutdown.load(Ordering::Acquire) {
            End::Stopped
        } else {
            end
        };
        if end != End::Exited(0) || !run.pdf.exists() {
            let _ = std::fs::remove_file(run.output("fdb_latexmk"));
        }
        tokio::task::spawn_blocking(move || finish(&run, &end, output))
            .await
            .map_err(|err| CoreError::internal(messages::unexpected(err)))
    }
}

impl Running {
    fn halt(&self) {
        if let Some(tree) = &self.tree {
            tree.kill();
        }
    }
}

fn stopped_before_start(run: &CompileRun) -> CompileResult {
    CompileResult {
        stopped: true,
        duration_ms: run.request_started.elapsed().as_millis() as u64,
        log: "The build was stopped before it started.".to_string(),
        ..CompileResult::default()
    }
}

fn finish(run: &CompileRun, end: &End, output: String) -> CompileResult {
    if matches!(end, End::Stopped | End::TimedOut) {
        run.discard_cut_short();
    }
    let ok = *end == End::Exited(0) && run.pdf.exists();
    let unchanged = ok && !run.wrote("pdf") && !run.wrote("log");
    let engine_log = run.read("log", unchanged);
    let tex_log = engine_log.as_deref().unwrap_or(&output);
    let (mut items, bad_boxes) = parse_log(tex_log, &run.main_rel);
    if let Some(blg) = run.read("blg", unchanged) {
        items.extend(parse_blg(&blg));
    }
    let (mut errors, warnings): (Vec<_>, Vec<_>) = items
        .into_iter()
        .partition(|item| item.kind == Severity::Error);
    if !ok {
        point_to_shell_escape(&mut errors, tex_log);
    }

    let wrote_pdf = matches!(end, End::Exited(_)) && run.wrote("pdf");
    match end {
        End::TimedOut => errors.push(LogItem::error(messages::timed_out(
            COMPILE_TIMEOUT.as_secs() / 60,
        ))),
        End::Unstarted(err) => {
            errors = vec![LogItem::error(messages::latexmk_unstarted(err))];
        }
        &End::Exited(code) if !ok && errors.is_empty() => {
            errors = latexmk_errors(&output);
            if errors.is_empty() {
                errors.push(LogItem::error(match code {
                    0 => messages::no_pdf_made(),
                    code => messages::latexmk_failed(code),
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
        pdf: (ok || wrote_pdf).then(|| run.pdf.to_string_lossy().into_owned()),
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

fn read_tail(mut file: std::fs::File, max: u64) -> std::io::Result<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    let len = file.metadata()?.len();
    let cut = len > max;
    file.seek(SeekFrom::Start(len.saturating_sub(max)))?;
    let mut bytes = Vec::with_capacity(len.min(max) as usize);
    file.take(max).read_to_end(&mut bytes)?;
    if cut {
        let start = bytes.iter().position(|&b| b == b'\n').map_or(0, |i| i + 1);
        bytes.drain(..start);
    }
    Ok(bytes)
}
