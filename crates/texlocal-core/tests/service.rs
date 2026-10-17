// The command surface: the JSON dispatch every host forwards to.

use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};
use tempfile::TempDir;
use texlocal_core::service::Service;
use texlocal_core::session::Sessions;

fn service() -> (TempDir, Service) {
    let dir = tempfile::Builder::new()
        .prefix("texlocal-service-")
        .tempdir()
        .unwrap();
    let service = Service::new(dir.path().to_path_buf());
    (dir, service)
}

/// A service whose data dir holds one blank project, "P".
fn with_project() -> (TempDir, Service) {
    let (dir, service) = service();
    texlocal_core::projects::create_project(&service.data_dir, "P", "blank").unwrap();
    (dir, service)
}

async fn call(service: &Service, command: &str, args: Value) -> Value {
    service
        .call(command, &args)
        .await
        .unwrap_or_else(|e| panic!("{command} failed: {} {}", e.status, e.message))
}

async fn status_of(service: &Service, command: &str, args: Value) -> u16 {
    service.call(command, &args).await.unwrap_err().status
}

#[tokio::test]
async fn a_free_project_name_is_the_next_untitled() {
    let (_dir, service) = service();
    // Nothing made: the series starts at "Untitled".
    let name = call(&service, "free_project_name", json!({})).await;
    assert_eq!(name, json!({ "name": "Untitled" }));
    for name in ["Untitled", "Untitled 2", "Untitled 3"] {
        let args = json!({ "name": name, "template": "blank" });
        assert_eq!(call(&service, "create_project", args).await["id"], name);
    }
    // A gap is filled first, and a name asked for is numbered the same way.
    std::fs::remove_dir_all(service.data_dir.join("Untitled 2")).unwrap();
    let next = call(&service, "free_project_name", json!({})).await;
    assert_eq!(next, json!({ "name": "Untitled 2" }));
    let from_taken = call(&service, "free_project_name", json!({ "name": "untitled" })).await;
    let case_insensitive = cfg!(any(target_os = "macos", windows));
    let expected = if case_insensitive {
        "untitled 2"
    } else {
        "untitled"
    };
    assert_eq!(from_taken["name"], expected);
    // A new project whose name is taken is numbered past it.
    let args = json!({ "name": "Untitled 3", "template": "blank" });
    let numbered = call(&service, "create_project", args).await;
    assert_eq!(numbered["id"], "Untitled 3 2");
    // Names the path rules refuse are refused, not numbered.
    let bad = json!({ "name": ".hidden" });
    assert_eq!(status_of(&service, "free_project_name", bad).await, 400);
    // A new project needs its name.
    assert_eq!(status_of(&service, "create_project", json!({})).await, 400);
}

#[tokio::test]
async fn a_new_project_is_made_with_its_engine_or_not_at_all() {
    let (_dir, service) = service();
    let args = json!({ "name": "Xe", "template": "blank", "engine": "xelatex" });
    let made = call(&service, "create_project", args).await;
    let settings = call(&service, "get_settings", json!({ "id": made["id"] })).await;
    assert_eq!(settings["engine"], "xelatex");
    let unknown = json!({ "name": "Odd", "engine": "troff" });
    assert_eq!(status_of(&service, "create_project", unknown).await, 400);
    assert!(!service.data_dir.join("Odd").exists(), "no project made");
}

