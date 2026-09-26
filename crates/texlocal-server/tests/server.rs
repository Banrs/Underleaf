// The browser host's contract: who may talk to it, and that each route maps
// onto the shared service with the desktop's semantics.

use std::sync::Arc;

use serde_json::{json, Value};
use tempfile::TempDir;
use texlocal_core::service::Service;
use texlocal_server::{http, App, Request, Response};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const PORT: u16 = 7878;
const TOKEN: &str = "secret";
const HOST: &str = "127.0.0.1:7878";

struct Fixture {
    _data: TempDir,
    _web: TempDir,
    app: App,
}

fn fixture() -> Fixture {
    let data = tempfile::tempdir().unwrap();
    let web = tempfile::tempdir().unwrap();
    std::fs::write(web.path().join("index.html"), "<!doctype html>").unwrap();
    texlocal_core::projects::create_project(data.path(), "P", "blank").unwrap();
    std::fs::create_dir_all(data.path().join("P/img")).unwrap();
    std::fs::write(data.path().join("P/img/a.svg"), "0123456789").unwrap();
    let app = App::new(
        Service::new(data.path().to_path_buf()),
        web.path().to_path_buf(),
        PORT,
        TOKEN.into(),
    );
    Fixture {
        _data: data,
        _web: web,
        app,
    }
}

fn request(method: &str, target: &str, headers: &[(&str, &str)], body: &[u8]) -> Request {
    Request {
        method: method.into(),
        target: target.into(),
        headers: headers
            .iter()
            .map(|(n, v)| (n.to_ascii_lowercase(), v.to_string()))
            .collect(),
        body: body.to_vec(),
    }
}

/// A request from the signed-in browser tab.
fn authed(method: &str, target: &str, extra: &[(&str, &str)], body: &[u8]) -> Request {
    let cookie = format!("texlocal_token={TOKEN}");
    let mut headers = vec![("host", HOST), ("cookie", cookie.as_str())];
    headers.extend_from_slice(extra);
    request(method, target, &headers, body)
}

fn json_body(response: &Response) -> Value {
    serde_json::from_slice(&response.body).unwrap()
}

#[tokio::test]
async fn requests_without_the_token_cookie_are_refused() {
    let f = fixture();
    let bare = request("GET", "/", &[("host", HOST)], b"");
    assert_eq!(f.app.handle(bare).await.status, 401);

    let wrong = request(
        "GET",
        "/",
        &[("host", HOST), ("cookie", "texlocal_token=nope")],
        b"",
    );
    assert_eq!(f.app.handle(wrong).await.status, 401);

    let api = request("POST", "/api/list_projects", &[("host", HOST)], b"");
    assert_eq!(f.app.handle(api).await.status, 401);
}

#[tokio::test]
async fn the_startup_token_is_traded_for_a_strict_http_only_cookie() {
    let f = fixture();
    let signed_in = f
        .app
        .handle(request("GET", "/?token=secret", &[("host", HOST)], b""))
        .await;
    assert_eq!(signed_in.status, 303);
    assert_eq!(signed_in.header("location"), Some("/"));
    let cookie = signed_in.header("set-cookie").unwrap();
    assert!(cookie.starts_with("texlocal_token=secret;"));
    assert!(cookie.contains("HttpOnly") && cookie.contains("SameSite=Strict"));

    let wrong = request("GET", "/?token=guess", &[("host", HOST)], b"");
    assert_eq!(f.app.handle(wrong).await.status, 401);
}

#[tokio::test]
async fn foreign_hosts_and_origins_are_refused_even_with_the_cookie() {
    let f = fixture();
    // DNS rebinding: an attacker's name resolving to 127.0.0.1.
    let rebound = request(
        "GET",
        "/",
        &[
            ("host", "evil.example:7878"),
            ("cookie", "texlocal_token=secret"),
        ],
        b"",
    );
    assert_eq!(f.app.handle(rebound).await.status, 403);

    let cross_site = authed(
        "POST",
        "/api/list_projects",
        &[("origin", "https://evil.example")],
        b"",
    );
    assert_eq!(f.app.handle(cross_site).await.status, 403);

    let same_site = authed(
        "POST",
        "/api/list_projects",
        &[("origin", "http://localhost:7878")],
        b"",
    );
    assert_eq!(f.app.handle(same_site).await.status, 200);
}

#[tokio::test]
async fn commands_dispatch_to_the_service_with_json_errors() {
    let f = fixture();
    let listed = f
        .app
        .handle(authed("POST", "/api/list_projects", &[], b""))
        .await;
    assert_eq!(listed.status, 200);
    assert_eq!(json_body(&listed)[0]["id"], "P");

    let body = json!({ "id": "P", "path": "a.tex", "text": "hi" }).to_string();
    let written = f
        .app
        .handle(authed("POST", "/api/write_file", &[], body.as_bytes()))
        .await;
    assert_eq!(written.status, 200);

    let escape = json!({ "id": "P", "path": "../../etc/passwd" }).to_string();
    let refused = f
        .app
        .handle(authed("POST", "/api/read_file", &[], escape.as_bytes()))
        .await;
    assert_eq!(refused.status, 400);
    assert!(json_body(&refused)["error"].is_string());

    let bad_json = f
        .app
        .handle(authed("POST", "/api/read_file", &[], b"{"))
        .await;
    assert_eq!(bad_json.status, 400);
    let unknown = f
        .app
        .handle(authed("POST", "/api/export_project", &[], b"{}"))
        .await;
    assert_eq!(unknown.status, 404);
}

