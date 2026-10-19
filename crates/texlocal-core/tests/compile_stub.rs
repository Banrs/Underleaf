//! Real spawn/kill/timeout coverage using a stub `latexmk` on PATH. Unix-only:
//! the stubs are shell scripts, and CI runs this on macOS.
#![cfg(unix)]

use std::fs;
use std::future::Future;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::json;
use tempfile::TempDir;
use texlocal_core::compile::{CompileManager, CompileResult};
use texlocal_core::error::CoreError;
use texlocal_core::paths::project_root;
use texlocal_core::projects::create_project;
use texlocal_core::service::Service;
use texlocal_core::settings::write_settings;
use texlocal_core::synctex::{InverseLoc, synctex_inverse};
use texlocal_core::tex::tex_available;
use tokio::task::JoinHandle;

/// A shell script at `path` that runs `script`.
fn executable(path: &Path, script: &str) {
    fs::write(path, format!("#!/bin/sh\n{script}")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A PATH that finds the programs in `bin` first.
fn path_with(bin: &Path) -> String {
    let path = std::env::var("PATH").unwrap_or_default();
    format!("{}:{path}", bin.display())
}

/// A stub latexmk in `bin` that runs `script`, and the PATH that finds it.
fn stub_env(bin: &Path, script: &str) -> String {
    fs::create_dir_all(bin).unwrap();
    executable(&bin.join("latexmk"), script);
    path_with(bin)
}

fn project(data: &Path) -> PathBuf {
    create_project(data, "proj", "blank", None).unwrap();
    project_root(data, "proj").unwrap()
}

/// A project, its manager, and a stub latexmk running `script` in the `bin`
/// beside the project, which its builds find.
fn setup(script: &str) -> (TempDir, PathBuf, CompileManager) {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    stub_env(&tmp.path().join("bin"), script);
    (tmp, root, CompileManager::default())
}

/// A build of the project at `root`, finding the stubs beside it.
async fn compile(mgr: &CompileManager, root: &Path) -> CompileResult {
    let stubs = path_with(&root.parent().unwrap().join("bin"));
    mgr.compile(root, &stubs).await.unwrap()
}

/// A project's build by a stub latexmk running `script`.
async fn built(script: &str) -> CompileResult {
    let (_tmp, root, mgr) = setup(script);
    compile(&mgr, &root).await
}

/// A compile left running while the test goes on.
fn in_flight(mgr: &Arc<CompileManager>, root: &Path) -> JoinHandle<CompileResult> {
    let (mgr, root) = (Arc::clone(mgr), root.to_path_buf());
    tokio::spawn(async move { compile(&mgr, &root).await })
}

/// A library of the projects `ids`, and a service whose PATH finds a stub
/// latexmk running `script`.
fn stub_service(script: &str, ids: &[&str]) -> (TempDir, Arc<Service>) {
    let tmp = TempDir::new().unwrap();
    let service = Service::new(tmp.path().to_path_buf());
    stub_env(&tmp.path().join("bin"), script);
    for id in ids {
        create_project(tmp.path(), id, "blank", None).unwrap();
    }
    (tmp, Arc::new(service))
}

/// A project's build, asked for as a session asks and left running.
fn build(service: &Arc<Service>, id: &'static str) -> JoinHandle<CompileResult> {
    let service = Arc::clone(service);
    let root = service.project_root(id).unwrap();
    tokio::spawn(async move { compile(&service.compile, &root).await })
}

/// Polls a later build just until it waits on the build before it.
async fn waits(mut build: Pin<&mut impl Future>) {
    std::future::poll_fn(|cx| match build.as_mut().poll(cx) {
        std::task::Poll::Pending => std::task::Poll::Ready(()),
        std::task::Poll::Ready(_) => panic!("replacement did not wait for the first build"),
    })
    .await;
}

/// Waits up to five seconds for a stub to make `path`, or fails saying `what` it didn't do.
async fn appears(path: &Path, what: &str) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !path.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{what}"));
}

/// Ten seconds is long past any kill, and well short of a stub's sleep.
fn promptly(started: Instant) {
    let took = started.elapsed();
    assert!(took < Duration::from_secs(10), "took {took:?}");
}

/// A build shows the PDF it wrote and its log's errors, as a failed build
/// compiling past errors does too.
#[tokio::test]
async fn a_build_parses_the_log_it_wrote_and_shows_its_pdf_whether_or_not_it_failed() {
    for exit in [0, 12] {
        let (_tmp, root, mgr) = setup(&format!(
            "mkdir -p build\nprintf './main.tex:3: Undefined control sequence.\\nl.3 x\\n' > build/main.log\nprintf 'fake' > build/main.pdf\nexit {exit}\n"
        ));
        let result = compile(&mgr, &root).await;

        assert_eq!(result.ok, exit == 0);
        let pdf = root.join("build/main.pdf");
        assert_eq!(result.pdf.as_deref(), pdf.to_str(), "absolute");
        assert!(result.pdf_changed);
        assert_eq!(result.errors.len(), 1);
        let place = (result.errors[0].file.as_deref(), result.errors[0].line);
        assert_eq!(place, (Some("main.tex"), Some(3)));
    }
}

#[tokio::test]
async fn an_incremental_no_op_keeps_the_existing_warnings() {
    let (_tmp, root, mgr) = setup(
        "mkdir -p build\nif [ ! -f build/main.pdf ]; then\n  printf 'LaTeX Warning: Reference missing on input line 3.\\n' > build/main.log\n  printf 'fake' > build/main.pdf\nfi\nexit 0\n",
    );
    let first = compile(&mgr, &root).await;
    let second = compile(&mgr, &root).await;

    assert!(first.ok && second.ok);
    assert!(first.pdf_changed);
    assert!(!second.pdf_changed);
    assert_eq!(serde_json::to_value(&second).unwrap()["pdfChanged"], false);
    assert_eq!(second.warnings, first.warnings);
    assert_eq!(second.warnings.len(), 1);
}

/// latexmk's record (.fdb_latexmk) stays after a good run and goes with a
/// failed, cancelled or stopped one, so the next run starts afresh.
#[tokio::test]
async fn latexmks_record_is_kept_by_a_good_run_and_forgotten_by_any_other_end() {
    // A stub that writes the record, then ends as `end` says.
    let recording =
        |end: &str| format!("mkdir -p build\nprintf 'record' > build/main.fdb_latexmk\n{end}");
    let (_tmp, root, mgr) = setup(&recording("printf 'fake' > build/main.pdf\nexit 0\n"));
    assert!(compile(&mgr, &root).await.ok);
    assert!(root.join("build/main.fdb_latexmk").exists());

    let (_tmp, root, mgr) = setup(&recording("exit 12\n"));
    assert!(!compile(&mgr, &root).await.ok);
    assert!(!root.join("build/main.fdb_latexmk").exists());

    // Cancelled, before the next can start.
    let (_tmp, root, mgr) = setup(&recording("sleep 20\n"));
    let record = root.join("build/main.fdb_latexmk");
    let task = in_flight(&Arc::new(mgr), &root);
    appears(&record, "latexmk did not write its record").await;
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    assert!(!record.exists());

    // Stopped by a rename.
    let (tmp, service) = stub_service(&recording("sleep 20\n"), &["one"]);
    let build = build(&service, "one");
    let record = tmp.path().join("one/build/main.fdb_latexmk");
    appears(&record, "latexmk did not write its record").await;

    // The folder moves before the build can remove the record itself.
    service
        .call("rename_project", &json!({ "id": "one", "name": "uno" }))
        .await
        .unwrap();
    assert!(build.await.unwrap().stopped);
    assert!(!tmp.path().join("uno/build/main.fdb_latexmk").exists());
}

/// What a run didn't write is the last build's: a good run shows no old log's
/// errors, and a failed one doesn't advertise an old PDF, which stays.
#[tokio::test]
async fn outputs_a_run_did_not_write_are_not_reported_as_its_own() {
    let (_tmp, root, mgr) = setup("mkdir -p build\nprintf 'fake' > build/main.pdf\nexit 0\n");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.log"), "./main.tex:9: Stale error.\n").unwrap();
    let result = compile(&mgr, &root).await;
    assert!(result.ok && result.errors.is_empty(), "{result:?}");

    let (_tmp, root, mgr) = setup(
        "mkdir -p build\nprintf './main.tex:4: Current failure.\\n' > build/main.log\nexit 1\n",
    );
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "old successful output").unwrap();
    let result = compile(&mgr, &root).await;
    assert!(!result.ok && !result.pdf_changed);
    assert_eq!(result.pdf, None);
    assert!(root.join("build/main.pdf").exists());
}