#[tokio::test]
async fn dispatch_round_trips_project_and_file_commands() {
    let (_dir, service) = service();
    let args = json!({ "name": "Paper", "template": "blank" });
    let info = call(&service, "create_project", args).await;
    let id = info["id"].as_str().unwrap().to_string();

    let listed = call(&service, "list_projects", json!({})).await;
    assert_eq!(listed[0]["id"], id);

    let args = json!({ "id": id, "path": "sec/a.tex", "text": "hello needle" });
    call(&service, "write_file", args).await;
    let args = json!({ "id": id, "path": "sec/a.tex" });
    let read = call(&service, "read_file", args).await;
    assert_eq!(read, json!({ "text": "hello needle" }));

    let args = json!({ "id": id, "query": "needle" });
    let groups = call(&service, "search_project", args).await;
    assert_eq!(groups[0]["file"], "sec/a.tex");
    assert_eq!(groups[0]["hits"][0]["after"], "");
    assert_eq!(groups[0]["hits"][0]["column"], 6);
    assert_eq!(groups[0]["hits"][0]["length"], 6);

    let tree = call(&service, "file_tree", json!({ "id": id })).await;
    assert!(tree.as_array().unwrap().iter().any(|n| n["name"] == "sec"));
}

/// The Mac app keeps it to know its own save's change event by a stat.
#[cfg(unix)]
#[tokio::test]
async fn a_write_answers_the_stamp_of_the_file_it_wrote() {
    use std::os::unix::fs::MetadataExt;
    let (dir, service) = with_project();
    let args = json!({ "id": "P", "path": "main.tex", "text": "saved" });
    let stamp = call(&service, "write_file", args).await;
    let meta = std::fs::metadata(dir.path().join("P/main.tex")).unwrap();
    assert_eq!(
        stamp,
        json!({ "inode": meta.ino(), "size": 5, "seconds": meta.mtime(), "nanoseconds": meta.mtime_nsec() })
    );
}

#[tokio::test]
async fn dispatch_rejects_unknown_commands_and_bad_arguments() {
    let (_dir, service) = with_project();

    // Raw bytes go through methods, not commands.
    for command in [
        "no_such_command",
        "upload_file",
        "export_project",
        "save_pdf_as",
    ] {
        let status = status_of(&service, command, json!({ "id": "P" })).await;
        assert_eq!(status, 404, "{command}");
    }
    let pdf = call(&service, "pdf_path", json!({ "id": "P" })).await;
    assert!(pdf.as_str().unwrap().ends_with(".pdf"), "{pdf}");
    // Missing and mistyped arguments, and paths the boundary refuses, which
    // apply through the dispatch exactly as through the methods.
    for (command, args) in [
        ("read_file", json!({ "id": "P" })),
        (
            "synctex_forward",
            json!({ "id": "P", "file": "a.tex", "line": "x" }),
        ),
        (
            "read_file",
            json!({ "id": "P", "path": "../../etc/passwd" }),
        ),
        ("read_file", json!({ "id": "../P", "path": "main.tex" })),
    ] {
        assert_eq!(status_of(&service, command, args).await, 400, "{command}");
    }
    // A write without its text is refused, never taken as an empty file.
    for args in [
        json!({ "id": "P", "path": "main.tex" }),
        json!({ "id": "P", "path": "main.tex", "text": null }),
    ] {
        let err = service.call("write_file", &args).await.unwrap_err();
        assert_eq!(err.status, 400);
        assert_eq!(
            err.message,
            "Invalid argument `text`: invalid type: null, expected a string"
        );
    }
    let args = json!({ "id": "P", "path": "main.tex" });
    let main = call(&service, "read_file", args).await;
    assert!(!main["text"].as_str().unwrap().is_empty());
}

/// A stand-in program `name` in `dir` that prints `line`: a shell script, or
/// a batch file on Windows. Its path.
fn fake_program(dir: &Path, name: &str, line: &str) -> std::path::PathBuf {
    std::fs::create_dir_all(dir).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let exe = dir.join(name);
        std::fs::write(&exe, format!("#!/bin/sh\necho '{line}'\n")).unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        exe
    }
    #[cfg(windows)]
    {
        let exe = dir.join(format!("{name}.bat"));
        std::fs::write(&exe, format!("@echo {line}\r\n")).unwrap();
        exe
    }
}

/// A folder holding a stand-in `latexmk` that prints a version.
fn fake_tex(dir: &Path) -> String {
    fake_program(dir, "latexmk", "Latexmk, stub 1.0");
    dir.to_string_lossy().into_owned()
}

