// The browser host's contract: who may talk to it, and that each route maps
// onto the shared service.

use std::sync::Arc;

use serde_json::{json, Value};
use tempfile::TempDir;
use texlocal_core::service::Service;
use texlocal_server::{serve, App, Bytes, Request, Response};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};

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
        body: Bytes::copy_from_slice(body),
    }
}

/// A request from the browser tab that holds the token.
fn authed(method: &str, target: &str, extra: &[(&str, &str)], body: &[u8]) -> Request {
    let mut headers = vec![("host", HOST), ("x-texlocal-token", TOKEN)];
    headers.extend_from_slice(extra);
    request(method, target, &headers, body)
}

fn json_body(response: &Response) -> Value {
    serde_json::from_slice(&response.body).unwrap()
}

#[tokio::test]
async fn project_routes_need_the_token_header() {
    let f = fixture();
    for (method, target) in [
        ("POST", "/api/list_projects"),
        ("POST", "/api/upload_file"),
        ("GET", "/__raw/P/img/a.svg"),
        ("HEAD", "/__raw/P/img/a.svg"),
        ("GET", "/__pdf/P"),
        ("GET", "/__download/pdf/P"),
        ("GET", "/__download/zip/P"),
    ] {
        let bare = request(method, target, &[("host", HOST)], b"");
        assert_eq!(f.app.handle(bare).await.status, 401, "{target}");
        let wrong = request(
            method,
            target,
            &[("host", HOST), ("x-texlocal-token", "nope")],
            b"",
        );
        assert_eq!(f.app.handle(wrong).await.status, 401, "{target}");
    }
    // Cookies go to every port on the host, so one isn't enough.
    let cookie = request(
        "POST",
        "/api/list_projects",
        &[("host", HOST), ("cookie", "texlocal_token=secret")],
        b"",
    );
    assert_eq!(f.app.handle(cookie).await.status, 401);
    // Nor is the token in the URL: only the page reads that.
    let query = request(
        "POST",
        "/api/list_projects?token=secret",
        &[("host", HOST)],
        b"",
    );
    assert_eq!(f.app.handle(query).await.status, 401);

    let signed = f
        .app
        .handle(authed("POST", "/api/list_projects", &[], b""))
        .await;
    assert_eq!(signed.status, 200);
}

#[tokio::test]
async fn only_the_web_ui_s_own_files_go_without_the_token() {
    let f = fixture();
    // Paths that only decode to a project route's prefix, and reads and
    // writes no route takes: the token is asked for before anything else.
    for (method, target) in [
        ("GET", "/%5F%5Fraw/P/img/a.svg"),
        ("GET", "/%5f%5Fpdf/P"),
        ("GET", "//__raw/P/img/a.svg"),
        ("GET", "/__anything"),
        ("GET", "/api"),
        ("GET", "/api/list_projects"),
        ("GET", "/%61pi/list_projects"),
        ("POST", "/"),
        ("PUT", "/index.html"),
        ("DELETE", "/__raw/P/img/a.svg"),
        ("OPTIONS", "/api/list_projects"),
    ] {
        let bare = request(method, target, &[("host", HOST)], b"");
        assert_eq!(f.app.handle(bare).await.status, 401, "{method} {target}");
    }
    // With it, a path is its decoded route however it's spelt, and a write
    // to a web file is not allowed.
    let decoded = f
        .app
        .handle(authed("GET", "/%5F%5Fraw/P/img/a.svg", &[], b""))
        .await;
    assert_eq!(decoded.body, b"0123456789");
    let put = f.app.handle(authed("PUT", "/index.html", &[], b"")).await;
    assert_eq!(put.status, 405);
    // The web UI's files, wherever they are, need none.
    std::fs::create_dir(f._web.path().join("dist")).unwrap();
    std::fs::write(f._web.path().join("dist/bundle.js"), "1").unwrap();
    for target in ["/", "/index.html", "/dist/bundle.js", "/dist/%62undle.js"] {
        let bare = request("GET", target, &[("host", HOST)], b"");
        assert_eq!(f.app.handle(bare).await.status, 200, "{target}");
    }
}