#[tokio::test]
async fn a_timed_out_compile_is_killed_and_reported_failed_with_the_output_it_wrote() {
    let (_tmp, root, mgr) = setup("echo 'Running pdflatex'\ntouch printed\nsleep 20\n");
    let started = Instant::now();
    // Once the stub has printed, tokio's clock goes straight to the build's
    // time limit, however long the stub took to print.
    let (result, ()) = tokio::join!(compile(&mgr, &root), async {
        appears(&root.join("printed"), "latexmk did not print").await;
        tokio::time::pause();
    });

    assert!(!result.ok);
    assert!(!result.stopped, "a timeout is a failure, not a Stop");
    assert_eq!(result.pdf, None);
    assert!(result.log.contains("Running pdflatex"), "{:?}", result.log);
    assert_eq!(result.errors.len(), 1);
    let message = &result.errors[0].message;
    assert!(message.contains("stopped after"), "{result:?}");
    // It says the build ran long, not that the document is at fault.
    assert!(!message.contains("forever"), "{message}");
    promptly(started);
}

#[tokio::test]
async fn a_descendant_holding_the_output_pipe_does_not_hold_the_compile() {
    // latexmk has exited, but something it started in the background (a
    // shell-escape `&`, a latexmkrc previewer) still holds stdout open. The
    // compile answers after a short drain grace, not at its timeout.
    let started = Instant::now();
    assert!(
        built("sleep 30 &\nmkdir -p build\nprintf 'fake' > build/main.pdf\nexit 0\n")
            .await
            .ok
    );
    promptly(started);
}

