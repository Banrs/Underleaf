//! The command surface, the JSON dispatch every host forwards to, and the
//! edit lock.

use std::fs;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::*;
use crate::projects::testing::{library, with_project};
use crate::session::Sessions;

async fn call(service: &Service, command: &str, args: Value) -> Value {
    service
        .call(command, &args)
        .await
        .unwrap_or_else(|e| panic!("{command} failed: {} {}", e.status, e.message))
}

async fn status_of(service: &Service, command: &str, args: Value) -> u16 {
    service.call(command, &args).await.unwrap_err().status
}

fn tex_dir(service: &Service) -> Option<PathBuf> {
    AppSettings::read(&service.data_dir).tex_dir
}

#[tokio::test]
async fn the_catalogue_lists_templates_and_engines_a_project_can_be_made_with() {
    let (_dir, service) = library();
    let catalogue = call(&service, "catalogue", json!({})).await;
    let beamer = json!({ "id": "beamer", "title": "Presentation" });
    assert_eq!(catalogue["templates"][3], beamer);
    let engines = catalogue["engines"].as_array().unwrap();
    for (n, engine) in engines.iter().enumerate() {
        let args = json!({ "name": format!("P{n}"), "engine": engine["id"] });
        call(&service, "create_project", args).await;
    }
    let defaults: Vec<_> = engines.iter().filter(|e| e["default"] == true).collect();
    assert_eq!(
        defaults,
        [&json!({ "id": "pdflatex", "title": "pdfLaTeX", "default": true })]
    );
}

#[tokio::test]
async fn a_free_project_name_is_the_next_untitled() {
    let (_dir, service) = library();
    let name = call(&service, "free_project_name", json!({})).await;
    assert_eq!(name, json!({ "name": "Untitled" }));
    for name in ["Untitled", "Untitled 2", "Untitled 3"] {
        let args = json!({ "name": name, "template": "blank" });
        assert_eq!(call(&service, "create_project", args).await["id"], name);
    }
    fs::remove_dir_all(service.data_dir.join("Untitled 2")).unwrap();
    let next = call(&service, "free_project_name", json!({})).await;
    assert_eq!(next, json!({ "name": "Untitled 2" }));
    let from_taken = call(&service, "free_project_name", json!({ "name": "untitled" })).await;
    assert_eq!(from_taken["name"], "untitled 2");
    let args = json!({ "name": "Untitled 3", "template": "blank" });
    let numbered = call(&service, "create_project", args).await;
    assert_eq!(numbered["id"], "Untitled 3 2");
    let bad = json!({ "name": ".hidden" });
    assert_eq!(status_of(&service, "free_project_name", bad).await, 400);
    assert_eq!(status_of(&service, "create_project", json!({})).await, 400);
}

#[tokio::test]
async fn a_new_project_is_made_with_its_engine() {
    let (_dir, service) = library();
    let args = json!({ "name": "Xe", "template": "blank", "engine": "xelatex" });
    let made = call(&service, "create_project", args).await;
    let settings = call(&service, "get_settings", json!({ "id": made["id"] })).await;
    assert_eq!(settings["engine"], "xelatex");
}

#[tokio::test]
async fn dispatch_rejects_unknown_commands_and_bad_arguments() {
    let (_dir, service) = with_project();
    assert_eq!(status_of(&service, "no_such_command", json!({})).await, 404);
    let pdf = call(&service, "pdf_path", json!({ "id": "P" })).await;
    assert!(pdf.as_str().unwrap().ends_with(".pdf"), "{pdf}");
    for (command, args) in [
        (
            "synctex_forward",
            json!({ "id": "P", "file": "a.tex", "line": "x" }),
        ),
        (
            "create_entry",
            json!({ "id": "P", "path": "../../etc/passwd" }),
        ),
        ("file_tree", json!({ "id": "../P" })),
        ("project_root", json!({ "id": "../x" })),
    ] {
        assert_eq!(status_of(&service, command, args).await, 400, "{command}");
    }
    for args in [json!({ "id": "P" }), json!({ "id": "P", "path": null })] {
        let err = service.call("create_entry", &args).await.unwrap_err();
        let expected = "Invalid argument `path`: invalid type: null, expected a string";
        assert_eq!((err.status, err.message.as_str()), (400, expected));
    }
}

/// A stand-in program `name` in `dir` that prints `line`: a shell script, or
/// a batch file on Windows. Its path.
fn fake_program(dir: &Path, name: &str, line: &str) -> PathBuf {
    fs::create_dir_all(dir).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let exe = dir.join(name);
        fs::write(&exe, format!("#!/bin/sh\necho '{line}'\n")).unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
        exe
    }
    #[cfg(windows)]
    {
        let exe = dir.join(format!("{name}.bat"));
        fs::write(&exe, format!("@echo {line}\r\n")).unwrap();
        exe
    }
}

fn fake_tex(dir: &Path) -> String {
    fake_program(dir, "latexmk", "Latexmk, Version 4.86a");
    dir.to_string_lossy().into_owned()
}

