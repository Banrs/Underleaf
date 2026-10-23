//! A build where TeX runs inside the app (iPadOS), as latexmk would make it: TeX until its
//! .aux settles and its log asks for no rerun, BibTeX when the .aux names a bibliography and
//! makeindex when TeX wrote an index, each when its input changed, and for XeLaTeX xdvipdfmx
//! at the end. Glossaries, bib2gls and biber aren't there, so their warnings show in the log;
//! nor is shell escape, whatever the project says.

use std::ffi::OsString;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use regex::bytes::Regex;

use super::{
    COMPILE_TIMEOUT, CompileManager, CompileResult, CompileRun, End, LOG_READ_MAX, read_tail,
    stopped_before_start,
};
use crate::inprocess::{self, Engine};
use crate::paths::Project;
use crate::settings::{self, Settings};
use crate::{CoreError, lock};

/// latexmk's own limit on TeX's passes in a build.
const MAX_PASSES: usize = 5;
/// What LaTeX and its packages say when the next pass would come out differently.
static RERUN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"Rerun to get|Rerun LaTeX|Please rerun LaTeX|Label\(s\) may have changed").unwrap()
});
/// The .aux's lines BibTeX reads.
static BIBLIOGRAPHY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\\(?:citation|bibdata|bibstyle)\{.*$").unwrap());
/// What TeX says when an `\include`d file's .aux goes to a folder the build folder lacks.
static UNWRITABLE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"I can't write on file `([^']+\.aux)'").unwrap());

impl CompileManager {
    pub(super) async fn compile_in_process(
        &self,
        project: &Project,
        settings: &Settings,
        run: CompileRun,
    ) -> Result<CompileResult, CoreError> {
        let engine = inprocess::engine()?;
        let job = Job {
            root: project.root.clone(),
            pdf: run.pdf.clone(),
            main: format!("./{}", run.main_rel),
            tex: Tex::of(settings.engine)?,
            halt: settings.stop_on_first_error,
            formats: inprocess::formats()?,
        };
        let output = tempfile::tempfile()?;
        let written = output.try_clone()?;
        let Some(cancel) = self.register(&project.root, |entry| Arc::clone(&entry.cancel)) else {
            return Ok(stopped_before_start(&run));
        };
        let halt = Arc::clone(&cancel);
        let mut passes = tokio::task::spawn_blocking(move || job.run(engine, &written, &halt));
        let (ran, timed_out) = match tokio::time::timeout(COMPILE_TIMEOUT, &mut passes).await {
            Ok(ran) => (ran, false),
            Err(_) => {
                cancel.store(1, Ordering::Release);
                (passes.await, true)
            }
        };
        let (end, tool) = match ran {
            Ok(_) if timed_out => (End::TimedOut, "TeX"),
            Ok((code, tool)) => (End::Exited(code), tool),
            Err(err) => (End::Unstarted(err.to_string()), "TeX"),
        };
        let output = read_tail(output, LOG_READ_MAX).unwrap_or_default();
        let output = crate::lossy_string(output);
        self.ended(&project.root, run, end, tool, output).await
    }
}

/// The TeX engine a project's setting names, and the name it is called by, which picks its
/// format.
#[derive(Clone, Copy)]
struct Tex {
    engine: &'static str,
    name: &'static str,
}

impl Tex {
    fn of(engine: settings::Engine) -> Result<Self, CoreError> {
        match engine {
            settings::Engine::Pdflatex => Ok(Self {
                engine: "pdftex",
                name: "pdflatex",
            }),
            settings::Engine::Xelatex => Ok(Self {
                engine: "xetex",
                name: "xelatex",
            }),
            settings::Engine::Lualatex => Err(CoreError::bad_request(
                "LuaLaTeX isn’t available on iPad. Choose pdfLaTeX or XeLaTeX in the project’s settings.",
            )),
        }
    }

    /// XeTeX writes XDV, which xdvipdfmx makes the PDF.
    fn xdv(self) -> bool {
        self.engine == "xetex"
    }
}

struct Job {
    root: PathBuf,
    /// The PDF, in the build folder; the run's other outputs are named as it.
    pdf: PathBuf,
    /// As TeX is given it, from the project's folder.
    main: String,
    tex: Tex,
    halt: bool,
    /// Where each engine's format is made once.
    formats: PathBuf,
}

/// Made one at a time: two builds would write the same format.
static MAKING: Mutex<()> = Mutex::new(());

impl Job {
    fn output(&self, ext: &str) -> PathBuf {
        self.pdf.with_extension(ext)
    }