/// A build that starts and runs on, until the project has a file named fast:
/// from then it builds at once.
const SLOW_UNTIL_FAST: &str = "if [ -f fast ]; then mkdir -p build; printf 'new' > build/main.pdf; exit 0; else touch started; sleep 20; fi\n";

#[tokio::test]
async fn a_new_compile_supersedes_the_in_flight_one_and_a_third_the_replacement_before_it_spawns() {
    {
        let (_tmp, root, mgr) = setup(SLOW_UNTIL_FAST);
        let mgr = Arc::new(mgr);

        let first = in_flight(&mgr, &root);
        appears(&root.join("started"), "first latexmk did not start").await;
        fs::write(root.join("fast"), "").unwrap();

        let second = compile(&mgr, &root).await;
        let first = first.await.unwrap();

        assert!(second.ok, "superseding compile should succeed");
        assert!(!first.ok, "superseded compile should be killed");
        assert_eq!(first.pdf, None);
        let pdf = fs::read_to_string(root.join("build/main.pdf")).unwrap();
        assert_eq!(pdf, "new");
    }
    {
        let (_tmp, root, mgr) = setup(
            r#"case "$*" in
  *-lualatex*) mkdir -p build; printf 'third' > build/main.pdf; exit 0 ;;
  *-xelatex*) touch replacement_started; sleep 20 ;;
  *) touch started; sleep 20 ;;
esac
"#,
        );
        let mgr = Arc::new(mgr);
        let first = in_flight(&mgr, &root);
        appears(&root.join("started"), "first latexmk did not start").await;
        // Each build reads the engine as it is asked for, which tells the three apart.
        let engine = |engine: &str| write_settings(&root, &json!({ "engine": engine })).unwrap();
        engine("xelatex");
        let mut second = Box::pin(compile(&mgr, &root));
        // Poll just until it waits on the first build, then register the third
        // without letting the first release the build directory in between.
        waits(second.as_mut()).await;
        engine("lualatex");

        let (third, second, first) = tokio::time::timeout(Duration::from_secs(5), async {
            let (third, second, first) = tokio::join!(compile(&mgr, &root), second, first);
            (third, second, first.unwrap())
        })
        .await
        .expect("compile generations deadlocked");
        assert!(third.ok);
        assert!(!second.ok);
        assert!(!first.ok);
        assert!(!root.join("replacement_started").exists());
        let pdf = fs::read_to_string(root.join("build/main.pdf")).unwrap();
        assert_eq!(pdf, "third");
    }
}

