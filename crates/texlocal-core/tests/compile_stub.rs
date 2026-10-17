//! Builds by a stand-in latexmk, a shell script: what the core makes of its
//! output and log, and how it starts, stops and replaces it; and inverse sync
//! by a stand-in synctex. Unix-only, as the stand-ins are; CI runs it on macOS.
#![cfg(unix)]

mod support;

use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};
use tempfile::TempDir;
use texlocal_core::compile::{CompileManager, CompileResult, tex_available};
use texlocal_core::projects::create_project;
use texlocal_core::service::Service;
use texlocal_core::settings::write_settings;
use tokio::task::JoinHandle;

/// A library of the projects `ids`, and a service whose builds find a
/// latexmk in the library's `bin` that runs `script` in the project's folder.
fn library(script: &str, ids: &[&str]) -> (TempDir, Arc<Service>) {
    let tmp = TempDir::new().unwrap();
    let bin = tmp.path().join("bin");
    fs::create_dir(&bin).unwrap();
    support::program(&bin, "latexmk", script);
    let mut service = Service::new(tmp.path().to_path_buf());
    let path = std::env::var("PATH").unwrap_or_default();
    service.compile.path_env = Some(format!("{}:{path}", bin.display()));
    for id in ids {
        create_project(tmp.path(), id, "blank").unwrap();
    }
    (tmp, Arc::new(service))
}

/// A library of one project, P, and P's folder.
fn setup(script: &str) -> (TempDir, Arc<Service>, PathBuf) {
    let (tmp, service) = library(script, &["P"]);
    let root = service.project_root("P").unwrap();
    (tmp, service, root)
}

async fn compile(compiles: &CompileManager, root: &Path) -> CompileResult {
    compiles.compile(root, None).await.unwrap()
}

/// A build of `root` left running while the test goes on.
fn in_flight(service: &Arc<Service>, root: &Path) -> JoinHandle<CompileResult> {
    let (service, root) = (Arc::clone(service), root.to_path_buf());
    tokio::spawn(async move { compile(&service.compile, &root).await })
}

/// Polls a build just until it waits on the one before it.
async fn waits(mut build: Pin<&mut impl Future>) {
    std::future::poll_fn(|cx| match build.as_mut().poll(cx) {
        std::task::Poll::Pending => std::task::Poll::Ready(()),
        std::task::Poll::Ready(_) => panic!("the build did not wait for the one before"),
    })
    .await;
}