    /// The status that decides the build and the program that gave it.
    fn run(&self, engine: &Engine, output: &File, cancel: &AtomicI32) -> (i32, &'static str) {
        let run = |program: &str, args: &[OsString], cwd: &Path, env: &[String]| {
            if cancel.load(Ordering::Acquire) != 0 {
                return 130;
            }
            let line = args.join(" ".as_ref());
            let _ = writeln!(&mut { output }, "Running '{}'", line.to_string_lossy());
            engine.run(program, args, cwd, output, env, cancel)
        };
        let build = self.pdf.parent().unwrap_or(&self.root);
        let made = fs::create_dir_all(build).and_then(|()| self.format(&run, output));
        match made {
            Ok(0) => {}
            Ok(status) => return (status, self.tex.name),
            Err(error) => {
                let _ = writeln!(&mut { output }, "{error}");
                return (1, self.tex.name);
            }
        }
        let mut args: Vec<OsString> = [self.tex.name, "-interaction=batchmode", "-file-line-error"]
            .map(OsString::from)
            .into();
        args.push("-synctex=1".into());
        args.extend(self.halt.then(|| "-halt-on-error".into()));
        args.extend(self.tex.xdv().then(|| "-no-pdf".into()));
        let mut outdir = OsString::from("-output-directory=");
        outdir.push(build);
        args.extend([outdir, self.main.clone().into()]);
        let env = [
            format!("TEXFORMATS={}", self.formats.display()),
            // Unwrapped, the log keeps each message and path on one line.
            "max_print_line=10000".to_owned(),
        ];
        // Beside the default paths, so BibTeX and makeindex find the project's own files.
        let project = |var| format!("{var}={}:", self.root.display());
        let bib_env = [project("BIBINPUTS"), project("BSTINPUTS")];
        let stem: OsString = self.pdf.file_stem().unwrap_or_default().into();
        let (mut cited, mut indexed, mut failed) = (None, None, None);
        let mut tex = 0;
        for _ in 0..MAX_PASSES {
            let before = fs::read(self.output("aux")).ok();
            tex = run(self.tex.engine, &args, &self.root, &env);
            // TeX Live makes no folders: as latexmk does, an `\include`d file's is made in the
            // build folder and TeX runs again.
            while tex != 0
                && let Some(folder) = self.missing_folder(build)
                && fs::create_dir_all(&folder).is_ok()
            {
                tex = run(self.tex.engine, &args, &self.root, &env);
            }
            if tex != 0 && (self.halt || cancel.load(Ordering::Acquire) != 0) {
                return (tex, self.tex.name);
            }
            let aux = fs::read(self.output("aux")).ok();
            let log = File::open(self.output("log")).and_then(|log| read_tail(log, 64 * 1024));
            let mut again = aux != before || log.is_ok_and(|log| RERUN.is_match(&log));
            let bibliography = aux.as_deref().map(|aux| {
                let lines = BIBLIOGRAPHY.find_iter(aux).map(|line| line.as_bytes());
                lines.collect::<Vec<_>>().concat()
            });
            let bibliography =
                bibliography.filter(|lines| memchr::memmem::find(lines, b"\\bibdata{").is_some());
            if bibliography.is_some() && bibliography != cited {
                let bbl = fs::read(self.output("bbl")).ok();
                let bibtex = ["bibtex".into(), stem.clone()];
                let status = run("bibtex", &bibtex, build, &bib_env);
                // 1 is BibTeX's warnings.
                if status > 1 {
                    failed.get_or_insert((status, "bibtex"));
                }
                again |= fs::read(self.output("bbl")).ok() != bbl;
                cited = bibliography;
            }
            let idx = fs::read(self.output("idx")).ok();
            if idx.is_some() && idx != indexed {
                let ind = fs::read(self.output("ind")).ok();
                let mut file = stem.clone();
                file.push(".idx");
                let makeindex = ["makeindex".into(), file];
                let status = run("makeindex", &makeindex, build, &[project("INDEXSTYLE")]);
                if status != 0 {
                    failed.get_or_insert((status, "makeindex"));
                }
                again |= fs::read(self.output("ind")).ok() != ind;
                indexed = idx;
            }
            if !again {
                break;
            }
        }
        if self.tex.xdv() && self.output("xdv").is_file() {
            let [pdf, xdv] = [self.output("pdf"), self.output("xdv")].map(OsString::from);
            let xdvipdfmx = ["xdvipdfmx".into(), "-E".into(), "-o".into(), pdf, xdv];
            let status = run("xdvipdfmx", &xdvipdfmx, &self.root, &[]);
            if status != 0 {
                failed.get_or_insert((status, "xdvipdfmx"));
            }
        }
        if tex != 0 {
            return (tex, self.tex.name);
        }
        failed.unwrap_or((0, self.tex.name))
    }

