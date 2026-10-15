//! Real spawn/kill/timeout coverage using a stub `latexmk` on PATH. Unix-only:
//! the stubs are shell scripts, and CI runs this on Linux and macOS.
#![cfg(unix)]

use std::fs;
use std::future::Future;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};
use tempfile::TempDir;
use texlocal_core::compile::{CompileManager, CompileResult, tex_available};
use texlocal_core::error::CoreError;
use texlocal_core::paths::project_root;
use texlocal_core::projects::create_project;
use texlocal_core::service::Service;
use texlocal_core::settings::write_settings;
use texlocal_core::synctex::{InverseLoc, synctex_inverse};
use tokio::task::JoinHandle;

fn executable(path: &Path, script: &str) {
    fs::write(path, script).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn stub_env(bin: &Path, script: &str) -> String {
    fs::create_dir_all(bin).unwrap();
    executable(&bin.join("latexmk"), script);
    format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

fn project(data: &Path) -> PathBuf {
    create_project(data, "proj", "blank").unwrap();
    let root = project_root(data, "proj").unwrap();
    write_settings(&root, &json!({ "mainFile": "main.tex" })).unwrap();
    root
}

/// A project, and a manager whose PATH finds a stub latexmk running `script`.
fn setup(script: &str) -> (TempDir, PathBuf, CompileManager) {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    let mut mgr = CompileManager::default();
    mgr.path_env = Some(stub_env(&tmp.path().join("bin"), script));
    (tmp, root, mgr)
}

async fn compile(mgr: &CompileManager, root: &Path) -> CompileResult {
    mgr.compile(root, None).await.unwrap()
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
    let mut service = Service::new(tmp.path().to_path_buf());
    service.compile.path_env = Some(stub_env(&tmp.path().join("bin"), script));
    for id in ids {
        create_project(tmp.path(), id, "blank").unwrap();
    }
    (tmp, Arc::new(service))
}

/// A project's build, asked for as a client asks and left running.
fn build(service: &Arc<Service>, id: &'static str) -> JoinHandle<Result<Value, CoreError>> {
    let service = Arc::clone(service);
    tokio::spawn(async move { service.call("compile", &json!({ "id": id })).await })
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

#[tokio::test]
async fn compile_happy_path_parses_the_log_it_wrote() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nmkdir -p build\nprintf './main.tex:3: Undefined control sequence.\\nl.3 x\\n' > build/main.log\nprintf 'fake' > build/main.pdf\nexit 0\n",
    );
    let result = compile(&mgr, &root).await;

    assert!(result.ok);
    assert_eq!(result.pdf.as_deref(), Some("build/main.pdf"));
    assert!(result.pdf_changed);
    assert_eq!(result.errors.len(), 1);
    assert_eq!(result.errors[0].file.as_deref(), Some("main.tex"));
    assert_eq!(result.errors[0].line, Some(3));
}

#[tokio::test]
async fn an_unchanged_compile_leaves_latexmk_free_to_skip_the_engine() {
    let (_tmp, root, mgr) = setup(RECORD_ARGS);
    compile(&mgr, &root).await;

    let passed = args(&root);
    assert!(!passed.contains(&"-g".into()), "{passed:?}");
}

#[tokio::test]
async fn an_incremental_no_op_keeps_the_existing_warnings() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nmkdir -p build\nif [ ! -f build/main.pdf ]; then\n  printf 'LaTeX Warning: Reference missing on input line 3.\\n' > build/main.log\n  printf 'fake' > build/main.pdf\nfi\nexit 0\n",
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

#[tokio::test]
async fn a_failed_run_forgets_latexmks_record_so_the_next_starts_afresh() {
    let (_tmp, root, mgr) =
        setup("#!/bin/sh\nmkdir -p build\nprintf 'record' > build/main.fdb_latexmk\nexit 12\n");
    let result = compile(&mgr, &root).await;
    assert!(!result.ok);
    assert!(!root.join("build/main.fdb_latexmk").exists());
}

#[tokio::test]
async fn a_cancelled_run_forgets_latexmks_record_before_the_next_can_start() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh
mkdir -p build
printf 'record' > build/main.fdb_latexmk
sleep 20
",
    );
    let record = root.join("build/main.fdb_latexmk");
    let task = in_flight(&Arc::new(mgr), &root);
    appears(&record, "latexmk did not write its record").await;
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    assert!(!record.exists());
}