#[cfg(unix)]
#[tokio::test] // one runtime thread: a command that blocked it would stall every request
async fn a_blocked_command_does_not_stall_other_requests() {
    let f = fixture();
    // Opening a FIFO blocks until a writer arrives, like a read of a file on
    // a slow disk or a walk of a huge project.
    let fifo = f._data.path().join("P/pipe.tex");
    assert!(std::process::Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .unwrap()
        .success());
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    let writer = std::thread::spawn(move || {
        let waited_out = rx.recv_timeout(std::time::Duration::from_secs(5)).is_err();
        std::fs::write(&fifo, "x").unwrap();
        waited_out
    });

    let body = json!({ "id": "P", "path": "pipe.tex" }).to_string();
    let (read, listed) = tokio::join!(
        f.app
            .handle(authed("POST", "/api/read_file", &[], body.as_bytes())),
        async {
            let listed = f
                .app
                .handle(authed("POST", "/api/list_projects", &[], b""))
                .await;
            let _ = tx.send(());
            listed
        },
    );
    assert_eq!(listed.status, 200);
    assert_eq!(json_body(&read)["text"], "x");
    assert!(
        !writer.join().unwrap(),
        "list_projects waited for the blocked read"
    );
}

#[tokio::test]
async fn uploads_arrive_raw_with_percent_encoded_metadata() {
    let f = fixture();
    let headers = [
        ("x-project", "P"),
        ("x-dir", "img"),
        ("x-path", "n%C3%BC.png"),
    ];
    let saved = f
        .app
        .handle(authed("POST", "/api/upload_file", &headers, b"png"))
        .await;
    assert_eq!(saved.status, 200);
    assert_eq!(json_body(&saved), json!({ "saved": ["img/nü.png"] }));

    let escape = [("x-project", "P"), ("x-dir", ""), ("x-path", "..%2F..%2Fx")];
    let refused = f
        .app
        .handle(authed("POST", "/api/upload_file", &escape, b"x"))
        .await;
    assert_eq!(refused.status, 400);
}

#[tokio::test]
async fn project_files_are_sandboxed_and_support_ranges() {
    let f = fixture();
    let whole = f
        .app
        .handle(authed("GET", "/__raw/P/img/a.svg", &[], b""))
        .await;
    assert_eq!(whole.status, 200);
    assert_eq!(whole.body, b"0123456789");
    assert_eq!(whole.header("content-type"), Some("image/svg+xml"));
    assert_eq!(
        whole.header("content-security-policy"),
        Some("sandbox; default-src 'none'")
    );

    let part = f
        .app
        .handle(authed(
            "GET",
            "/__raw/P/img/a.svg",
            &[("range", "bytes=2-4")],
            b"",
        ))
        .await;
    assert_eq!(part.status, 206);
    assert_eq!(part.body, b"234");
    assert_eq!(part.header("content-range"), Some("bytes 2-4/10"));

    let beyond = f
        .app
        .handle(authed(
            "GET",
            "/__raw/P/img/a.svg",
            &[("range", "bytes=50-")],
            b"",
        ))
        .await;
    assert_eq!(beyond.status, 416);

    let escape = f
        .app
        .handle(authed("GET", "/__raw/P/..%2F..%2Fsecret", &[], b""))
        .await;
    assert_ne!(escape.status, 200);
}

#[tokio::test]
async fn only_regular_files_are_served() {
    let f = fixture();
    for target in ["/__raw/P/img", "/__raw/P/img/missing.png"] {
        let response = f.app.handle(authed("GET", target, &[], b"")).await;
        assert_eq!(response.status, 404, "{target}");
        assert_eq!(
            response.header("content-security-policy"),
            Some("sandbox; default-src 'none'"),
            "{target}"
        );
    }
    let no_pdf = f.app.handle(authed("GET", "/__pdf/P", &[], b"")).await;
    assert_eq!(no_pdf.status, 404);
    let no_project = f.app.handle(authed("GET", "/__pdf/Q", &[], b"")).await;
    assert_eq!(no_project.status, 404);

    std::fs::create_dir(f._web.path().join("dist")).unwrap();
    for target in ["/dist", "/missing.js"] {
        let response = f.app.handle(authed("GET", target, &[], b"")).await;
        assert_eq!(response.status, 404, "{target}");
    }
    let head = f.app.handle(authed("HEAD", "/index.html", &[], b"")).await;
    assert_eq!(head.status, 200);
}