#[tokio::test]
async fn nothing_from_a_project_is_served_without_the_token() {
    // Every spelling of every route, and paths no route takes: whatever
    // answers with a project's bytes when signed must want the token, so a
    // route the guard didn't decide on fails here.
    let f = fixture();
    let routes = [
        "/__raw/P/img/a.svg",
        "/__pdf/P",
        "/__download/zip/P",
        "/__download/pdf/P",
        "/api/read_file",
        "/api/list_projects",
        "/api/upload_file",
    ];
    let spellings = |route: &str| {
        let rest = &route[1..];
        [
            route.to_string(),
            format!("//{rest}"),
            format!("/./{rest}"),
            format!("{route}?x=1"),
            route
                .replacen("__", "%5F%5F", 1)
                .replacen("api", "%61pi", 1),
            format!("/P/{rest}"),
            format!("/files/{rest}"),
        ]
    };
    let mut reached = 0;
    for target in routes.iter().flat_map(|route| spellings(route)) {
        for method in ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"] {
            let body = br#"{"id":"P","path":"img/a.svg"}"#;
            let upload = [("x-project", "P"), ("x-dir", ""), ("x-path", "b.svg")];
            let signed = f.app.handle(authed(method, &target, &upload, body)).await;
            let from_project = signed.status == 200
                && (signed.header("content-type") != Some("text/html") || method == "POST");
            if from_project {
                reached += 1;
                let mut headers = vec![("host", HOST)];
                headers.extend(upload);
                let bare = f.app.handle(request(method, &target, &headers, body)).await;
                assert_eq!(bare.status, 401, "{method} {target}");
            }
        }
    }
    assert!(reached >= 7 * 2, "the sweep reached the project routes");
}

#[tokio::test]
async fn the_web_ui_loads_without_the_token_and_keeps_its_url_to_itself() {
    let f = fixture();
    // The printed URL: the page loads, and its script takes the token.
    let first = f
        .app
        .handle(request("GET", "/?token=secret", &[("host", HOST)], b""))
        .await;
    assert_eq!(first.status, 200);
    assert!(first.header("set-cookie").is_none());
    assert_eq!(first.header("referrer-policy"), Some("no-referrer"));
    let bare = request("GET", "/", &[("host", HOST)], b"");
    assert_eq!(f.app.handle(bare).await.status, 200);
    // A web file is still only served to this server's own names.
    let rebound = request("GET", "/", &[("host", "evil.example:7878")], b"");
    assert_eq!(f.app.handle(rebound).await.status, 403);
}

#[tokio::test]
async fn foreign_hosts_and_origins_are_refused_even_with_the_token() {
    let f = fixture();
    // DNS rebinding: an attacker's name resolving to 127.0.0.1.
    let rebound = request(
        "POST",
        "/api/list_projects",
        &[("host", "evil.example:7878"), ("x-texlocal-token", TOKEN)],
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

    // Another loopback port is same-site, but not this server.
    let other_port = authed(
        "POST",
        "/api/list_projects",
        &[("origin", "http://127.0.0.1:9999")],
        b"",
    );
    assert_eq!(f.app.handle(other_port).await.status, 403);

    let same_site = authed(
        "POST",
        "/api/list_projects",
        &[("origin", "http://localhost:7878")],
        b"",
    );
    assert_eq!(f.app.handle(same_site).await.status, 200);
}

#[tokio::test]
async fn no_page_may_frame_the_app() {
    let f = fixture();
    let index = f.app.handle(authed("GET", "/", &[], b"")).await;
    assert_eq!(
        index.header("content-security-policy"),
        Some("frame-ancestors 'none'")
    );
    assert_eq!(index.header("x-frame-options"), Some("DENY"));
    // A project file keeps its sandbox, the stricter policy.
    let raw = f
        .app
        .handle(authed("GET", "/__raw/P/img/a.svg", &[], b""))
        .await;
    assert_eq!(
        raw.header("content-security-policy"),
        Some("sandbox; default-src 'none'")
    );
    assert_eq!(raw.header("x-frame-options"), Some("DENY"));
    // Refusals can still carry the first page's token-bearing URL.
    let refused = f
        .app
        .handle(request(
            "GET",
            "/?token=secret",
            &[("host", "evil.example")],
            b"",
        ))
        .await;
    assert_eq!(refused.status, 403);
    assert_eq!(refused.header("referrer-policy"), Some("no-referrer"));
    assert_eq!(refused.header("x-frame-options"), Some("DENY"));
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

    // A unit the server doesn't know is ignored, as RFC 9110 has it.
    let unknown = f
        .app
        .handle(authed(
            "GET",
            "/__raw/P/img/a.svg",
            &[("range", "items=0-1")],
            b"",
        ))
        .await;
    assert_eq!((unknown.status, unknown.body.len()), (200, 10));

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
    start_with(1024).await
}

async fn start_with(max_body: usize) -> (Fixture, u16) {
    let f = fixture();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let data = f._data.path().to_path_buf();
    let web = f._web.path().to_path_buf();
    let app = Arc::new(App::new(Service::new(data), web, port, TOKEN.into()));
    tokio::spawn(serve(app, listener, max_body, std::future::pending()));
    (f, port)
}

async fn connect(port: u16) -> tokio::net::TcpStream {
    tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap()
}

async fn read_response(stream: &mut (impl AsyncRead + Unpin)) -> String {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk).await.unwrap();
        buf.extend_from_slice(&chunk[..n]);
        let text = String::from_utf8_lossy(&buf).into_owned();
        if let Some(head_end) = text.find("\r\n\r\n") {
            let len: usize = text
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim())
                })
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