/// Waits up to five seconds for a stub to make `path`.
async fn appears(path: &Path) {
    let made = async {
        while !path.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    let made = tokio::time::timeout(Duration::from_secs(5), made).await;
    made.unwrap_or_else(|_| panic!("the stub made no {}", path.display()));
}

/// Ten seconds is long past any kill, and well short of a stub's sleep.
#[track_caller]
fn promptly(started: Instant) {
    let took = started.elapsed();
    assert!(took < Duration::from_secs(10), "took {took:?}");
}

/// A build as "ok" or "failed", "pdf" if it shows the PDF it wrote, and each
/// error as "file:line: message".
fn outcome(result: &CompileResult) -> String {
    let mut shown = vec![if result.ok { "ok" } else { "failed" }.to_owned()];
    shown.extend(result.pdf.as_ref().map(|_| "pdf".to_owned()));
    for error in &result.errors {
        let file = error.file.as_deref().unwrap_or_default();
        let line = error.line.map(|line| line.to_string()).unwrap_or_default();
        shown.push(format!("{file}:{line}: {}", error.message));
    }
    shown.join("; ")
}

/// A script's parts, which a case names in braces.
const PARTS: [(&str, &str); 5] = [
    (
        "{LOG}",
        "printf './main.tex:3: Undefined control sequence.\\nl.3 x\\n' > build/main.log\n",
    ),
    ("{QUIET}", "printf 'No errors here.\\n' > build/main.log\n"),
    ("{PDF}", "printf 'fake' > build/main.pdf\n"),
    (
        "{SUMMARY}",
        "printf 'Collected error summary (may duplicate other messages):\\n  biber build/main: Could not find build/main.bcf\\n'\n",
    ),
    (
        "{BIBTEX}",
        "printf \"I was expecting a \\`,' or a \\`}'---line 1 of file refs.bib\\n\" > build/main.blg\n",
    ),
];
const PDF: &str = "mkdir -p build\nprintf 'fake' > build/main.pdf\n";

/// What a build shows, as `outcome` gives it, after a latexmk running the
/// script; a file "old" there is from a run two minutes before.
#[tokio::test]
async fn a_build_shows_the_pdf_and_the_errors_of_its_own_run() {
    for case in [
        "ok; pdf; main.tex:3: Undefined control sequence. | {LOG}{PDF}exit 0",
        // Compiling past errors, a failed build shows its PDF too.
        "failed; pdf; main.tex:3: Undefined control sequence. | {LOG}{PDF}exit 12",
        "ok; pdf | old main.log | {PDF}exit 0",
        "failed; main.tex:3: Undefined control sequence. | old main.pdf | {LOG}exit 1",
        "failed; refs.bib:1: I was expecting a `,' or a `}' | {QUIET}{BIBTEX}exit 12",
        // latexmk's summary, for what the log doesn't explain; or its exit code.
        "failed; :: biber build/main: Could not find build/main.bcf | {QUIET}{SUMMARY}exit 12",
        "failed; :: latexmk stopped with exit code 12. See the Build Log. | exit 12",
        // latexmk has exited, but what it started in the background (a
        // shell-escape `&`, a latexmkrc previewer) holds its output open: the
        // build answers after a short grace, not at its time limit.
        "ok; pdf | sleep 30 &\n{PDF}exit 0",
    ] {
        let parts: Vec<_> = case.split(" | ").collect();
        let script = PARTS
            .iter()
            .fold(parts[parts.len() - 1].to_owned(), |script, (name, part)| {
                script.replace(name, part)
            });
        let (_tmp, service, root) = setup(&format!("mkdir -p build\n{script}"));
        if let [_, old, _] = parts[..] {
            let path = root.join("build").join(old.strip_prefix("old ").unwrap());
            fs::create_dir(root.join("build")).unwrap();
            fs::write(&path, "./main.tex:9: Stale error.\n").unwrap();
            let file = fs::File::options().append(true).open(&path).unwrap();
            let before = SystemTime::now() - Duration::from_secs(120);
            file.set_modified(before).unwrap();
        }
        let started = Instant::now();
        let result = compile(&service.compile, &root).await;
        promptly(started);
        assert_eq!(outcome(&result), parts[0], "{script}");
        let pdf = root.join("build/main.pdf");
        assert_eq!(result.pdf.as_deref(), result.pdf.as_ref().and(pdf.to_str()));
        assert_eq!(result.pdf_changed, result.pdf.is_some(), "{script}");
        // The Build Log has the engine's log, then latexmk's own output.
        if script.contains("summary") {
            let log = &result.log;
            assert!(log.starts_with("No errors here.\n") && log.contains("Collected"));
        }
    }
}

#[tokio::test]
async fn a_build_with_nothing_to_do_keeps_the_warnings_it_found() {
    let warn = "printf 'LaTeX Warning: Reference missing on input line 3.\\n' > build/main.log";
    let (_tmp, service, root) = setup(&format!("[ -f build/main.pdf ] && exit 0\n{PDF}{warn}"));
    let first = compile(&service.compile, &root).await;
    let second = compile(&service.compile, &root).await;
    assert!(first.ok && second.ok);
    assert!(first.pdf_changed && !second.pdf_changed);
    assert_eq!(serde_json::to_value(&second).unwrap()["pdfChanged"], false);
    assert_eq!(second.warnings.len(), 1);
    assert_eq!(second.warnings, first.warnings);
}

/// latexmk's record (.fdb_latexmk) stays after a good run and goes with a
/// failed, cancelled or stopped one, so the next run starts afresh.
#[tokio::test]
async fn latexmks_record_is_kept_by_a_good_run_and_forgotten_by_any_other_end() {
    let record = "mkdir -p build\nprintf 'record' > build/main.fdb_latexmk\n";
    for (end, kept) in [(PDF, true), ("exit 12\n", false)] {
        let (_tmp, service, root) = setup(&format!("{record}{end}"));
        assert_eq!(compile(&service.compile, &root).await.ok, kept);
        assert_eq!(root.join("build/main.fdb_latexmk").exists(), kept);
    }
    // Cancelled, gone before the next can start.
    let (tmp, service, root) = setup(&format!("{record}sleep 20\n"));
    let task = in_flight(&service, &root);
    let record = root.join("build/main.fdb_latexmk");
    appears(&record).await;
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    assert!(!record.exists());
    // Stopped by a rename, which moves the folder before the build can
    // remove the record itself.
    let task = in_flight(&service, &root);
    appears(&record).await;
    let args = json!({ "id": "P", "name": "Q" });
    service.call("rename_project", &args).await.unwrap();
    assert!(task.await.unwrap().stopped);
    assert!(!tmp.path().join("Q/build/main.fdb_latexmk").exists());
}

#[tokio::test]
async fn a_build_past_its_time_limit_is_killed_and_fails_with_what_it_printed() {
    let (_tmp, service, root) = setup("echo 'Running pdflatex'\ntouch printed\nsleep 20\n");
    let started = Instant::now();
    // Once the stub has printed, tokio's clock goes straight to the build's
    // time limit, however long the stub took to print.
    let (result, ()) = tokio::join!(compile(&service.compile, &root), async {
        appears(&root.join("printed")).await;
        tokio::time::pause();
    });
    promptly(started);
    assert!(!result.stopped, "a timeout is a failure, not a Stop");
    assert!(outcome(&result).starts_with("failed; :: The build was stopped after"));
    assert!(result.log.contains("Running pdflatex"), "{:?}", result.log);
}

/// A build that runs on until the project has a file named fast, from when it
/// builds at once.
const SLOW_UNTIL_FAST: &str = "if [ -f fast ]; then mkdir -p build; printf 'new' > build/main.pdf; exit 0; else touch started; sleep 20; fi\n";

#[tokio::test]
async fn a_new_build_ends_the_one_running_and_a_third_the_waiting_one() {
    let (_tmp, service, root) = setup(SLOW_UNTIL_FAST);
    let first = in_flight(&service, &root);
    appears(&root.join("started")).await;
    fs::write(root.join("fast"), "").unwrap();
    let second = compile(&service.compile, &root).await;
    let first = first.await.unwrap();
    assert_eq!((first.ok, first.pdf, second.ok), (false, None, true));
    assert_eq!(
        fs::read_to_string(root.join("build/main.pdf")).unwrap(),
        "new"
    );

    // Each build reads the engine as it starts, which tells the three apart.
    let script = "case \"$*\" in\n  *-lualatex*) mkdir -p build; printf 'third' > build/main.pdf ;;\n  \
        *-xelatex*) touch replacement_started; sleep 20 ;;\n  *) touch started; sleep 20 ;;\nesac\n";
    let (_tmp, service, root) = setup(script);
    let engine = |engine: &str| write_settings(&root, &json!({ "engine": engine })).unwrap();
    let first = in_flight(&service, &root);
    appears(&root.join("started")).await;
    engine("xelatex");
    let mut second = Box::pin(service.compile.compile(&root, None));
    // Just until it waits on the first, so that the third is asked for before
    // the first lets the build folder go.
    waits(second.as_mut()).await;
    engine("lualatex");
    let all = async {
        let (third, second, first) =
            tokio::join!(service.compile.compile(&root, None), second, first);
        [third.unwrap().ok, second.unwrap().ok, first.unwrap().ok]
    };
    let ok = tokio::time::timeout(Duration::from_secs(5), all).await;
    assert_eq!(ok.expect("the builds deadlocked"), [true, false, false]);
    assert!(!root.join("replacement_started").exists());
    assert_eq!(
        fs::read_to_string(root.join("build/main.pdf")).unwrap(),
        "third"
    );
}

#[tokio::test]
async fn a_waiting_build_cancelled_lets_no_later_one_overtake_the_one_running() {
    let (_tmp, service, root) = setup(
        "if [ -f fast ]; then\n  kill -0 \"$(cat first.pid)\" 2>/dev/null && touch overlap\n  mkdir -p build; printf new > build/main.pdf; exit 0\nfi\necho $$ > first.pid\nsleep 20\n",
    );
    let first = in_flight(&service, &root);
    appears(&root.join("first.pid")).await;
    let mut replacement = Box::pin(service.compile.compile(&root, None));
    waits(replacement.as_mut()).await;
    drop(replacement);

    fs::write(root.join("fast"), "").unwrap();
    let third = tokio::time::timeout(Duration::from_secs(5), compile(&service.compile, &root));
    assert!(third.await.expect("the third build waited forever").ok);
    assert!(first.await.unwrap().stopped);
    assert!(
        !root.join("overlap").exists(),
        "the third overtook the first"
    );
}

/// Dropping the build kills latexmk, and the engine it started must not keep
/// writing into the build folder either.
#[tokio::test]
async fn a_cancelled_build_takes_its_whole_tree_down() {
    let (_tmp, service, root) = setup("(touch started; sleep 1; touch late) &\nsleep 20\n");
    let task = in_flight(&service, &root);
    appears(&root.join("started")).await;
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert!(
        !root.join("late").exists(),
        "a descendant outlived the cancel"
    );
}

/// An unchanged build leaves latexmk free to skip the engine (no -g); a build
/// compiles past errors unless the project stops on the first; and -norc turns
/// off every rc file latexmk would read by itself, the project's included,
/// which only a trusted project (shell escape) keeps.
#[tokio::test]
async fn latexmk_is_given_the_arguments_the_settings_call_for() {
    let (_tmp, service, root) = setup(&format!("{PDF}echo \"$@\" > build/args\n"));
    for (settings, given, not_given) in [
        (json!({}), "-f -norc", "-g -halt-on-error"),
        (json!({ "stopOnFirstError": true }), "-halt-on-error", "-f"),
        (json!({ "shellEscape": true }), "-shell-escape", "-norc"),
    ] {
        write_settings(&root, &settings).unwrap();
        compile(&service.compile, &root).await;
        let args = fs::read_to_string(root.join("build/args")).unwrap();
        let passed: Vec<_> = args.split_whitespace().collect();
        assert!(
            given.split(' ').all(|arg| passed.contains(&arg)),
            "{passed:?}"
        );
        assert!(
            !not_given.split(' ').any(|arg| passed.contains(&arg)),
            "{passed:?}"
        );
    }
}

#[tokio::test]
async fn stop_rename_and_quit_each_end_only_their_own_builds_and_say_so() {
    let ids = ["one", "two", "three"];
    let (tmp, service) = library(SLOW_UNTIL_FAST, &ids);
    let roots = ids.map(|id| service.project_root(id).unwrap());
    let [one, two, three] = roots.each_ref().map(|root| in_flight(&service, root));
    for root in &roots {
        appears(&root.join("started")).await;
    }
    let call = async |command: &str, args: Value| service.call(command, &args).await;

    let started = Instant::now();
    assert_eq!(
        call("stop_compile", json!({ "id": "one" })).await.unwrap(),
        true
    );
    let one = one.await.unwrap();
    assert!(one.stopped && !one.ok);
    promptly(started);
    assert!(
        !two.is_finished() && !three.is_finished(),
        "another's build stopped too"
    );
    // The project builds again after a Stop.
    fs::write(roots[0].join("fast"), "").unwrap();
    let again = in_flight(&service, &roots[0]).await.unwrap();
    assert!(again.ok && !again.stopped);
    let idle = call("stop_compile", json!({ "id": "one" })).await;
    assert_eq!(idle.unwrap(), false, "nothing is running");

    // A rename refused leaves the build running; one that goes ahead stops it.
    create_project(tmp.path(), "taken", "blank").unwrap();
    let refused = call("rename_project", json!({ "id": "two", "name": "taken" })).await;
    assert_eq!(refused.unwrap_err().status, 409);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!two.is_finished());
    let started = Instant::now();
    call("rename_project", json!({ "id": "two", "name": "uno" }))
        .await
        .unwrap();
    assert!(two.await.unwrap().stopped);
    promptly(started);
    assert!(!three.is_finished());
    // Quitting stops the rest, and they say so too.
    call("kill_all", json!({})).await.unwrap();
    assert!(three.await.unwrap().stopped);
}