#[tokio::test]
async fn web_assets_stay_inside_the_web_directory() {
    let f = fixture();
    let index = f.app.handle(authed("GET", "/", &[], b"")).await;
    assert_eq!(index.status, 200);
    assert_eq!(index.header("content-type"), Some("text/html"));

    for target in ["/../Cargo.toml", "/%2E%2E/Cargo.toml", "/..%2FCargo.toml"] {
        let escaped = f.app.handle(authed("GET", target, &[], b"")).await;
        assert_eq!(escaped.status, 404, "{target}");
    }
}

#[tokio::test]
async fn exports_download_as_attachments() {
    let f = fixture();
    let zip = f
        .app
        .handle(authed("GET", "/__download/zip/P", &[], b""))
        .await;
    assert_eq!(zip.status, 200);
    assert_eq!(zip.header("content-type"), Some("application/zip"));
    assert_eq!(
        zip.header("content-disposition"),
        Some("attachment; filename*=UTF-8''P%2Ezip")
    );
    assert_eq!(&zip.body[..2], b"PK");

    let pdf = f
        .app
        .handle(authed("GET", "/__download/pdf/P", &[], b""))
        .await;
    assert_eq!(pdf.status, 404);
}

// ---------- over a real socket ----------

async fn start() -> (Fixture, u16) {
    let f = fixture();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let data = f._data.path().to_path_buf();
    let web = f._web.path().to_path_buf();
    let app = Arc::new(App::new(Service::new(data), web, port, TOKEN.into()));
    let handler = Arc::new(move |req| {
        let app = app.clone();
        async move { app.handle(req).await }
    });
    tokio::spawn(http::serve(listener, handler, 1024, std::future::pending()));
    (f, port)
}

async fn read_response(stream: &mut tokio::net::TcpStream) -> String {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk).await.unwrap();
        buf.extend_from_slice(&chunk[..n]);
        let text = String::from_utf8_lossy(&buf).into_owned();
        if let Some(head_end) = text.find("\r\n\r\n") {
            let len: usize = text
                .lines()
                .find_map(|l| l.strip_prefix("Content-Length: "))
                .unwrap()
                .parse()
                .unwrap();
            if buf.len() >= head_end + 4 + len || n == 0 {
                return text;
            }
        }
        if n == 0 {
            return text;
        }
    }
}

#[tokio::test]
async fn one_connection_carries_several_requests_with_bodies() {
    let (_f, port) = start().await;
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    let head = format!("Host: 127.0.0.1:{port}\r\nCookie: texlocal_token={TOKEN}");

    let body = r#"{"id":"P","path":"main.tex"}"#;
    let post = format!(
        "POST /api/read_file HTTP/1.1\r\n{head}\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(post.as_bytes()).await.unwrap();
    let first = read_response(&mut stream).await;
    assert!(first.starts_with("HTTP/1.1 200 OK"), "{first}");
    assert!(first.contains("Connection: keep-alive"));

    let get = format!("GET /__raw/P/img/a.svg HTTP/1.1\r\n{head}\r\n\r\n");
    stream.write_all(get.as_bytes()).await.unwrap();
    let second = read_response(&mut stream).await;
    assert!(second.starts_with("HTTP/1.1 200 OK"), "{second}");
    assert!(second.ends_with("0123456789"));
}

#[tokio::test]
async fn a_request_pipelined_behind_a_body_is_kept() {
    let (_f, port) = start().await;
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    let head = format!("Host: 127.0.0.1:{port}\r\nCookie: texlocal_token={TOKEN}");
    let body = r#"{"id":"P","path":"main.tex"}"#;
    let both = format!(
        "POST /api/read_file HTTP/1.1\r\n{head}\r\nContent-Length: {}\r\n\r\n{body}\
         GET /__raw/P/img/a.svg HTTP/1.1\r\n{head}\r\n\r\n",
        body.len()
    );
    stream.write_all(both.as_bytes()).await.unwrap();
    let mut text = String::new();
    while !text.ends_with("0123456789") {
        let mut chunk = [0u8; 4096];
        let n = stream.read(&mut chunk).await.unwrap();
        assert!(n > 0, "connection closed after: {text}");
        text.push_str(&String::from_utf8_lossy(&chunk[..n]));
    }
    assert_eq!(text.matches("HTTP/1.1 200 OK").count(), 2, "{text}");
    assert!(text.contains("documentclass"), "{text}");
}

#[tokio::test]
async fn oversized_and_chunked_bodies_are_refused_before_reading() {
    let (_f, port) = start().await;
    for extra in ["Content-Length: 5000", "Transfer-Encoding: chunked"] {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        let req = format!(
            "POST /api/list_projects HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n{extra}\r\n\r\n"
        );
        stream.write_all(req.as_bytes()).await.unwrap();
        let response = read_response(&mut stream).await;
        let expected = if extra.starts_with("Content") {
            "413"
        } else {
            "501"
        };
        assert!(
            response.starts_with(&format!("HTTP/1.1 {expected}")),
            "{response}"
        );
        assert!(response.contains("Connection: close"));
    }
}