#[tokio::test]
async fn a_build_stopped_by_a_rename_forgets_latexmks_record() {
    let (tmp, service) = stub_service(
        "#!/bin/sh\nmkdir -p build\nprintf 'record' > build/main.fdb_latexmk\nsleep 20\n",
        &["one"],
    );
    let build = build(&service, "one");
    let record = tmp.path().join("one/build/main.fdb_latexmk");
    appears(&record, "latexmk did not write its record").await;

    // The folder moves before the build can remove the record itself.
    service
        .call("rename_project", &json!({ "id": "one", "name": "uno" }))
        .await
        .unwrap();
    let result = build.await.unwrap().unwrap();
    assert_eq!(result["stopped"], true);
    assert!(!tmp.path().join("uno/build/main.fdb_latexmk").exists());
}

#[tokio::test]
async fn a_good_run_keeps_latexmks_record() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nmkdir -p build\nprintf 'record' > build/main.fdb_latexmk\nprintf 'fake' > build/main.pdf\nexit 0\n",
    );
    assert!(compile(&mgr, &root).await.ok);
    assert!(root.join("build/main.fdb_latexmk").exists());
}

#[tokio::test]
async fn a_stale_log_is_not_reported() {
    let (_tmp, root, mgr) =
        setup("#!/bin/sh\nmkdir -p build\nprintf 'fake' > build/main.pdf\nexit 0\n");
    fs::create_dir_all(root.join("build")).unwrap();
    let log = root.join("build/main.log");
    fs::write(&log, "./main.tex:9: Stale error.\n").unwrap();
    let two_minutes_ago = SystemTime::now() - Duration::from_secs(120);
    fs::File::options()
        .append(true)
        .open(&log)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(two_minutes_ago))
        .unwrap();

    let result = compile(&mgr, &root).await;

    assert!(result.ok);
    assert!(
        result.errors.is_empty(),
        "stale log leaked: {:?}",
        result.errors
    );
}

#[tokio::test]
async fn a_failed_run_does_not_advertise_a_preexisting_pdf() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nmkdir -p build\nprintf './main.tex:4: Current failure.\\n' > build/main.log\nexit 1\n",
    );
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "old successful output").unwrap();

    let result = compile(&mgr, &root).await;

    assert!(!result.ok);
    assert_eq!(result.pdf, None, "old PDF must not be labelled as this run");
    assert!(!result.pdf_changed);
    assert!(
        root.join("build/main.pdf").exists(),
        "old preview may remain on disk"
    );
}

#[tokio::test]
async fn a_timed_out_compile_keeps_the_output_it_wrote() {
    let (_tmp, root, mgr) = setup("#!/bin/sh\necho 'Running pdflatex'\ntouch printed\nsleep 20\n");
    // Once the stub has printed, tokio's clock goes straight to the build's
    // time limit, however long the stub took to print.
    let (result, ()) = tokio::join!(compile(&mgr, &root), async {
        appears(&root.join("printed"), "latexmk did not print").await;
        tokio::time::pause();
    });

    assert!(!result.ok);
    assert!(result.log.contains("Running pdflatex"), "{:?}", result.log);
}

#[tokio::test]
async fn a_timed_out_compile_is_killed_and_reported_failed() {
    let (_tmp, root, mut mgr) = setup("#!/bin/sh\nsleep 20\n");
    mgr.timeout = Some(Duration::from_millis(300));
    let started = Instant::now();
    let result = compile(&mgr, &root).await;

    assert!(!result.ok);
    assert!(!result.stopped, "a timeout is a failure, not a Stop");
    assert_eq!(result.pdf, None);
    assert_eq!(result.errors.len(), 1);
    assert!(
        result.errors[0].message.contains("stopped after"),
        "{:?}",
        result.errors
    );
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "kill did not take effect"
    );
}

#[tokio::test]
async fn a_descendant_holding_the_output_pipe_does_not_hold_the_compile() {
    // latexmk has exited, but something it started in the background (a
    // shell-escape `&`, a latexmkrc previewer) still holds stdout open. The
    // compile answers after a short drain grace, not at its timeout.
    let (_tmp, root, mgr) =
        setup("#!/bin/sh\nsleep 30 &\nmkdir -p build\nprintf 'fake' > build/main.pdf\nexit 0\n");
    let started = Instant::now();
    let result = compile(&mgr, &root).await;

    assert!(result.ok);
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "compile waited {:?} on a leftover process",
        started.elapsed()
    );
}