#[tokio::test]
async fn a_cancelled_waiting_replacement_does_not_let_the_next_build_overtake_its_predecessor() {
    let (_tmp, root, mgr) = setup(
        "if [ -f fast ]; then\n  if kill -0 \"$(cat first.pid)\" 2>/dev/null; then touch overlap; fi\n  mkdir -p build; printf 'new' > build/main.pdf\nelse\n  echo $$ > first.pid\n  sleep 20\nfi\n",
    );
    let mgr = Arc::new(mgr);
    let first = in_flight(&mgr, &root);
    appears(&root.join("first.pid"), "first latexmk did not start").await;

    let mut replacement = Box::pin(compile(&mgr, &root));
    waits(replacement.as_mut()).await;
    drop(replacement);

    fs::write(root.join("fast"), "").unwrap();
    let third = tokio::time::timeout(Duration::from_secs(5), compile(&mgr, &root))
        .await
        .expect("third build waited forever");
    let first = first.await.unwrap();
    assert!(third.ok);
    assert!(first.stopped);
    assert!(!root.join("overlap").exists(), "third overtook the first");
}

#[tokio::test]
async fn a_cancelled_compile_takes_its_whole_tree_down() {
    // Dropping the compile future kills latexmk (kill_on_drop), but the
    // engine it started must not keep writing into the build directory.
    let (_tmp, root, mgr) = setup("(touch started; sleep 1; touch late) &\nsleep 20\n");
    let task = in_flight(&Arc::new(mgr), &root);
    appears(&root.join("started"), "latexmk descendant did not start").await;
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());

    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert!(
        !root.join("late").exists(),
        "a descendant outlived the cancel"
    );
}

/// An unchanged compile leaves latexmk free to skip the engine (no -g); a build
/// compiles past errors unless the project stops on the first; and -norc turns
/// off every rc file latexmk would read by itself, the project's included,
/// which only a trusted project (shell escape) keeps.
#[tokio::test]
async fn latexmk_is_given_the_arguments_the_settings_call_for() {
    // The stub keeps the arguments it was given.
    let (_tmp, root, mgr) =
        setup("mkdir -p build\necho \"$@\" > build/args\nprintf 'fake' > build/main.pdf\nexit 0\n");
    let cases: [(_, &[&str], &[&str]); 3] = [
        (json!({}), &["-f", "-norc"], &["-g", "-halt-on-error"]),
        (
            json!({ "stopOnFirstError": true }),
            &["-halt-on-error"],
            &["-f"],
        ),
        (
            json!({ "shellEscape": true }),
            &["-shell-escape"],
            &["-norc"],
        ),
    ];
    for (settings, given, not_given) in cases {
        write_settings(&root, &settings).unwrap();
        compile(&mgr, &root).await;
        let args = fs::read_to_string(root.join("build/args")).unwrap();
        let passed: Vec<_> = args.split_whitespace().collect();
        assert!(given.iter().all(|arg| passed.contains(arg)), "{passed:?}");
        assert!(
            !not_given.iter().any(|arg| passed.contains(arg)),
            "{passed:?}"
        );
    }
}

/// A failure the engine's log doesn't explain names its cause: bibtex's own
/// log, else latexmk's summary of the step that failed, else the exit code.
#[tokio::test]
async fn a_failure_the_engines_log_doesnt_explain_names_its_cause() {
    let quiet = "mkdir -p build\nprintf 'No errors here.\\n' > build/main.log\n";
    let bibtex = "printf \"I was expecting a \\`,' or a \\`}'---line 1 of file refs.bib\\n\" > build/main.blg\nexit 12\n";
    let result = built(&[quiet, bibtex].concat()).await;
    assert!(!result.ok);
    let places: Vec<_> = (result.errors.iter())
        .map(|error| (error.file.as_deref(), error.line))
        .collect();
    assert_eq!(places, [(Some("refs.bib"), Some(1))]);

    let summary = "printf 'Collected error summary (may duplicate other messages):\\n  biber build/main: Could not find build/main.bcf\\n'\nexit 12\n";
    let result = built(&[quiet, summary].concat()).await;
    assert_eq!(result.errors.len(), 1, "{:?}", result.errors);
    assert_eq!(
        result.errors[0].message,
        "biber build/main: Could not find build/main.bcf"
    );
    // The Build Log keeps latexmk's own output after the engine's log.
    let log = &result.log;
    assert!(log.starts_with("No errors here."), "{log:?}");
    assert!(log.contains("Collected error summary"), "{log:?}");

    // With no summary either, the exit code.
    let result = built("exit 12\n").await;
    assert_eq!(result.errors.len(), 1);
    assert!(result.errors[0].message.contains("exit code 12"));
}