async fn assert_closed(stream: &mut tokio::net::TcpStream) {
    let mut byte = [0];
    let closed = tokio::time::timeout(std::time::Duration::from_secs(3), stream.read(&mut byte))
        .await
        .expect("the refused request kept its connection open");
    assert!(matches!(closed, Ok(0) | Err(_)), "{closed:?}");
}

#[tokio::test]
async fn an_absolute_form_target_is_routed_by_its_path() {
    let (_f, port) = start().await;
    let mut stream = connect(port).await;
    let req = format!(
        "GET http://127.0.0.1:{port}/__raw/P/img/a.svg HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX-TeXLocal-Token: {TOKEN}\r\n\r\n"
    );
    stream.write_all(req.as_bytes()).await.unwrap();
    let raw = read_response(&mut stream).await;
    assert!(raw.starts_with("HTTP/1.1 200 OK"), "{raw}");
    assert!(raw.ends_with("0123456789"), "{raw}");
}

#[tokio::test]
async fn one_connection_carries_several_requests_with_bodies() {
    let (_f, port) = start().await;
    let mut stream = connect(port).await;
    let head = format!("Host: 127.0.0.1:{port}\r\nX-TeXLocal-Token: {TOKEN}");

    let body = r#"{"id":"P","path":"main.tex"}"#;
    let post = format!(
        "POST /api/read_file HTTP/1.1\r\n{head}\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(post.as_bytes()).await.unwrap();
    let first = read_response(&mut stream).await;
    assert!(first.starts_with("HTTP/1.1 200 OK"), "{first}");
    assert!(!first.to_ascii_lowercase().contains("connection: close"));

    let get = format!("GET /__raw/P/img/a.svg HTTP/1.1\r\n{head}\r\n\r\n");
    stream.write_all(get.as_bytes()).await.unwrap();
    let second = read_response(&mut stream).await;
    assert!(second.starts_with("HTTP/1.1 200 OK"), "{second}");
    assert!(second.ends_with("0123456789"));
}

#[tokio::test]
async fn a_request_pipelined_behind_a_body_is_kept() {
    let (_f, port) = start().await;
    let mut stream = connect(port).await;
    let head = format!("Host: 127.0.0.1:{port}\r\nX-TeXLocal-Token: {TOKEN}");
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
    for (extra, expected) in [
        ("Content-Length: 5000", "413"),
        ("Transfer-Encoding: chunked", "501"),
        ("Content-Length: 5\r\nContent-Length: 6", "400"),
        ("Content-Length: +5", "400"),
    ] {
        let mut stream = connect(port).await;
        let req = format!(
            "POST /api/list_projects HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n{extra}\r\n\r\n"
        );
        stream.write_all(req.as_bytes()).await.unwrap();
        let response = read_response(&mut stream).await;
        assert!(
            response.starts_with(&format!("HTTP/1.1 {expected}")),
            "{response}"
        );
        assert_closed(&mut stream).await;
    }
}

/// The three refusals of `guard`, each with the token or Host it lacks.
fn unauthenticated_heads(port: u16) -> [(String, &'static str); 3] {
    let token = format!("X-TeXLocal-Token: {TOKEN}");
    [
        (format!("Host: evil.example:{port}\r\n{token}"), "403"),
        (
            format!("Host: 127.0.0.1:{port}\r\n{token}\r\nOrigin: https://evil.example"),
            "403",
        ),
        (format!("Host: 127.0.0.1:{port}"), "401"),
    ]
}

const BIG: usize = 64 << 20;

#[tokio::test]
async fn unauthenticated_requests_are_answered_before_their_bodies() {
    let (_f, port) = start_with(BIG).await;
    for (head, expected) in unauthenticated_heads(port) {
        // Only the head is sent: waiting for the body would time out.
        let mut stream = connect(port).await;
        let req =
            format!("POST /api/upload_file HTTP/1.1\r\n{head}\r\nContent-Length: {BIG}\r\n\r\n");
        stream.write_all(req.as_bytes()).await.unwrap();
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_response(&mut stream),
        )
        .await
        .expect("answered without waiting for the body");
        assert!(
            response.starts_with(&format!("HTTP/1.1 {expected}")),
            "{response}"
        );
        assert_closed(&mut stream).await;
    }
}

#[tokio::test]
async fn a_refused_upload_still_delivers_the_whole_response() {
    let (_f, port) = start_with(BIG).await;
    for (head, expected) in unauthenticated_heads(port) {
        let stream = connect(port).await;
        let (mut reader, mut writer) = stream.into_split();
        let req =
            format!("POST /api/upload_file HTTP/1.1\r\n{head}\r\nContent-Length: {BIG}\r\n\r\n");
        // The body keeps coming while the refusal is sent, as a browser's
        // upload does.
        let upload = tokio::spawn(async move {
            writer.write_all(req.as_bytes()).await.unwrap();
            let chunk = vec![b'x'; 1 << 20];
            let mut sent = 0;
            while sent < BIG && writer.write_all(&chunk).await.is_ok() {
                sent += chunk.len();
            }
            sent
        });
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            read_response(&mut reader),
        )
        .await
        .unwrap();
        assert!(
            response.starts_with(&format!("HTTP/1.1 {expected}")),
            "{response}"
        );
        let message = if expected == "401" {
            "Open the URL texlocal-server printed at startup"
        } else {
            "Forbidden"
        };
        assert!(response.contains(message), "{response}");

        // The server discards a bounded amount and closes, never taking the
        // whole body.
        let sent = tokio::time::timeout(std::time::Duration::from_secs(10), upload)
            .await
            .expect("the server closed the connection")
            .unwrap();
        assert!(sent < BIG, "the server read the whole body");
    }
}