    /// The folder in `build` TeX's log says an .aux couldn't be written to, if it is missing
    /// and inside `build`.
    fn missing_folder(&self, build: &Path) -> Option<PathBuf> {
        let log = File::open(self.output("log")).and_then(|log| read_tail(log, 64 * 1024));
        let log = log.ok()?;
        let name = UNWRITABLE.captures(&log)?.get(1)?.as_bytes();
        let folder = Path::new(std::str::from_utf8(name).ok()?).parent()?;
        let inside = folder
            .components()
            .all(|part| matches!(part, Component::Normal(_)));
        let folder = build.join(folder);
        (inside && !folder.exists()).then_some(folder)
    }

    /// The engine's format, made in a folder of its own and moved into place, so a run cut
    /// short leaves none half written.
    fn format(
        &self,
        run: &impl Fn(&str, &[OsString], &Path, &[String]) -> i32,
        output: &File,
    ) -> std::io::Result<i32> {
        let _one = lock(&MAKING);
        let name = self.tex.name;
        let format = self.formats.join(format!("{name}.fmt"));
        if format.is_file() {
            return Ok(0);
        }
        fs::create_dir_all(&self.formats)?;
        let making = tempfile::tempdir_in(&self.formats)?;
        let mut ini: Vec<OsString> = [name, "-ini", "-etex", "-interaction=batchmode"]
            .map(OsString::from)
            .into();
        ini.push(format!("-jobname={name}").into());
        // As fmtutil makes it: letters past ASCII written as they are, not as ^^ codes.
        ini.extend((name == "pdflatex").then(|| "-translate-file=cp227.tcx".into()));
        ini.push(format!("{name}.ini").into());
        let status = run(self.tex.engine, &ini, making.path(), &[]);
        if status == 0 {
            fs::rename(making.path().join(format!("{name}.fmt")), &format)?;
        } else if let Ok(log) = fs::read(making.path().join(format!("{name}.log"))) {
            (&mut { output }).write_all(&log)?;
        }
        Ok(status)
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::{CStr, c_char, c_int, c_void};
    use std::sync::Mutex;

    use super::*;

    /// What each run was: its name, and the options that tell the passes apart.
    static RAN: Mutex<Vec<String>> = Mutex::new(Vec::new());

    /// TeX's programs as files: TeX reads its directives from the main file, and writes what
    /// it would of them.
    extern "C" fn fake(
        _engine: *const c_char,
        argc: c_int,
        argv: *const *const c_char,
        cwd: *const c_char,
        _output: c_int,
        _env: *const *const c_char,
        cancel: *const c_int,
    ) -> c_int {
        let text = |ptr| {
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned()
        };
        let args: Vec<String> = (0..argc as usize)
            .map(|i| text(unsafe { *argv.add(i) }))
            .collect();
        let cwd = PathBuf::from(text(cwd));
        let shown = ["-ini", "-no-pdf", "-halt-on-error"];
        let flags = args.iter().filter(|arg| shown.contains(&arg.as_str()));
        let ran = std::iter::once(&args[0])
            .chain(flags)
            .cloned()
            .collect::<Vec<_>>();
        RAN.lock().unwrap().push(ran.join(" "));
        let value = |prefix: &str| args.iter().find_map(|arg| arg.strip_prefix(prefix));
        let write = |path: PathBuf, text: &str| fs::write(path, text).unwrap();
        match args[0].as_str() {
            _ if args.contains(&"-ini".into()) => {
                write(cwd.join(format!("{}.fmt", value("-jobname=").unwrap())), "");
            }
            "pdflatex" | "xelatex" => {
                let main = fs::read_to_string(cwd.join(args.last().unwrap())).unwrap();
                let out = PathBuf::from(value("-output-directory=").unwrap());
                if main.contains("stop") {
                    unsafe { *cancel.cast_mut() = 1 };
                    return 130;
                }
                if main.contains("include") && !out.join("ch").exists() {
                    let unwritable = "./main.tex:1: I can't write on file `ch/intro.aux'.\n";
                    write(out.join("main.log"), unwritable);
                    return 1;
                }
                let mut aux = String::from("\\relax\n");
                if main.contains("cite") {
                    aux += "\\citation{knuth}\n\\bibdata{refs}\n";
                    if out.join("main.bbl").exists() {
                        aux += "\\bibcite{knuth}{1}\n";
                    }
                }
                if main.contains("loop") {
                    let passes = fs::read_to_string(out.join("main.aux")).unwrap_or_default();
                    aux += &"%\n".repeat(passes.matches('%').count() + 1);
                }
                write(out.join("main.aux"), &aux);
                if main.contains("index") {
                    write(out.join("main.idx"), "\\indexentry{TeX}{1}\n");
                }
                let pdf = if args.contains(&"-no-pdf".into()) {
                    "xdv"
                } else {
                    "pdf"
                };
                write(out.join("main").with_extension(pdf), "");
                if main.contains("error") {
                    write(
                        out.join("main.log"),
                        "./main.tex:1: Undefined control sequence.\n",
                    );
                    return 1;
                }
                write(out.join("main.log"), "");
            }
            "bibtex" => write(cwd.join("main.bbl"), "\\begin{thebibliography}{1}"),
            "makeindex" => write(cwd.join("main.ind"), "\\begin{theindex}"),
            "xdvipdfmx" => write(PathBuf::from(&args[3]), ""),
            _ => return -1,
        }
        0
    }

    extern "C" fn no_live(
        _: c_int,
        _: *const *const c_char,
        _: *const c_char,
        _: *mut c_int,
        _: *mut c_int,
        _: *mut c_int,
    ) -> *mut c_void {
        std::ptr::null_mut()
    }

    extern "C" fn no_wait(_: *mut c_void) -> c_int {
        -1
    }

    const ENGINE: Engine = Engine {
        live_start: no_live,
        session_wait: no_wait,
        run: fake,
    };

    /// The first build makes the format, runs BibTeX and makeindex after the first pass and
    /// TeX until the .aux settles; the next runs them again only to find nothing changed. A
    /// .aux that never settles stops at the limit, XeLaTeX's XDV goes through xdvipdfmx once,
    /// Stop on First Error ends at the failed pass, a Stop ends the build at once, and a pass
    /// that can't write an `\include`d file's .aux runs again once its folder is made.
    #[test]
    fn a_build_runs_what_latexmk_would_until_the_aux_settles() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("project");
        fs::create_dir(&root).unwrap();
        let job = |main: &str, engine, halt| {
            fs::write(root.join("main.tex"), main).unwrap();
            Job {
                root: root.clone(),
                pdf: root.join("build/main.pdf"),
                main: "./main.tex".into(),
                tex: Tex::of(engine).unwrap(),
                halt,
                formats: dir.path().join("formats"),
            }
        };
        let (pdf, xe) = (settings::Engine::Pdflatex, settings::Engine::Xelatex);
        let output = tempfile::tempfile().unwrap();
        let cases: [(_, _, _, &[&str], _); 7] = [
            (
                "cite index",
                pdf,
                false,
                &[
                    "pdflatex -ini",
                    "pdflatex",
                    "bibtex",
                    "makeindex",
                    "pdflatex",
                    "pdflatex",
                ],
                (0, "pdflatex"),
            ),
            (
                "cite index",
                pdf,
                false,
                &["pdflatex", "bibtex", "makeindex"],
                (0, "pdflatex"),
            ),
            (
                "loop",
                xe,
                false,
                &[
                    "xelatex -ini",
                    "xelatex -no-pdf",
                    "xelatex -no-pdf",
                    "xelatex -no-pdf",
                    "xelatex -no-pdf",
                    "xelatex -no-pdf",
                    "xdvipdfmx",
                ],
                (0, "xelatex"),
            ),
            (
                "cite error",
                pdf,
                true,
                &["pdflatex -halt-on-error"],
                (1, "pdflatex"),
            ),
            (
                "cite error",
                pdf,
                false,
                &["pdflatex", "bibtex", "pdflatex", "pdflatex"],
                (1, "pdflatex"),
            ),
            ("stop", pdf, false, &["pdflatex"], (130, "pdflatex")),
            (
                "include",
                pdf,
                true,
                &["pdflatex -halt-on-error"; 3],
                (0, "pdflatex"),
            ),
        ];
        for (case, (main, engine, halt, ran, end)) in cases.into_iter().enumerate() {
            // The second builds the first's project again; the rest start afresh.
            if case != 1 {
                let _ = fs::remove_dir_all(root.join("build"));
            }
            let cancel = AtomicI32::new(0);
            assert_eq!(
                job(main, engine, halt).run(&ENGINE, &output, &cancel),
                end,
                "{main}"
            );
            assert_eq!(std::mem::take(&mut *RAN.lock().unwrap()), ran, "{main}");
        }
        assert!(Tex::of(settings::Engine::Lualatex).is_err());
    }
}
