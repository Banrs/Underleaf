//! Building a project with latexmk, or where TeX runs inside the app with the passes latexmk
//! would make (`passes`): Stop and quit, an automatic build's timeout, and the stale-output
//! guard. A session runs one build at a time.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::error::CoreError;
use crate::lock;
use crate::logparse::{
    LogItem, Severity, latexmk_errors, parse_blg, parse_log, point_to_shell_escape,
};
use crate::paths::{Project, safe_rel_file};
use crate::process::{self, Tree, drive};
use crate::settings::read_settings;
use crate::stamp::Stamp;

/// An automatic build's alone: one asked for runs until it ends or is stopped, but a document
/// that loops would start a build that never ends at each pause in typing.
const COMPILE_TIMEOUT: Duration = Duration::from_secs(180);
const LOG_TAIL: usize = 200_000;
/// A log that loops on `\message` can reach gigabytes before a timeout or Stop.
const LOG_READ_MAX: u64 = 16 * 1024 * 1024;
/// The outputs whose stamps tell whether a run wrote them.
const STAMPED: [&str; 4] = ["log", "pdf", "blg", "aux"];
/// latexmk's rules for glossaries, acronyms, bib2gls and nomencl, which it lacks and Overleaf
/// adds: they run TeX's own programs on the build folder's files, and a rule the user's or the
/// project's latexmkrc made for the same files wins. bib2gls may write beside the project, and
/// its log names the .bib files a rebuild watches.
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
    /// Set to end a build that runs inside the app.
    cancel: Arc<AtomicI32>,
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
    /// The PDF; latexmk names the run's other outputs as it, with their own extensions.
    pdf: PathBuf,
    before: HashMap<&'static str, Stamp>,
    request_started: Instant,
}

impl CompileRun {
    fn output(&self, ext: &str) -> PathBuf {
        self.pdf.with_extension(ext)
    }

    /// By stamp: a file's length and time to the nanosecond, whatever the volume's clock.
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
    pub fn kill_all(&self) {
        let running = lock(&self.running);
        self.shutdown.store(true, Ordering::Release);
        for entry in running.values() {
            entry.halt();
        }
    }

    pub fn stop(&self, root: &Path) -> bool {
        let mut running = lock(&self.running);
        let Some(entry) = running.get_mut(root) else {
            return false;
        };
        entry.stopped = true;
        entry.halt();
        if let Some(record) = entry.record.take() {
            let _ = std::fs::remove_file(record);
        }
        true
    }

