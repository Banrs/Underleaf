// The shared command surface: the JSON dispatch every non-Tauri host forwards
// to, and the route table both URL-serving hosts use.

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
    let (_dir, service) = service();
    call(
        &service,
        "create_project",
        json!({ "name": "P", "template": "blank" }),
    )
    .await;

    assert_eq!(status_of(&service, "no_such_command", json!({})).await, 404);
    assert_eq!(
        status_of(&service, "read_file", json!({ "id": "P" })).await,
        400
    );
    assert_eq!(
        status_of(
            &service,
            "synctex_forward",
            json!({ "id": "P", "file": "a.tex", "line": "x" })
        )
        .await,
        400
    );
    // Path checks apply through the dispatch exactly as through the methods.
    assert_eq!(
        status_of(
            &service,
            "read_file",
            json!({ "id": "P", "path": "../../etc/passwd" })
        )
        .await,
        400
    );
    assert_eq!(
        status_of(
            &service,
            "read_file",
            json!({ "id": "../P", "path": "main.tex" })
        )
        .await,
        400
    );
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
    let (_dir, service) = service();
    call(
        &service,
        "create_project",
        json!({ "name": "P", "template": "blank" }),
    )
    .await;
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
    let (_dir, service) = service();
    texlocal_core::projects::create_project(&service.data_dir, "P", "blank").unwrap();
    let spec = |path: &str, size: usize| texlocal_core::service::UploadSpec {
        path: path.into(),
        size,
    };

    assert!(service
        .validate_uploads("P", "img", &[spec("a.png", 1), spec("b.png", 1)])
        .is_ok());
    let dup = service
        .validate_uploads("P", "", &[spec("a.png", 1), spec("a.png", 1)])
        .unwrap_err();
    assert_eq!(dup.status, 400);
    let big = service
        .validate_uploads(
            "P",
            "",
            &[spec("a.png", texlocal_core::service::UPLOAD_MAX_BYTES + 1)],
        )
        .unwrap_err();
    assert_eq!(big.status, 400);
    assert!(service
        .validate_uploads("P", "", &[spec("../x.png", 1)])
        .is_err());

    let saved = service.upload_file("P", "img", "c.png", b"png").unwrap();
    assert_eq!(saved, "img/c.png");
    assert_eq!(
        std::fs::read(service.data_dir.join("P/img/c.png")).unwrap(),
        b"png"
    );
}

#[test]
fn serve_routes_resolve_through_the_project_boundary() {
    let (_dir, service) = service();
    texlocal_core::projects::create_project(&service.data_dir, "P", "blank").unwrap();
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