#[tokio::test]
async fn the_tex_folder_holds_latexmk_or_is_a_root_above_one_and_is_kept_until_cleared() {
    let (_dir, service) = library();
    let tex = TempDir::new().unwrap();
    let empty = service
        .call("set_tex_dir", &json!({ "dir": tex.path() }))
        .await;
    let empty = empty.unwrap_err();
    assert!(empty.status == 400 && empty.message.contains("doesn't contain latexmk"));
    assert_eq!(tex_dir(&service), None);

    // A TeX root resolves to its bin folder, which the status reports.
    let bin = fake_tex(&tex.path().join("bin").join("universal-darwin"));
    let chosen = call(&service, "set_tex_dir", json!({ "dir": tex.path() })).await;
    assert_eq!(chosen["texDir"], bin);
    assert_eq!(call(&service, "status", json!({})).await, chosen);
    assert_eq!(chosen["latexmkVersion"], "4.86a");
    assert_eq!(tex_dir(&service).unwrap().to_string_lossy(), bin);
    let listed = call(&service, "list_projects", json!({})).await;
    assert!(listed.as_array().unwrap().is_empty());

    let status = call(&service, "set_tex_dir", json!({ "dir": null })).await;
    assert_eq!(status["texDir"], Value::Null);
    assert_eq!(tex_dir(&service), None);
}

#[tokio::test]
async fn set_texpresso_dir_accepts_only_a_folder_with_texpresso() {
    let (_dir, service) = library();
    let tex = TempDir::new().unwrap();
    let bin = fake_tex(&tex.path().join("tex"));
    call(&service, "set_tex_dir", json!({ "dir": bin })).await;

    let empty = TempDir::new().unwrap();
    let refused = service
        .call("set_texpresso_dir", &json!({ "dir": empty.path() }))
        .await
        .unwrap_err();
    assert_eq!(refused.status, 400);
    assert!(call(&service, "status", json!({})).await["texpressoDir"].is_null());

    let exe = fake_program(empty.path(), "texpresso", "");
    let args = json!({ "dir": empty.path() });
    let status = call(&service, "set_texpresso_dir", args).await;
    let chosen = empty.path().to_string_lossy();
    assert_eq!(status["texpressoDir"], chosen.as_ref());
    assert_eq!(status["texDir"], bin);
    if std::env::var_os("TEXLOCAL_TEXPRESSO").is_none() {
        let exe = dunce::canonicalize(&exe).unwrap();
        assert_eq!(status["texpresso"], exe.to_string_lossy().as_ref());
    }

    let cleared = call(&service, "set_texpresso_dir", json!({ "dir": null })).await;
    assert!(cleared["texpressoDir"].is_null());
    assert_eq!(tex_dir(&service).unwrap().to_string_lossy(), bin);
}

#[tokio::test]
async fn a_rename_answers_the_moved_ui_state_and_the_main_file_it_moved() {
    let (_dir, service) = with_project();
    let service = Arc::new(service);
    let root = service.project_root("P").unwrap();
    fs::create_dir(root.join("ch")).unwrap();
    fs::write(root.join("ch/a.tex"), "").unwrap();
    let patch = json!({ "expandedFolders": ["ch"] });
    let args = json!({ "id": "P", "patch": patch });
    call(&service, "set_ui_state", args).await;
    let sessions = Sessions::new(Arc::clone(&service));
    let ask = async |command: &str, args: Value| {
        let answer = sessions.call(command, &args).await;
        answer.unwrap_or_else(|e| panic!("{command} failed: {} {}", e.status, e.message))
    };
    ask("session_open", json!({ "id": "P", "session": 1 })).await;

    let args = json!({ "session": 1, "patch": { "mainFile": "ch/a.tex" } });
    ask("session_set_settings", args).await;
    let args = json!({ "session": 1, "from": "ch", "to": "chapters" });
    let renamed = ask("session_rename", args).await;
    assert_eq!(renamed["mainFile"], "chapters/a.tex");
    assert_eq!(renamed["ui"]["expandedFolders"], json!(["chapters"]));
    let args = json!({ "session": 1, "path": "chapters" });
    let refused = sessions.call("session_prepare_delete", &args).await;
    assert_eq!(refused.unwrap_err().status, 409);
    ask("session_close", json!({ "session": 1 })).await;
}

// MARK: - The edit lock

#[test]
fn a_panic_during_an_edit_does_not_stop_later_edits() {
    let (_dir, service) = with_project();
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        service.with_project("P", |_| -> Result<(), CoreError> { panic!("a bug") })
    }));
    assert!(panicked.is_err());
    assert!(service.with_project("P", |_| Ok(())).is_ok());
}

/// The interface state a host keeps and the main file a session's rename moves share the
/// settings file: each read, change and write keeps the other's change.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ui_state_patches_and_main_file_renames_preserve_both_changes() {
    let (_dir, service) = with_project();
    let service = Arc::new(service);
    let root = service.project_root("P").unwrap();
    for index in 0..16 {
        let (from, to) = if index % 2 == 0 {
            ("main.tex", "paper.tex")
        } else {
            ("paper.tex", "main.tex")
        };
        let folder = format!("part {index}");
        let start = Arc::new(tokio::sync::Barrier::new(2));
        let patch = tokio::spawn({
            let (service, start) = (Arc::clone(&service), Arc::clone(&start));
            let args = json!({ "id": "P", "patch": { "expandedFolders": [folder] } });
            async move {
                start.wait().await;
                service.call("set_ui_state", &args).await.unwrap();
            }
        });
        start.wait().await;
        service
            .with_project("P", |root| projects::rename_entry(root, from, to))
            .unwrap();
        patch.await.unwrap();
        assert_eq!(settings::read_settings(&root).main_file, to);
        assert_eq!(settings::read_ui(&root).expanded_folders, [folder]);
    }
}