#[tokio::test]
async fn set_tex_dir_accepts_a_folder_with_latexmk_or_a_tex_root_above_one() {
    let (_dir, service) = service();
    let tex = TempDir::new().unwrap();

    let empty = service
        .call("set_tex_dir", &json!({ "dir": tex.path() }))
        .await
        .unwrap_err();
    assert_eq!(empty.status, 400);
    assert!(empty.message.contains("doesn't contain latexmk"));
    let relative = json!({ "dir": "relative/bin" });
    assert_eq!(status_of(&service, "set_tex_dir", relative).await, 400);
    assert_eq!(service.tex_dir(), None);

    let bin = fake_tex(&tex.path().join("bin").join("x"));
    let status = call(&service, "set_tex_dir", json!({ "dir": bin })).await;
    assert_eq!(status["texDir"], bin);

    // A picked TeX root resolves to its bin folder.
    let root = TempDir::new().unwrap();
    let bin = fake_tex(&root.path().join("bin").join("universal-darwin"));
    let status = call(&service, "set_tex_dir", json!({ "dir": root.path() })).await;
    assert_eq!(status["texDir"], bin);
}

/// TeXpresso's folder must hold the program; it's kept beside the TeX folder and
/// goes back to the TeX path when cleared.
#[tokio::test]
async fn set_texpresso_dir_accepts_only_a_folder_with_texpresso() {
    let (_dir, service) = service();
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
    assert_eq!(service.tex_dir().unwrap().to_string_lossy(), bin);
}

#[tokio::test]
async fn the_tex_dir_persists_in_the_data_dir_and_clears_to_automatic() {
    let (dir, service) = with_project();
    let tex = TempDir::new().unwrap();
    let bin = fake_tex(tex.path());
    call(&service, "set_tex_dir", json!({ "dir": bin })).await;

    // The settings file is not listed as a project.
    let listed = call(&service, "list_projects", json!({})).await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["id"], "P");

    // Another host on the same data dir sees the same choice.
    let other = Service::new(dir.path().to_path_buf());
    assert_eq!(other.tex_dir(), Some(tex.path().to_path_buf()));
    let saved = std::fs::read(dir.path().join(".texlocal-app.json")).unwrap();
    let saved: Value = serde_json::from_slice(&saved).unwrap();
    assert_eq!(saved, json!({ "texDir": bin }));

    let status = call(&service, "set_tex_dir", json!({ "dir": null })).await;
    assert_eq!(status["texDir"], Value::Null);
    assert_eq!(other.tex_dir(), None);

    call(&service, "set_tex_dir", json!({ "dir": bin })).await;
    call(&service, "set_tex_dir", json!({ "dir": "  " })).await;
    assert_eq!(service.tex_dir(), None);
}

#[tokio::test]
async fn status_reports_the_current_tex_choice() {
    let (_dir, service) = service();
    let first = call(&service, "status", json!({})).await;
    assert_eq!(first["texDir"], Value::Null);
    assert!(first.as_object().unwrap().contains_key("found"));

    let tex = TempDir::new().unwrap();
    let bin = fake_tex(tex.path());
    let chosen = call(&service, "set_tex_dir", json!({ "dir": bin })).await;
    assert_eq!(chosen["texDir"], bin);
    assert_eq!(call(&service, "status", json!({})).await, chosen);
    assert_eq!(chosen["available"], true);
    assert_eq!(chosen["version"], "Latexmk, stub 1.0");
    assert_eq!(
        chosen["latexmkVersion"],
        Value::Null,
        "the stub says no version number"
    );
    assert_eq!(chosen["found"], bin);

    // An update in the same folder is reflected without another folder choice.
    fake_program(tex.path(), "latexmk", "Latexmk, stub 2.0");
    let updated = call(&service, "status", json!({})).await;
    assert_eq!(updated["version"], "Latexmk, stub 2.0");
    assert_eq!(updated["texDir"], bin);

    let automatic = call(&service, "set_tex_dir", json!({ "dir": null })).await;
    assert_eq!(automatic["texDir"], Value::Null);
    assert_ne!(automatic["version"], "Latexmk, stub 1.0");
}