#[tokio::test]
async fn stop_rename_and_quit_each_end_only_their_own_builds_and_say_so() {
    let ids = ["one", "two", "three"];
    let (tmp, service) = stub_service(SLOW_UNTIL_FAST, &ids);
    let [one, two, three] = ids.map(|id| build(&service, id));
    for id in ids {
        let started = tmp.path().join(id).join("started");
        appears(&started, "latexmk did not start").await;
    }

    let started = Instant::now();
    let stop = |id: &str| {
        let service = Arc::clone(&service);
        let args = json!({ "id": id });
        async move { service.call("stop_compile", &args).await }
    };
    assert_eq!(stop("one").await.unwrap(), true);
    let one = one.await.unwrap();
    assert!(one.stopped && !one.ok);
    promptly(started);
    assert!(
        !two.is_finished() && !three.is_finished(),
        "another project's build was stopped too"
    );

    // The project builds again after a Stop.
    fs::write(project_root(tmp.path(), "one").unwrap().join("fast"), "").unwrap();
    let again = build(&service, "one").await.unwrap();
    assert!(again.ok && !again.stopped);

    assert_eq!(stop("one").await.unwrap(), false, "nothing is running");

    // A rename refused leaves the build running; one that goes ahead stops it.
    create_project(tmp.path(), "taken", "blank", None).unwrap();
    let refused = service
        .call("rename_project", &json!({ "id": "two", "name": "taken" }))
        .await;
    assert_eq!(refused.unwrap_err().status, 409);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!two.is_finished());

    let started = Instant::now();
    service
        .call("rename_project", &json!({ "id": "two", "name": "uno" }))
        .await
        .unwrap();
    assert!(two.await.unwrap().stopped);
    promptly(started);
    assert!(!three.is_finished());

    // Quitting stops the rest, and they say so too.
    service.compile.kill_all();
    assert!(three.await.unwrap().stopped);
}

#[tokio::test]
async fn quitting_stops_a_build_asked_for_after_it_and_one_waiting_to_start() {
    // Each run of the stub adds a line to `starts`.
    let script = "echo x >> starts\nsleep 20\n";
    let (_tmp, root, mgr) = setup(script);
    let mgr = Arc::new(mgr);
    let first = in_flight(&mgr, &root);
    appears(&root.join("starts"), "first latexmk did not start").await;
    let mut waiting = Box::pin(compile(&mgr, &root));
    waits(waiting.as_mut()).await;

    mgr.kill_all();

    let started = Instant::now();
    let (waiting, first) = tokio::join!(waiting, first);
    assert!(first.unwrap().stopped);
    assert!(waiting.stopped);
    // A build asked for once the app has begun to quit.
    let late = compile(&mgr, &root).await;
    assert!(late.stopped && !late.ok);
    assert_eq!(fs::read_to_string(root.join("starts")).unwrap(), "x\n");
    promptly(started);
}

#[tokio::test]
async fn a_stopped_build_removes_the_aux_and_pdf_it_cut_short_and_leaves_the_rest() {
    // The engine has begun both, and is killed with them half-written.
    let (_tmp, root, mgr) = setup(
        "mkdir -p build\nprintf 'half' > build/main.aux\nprintf '%%PDF-half' > build/main.pdf\ntouch printed\nsleep 20\n",
    );
    let mgr = Arc::new(mgr);
    let task = in_flight(&mgr, &root);
    appears(&root.join("printed"), "latexmk did not write").await;
    assert!(mgr.stop(&root));
    let result = task.await.unwrap();
    assert!(result.stopped);
    assert!(!root.join("build/main.aux").exists());
    assert!(!root.join("build/main.pdf").exists());

    // Killed before it wrote them, the last build's stay.
    let (_tmp, root, mgr) = setup("touch printed\nsleep 20\n");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.aux"), "whole").unwrap();
    fs::write(root.join("build/main.pdf"), "whole").unwrap();
    let mgr = Arc::new(mgr);
    let task = in_flight(&mgr, &root);
    appears(&root.join("printed"), "latexmk did not start").await;
    assert!(mgr.stop(&root));
    assert!(task.await.unwrap().stopped);
    assert_eq!(fs::read(root.join("build/main.aux")).unwrap(), b"whole");
    assert_eq!(fs::read(root.join("build/main.pdf")).unwrap(), b"whole");
}

/// An inverse sync from a spot the stub synctex answers for, with the clicked
/// page's text and the index clicked in it.
async fn inverse(
    root: &Path,
    click: Option<(&str, usize)>,
    path: &str,
) -> Result<InverseLoc, CoreError> {
    synctex_inverse(root, 1.0, 10.0, 20.0, click, None, path).await
}

