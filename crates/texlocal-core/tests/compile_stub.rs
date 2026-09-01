//! Real spawn/kill/timeout coverage using a stub `latexmk` on PATH — the part
//! of compile.js the JS suite never exercised. Unix-only: the stubs are shell
//! scripts, and CI runs this on Linux and macOS.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tempfile::TempDir;
use texlocal_core::compile::{tex_available, CompileManager, CompileOverrides};
use texlocal_core::paths::project_root;
use texlocal_core::projects::create_project;
use texlocal_core::settings::write_settings;

fn stub_env(bin: &Path, script: &str) -> String {
    fs::create_dir_all(bin).unwrap();
    let path = bin.join("latexmk");
    fs::write(&path, script).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

fn project(data: &Path) -> std::path::PathBuf {
    create_project(data, "proj", "blank").unwrap();
    let root = project_root(data, "proj").unwrap();
    write_settings(&root, &json!({ "mainFile": "main.tex" })).unwrap();
    root
}

#[tokio::test]
async fn compile_happy_path_parses_the_log_it_wrote() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    let path = stub_env(
        &tmp.path().join("bin"),
        "#!/bin/sh\nmkdir -p build\nprintf './main.tex:3: Undefined control sequence.\\nl.3 x\\n' > build/main.log\nprintf 'fake' > build/main.pdf\nexit 0\n",
    );

    let mut mgr = CompileManager::new();
    mgr.path_env = Some(path);
    let result = mgr
        .compile(&root, &CompileOverrides::default())
        .await
        .unwrap();

    assert!(result.ok);
    assert_eq!(result.pdf.as_deref(), Some("build/main.pdf"));
    assert_eq!(result.errors.len(), 1);
    assert_eq!(result.errors[0].file.as_deref(), Some("main.tex"));
    assert_eq!(result.errors[0].line, Some(3));
}

#[tokio::test]
async fn a_stale_log_is_not_reported() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.log"), "./main.tex:9: Stale error.\n").unwrap();
    let mtime = filetime_from_secs_ago(120);
    set_mtime(&root.join("build/main.log"), mtime);
    let path = stub_env(
        &tmp.path().join("bin"),
        "#!/bin/sh\nmkdir -p build\nprintf 'fake' > build/main.pdf\nexit 0\n",
    );

    let mut mgr = CompileManager::new();
    mgr.path_env = Some(path);
    let result = mgr
        .compile(&root, &CompileOverrides::default())
        .await
        .unwrap();

    assert!(result.ok);
    assert!(
        result.errors.is_empty(),
        "stale log leaked: {:?}",
        result.errors
    );
}

#[tokio::test]
async fn a_failed_run_does_not_advertise_a_preexisting_pdf() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "old successful output").unwrap();
    let path = stub_env(
        &tmp.path().join("bin"),
        "#!/bin/sh\nmkdir -p build\nprintf './main.tex:4: Current failure.\\n' > build/main.log\nexit 1\n",
    );

    let mut mgr = CompileManager::new();
    mgr.path_env = Some(path);
    let result = mgr
        .compile(&root, &CompileOverrides::default())
        .await
        .unwrap();

    assert!(!result.ok);
    assert_eq!(result.pdf, None, "old PDF must not be labelled as this run");
    assert!(root.join("build/main.pdf").exists(), "old preview may remain on disk");
}

#[tokio::test]
async fn a_timed_out_compile_is_killed_and_reported_failed() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    let path = stub_env(&tmp.path().join("bin"), "#!/bin/sh\nsleep 20\n");

    let mut mgr = CompileManager::new();
    mgr.path_env = Some(path);
    mgr.timeout = Some(Duration::from_millis(300));
    let started = std::time::Instant::now();
    let result = mgr
        .compile(&root, &CompileOverrides::default())
        .await
        .unwrap();

    assert!(!result.ok);
    assert_eq!(result.pdf, None);
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "kill did not take effect"
    );
}