/// Inverse sync by a synctex in the TeX folder chosen that answers `input`
/// for the spot clicked: the file, line and column found, or the status.
async fn inverse(service: &Service, input: &str, click: Option<(&str, usize)>) -> Value {
    let bin = service.tex_dir().unwrap();
    let answer = format!("printf 'SyncTeX result begin\\nInput:{input}\\nLine:7\\n'\n");
    support::program(&bin, "synctex", &answer);
    let mut args = json!({ "id": "P", "page": 1, "x": 10.0, "y": 20.0 });
    if let Some((text, at)) = click {
        (args["text"], args["at"]) = (json!(text), json!(at));
    }
    let found = service.call("synctex_inverse", &args).await;
    found.unwrap_or_else(|err| json!(err.status))
}

/// TeX names its inputs by the physical working directory, so a library
/// reached through a link comes back under its real path; a build from
/// before a rename or move names the old folder. Nothing outside the
/// project, or generated, or the settings, is a source.
#[tokio::test]
async fn inverse_sync_finds_a_source_of_the_project_by_any_name_tex_gives_it() {
    let tmp = TempDir::new().unwrap();
    let (real, linked) = (tmp.path().join("real"), tmp.path().join("linked"));
    fs::create_dir(&real).unwrap();
    std::os::unix::fs::symlink(&real, &linked).unwrap();
    create_project(&linked, "P", "blank").unwrap();
    let service = Service::new(linked.clone());
    let root = linked.join("P");
    let text = "\n\n\n\nÜnï words \\word, the\nword next\nfinal\n";
    for (file, text) in [("chapter.tex", text), ("build/main.pdf", "pdf")] {
        fs::create_dir_all(root.join(file).parent().unwrap()).unwrap();
        fs::write(root.join(file), text).unwrap();
    }
    let bin = tmp.path().join("bin");
    fs::create_dir(&bin).unwrap();
    support::program(&bin, "latexmk", "exit 0\n");
    service
        .call("set_tex_dir", &json!({ "dir": bin }))
        .await
        .unwrap();

    let physical = format!("{}/./chapter.tex", real.join("P").display());
    let found = json!({ "file": "chapter.tex", "line": 7 });
    assert_eq!(inverse(&service, &physical, None).await, found);
    assert_eq!(
        inverse(&service, "/old/Paper/./chapter.tex", None).await,
        found
    );
    // The letter clicked is looked for on the line TeX recorded or one near.
    let word = inverse(&service, "chapter.tex", Some(("theword", 4))).await;
    assert_eq!(
        word,
        json!({ "file": "chapter.tex", "line": 6, "column": 1 })
    );
    assert_eq!(
        inverse(&service, "chapter.tex", Some(("absent", 0))).await,
        found
    );

    fs::write(root.join("build/generated.tex"), "secret").unwrap();
    fs::create_dir_all(root.join("Build")).unwrap(); // build/ itself where the volume ignores case
    fs::write(root.join("Build/generated.tex"), "secret").unwrap();
    fs::write(tmp.path().join("outside.tex"), "secret").unwrap();
    std::os::unix::fs::symlink(tmp.path().join("outside.tex"), root.join("linked.tex")).unwrap();
    std::os::unix::fs::symlink(root.join("build"), root.join("generated")).unwrap();
    for input in [
        "linked.tex",
        "generated/generated.tex",
        ".texlocal.json",
        "build/generated.tex",
        "Build/generated.tex",
        "/old/Paper/./../outside.tex",
        "/old/Paper/./linked.tex",
        "/old/Paper/./generated/generated.tex",
        "/old/Paper/./Build/generated.tex",
        "../outside.tex",
    ] {
        let refused = inverse(&service, input, Some(("secret", 2))).await;
        assert_eq!(refused, json!(404), "{input}");
    }
}