#[tokio::test]
async fn a_new_compile_supersedes_the_in_flight_one() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nif [ -f fast ]; then mkdir -p build; printf 'new' > build/main.pdf; exit 0; else touch started; sleep 20; fi\n",
    );
    let mgr = Arc::new(mgr);

    let first = in_flight(&mgr, &root);
    appears(&root.join("started"), "first latexmk did not start").await;
    fs::write(root.join("fast"), "").unwrap();

    let second = compile(&mgr, &root).await;
    let first = first.await.unwrap();

    assert!(second.ok, "superseding compile should succeed");
    assert!(!first.ok, "superseded compile should be killed");
    assert_eq!(first.pdf, None);
    assert_eq!(
        fs::read_to_string(root.join("build/main.pdf")).unwrap(),
        "new"
    );
}

#[tokio::test]
async fn a_third_compile_can_supersede_a_replacement_before_it_spawns() {
    let (_tmp, root, mgr) = setup(
        r#"#!/bin/sh
case "$*" in
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
    let mut second = Box::pin(mgr.compile(&root, None));
    // Poll just until it waits on the first build, then register the third
    // without letting the first release the build directory in between.
    waits(second.as_mut()).await;
    engine("lualatex");

    let (third, second, first) = tokio::time::timeout(Duration::from_secs(5), async {
        let (third, second, first) = tokio::join!(mgr.compile(&root, None), second, first,);
        (third.unwrap(), second.unwrap(), first.unwrap())
    })
    .await
    .expect("compile generations deadlocked");
    assert!(third.ok);
    assert!(!second.ok);
    assert!(!first.ok);
    assert!(!root.join("replacement_started").exists());
    assert_eq!(
        fs::read_to_string(root.join("build/main.pdf")).unwrap(),
        "third"
    );
}

#[tokio::test]
async fn a_cancelled_waiting_replacement_does_not_let_the_next_build_overtake_its_predecessor() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nif [ -f fast ]; then\n  if kill -0 \"$(cat first.pid)\" 2>/dev/null; then touch overlap; fi\n  mkdir -p build; printf 'new' > build/main.pdf\nelse\n  echo $$ > first.pid\n  sleep 20\nfi\n",
    );
    let mgr = Arc::new(mgr);
    let first = in_flight(&mgr, &root);
    appears(&root.join("first.pid"), "first latexmk did not start").await;

    let mut replacement = Box::pin(mgr.compile(&root, None));
    waits(replacement.as_mut()).await;
    drop(replacement);

    fs::write(root.join("fast"), "").unwrap();
    let third = tokio::time::timeout(Duration::from_secs(5), compile(&mgr, &root))
        .await
        .expect("third build waited forever");
    let first = first.await.unwrap();
    assert!(third.ok);
    assert!(first.stopped);
    assert!(
        !root.join("overlap").exists(),
        "third build overtook the first"
    );
}

#[tokio::test]
async fn a_cancelled_compile_takes_its_whole_tree_down() {
    // Dropping the compile future kills latexmk (kill_on_drop), but the
    // engine it started must not keep writing into the build directory.
    let (_tmp, root, mgr) = setup("#!/bin/sh\n(touch started; sleep 1; touch late) &\nsleep 20\n");
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

/// The arguments the stub latexmk was given.
const RECORD_ARGS: &str =
    "#!/bin/sh\nmkdir -p build\necho \"$@\" > build/args\nprintf 'fake' > build/main.pdf\nexit 0\n";

fn args(root: &Path) -> Vec<String> {
    let args = fs::read_to_string(root.join("build/args")).unwrap();
    args.split_whitespace().map(str::to_string).collect()
}

#[tokio::test]
async fn a_build_compiles_past_errors_unless_the_project_stops_on_the_first() {
    let (_tmp, root, mgr) = setup(RECORD_ARGS);
    compile(&mgr, &root).await;
    let passed = args(&root);
    assert!(passed.contains(&"-f".into()), "{passed:?}");
    assert!(!passed.contains(&"-halt-on-error".into()), "{passed:?}");

    write_settings(&root, &json!({ "stopOnFirstError": true })).unwrap();
    compile(&mgr, &root).await;
    let passed = args(&root);
    assert!(passed.contains(&"-halt-on-error".into()), "{passed:?}");
    assert!(!passed.contains(&"-f".into()), "{passed:?}");
}

#[tokio::test]
async fn a_projects_own_latexmkrc_runs_only_with_shell_escape() {
    // -norc turns off every rc file latexmk would read by itself, the
    // project's included; a trusted project keeps them.
    let (_tmp, root, mgr) = setup(RECORD_ARGS);
    compile(&mgr, &root).await;
    assert!(args(&root).contains(&"-norc".into()));

    write_settings(&root, &json!({ "shellEscape": true })).unwrap();
    compile(&mgr, &root).await;
    let passed = args(&root);
    assert!(!passed.contains(&"-norc".into()), "{passed:?}");
    assert!(passed.contains(&"-shell-escape".into()), "{passed:?}");
}

#[tokio::test]
async fn a_failed_run_shows_the_pdf_it_wrote_with_its_errors() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nmkdir -p build\nprintf './main.tex:4: Undefined control sequence.\\nl.4 x\\n' > build/main.log\nprintf 'fake' > build/main.pdf\nexit 12\n",
    );
    let result = compile(&mgr, &root).await;

    assert!(!result.ok);
    assert_eq!(result.pdf.as_deref(), Some("build/main.pdf"));
    assert!(result.pdf_changed);
    assert_eq!(result.errors.len(), 1);
    assert_eq!(result.errors[0].line, Some(4));
}