#[tokio::test]
async fn a_new_compile_supersedes_the_in_flight_one() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    let path = stub_env(
        &tmp.path().join("bin"),
        "#!/bin/sh\nif [ -f fast ]; then mkdir -p build; printf 'new' > build/main.pdf; exit 0; else sleep 20; fi\n",
    );

    let mgr = Arc::new({
        let mut m = CompileManager::new();
        m.path_env = Some(path);
        m
    });

    let first = tokio::spawn({
        let mgr = Arc::clone(&mgr);
        let root = root.clone();
        async move {
            mgr.compile(&root, &CompileOverrides::default())
                .await
                .unwrap()
        }
    });
    tokio::time::sleep(Duration::from_millis(400)).await;
    fs::write(root.join("fast"), "").unwrap();

    let second = mgr
        .compile(&root, &CompileOverrides::default())
        .await
        .unwrap();
    let first = first.await.unwrap();

    assert!(second.ok, "superseding compile should succeed");
    assert!(!first.ok, "superseded compile should be killed");
    assert_eq!(first.pdf, None);
    assert_eq!(fs::read_to_string(root.join("build/main.pdf")).unwrap(), "new");
}

#[tokio::test]
async fn a_third_compile_can_supersede_a_replacement_before_it_spawns() {
    let tmp = TempDir::new().unwrap();
    let root = project(tmp.path());
    let path = stub_env(
        &tmp.path().join("bin"),
        r#"#!/bin/sh
case "$*" in
  *-lualatex*) mkdir -p build; printf 'third' > build/main.pdf; exit 0 ;;
  *) sleep 20 ;;
esac
"#,
    );

    let mgr = Arc::new({
        let mut m = CompileManager::new();
        m.path_env = Some(path);
        m
    });
    let launch = |mgr: Arc<CompileManager>, root: std::path::PathBuf, engine: &str| {
        let options = CompileOverrides {
            engine: Some(engine.to_string()),
            ..CompileOverrides::default()
        };
        tokio::spawn(async move { mgr.compile(&root, &options).await.unwrap() })
    };

    let first = launch(Arc::clone(&mgr), root.clone(), "pdflatex");
    tokio::time::sleep(Duration::from_millis(250)).await;
    let second = launch(Arc::clone(&mgr), root.clone(), "xelatex");
    // The second request is waiting for the first process to settle and may not
    // have a child PID yet. The third must still supersede it without deadlock.
    tokio::time::sleep(Duration::from_millis(5)).await;
    let third = launch(Arc::clone(&mgr), root.clone(), "lualatex");

    let (third, second, first) = tokio::time::timeout(Duration::from_secs(5), async {
        (
            third.await.unwrap(),
            second.await.unwrap(),
            first.await.unwrap(),
        )
    })
    .await
    .expect("compile generations deadlocked");
    assert!(third.ok);
    assert!(!second.ok);
    assert!(!first.ok);
    assert_eq!(fs::read_to_string(root.join("build/main.pdf")).unwrap(), "third");
}

#[tokio::test]
async fn tex_available_reports_the_stub_version() {
    let tmp = TempDir::new().unwrap();
    let path = stub_env(
        &tmp.path().join("bin"),
        "#!/bin/sh\nprintf 'Latexmk, John Collins, 1 January 2024. Version 4.83\\n'\nexit 0\n",
    );
    let status = tex_available(Some(&path)).await;
    assert!(status.available);
    assert!(status.version.unwrap().starts_with("Latexmk"));

    let none = tex_available(Some("/nonexistent-dir-for-test")).await;
    assert!(!none.available);
    assert_eq!(none.version, None);
}

fn filetime_from_secs_ago(secs: u64) -> std::time::SystemTime {
    std::time::SystemTime::now() - Duration::from_secs(secs)
}

fn set_mtime(path: &Path, to: std::time::SystemTime) {
    let file = fs::File::options().append(true).open(path).unwrap();
    file.set_times(fs::FileTimes::new().set_modified(to))
        .unwrap();
}
