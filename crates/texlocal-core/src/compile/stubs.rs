//! Builds run for real by stub TeX tools on the PATH: shell scripts, so Unix
//! only, as CI runs these on macOS.

use std::cell::Cell;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::json;
use tempfile::TempDir;
use tokio::task::JoinHandle;

use super::CompileResult;
use crate::logparse::SHELL_ESCAPE;
use crate::paths::Project;
use crate::projects::testing::{names_in, with_project};
use crate::projects::{create_project, open_path};
use crate::service::Service;
use crate::settings::write_settings;
use crate::synctex::synctex_inverse;
use crate::tex::tex_available;

pub(crate) fn stub(dir: &Path, name: &str, script: &str) {
    let path = dir.join("bin").join(name);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, format!("#!/bin/sh\n{script}")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn setup(script: &str) -> (TempDir, Arc<Service>, PathBuf) {
    let (dir, service) = with_project();
    stub(dir.path(), "latexmk", script);
    let root = service.project("P").unwrap().root;
    (dir, Arc::new(service), root)
}

fn stubs(service: &Service) -> String {
    let bin = service.data_dir.with_file_name("bin");
    format!("{}:{}", bin.display(), std::env::var("PATH").unwrap())
}

async fn compile(service: &Service, root: &Path) -> CompileResult {
    let path = stubs(service);
    let project = Project::in_folder(root);
    service
        .compile
        .compile(&project, &path, false)
        .await
        .unwrap()
}

async fn built(script: &str) -> CompileResult {
    let (_dir, service, root) = setup(script);
    compile(&service, &root).await
}

fn in_flight(service: &Arc<Service>, root: &Path) -> JoinHandle<CompileResult> {
    let (service, root) = (Arc::clone(service), root.to_path_buf());
    tokio::spawn(async move { compile(&service, &root).await })
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

#[tokio::test]
async fn a_build_parses_the_log_it_wrote_and_shows_its_pdf_whether_or_not_it_failed() {
    for exit in [0, 12] {
        let (_dir, service, root) = setup(&format!(
            "mkdir -p build\nprintf './main.tex:3: Undefined control sequence.\\nl.3 x\\n' > build/main.log\nprintf 'fake' > build/main.pdf\nexit {exit}\n"
        ));
        let result = compile(&service, &root).await;

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
    let (_dir, service, root) = setup(
        "mkdir -p build\nif [ ! -f build/main.pdf ]; then\n  printf 'LaTeX Warning: Reference missing on input line 3.\\n' > build/main.log\n  printf 'fake' > build/main.pdf\nfi\nexit 0\n",
    );
    let first = compile(&service, &root).await;
    let second = compile(&service, &root).await;

    assert!(first.ok && second.ok);
    assert!(first.pdf_changed && !second.pdf_changed);
    assert_eq!(serde_json::to_value(&second).unwrap()["pdfChanged"], false);
    assert_eq!(second.warnings, first.warnings);
    assert_eq!(second.warnings.len(), 1);
}

/// latexmk's record (.fdb_latexmk) stays after a good run and goes with a
/// failed one, so the next run starts afresh.
#[tokio::test]
async fn latexmks_record_is_kept_by_a_good_run_and_forgotten_by_a_failed_one() {
    for (end, kept) in [
        ("printf 'fake' > build/main.pdf\nexit 0\n", true),
        ("exit 12\n", false),
    ] {
        let record = "mkdir -p build\nprintf 'record' > build/main.fdb_latexmk\n";
        let (_dir, service, root) = setup(&[record, end].concat());
        compile(&service, &root).await;
        assert_eq!(root.join("build/main.fdb_latexmk").exists(), kept, "{end}");
    }
}

#[tokio::test]
async fn outputs_a_run_did_not_write_are_not_reported_as_its_own() {
    let (_dir, service, root) = setup("mkdir -p build\nprintf 'fake' > build/main.pdf\nexit 0\n");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.log"), "./main.tex:9: Stale error.\n").unwrap();
    let result = compile(&service, &root).await;
    assert!(result.ok && result.errors.is_empty(), "{result:?}");

    let (_dir, service, root) = setup(
        "mkdir -p build\nprintf './main.tex:4: Current failure.\\n' > build/main.log\nexit 1\n",
    );
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "old successful output").unwrap();
    let result = compile(&service, &root).await;
    assert!(!result.ok && !result.pdf_changed);
    assert_eq!(result.pdf, None);
    assert!(root.join("build/main.pdf").exists());
}

#[tokio::test]
async fn a_timed_out_automatic_build_is_killed_and_reported_failed_with_the_output_it_wrote() {
    let (_dir, service, root) = setup("echo 'Running pdflatex'\ntouch printed\nsleep 20\n");
    let started = Instant::now();
    // Once the stub has printed, tokio's clock jumps straight to the build's time limit.
    let (project, path) = (Project::in_folder(&root), stubs(&service));
    let auto = service.compile.compile(&project, &path, true);
    let (result, ()) = tokio::join!(auto, async {
        appears(&root.join("printed"), "latexmk did not print").await;
        tokio::time::pause();
    });
    let result = result.unwrap();

    assert!(!result.ok);
    assert!(!result.stopped, "a timeout is a failure, not a Stop");
    assert_eq!(result.pdf, None);
    assert!(result.log.contains("Running pdflatex"), "{:?}", result.log);
    assert_eq!(result.errors.len(), 1);
    let message = &result.errors[0].message;
    assert!(message.contains("stopped after"), "{result:?}");
    assert!(!message.contains("forever"), "{message}");
    promptly(started);
}

/// Asked for, a build runs past the automatic one's time limit until it ends.
#[tokio::test]
async fn a_build_asked_for_has_no_time_limit() {
    let (_dir, service, root) = setup(
        "touch printed\nwhile [ ! -f go ]; do sleep 0.01; done\nmkdir -p build\nprintf 'fake' > build/main.pdf\n",
    );
    let (result, ()) = tokio::join!(compile(&service, &root), async {
        appears(&root.join("printed"), "latexmk did not print").await;
        tokio::time::pause();
        tokio::time::advance(super::COMPILE_TIMEOUT * 2).await;
        fs::write(root.join("go"), "").unwrap();
    });
    assert!(result.ok, "{result:?}");
}

#[tokio::test]
async fn a_descendant_holding_the_output_pipe_does_not_hold_the_compile() {
    // latexmk has exited but a background child still holds stdout open: the compile answers after a short drain grace.
    let started = Instant::now();
    let build = built("sleep 30 &\nmkdir -p build\nprintf 'fake' > build/main.pdf\nexit 0\n");
    assert!(build.await.ok);
    promptly(started);
}

/// An unchanged compile lets latexmk skip the engine; builds compile past errors unless the project stops on the first; -norc is dropped only for a trusted project; the user's rc comes before every option it could override; the glossary rules are given either way.
#[tokio::test]
async fn latexmk_is_given_the_arguments_the_settings_call_for() {
    let (_dir, service, root) =
        setup("mkdir -p build\necho \"$@\" > build/args\nprintf 'fake' > build/main.pdf\nexit 0\n");
    let cases: [(_, &[&str], &[&str]); 3] = [
        (json!({}), &["-f", "-norc", "-e"], &["-g", "-halt-on-error"]),
        (
            json!({ "stopOnFirstError": true }),
            &["-halt-on-error"],
            &["-f"],
        ),
        (
            json!({ "shellEscape": true }),
            &["-shell-escape", "-e"],
            &["-norc"],
        ),
    ];
    for (settings, given, not_given) in cases {
        write_settings(&root.join(".texlocal.json"), &settings).unwrap();
        compile(&service, &root).await;
        let args = fs::read_to_string(root.join("build/args")).unwrap();
        let passed: Vec<_> = args.split_whitespace().collect();
        let engine = passed.iter().position(|&arg| arg == "-pdf").unwrap();
        let trusted = settings["shellEscape"] == true;
        let mut first = vec![if trusted { "-shell-escape" } else { "-norc" }];
        let rc = super::user_latexmkrc(|key| std::env::var_os(key));
        if let Some(rc) = rc.as_deref().filter(|_| !trusted) {
            first.extend(["-r", rc]);
        }
        assert_eq!(passed[..engine], first);
        assert!(given.iter().all(|arg| passed.contains(arg)), "{passed:?}");
        assert!(
            !not_given.iter().any(|arg| passed.contains(arg)),
            "{passed:?}"
        );
    }
}

/// A folder opened where it is builds beside the library, where `-outdir` says, writing
/// nothing in the folder.
#[tokio::test]
async fn an_opened_folders_build_lands_in_its_store() {
    let (dir, service, _) = setup(
        "for arg; do case $arg in -outdir=*) out=${arg#-outdir=};; esac; done\nmkdir -p \"$out\" && printf 'fake' > \"$out/main.pdf\"\n",
    );
    let folder = dir.path().join("My Thesis");
    fs::create_dir(&folder).unwrap();
    fs::write(folder.join("main.tex"), "").unwrap();
    let id = open_path(&service, &folder).unwrap().project.id;
    let project = service.project(&id).unwrap();
    let result = service
        .compile
        .compile(&project, &stubs(&service), false)
        .await;
    let pdf = project.build.join("main.pdf");
    assert_eq!(
        result.unwrap().pdf,
        Some(pdf.to_string_lossy().into_owned())
    );
    assert_eq!(names_in(&folder), ["main.tex"]);
}

/// A failure the engine's log doesn't explain names its cause: bibtex's own
/// log, else latexmk's summary of the step that failed, else the exit code.
#[tokio::test]
async fn a_failure_the_engines_log_doesnt_explain_names_its_cause() {
    let quiet = "mkdir -p build\nprintf 'No errors here.\\n' > build/main.log\n";
    let bibtex = "printf \"I was expecting a \\`,' or a \\`}'---line 1 of file refs.bib\\n\" > build/main.blg\nexit 12\n";
    let result = built(&[quiet, bibtex].concat()).await;
    assert_eq!(
        result.errors[0].file.as_deref(),
        Some("refs.bib"),
        "{result:?}"
    );

    let summary = "printf 'Collected error summary (may duplicate other messages):\\n  biber build/main: Could not find build/main.bcf\\n'\nexit 12\n";
    let result = built(&[quiet, summary].concat()).await;
    assert!(result.errors[0].message.starts_with("biber"), "{result:?}");
    let log = &result.log;
    assert!(log.starts_with("No errors here.") && log.contains("Collected error summary"));

    let result = built("exit 12\n").await;
    assert!(
        result.errors[0].message.contains("exit code 12"),
        "{result:?}"
    );
}

/// At the package's error that asks for it, else with no place when TeX refused a program.
#[tokio::test]
async fn a_build_failed_for_want_of_shell_escape_says_where_to_allow_it() {
    let log = |text| format!("mkdir -p build\nprintf '{text}\\n' > build/main.log\nexit 12\n");
    let minted =
        "./main.tex:3: Package minted Error: You must invoke LaTeX with the -shell-escape flag.";
    let refused = "runsystem(pygmentize -V)...disabled (restricted).";
    for (text, place) in [
        (minted, (Some("main.tex"), Some(3))),
        (refused, (None, None)),
    ] {
        let result = built(&log(text)).await;
        let found: Vec<_> = (result.errors.iter())
            .map(|e| (e.message.as_str(), e.file.as_deref(), e.line))
            .collect();
        assert_eq!(found, [(SHELL_ESCAPE, place.0, place.1)]);
    }
}

#[tokio::test]
async fn stop_rename_and_quit_each_end_only_their_own_builds_and_say_so() {
    let (_dir, service, _) = setup(
        "mkdir -p build\nif [ -f fast ]; then printf 'new' > build/main.pdf; else printf 'record' > build/main.fdb_latexmk; touch started; sleep 20; fi\n",
    );
    let ids = ["one", "two", "three"];
    for id in ids {
        create_project(&service.data_dir, id, "blank", None).unwrap();
    }
    let build = |id: &str| in_flight(&service, &service.project(id).unwrap().root);
    let [one, two, three] = ids.map(&build);
    for id in ids {
        let started = service.data_dir.join(id).join("started");
        appears(&started, "latexmk did not start").await;
    }

    let started = Instant::now();
    let stop = |id: &str| service.compile.stop(&service.project(id).unwrap().root);
    assert!(stop("one"));
    let one = one.await.unwrap();
    assert!(one.stopped && !one.ok);
    promptly(started);
    assert!(
        !two.is_finished() && !three.is_finished(),
        "another project's build was stopped too"
    );

    fs::write(service.data_dir.join("one/fast"), "").unwrap();
    let again = build("one").await.unwrap();
    assert!(again.ok && !again.stopped);
    assert!(!stop("one"), "nothing is running");

    // A rename refused leaves the build running; one that goes ahead stops it,
    // and its record goes before the folder moves, where the build can't reach it.
    create_project(&service.data_dir, "taken", "blank", None).unwrap();
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
    assert!(!service.data_dir.join("uno/build/main.fdb_latexmk").exists());
    assert!(!three.is_finished());

    service.compile.kill_all();
    assert!(three.await.unwrap().stopped);
    assert!(build("one").await.unwrap().stopped);
}

#[tokio::test]
async fn a_stopped_build_removes_the_aux_and_pdf_it_cut_short_and_leaves_the_rest() {
    let (_dir, service, root) = setup(
        "mkdir -p build\nprintf 'half' > build/main.aux\nprintf '%%PDF-half' > build/main.pdf\ntouch printed\nsleep 20\n",
    );
    let task = in_flight(&service, &root);
    appears(&root.join("printed"), "latexmk did not write").await;
    assert!(service.compile.stop(&root));
    assert!(task.await.unwrap().stopped);
    assert!(!root.join("build/main.aux").exists());
    assert!(!root.join("build/main.pdf").exists());

    let (_dir, service, root) = setup("touch printed\nsleep 20\n");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.aux"), "whole").unwrap();
    fs::write(root.join("build/main.pdf"), "whole").unwrap();
    let task = in_flight(&service, &root);
    appears(&root.join("printed"), "latexmk did not start").await;
    assert!(service.compile.stop(&root));
    assert!(task.await.unwrap().stopped);
    assert_eq!(fs::read(root.join("build/main.aux")).unwrap(), b"whole");
    assert_eq!(fs::read(root.join("build/main.pdf")).unwrap(), b"whole");
}

#[tokio::test]
async fn inverse_sync_finds_the_source_and_the_clicked_letters_column() {
    let (dir, service, root) = setup("exit 0\n");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "fake").unwrap();
    let text = "\n\n\n\nÜnï words \\word, the\nword next\nfinal\n";
    fs::write(root.join("chapter.tex"), text).unwrap();
    let synctex =
        "printf 'SyncTeX result begin\\nInput:%s/./chapter.tex\\nLine:7\\n' \"$(pwd -P)\"\n";
    stub(dir.path(), "synctex", synctex);
    let path = stubs(&service);
    for (click, line, column) in [
        (None, 7, None),
        (Some(("theword", 4)), 6, Some(1)),
        (Some(("absent", 0)), 7, None),
    ] {
        let project = Project::in_folder(&root);
        let found = synctex_inverse(&project, 1.0, 10.0, 20.0, click, None, &path);
        let loc = found.await.unwrap();
        assert_eq!(
            (loc.file.as_str(), loc.line, loc.column),
            ("chapter.tex", line, column)
        );
    }
}

thread_local! {
    static FORKS: Cell<usize> = const { Cell::new(0) };
}

extern "C" fn forked() {
    FORKS.with(|forks| forks.set(forks.get() + 1));
}

/// A forked child of a multithreaded process can crash before its exec, so a missing latexmk is reported without starting anything.
#[tokio::test]
async fn tools_report_their_version_and_start_by_posix_spawn_never_a_fork() {
    // SAFETY: the handler only counts, in the parent, after a fork.
    assert_eq!(unsafe { libc::pthread_atfork(None, Some(forked), None) }, 0);
    let before = FORKS.with(Cell::get);
    let (_dir, service, root) = setup("echo 'Latexmk, John Collins, Version 4.85'\nexit 0\n");
    let status = tex_available(&stubs(&service)).await;
    assert!(status.available);
    assert_eq!(status.latexmk_version.as_deref(), Some("4.85"));
    compile(&service, &root).await;

    let none = "/nonexistent-dir-for-test";
    let status = tex_available(none).await;
    assert!(!status.available && status.latexmk_version.is_none());
    let project = Project::in_folder(&root);
    let result = service
        .compile
        .compile(&project, none, false)
        .await
        .unwrap();
    let message = &result.errors[0].message;
    assert!(message.starts_with("Couldn't start latexmk"), "{message}");
    assert_eq!(FORKS.with(Cell::get), before);
}