static FORKS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

extern "C" fn forked() {
    FORKS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
}

/// latexmk's version is found by running it, and a missing one is reported
/// without starting anything. A forked child of a multithreaded process (the
/// Mac app) can crash before its exec; std forks for a bare name when PATH is set.
#[tokio::test]
async fn tools_report_their_version_and_start_by_posix_spawn_never_a_fork() {
    assert_eq!(unsafe { libc::pthread_atfork(None, Some(forked), None) }, 0);
    let forks = || FORKS.load(std::sync::atomic::Ordering::SeqCst);
    let before = forks();
    let (_tmp, service, root) = setup("echo 'Latexmk, John Collins, Version 4.85'\n");
    let status = tex_available(service.compile.path_env.as_deref().unwrap()).await;
    assert!(status.available && status.version.unwrap().starts_with("Latexmk"));
    compile(&service.compile, &root).await;

    let none = tex_available("/nonexistent-dir-for-test").await;
    assert!(!none.available && none.version.is_none());
    let mut missing = CompileManager::default();
    missing.path_env = Some("/nonexistent-dir-for-test".into());
    let failed = outcome(&compile(&missing, &root).await);
    assert!(
        failed.starts_with("failed; :: Couldn't start latexmk"),
        "{failed}"
    );
    assert_eq!(forks(), before);
}