    pub fn clean(build: &Path) -> Result<(), CoreError> {
        match std::fs::remove_dir_all(build) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    pub async fn compile(
        &self,
        project: &Project,
        path_env: &str,
        auto: bool,
    ) -> Result<CompileResult, CoreError> {
        let request_started = Instant::now();
        let root = &project.root;
        let settings = read_settings(&project.settings);
        let main_rel = safe_rel_file(&settings.main_file)?;
        if !root.join(&main_rel).exists() {
            return Err(CoreError::bad_request(format!(
                "Main file not found: {main_rel}"
            )));
        }
        let pdf = settings.output(&project.build, "pdf")?;
        let before = STAMPED.into_iter().filter_map(|ext| {
            let meta = std::fs::metadata(pdf.with_extension(ext)).ok()?;
            Some((ext, Stamp::of(&meta)))
        });
        let run = CompileRun {
            before: before.collect(),
            main_rel,
            pdf,
            request_started,
        };
        let command = process::command("latexmk", Some(root), path_env).map(|mut command| {
            // A project's own latexmkrc runs Perl on every build, so only a trusted project's
            // is read.
            if settings.shell_escape {
                command.arg("-shell-escape");
            } else {
                command.arg("-norc");
                // latexmk obeys an rc file where it comes in the arguments, so the user's goes
                // first and can't move the PDF out of the build folder or swap the engine.
                if let Some(rc) = user_latexmkrc(|key| std::env::var_os(key)) {
                    command.arg("-r").arg(rc);
                }
            }
            command.args([
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
            ]);
            command.arg("-e").arg(GLOSSARY_RULES);
            // No build folder is made here: one made before the stop check could ghost a
            // project renamed meanwhile. Absolute, as a project's may be outside it.
            for option in ["-outdir=", "-auxdir="] {
                let mut arg = OsString::from(option);
                arg.push(&project.build);
                command.arg(arg);
            }
            command.arg(format!("./{}", run.main_rel));
            command
        });
        let started = self.register(root, |entry| {
            entry.record = Some(run.output("fdb_latexmk"));
            command
                .and_then(|mut command| Tree::spawn(&mut command))
                .inspect(|(_, tree)| entry.tree = Some(tree.clone()))
        });
        let Some(spawned) = started else {
            return Ok(stopped_before_start(&run));
        };
        let (end, output) = match spawned {
            Err(err) => (End::Unstarted(err.to_string()), err.to_string()),
            Ok((mut child, tree)) => {
                let (code, mut output, stderr, timed_out) =
                    drive(&mut child, &tree, auto.then_some(COMPILE_TIMEOUT)).await;
                output.push_str(&stderr);
                let end = if timed_out {
                    End::TimedOut
                } else {
                    End::Exited(code)
                };
                (end, output)
            }
        };
        self.ended(root, run, end, "latexmk", output).await
    }

    /// The build's entry, made under the lock `kill_all` takes: None once quitting began, when
    /// a build would start an engine nothing ends.
    fn register<T>(&self, root: &Path, start: impl FnOnce(&mut Running) -> T) -> Option<T> {
        let mut running = lock(&self.running);
        if self.shutdown.load(Ordering::Acquire) {
            return None;
        }
        Some(start(running.entry(root.to_path_buf()).or_default()))
    }

    /// `tool` names what ran, for a failure nothing else explains.
    async fn ended(
        &self,
        root: &Path,
        run: CompileRun,
        end: End,
        tool: &'static str,
        output: String,
    ) -> Result<CompileResult, CoreError> {
        let entry = lock(&self.running).remove(root).unwrap_or_default();
        let end = if entry.stopped || self.shutdown.load(Ordering::Acquire) {
            End::Stopped
        } else {
            end
        };
        if let Some(record) = entry.record
            && (end != End::Exited(0) || !run.pdf.exists())
        {
            let _ = std::fs::remove_file(record);
        }
        tokio::task::spawn_blocking(move || finish(&run, &end, tool, output))
            .await
            .map_err(|err| CoreError::internal(err.to_string()))
    }
}

impl Running {
    fn halt(&self) {
        self.cancel.store(1, Ordering::Release);
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

fn finish(run: &CompileRun, end: &End, tool: &str, output: String) -> CompileResult {
    if matches!(end, End::Stopped | End::TimedOut) {
        run.discard_cut_short();
    }
    let ok = *end == End::Exited(0) && run.pdf.exists();
    // A no-op build keeps the PDF and its log; an old log after a new PDF is the last build's.
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
        End::TimedOut => errors.push(LogItem::error(format!(
            "This automatic build was stopped after {} minutes without finishing. Compile to build without a time limit; the Build Log shows how far it got.",
            COMPILE_TIMEOUT.as_secs() / 60
        ))),
        End::Unstarted(err) => {
            errors = vec![LogItem::error(format!("Couldn't start {tool}: {err}"))];
        }
        // A failure always names a cause: latexmk's summary of the failed step, else the exit.
        &End::Exited(code) if !ok && errors.is_empty() => {
            errors = latexmk_errors(&output);
            if errors.is_empty() {
                errors.push(LogItem::error(match code {
                    0 => "The build made no PDF. See the Build Log.".to_string(),
                    code => format!("{tool} stopped with exit code {code}. See the Build Log."),
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

/// From a line's start when it cuts: a cut line would parse as garbage.
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

#[cfg(test)]
pub(crate) mod stubs;

#[cfg(test)]
mod tests {
    use super::{LOG_TAIL, joined_log, read_tail, user_latexmkrc};
    use crate::tail;
    use std::ffi::OsString;
    use std::path::Path;

    #[test]
    fn cleaning_removes_the_build_folder_and_a_missing_one_is_clean() {
        let dir = tempfile::tempdir().unwrap();
        let clean = || super::CompileManager::clean(&dir.path().join("build"));
        clean().unwrap();
        std::fs::create_dir_all(dir.path().join("build/sub")).unwrap();
        std::fs::write(dir.path().join("build/main.aux"), "x").unwrap();
        std::fs::write(dir.path().join("main.tex"), "x").unwrap();
        clean().unwrap();
        assert!(!dir.path().join("build").exists());
        assert!(dir.path().join("main.tex").exists());
    }

    #[test]
    fn a_long_log_is_read_from_its_last_whole_line_and_character() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("main.log");
        std::fs::write(&path, "first line\nsecond line\n./main.tex:3: Boom.\n").unwrap();
        let file = || std::fs::File::open(&path).unwrap();
        assert_eq!(
            read_tail(file(), 30).unwrap(),
            b"./main.tex:3: Boom.\n".to_vec()
        );
        assert_eq!(
            read_tail(file(), 1000).unwrap(),
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
    }

    /// TeX Live on the PATH: `cargo test -p texlocal-core thesis -- --ignored`.
    #[tokio::test]
    #[ignore = "needs TeX Live"]
    async fn a_thesis_builds_its_glossary_acronyms_nomenclature_and_index() {
        let (_dir, service) = crate::projects::testing::library();
        crate::projects::create_project(&service.data_dir, "My Thesis", "blank", None).unwrap();
        let project = service.project("My Thesis").unwrap();
        let root = &project.root;
        std::fs::write(
            root.join("main.tex"),
            r"\documentclass{report}
\usepackage[acronym]{glossaries}
\usepackage{nomencl,makeidx}
\makeglossaries\makenomenclature\makeindex
\newglossaryentry{tex}{name={TeX},description={a typesetting system}}
\newacronym{pdf}{PDF}{Portable Document Format}
\begin{document}
\gls{tex} makes a \gls{pdf}. Zebra\index{Zebra}\nomenclature{$c$}{Speed of light}
\printglossaries\printnomenclature\printindex
\end{document}
",
        )
        .unwrap();
        let path = std::env::var("PATH").unwrap();
        let result = service
            .compile
            .compile(&project, &path, false)
            .await
            .unwrap();
        assert!(result.ok, "{}", result.log);
        for (ext, entry) in [
            ("gls", r"\glossentry{tex}"),
            ("acr", r"\glossentry{pdf}"),
            ("nls", "Speed of light"),
            ("ind", "Zebra"),
        ] {
            let list = std::fs::read_to_string(project.build.join("main").with_extension(ext));
            assert!(list.unwrap().contains(entry), "{ext}");
        }
    }

    /// TeX Live's `openout_any = p` lets TeX write to `-outdir`, bibtex finds the folder's .bib
    /// from it, and SyncTeX maps the folder's files both ways: `cargo test -p texlocal-core
    /// opened_folder -- --ignored`.
    #[tokio::test]
    #[ignore = "needs TeX Live"]
    async fn an_opened_folder_builds_beside_the_library_and_syncs_with_its_files() {
        use crate::synctex::{synctex_forward_at, synctex_inverse};
        let (dir, service) = crate::projects::testing::library();
        let folder = dir.path().join("My Paper");
        std::fs::create_dir_all(folder.join("ch")).unwrap();
        let main = r"\documentclass{article}
\begin{document}
See \cite{knuth}.

\input{ch/intro}
\bibliographystyle{plain}
\bibliography{refs}
\end{document}
";
        let bib = "@book{knuth, author={Donald Knuth}, title={The TeXbook}, year={1984}}";
        for (file, text) in [
            ("main.tex", main),
            ("ch/intro.tex", "An introduction.\n"),
            ("refs.bib", bib),
        ] {
            std::fs::write(folder.join(file), text).unwrap();
        }
        let opened = crate::projects::open_path(&service, &folder).unwrap();
        let project = service.project(&opened.project.id).unwrap();
        let path = std::env::var("PATH").unwrap();
        let result = service
            .compile
            .compile(&project, &path, false)
            .await
            .unwrap();
        assert!(result.ok, "{}", result.log);
        let bbl = std::fs::read_to_string(project.build.join("main.bbl")).unwrap();
        assert!(bbl.contains("The TeXbook"), "{bbl}");
        let names = crate::projects::testing::names_in(&folder);
        assert_eq!(names, ["ch", "main.tex", "refs.bib"]);

        let shown = synctex_forward_at(&project, "ch/intro.tex", 1, None).unwrap();
        let (x, y) = (shown.h.unwrap() + 5.0, shown.v.unwrap() - 2.0);
        let clicked = synctex_inverse(&project, shown.page, x, y, None, None, &|_| None);
        assert_eq!(clicked.unwrap().file, "ch/intro.tex");
    }
}