#[tokio::test]
async fn inverse_sync_finds_the_source_through_a_linked_data_dir() {
    // TeX names inputs by the physical working directory, so a library
    // reached through a symlink comes back under its real path.
    let tmp = TempDir::new().unwrap();
    let real = tmp.path().join("real");
    fs::create_dir_all(&real).unwrap();
    let linked = tmp.path().join("linked");
    std::os::unix::fs::symlink(&real, &linked).unwrap();
    let root = project(&linked);
    fs::write(root.join("chapter.tex"), "text\n").unwrap();
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "fake").unwrap();

    let bin = tmp.path().join("bin");
    let path = stub_env(&bin, "exit 0\n");
    let synctex = bin.join("synctex");
    executable(
        &synctex,
        "printf 'SyncTeX result begin\\nInput:%s/./chapter.tex\\nLine:7\\n' \"$(pwd -P)\"\n",
    );

    let loc = inverse(&root, None, &path).await.unwrap();
    assert_eq!(loc.file, "chapter.tex");
    assert_eq!((loc.line, loc.column), (7, None));

    // The clicked letter is looked for in the source file, on the line TeX
    // recorded or a nearby one (synctex.rs tests the matching itself).
    let text = "\n\n\n\nÜnï words \\word, the\nword next\nfinal\n";
    fs::write(root.join("chapter.tex"), text).unwrap();
    for (word, offset, line, column) in [("theword", 4, 6, Some(1)), ("absent", 0, 7, None)] {
        let loc = inverse(&root, Some((word, offset)), &path).await.unwrap();
        assert_eq!((loc.line, loc.column), (line, column), "{word}");
    }

    // A build made before the project was renamed or moved names its old folder.
    executable(
        &synctex,
        "printf 'Input:/old/Paper/./chapter.tex\\nLine:7\\n'\n",
    );
    let loc = inverse(&root, None, &path).await.unwrap();
    assert_eq!((loc.file.as_str(), loc.line), ("chapter.tex", 7));
}

#[tokio::test]
async fn sync_without_a_synctex_program_says_it_is_not_available() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "fake").unwrap();
    let err = inverse(&root, None, "/nonexistent-dir-for-test")
        .await
        .unwrap_err();
    assert_eq!(err.status, 404);
    assert!(err.message.contains("not available"), "{err}");
}

#[tokio::test]
async fn inverse_sync_rejects_unsafe_sources_before_reading_words() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "fake").unwrap();
    fs::write(root.join("build/generated.tex"), "secret").unwrap();
    fs::create_dir_all(root.join("Build")).unwrap();
    fs::write(root.join("Build/generated.tex"), "secret").unwrap();
    let outside = tmp.path().join("outside.tex");
    fs::write(&outside, "secret").unwrap();
    std::os::unix::fs::symlink(&outside, root.join("linked.tex")).unwrap();
    std::os::unix::fs::symlink(root.join("build"), root.join("generated")).unwrap();
    let bin = tmp.path().join("bin");
    let path = stub_env(&bin, "exit 0\n");
    let mut accepted = Vec::new();
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
    ] {
        let answer = format!("printf 'Input:{input}\\nLine:1\\n'\n");
        executable(&bin.join("synctex"), &answer);
        if let Ok(loc) = inverse(&root, Some(("secret", 2)), &path).await {
            accepted.push((input, loc.file, loc.column));
        }
    }
    assert!(accepted.is_empty(), "unsafe sources accepted: {accepted:?}");
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
    let before = FORKS.load(std::sync::atomic::Ordering::SeqCst);
    let (tmp, root, mgr) = setup("echo 'Latexmk, John Collins, Version 4.85'\nexit 0\n");
    let status = tex_available(&path_with(&tmp.path().join("bin"))).await;
    assert!(status.available);
    assert!(status.version.unwrap().starts_with("Latexmk"));
    compile(&mgr, &root).await;

    let none = "/nonexistent-dir-for-test";
    let status = tex_available(none).await;
    assert!(!status.available);
    assert_eq!(status.version, None);
    let result = mgr.compile(&root, none).await.unwrap();
    let message = &result.errors[0].message;
    assert!(message.starts_with("Couldn't start latexmk"), "{message}");
    assert_eq!(FORKS.load(std::sync::atomic::Ordering::SeqCst), before);
}
