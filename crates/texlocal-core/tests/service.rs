// The shared command surface: the JSON dispatch every non-Tauri host forwards
// to, and the route table both URL-serving hosts use.

use std::path::Path;

use serde_json::{json, Value};
use tempfile::TempDir;
use texlocal_core::serve;
use texlocal_core::service::Service;

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
async fn dispatch_round_trips_project_and_file_commands() {
    let (_dir, service) = service();
    let info = call(
        &service,
        "create_project",
        json!({ "name": "Paper", "template": "blank" }),
    )
    .await;
    let id = info["id"].as_str().unwrap().to_string();

    let listed = call(&service, "list_projects", json!({})).await;
    assert_eq!(listed[0]["id"], id);

    call(
        &service,
        "write_file",
        json!({ "id": id, "path": "sec/a.tex", "text": "hello needle" }),
    )
    .await;
    let read = call(
        &service,
        "read_file",
        json!({ "id": id, "path": "sec/a.tex" }),
    )
    .await;
    assert_eq!(read, json!({ "text": "hello needle" }));

    let hits = call(
        &service,
        "search_project",
        json!({ "id": id, "query": "needle" }),
    )
    .await;
    assert_eq!(hits[0]["file"], "sec/a.tex");

    let tree = call(&service, "file_tree", json!({ "id": id })).await;
    assert!(tree.as_array().unwrap().iter().any(|n| n["name"] == "sec"));
}