#[tokio::test]
async fn a_bibtex_error_is_reported_from_its_own_log() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nmkdir -p build\nprintf 'No errors here.\\n' > build/main.log\nprintf \"I was expecting a \\`,' or a \\`}'---line 1 of file refs.bib\\n\" > build/main.blg\nexit 12\n",
    );
    let result = compile(&mgr, &root).await;

    assert!(!result.ok);
    assert_eq!(result.errors.len(), 1, "{:?}", result.errors);
    assert_eq!(result.errors[0].file.as_deref(), Some("refs.bib"));
    assert_eq!(result.errors[0].line, Some(1));
}

#[tokio::test]
async fn a_failure_the_log_doesnt_explain_names_latexmks_summary() {
    let (_tmp, root, mgr) = setup(
        "#!/bin/sh\nmkdir -p build\nprintf 'No errors here.\\n' > build/main.log\nprintf 'Collected error summary (may duplicate other messages):\\n  biber build/main: Could not find build/main.bcf\\n'\nexit 12\n",
    );
    let result = compile(&mgr, &root).await;

    assert_eq!(result.errors.len(), 1, "{:?}", result.errors);
    assert_eq!(
        result.errors[0].message,
        "biber build/main: Could not find build/main.bcf"
    );
    // The Build Log keeps latexmk's own output after the engine's log.
    assert!(
        result.log.starts_with("No errors here."),
        "{:?}",
        result.log
    );
    assert!(
        result.log.contains("Collected error summary"),
        "{:?}",
        result.log
    );

    // With no summary either, the exit code.
    let (_tmp, root, mgr) = setup("#!/bin/sh\nexit 12\n");
    let result = compile(&mgr, &root).await;
    assert_eq!(result.errors.len(), 1);
    assert!(result.errors[0].message.contains("exit code 12"));
}

#[tokio::test]
async fn stopping_a_build_ends_that_projects_build_only_and_says_so() {
    let (tmp, service) = stub_service(
        "#!/bin/sh\nif [ -f fast ]; then mkdir -p build; printf 'new' > build/main.pdf; exit 0; else touch started; sleep 20; fi\n",
        &["one", "two"],
    );
    let (one, two) = (build(&service, "one"), build(&service, "two"));
    for id in ["one", "two"] {
        appears(
            &tmp.path().join(id).join("started"),
            "latexmk did not start",
        )
        .await;
    }

    let started = Instant::now();
    let stop = |id: &str| {
        let service = Arc::clone(&service);
        let args = json!({ "id": id });
        async move { service.call("stop_compile", &args).await }
    };
    assert_eq!(stop("one").await.unwrap(), true);
    let one = one.await.unwrap().unwrap();
    assert_eq!(one["stopped"], true);
    assert_eq!(one["ok"], false);
    assert!(started.elapsed() < Duration::from_secs(10));
    assert!(
        !two.is_finished(),
        "the other project's build was stopped too"
    );

    // The project builds again after a Stop.
    fs::write(project_root(tmp.path(), "one").unwrap().join("fast"), "").unwrap();
    let again = service
        .call("compile", &json!({ "id": "one" }))
        .await
        .unwrap();
    assert_eq!(
        (again["ok"].clone(), again["stopped"].clone()),
        (json!(true), json!(false))
    );

    assert_eq!(stop("one").await.unwrap(), false, "nothing is running");

    // Quitting stops the rest, and they say so too.
    service.compile.kill_all();
    assert_eq!(two.await.unwrap().unwrap()["stopped"], true);
}