#[tokio::test]
async fn refusals_without_a_pending_body_keep_the_connection() {
    let (_f, port) = start().await;
    let mut stream = connect(port).await;
    let host = format!("Host: 127.0.0.1:{port}");

    let bare = format!("POST /api/list_projects HTTP/1.1\r\n{host}\r\n\r\n");
    stream.write_all(bare.as_bytes()).await.unwrap();
    let refused = read_response(&mut stream).await;
    assert!(refused.starts_with("HTTP/1.1 401"), "{refused}");
    assert!(
        !refused.to_ascii_lowercase().contains("connection: close"),
        "{refused}"
    );

    // A small body arrives with its head, so it is skipped, not read.
    let token = format!("X-TeXLocal-Token: {TOKEN}");
    let foreign = format!(
        "POST /api/list_projects HTTP/1.1\r\n{host}\r\n{token}\r\n\
         Origin: https://evil.example\r\nContent-Length: 2\r\n\r\n{{}}"
    );
    stream.write_all(foreign.as_bytes()).await.unwrap();
    let refused = read_response(&mut stream).await;
    assert!(refused.starts_with("HTTP/1.1 403"), "{refused}");
    assert!(
        !refused.to_ascii_lowercase().contains("connection: close"),
        "{refused}"
    );

    let page = format!("GET /?token={TOKEN} HTTP/1.1\r\n{host}\r\n\r\n");
    stream.write_all(page.as_bytes()).await.unwrap();
    let page = read_response(&mut stream).await;
    assert!(page.starts_with("HTTP/1.1 200 OK"), "{page}");
    assert!(!page.contains("Set-Cookie"), "{page}");

    let body = r#"{"id":"P","path":"main.tex"}"#;
    let post = format!(
        "POST /api/read_file HTTP/1.1\r\n{host}\r\n{token}\r\n\
         Content-Length: {}\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(post.as_bytes()).await.unwrap();
    let read = read_response(&mut stream).await;
    assert!(read.starts_with("HTTP/1.1 200 OK"), "{read}");
    assert!(read.contains("documentclass"), "{read}");
}

#[tokio::test]
async fn a_head_sent_a_byte_at_a_time_is_still_read() {
    let (_f, port) = start().await;
    let mut stream = connect(port).await;
    stream.set_nodelay(true).unwrap();
    // With the empty line RFC 9112 lets a client send before a request.
    let req = format!(
        "\r\nGET /__raw/P/img/a.svg HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\
         X-TeXLocal-Token: {TOKEN}\r\n\r\n"
    );
    for byte in req.as_bytes() {
        stream.write_all(&[*byte]).await.unwrap();
        tokio::task::yield_now().await;
    }
    let response = read_response(&mut stream).await;
    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    assert!(response.ends_with("0123456789"), "{response}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_head_of_endless_blank_lines_is_cut_off() {
    let (_f, port) = start().await;
    let stream = connect(port).await;
    let (mut reader, mut writer) = stream.into_split();
    // Empty lines before a request are dropped, never growing the head
    // towards its size limit, so only the head's time limit ends them.
    let feed = tokio::spawn(async move {
        let blank = b"\r\n".repeat(4096);
        let until = tokio::time::Instant::now() + std::time::Duration::from_secs(20);
        while tokio::time::Instant::now() < until {
            if writer.write_all(&blank).await.is_err() {
                return;
            }
        }
    });
    let mut chunk = [0u8; 64];
    let closed = tokio::time::timeout(std::time::Duration::from_secs(15), reader.read(&mut chunk))
        .await
        .expect("the connection outlived the head's time limit");
    match closed {
        Ok(0) | Err(_) => {}
        Ok(n) => assert!(
            String::from_utf8_lossy(&chunk[..n]).starts_with("HTTP/1.1 431"),
            "{}",
            String::from_utf8_lossy(&chunk[..n])
        ),
    }
    feed.abort();
}

#[tokio::test]
async fn a_dribbling_body_has_one_deadline() {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let entered = Arc::new(tokio::sync::Notify::new());
    let seen = Arc::clone(&entered);
    tokio::spawn(texlocal_server::http::serve(
        listener,
        Arc::new(|_, ()| async { Response::text(200, "complete") }),
        Arc::new(move |_: &Request| {
            seen.notify_one();
            Ok(())
        }),
        100,
        std::future::pending::<()>(),
    ));
    let stream = connect(port).await;
    let (mut reader, mut writer) = stream.into_split();
    writer
        .write_all(b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nx")
        .await
        .unwrap();
    entered.notified().await;
    tokio::time::pause();
    let feed = tokio::spawn(async move {
        for _ in 0..5 {
            tokio::time::sleep(std::time::Duration::from_secs(20)).await;
            if writer.write_all(b"x").await.is_err() {
                return;
            }
        }
    });
    let response = tokio::time::timeout(
        std::time::Duration::from_secs(65),
        read_response(&mut reader),
    )
    .await
    .expect("body bytes extended the total deadline");
    assert!(response.starts_with("HTTP/1.1 408"), "{response}");
    feed.abort();
}