#[tokio::test]
async fn dispatch_serves_the_logic_the_hosts_used_to_hold() {
    let (dir, service) = with_project();

    // A free name is numbered past those taken; a plain create still refuses one.
    for expected in ["untitled.tex", "untitled 2.tex"] {
        let args = json!({ "id": "P", "path": "untitled.tex", "free": true });
        let made = call(&service, "create_entry", args).await;
        assert_eq!(made, json!({ "path": expected }));
    }
    let taken = json!({ "id": "P", "path": "untitled.tex" });
    assert_eq!(status_of(&service, "create_entry", taken).await, 409);
    let tree = call(&service, "file_tree", json!({ "id": "P" })).await;
    assert!(tree.as_array().unwrap().iter().all(|n| n["kind"] == "tex"));

    // Where a path in the library is.
    let path = dir.path().join("P/sec/new.tex");
    let located = call(&service, "locate", json!({ "path": path })).await;
    assert_eq!(located, json!({ "id": "P", "path": "sec/new.tex" }));
    let outside = json!({ "path": dir.path().parent().unwrap() });
    assert_eq!(call(&service, "locate", outside).await, Value::Null);

    // The interface state is kept with the project (and follows a rename: projects.rs).
    let patch = json!({ "expandedFolders": ["sec"], "foldedHeadings": ["sec/a.tex\t2:A#1"] });
    let args = json!({ "id": "P", "patch": patch });
    call(&service, "set_ui_state", args).await;
    let ui = call(&service, "get_ui_state", json!({ "id": "P" })).await;
    assert_eq!(ui, patch);
    // It is not a file the generic APIs reach.
    let name = ".texlocal.json";
    let args = json!({ "id": "P", "path": name, "text": "{}" });
    assert_eq!(status_of(&service, "write_file", args).await, 400);

    // The word a source line's caret is on, among a forward sync's pages.
    let args = json!({ "id": "P", "path": "main.tex", "text": "alpha beta gamma\n" });
    call(&service, "write_file", args).await;
    let page = json!({ "page": 2, "text": "alpha beta gamma", "near": [[0, 16]] });
    let args = json!({ "id": "P", "file": "main.tex", "line": 1, "column": 8, "pages": [page] });
    let hit = call(&service, "synctex_match", args).await;
    assert_eq!(hit, json!({ "page": 2, "start": 6, "end": 10 }));
    let beyond = json!({ "id": "P", "file": "main.tex", "line": 9, "column": 0, "pages": [] });
    assert_eq!(call(&service, "synctex_match", beyond).await, Value::Null);
}

#[tokio::test]
async fn a_rename_answers_the_moved_ui_state_and_the_main_file_it_moved() {
    let (_dir, service) = with_project();
    let service = Arc::new(service);
    let root = service.project_root("P").unwrap();
    std::fs::create_dir(root.join("ch")).unwrap();
    std::fs::write(root.join("ch/a.tex"), "").unwrap();
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
    // The sidebar's state moved with the folder, and the main file with it.
    let args = json!({ "session": 1, "from": "ch", "to": "chapters" });
    let renamed = ask("session_rename", args).await;
    assert_eq!(renamed["mainFile"], "chapters/a.tex");
    assert_eq!(renamed["ui"]["expandedFolders"], json!(["chapters"]));
    // The session refuses to trash the main file it moved.
    let args = json!({ "session": 1, "path": "chapters" });
    let refused = sessions.call("session_prepare_delete", &args).await;
    assert_eq!(refused.unwrap_err().status, 409);
    ask("session_close", json!({ "session": 1 })).await;
}