#[tokio::test]
async fn renaming_a_project_stops_its_build() {
    let (tmp, service) = stub_service("#!/bin/sh\ntouch started\nsleep 20\n", &["one"]);
    let build = build(&service, "one");
    appears(&tmp.path().join("one/started"), "latexmk did not start").await;

    // A rename refused leaves the build running.
    create_project(tmp.path(), "taken", "blank").unwrap();
    let refused = service
        .call("rename_project", &json!({ "id": "one", "name": "taken" }))
        .await;
    assert_eq!(refused.unwrap_err().status, 409);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!build.is_finished());

    let started = Instant::now();
    service
        .call("rename_project", &json!({ "id": "one", "name": "uno" }))
        .await
        .unwrap();
    let result = build.await.unwrap().unwrap();
    assert_eq!(result["stopped"], true);
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[tokio::test]
async fn tex_available_reports_the_stub_version() {
    let tmp = TempDir::new().unwrap();
    let path = stub_env(
        &tmp.path().join("bin"),
        "#!/bin/sh\nprintf 'Latexmk, John Collins, 1 January 2024. Version 4.83\\n'\nexit 0\n",
    );
    let status = tex_available(&path).await;
    assert!(status.available);
    assert!(status.version.unwrap().starts_with("Latexmk"));

    let none = tex_available("/nonexistent-dir-for-test").await;
    assert!(!none.available);
    assert_eq!(none.version, None);
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
    let path = stub_env(&bin, "#!/bin/sh\nexit 0\n");
    let synctex = bin.join("synctex");
    executable(
        &synctex,
        "#!/bin/sh\nprintf 'SyncTeX result begin\\nInput:%s/./chapter.tex\\nLine:7\\n' \"$(pwd -P)\"\n",
    );

    let loc = inverse(&root, None, &path).await.unwrap();
    assert_eq!(loc.file, "chapter.tex");
    assert_eq!((loc.line, loc.column), (7, None));

    // The clicked word, on the line TeX recorded or a nearby one: whole, not a
    // command's name, run together with its neighbours as PDF text may be,
    // with its ligatures spelt out; its clicked letter's column in UTF-16 units.
    let text = "\n\n\n\nÜnï words \\word, the\nword next\nfinal\n";
    fs::write(root.join("chapter.tex"), text).unwrap();
    for (word, offset, line, column) in [
        ("“word,”", 0, 6, Some(0)),
        ("theword", 0, 5, Some(17)),
        ("theword", 4, 6, Some(1)),
        ("wordnext", 5, 6, Some(6)),
        ("Ünï", 2, 5, Some(2)),
        ("ﬁnal", 1, 7, Some(2)),
        ("absent", 0, 7, None),
    ] {
        let loc = inverse(&root, Some((word, offset)), &path).await.unwrap();
        assert_eq!((loc.line, loc.column), (line, column), "{word}");
    }

    // A build made before the project was renamed or moved names its old folder.
    fs::write(
        &synctex,
        "#!/bin/sh\nprintf 'Input:/old/Paper/./chapter.tex\\nLine:7\\n'\n",
    )
    .unwrap();
    let loc = inverse(&root, None, &path).await.unwrap();
    assert_eq!((loc.file.as_str(), loc.line), ("chapter.tex", 7));
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
    let path = stub_env(&bin, "#!/bin/sh\nexit 0\n");
    let synctex = bin.join("synctex");
    executable(&synctex, "");
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
        fs::write(
            &synctex,
            format!("#!/bin/sh\nprintf 'Input:{input}\\nLine:1\\n'\n"),
        )
        .unwrap();
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

#[tokio::test]
async fn tools_start_by_posix_spawn_never_a_fork() {
    // A forked child of a multithreaded process (the Mac app) can crash
    // before its exec; std forks for a bare name when PATH is set.
    assert_eq!(unsafe { libc::pthread_atfork(None, Some(forked), None) }, 0);
    let before = FORKS.load(std::sync::atomic::Ordering::SeqCst);
    let (_tmp, root, mgr) =
        setup("#!/bin/sh\necho 'Latexmk, John Collins, Version 4.85'\nexit 0\n");
    assert!(
        tex_available(mgr.path_env.as_deref().unwrap())
            .await
            .available
    );
    compile(&mgr, &root).await;
    // Missing, it is reported without starting anything.
    assert!(!tex_available("/nonexistent-dir-for-test").await.available);
    let mut missing = CompileManager::default();
    missing.path_env = Some("/nonexistent-dir-for-test".into());
    let result = compile(&missing, &root).await;
    assert!(
        result.errors[0]
            .message
            .starts_with("Couldn't start latexmk")
    );
    assert_eq!(FORKS.load(std::sync::atomic::Ordering::SeqCst), before);
}