#[tokio::test]
async fn dispatch_rejects_unknown_commands_and_bad_arguments() {
    let (_dir, service) = with_project();

    assert_eq!(status_of(&service, "no_such_command", json!({})).await, 404);
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
    let main = call(
        &service,
        "read_file",
        json!({ "id": "P", "path": "main.tex" }),
    )
    .await;
    assert!(!main["text"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn byte_and_absolute_path_operations_are_not_reachable_by_name() {
    let (_dir, service) = service();
    for command in [
        "upload_file",
        "export_project",
        "save_pdf_as",
        "pdf_path",
        "raw_path",
    ] {
        assert_eq!(
            status_of(&service, command, json!({ "id": "P" })).await,
            404,
            "{command}"
        );
    }
}

#[tokio::test]
async fn writes_invalidate_the_symbols_cache() {
    let (_dir, service) = with_project();
    call(
        &service,
        "write_file",
        json!({ "id": "P", "path": "a.tex", "text": "\\label{one}" }),
    )
    .await;
    let first = call(&service, "scan_symbols", json!({ "id": "P" })).await;
    assert_eq!(first["labels"], json!(["one"]));

    // Same length: the new label must still replace the cached one.
    call(
        &service,
        "write_file",
        json!({ "id": "P", "path": "a.tex", "text": "\\label{two}" }),
    )
    .await;
    let second = call(&service, "scan_symbols", json!({ "id": "P" })).await;
    assert_eq!(second["labels"], json!(["two"]));
}

#[test]
fn uploads_are_validated_as_a_batch_before_any_write() {
    let (_dir, service) = with_project();
    let spec = |path: &str, size: usize| texlocal_core::service::UploadSpec {
        path: path.into(),
        size,
    };

    assert!(service
        .validate_uploads("P", "img", &[spec("a.png", 1), spec("b.png", 1)])
        .is_ok());
    for batch in [
        [spec("a.png", 1), spec("a.png", 1)],
        [
            spec("a.png", 1),
            spec("b.png", texlocal_core::service::UPLOAD_MAX_BYTES + 1),
        ],
        [spec("a.png", 1), spec("../x.png", 1)],
    ] {
        assert_eq!(
            service
                .validate_uploads("P", "", &batch)
                .unwrap_err()
                .status,
            400
        );
    }

    let saved = service.upload_file("P", "img", "c.png", b"png").unwrap();
    assert_eq!(saved, "img/c.png");
    assert_eq!(
        std::fs::read(service.data_dir.join("P/img/c.png")).unwrap(),
        b"png"
    );
}

#[test]
fn serve_routes_resolve_through_the_project_boundary() {
    let (_dir, service) = with_project();
    let seg = |parts: &[&str]| parts.iter().map(|s| s.to_string()).collect::<Vec<_>>();

    let raw = serve::resolve(&service, &seg(&["__raw", "P", "img", "a.png"])).unwrap();
    assert!(raw.sandboxed);
    assert!(raw.path.ends_with("P/img/a.png"));

    let pdf = serve::resolve(&service, &seg(&["__pdf", "P"])).unwrap();
    assert!(!pdf.sandboxed);
    assert_eq!(pdf.path.extension().unwrap(), "pdf");

    assert!(serve::resolve(&service, &seg(&["__raw", "P", "..", "..", "secret"])).is_err());
    assert_eq!(
        serve::resolve(&service, &seg(&["elsewhere"]))
            .err()
            .unwrap()
            .status,
        404
    );
}

/// A folder holding a stand-in `latexmk`. On Unix it runs and prints a
/// version; on Windows it is not a real program, so it is found but fails.
fn fake_tex(dir: &Path) -> String {
    std::fs::create_dir_all(dir).unwrap();
    let exe = dir.join(if cfg!(windows) {
        "latexmk.exe"
    } else {
        "latexmk"
    });
    std::fs::write(&exe, "#!/bin/sh\necho 'Latexmk, stub 1.0'\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    dir.to_string_lossy().into_owned()
}

#[tokio::test]
async fn set_tex_dir_accepts_only_a_folder_with_latexmk() {
    let (_dir, service) = service();
    let tex = TempDir::new().unwrap();

    let empty = service
        .call("set_tex_dir", &json!({ "dir": tex.path() }))
        .await
        .unwrap_err();
    assert_eq!(empty.status, 400);
    assert!(empty.message.contains("doesn't contain latexmk"));
    assert_eq!(
        status_of(&service, "set_tex_dir", json!({ "dir": "relative/bin" })).await,
        400
    );
    assert_eq!(service.tex_dir(), None);

    let bin = fake_tex(&tex.path().join("bin").join("x"));
    let status = call(&service, "set_tex_dir", json!({ "dir": bin })).await;
    assert_eq!(status["texDir"], bin);
}

#[tokio::test]
async fn set_tex_dir_resolves_a_picked_tex_root_to_its_bin_folder() {
    let (_dir, service) = service();
    let root = TempDir::new().unwrap();
    let bin = fake_tex(&root.path().join("bin").join("windows"));

    let status = call(&service, "set_tex_dir", json!({ "dir": root.path() })).await;
    assert_eq!(status["texDir"], bin);
}

#[tokio::test]
async fn the_tex_dir_persists_in_the_data_dir_and_clears_to_automatic() {
    let (dir, service) = service();
    let tex = TempDir::new().unwrap();
    let bin = fake_tex(tex.path());
    call(&service, "set_tex_dir", json!({ "dir": bin })).await;

    // Another host on the same data dir sees the same choice.
    let other = Service::new(dir.path().to_path_buf());
    assert_eq!(other.tex_dir(), Some(tex.path().to_path_buf()));
    let saved: Value = serde_json::from_slice(
        &std::fs::read(dir.path().join(texlocal_core::service::APP_SETTINGS_FILE)).unwrap(),
    )
    .unwrap();
    assert_eq!(saved, json!({ "texDir": bin }));

    let status = call(&service, "set_tex_dir", json!({ "dir": null })).await;
    assert_eq!(status["texDir"], Value::Null);
    assert_eq!(other.tex_dir(), None);

    call(&service, "set_tex_dir", json!({ "dir": bin })).await;
    call(&service, "set_tex_dir", json!({ "dir": "  " })).await;
    assert_eq!(service.tex_dir(), None);
}

#[tokio::test]
async fn changing_the_tex_dir_invalidates_the_cached_status() {
    let (_dir, service) = service();
    let first = call(&service, "status", json!({})).await;
    assert_eq!(first["texDir"], Value::Null);
    assert!(first.as_object().unwrap().contains_key("found"));

    let tex = TempDir::new().unwrap();
    let bin = fake_tex(tex.path());
    let chosen = call(&service, "set_tex_dir", json!({ "dir": bin })).await;
    assert_eq!(chosen["texDir"], bin);
    assert_eq!(call(&service, "status", json!({})).await, chosen);
    if cfg!(unix) {
        assert_eq!(chosen["available"], true);
        assert_eq!(chosen["version"], "Latexmk, stub 1.0");
        assert_eq!(chosen["found"], bin);
    } else {
        // First on the PATH but not a program: whatever TeX the first status
        // found and cached, this one was probed afresh.
        assert_eq!(chosen["available"], false);
    }

    let automatic = call(&service, "set_tex_dir", json!({ "dir": null })).await;
    assert_eq!(automatic["texDir"], Value::Null);
    assert_ne!(automatic["version"], "Latexmk, stub 1.0");
}

#[tokio::test]
async fn list_dirs_lists_visible_subfolders_by_name() {
    let (_dir, service) = service();
    let tmp = TempDir::new().unwrap();
    for name in ["beta", "Alpha", ".hidden"] {
        std::fs::create_dir(tmp.path().join(name)).unwrap();
    }
    std::fs::write(tmp.path().join("file.txt"), "secret").unwrap();

    let listing = call(&service, "list_dirs", json!({ "path": tmp.path() })).await;
    assert_eq!(listing["path"], tmp.path().to_string_lossy().as_ref());
    assert_eq!(
        listing["parent"],
        tmp.path().parent().unwrap().to_string_lossy().as_ref()
    );
    assert_eq!(listing["dirs"], json!(["Alpha", "beta"]));
    assert_eq!(listing["hasLatexmk"], false);
    assert!(!listing["roots"].as_array().unwrap().is_empty());

    let bin = fake_tex(&tmp.path().join("beta"));
    let tex = call(&service, "list_dirs", json!({ "path": bin })).await;
    assert_eq!(tex["hasLatexmk"], true);

    // With no path it starts at the chosen TeX folder.
    call(&service, "set_tex_dir", json!({ "dir": bin })).await;
    let start = call(&service, "list_dirs", json!({ "path": null })).await;
    assert_eq!(start["path"], bin);

    let missing = tmp.path().join("missing");
    assert_eq!(
        status_of(&service, "list_dirs", json!({ "path": missing })).await,
        400
    );
    assert_eq!(
        status_of(&service, "list_dirs", json!({ "path": "relative" })).await,
        400
    );
}

#[tokio::test]
async fn the_app_settings_file_is_not_listed_as_a_project() {
    let (_dir, service) = with_project();
    let tex = TempDir::new().unwrap();
    call(
        &service,
        "set_tex_dir",
        json!({ "dir": fake_tex(tex.path()) }),
    )
    .await;

    let listed = call(&service, "list_projects", json!({})).await;
    let ids: Vec<&str> = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["P"]);
}
