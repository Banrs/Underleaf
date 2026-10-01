//! TeXLocal in a browser: the web UI plus an HTTP adapter over
//! `texlocal_core::service`. Loopback only, and every request must carry the
//! token printed at startup. That is not optional hardening: a project can turn
//! on `-shell-escape`, so anything that can reach `/api/compile` can run
//! commands as this user. The Host check stops DNS rebinding, and the Origin
//! check stops another site's page from driving the API.
//!
//! The token travels in an `X-TeXLocal-Token` header, never a cookie: cookies
//! ignore ports, so one would also go to every other service on 127.0.0.1,
//! another account's among them. The page keeps the token from its first
//! URL in sessionStorage, which is per origin and so per port. The web UI's
//! own files hold no data and stay open, so that page can load to read it.

pub mod http;

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};
use serde_json::{json, Value};
use texlocal_core::service::{Service, UPLOAD_MAX_BYTES};
use texlocal_core::{paths, serve, zipexport, CoreError};

pub use http::{Request, Response};
use tokio::net::TcpListener;

/// The header every request for project data carries the token in.
const TOKEN_HEADER: &str = "x-texlocal-token";
/// Uploads and whole documents travel in one body.
pub const MAX_BODY: usize = UPLOAD_MAX_BYTES + 1024 * 1024;

pub struct App {
    pub service: Arc<Service>,
    web_dir: Arc<Path>,
    token: String,
    hosts: [String; 2],
}

/// 32 random bytes as hex.
pub fn new_token() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("the OS random source is available");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn same(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes()
            .zip(b.bytes())
            .fold(0, |acc, (x, y)| acc | (x ^ y))
            == 0
}

fn decode(segment: &str) -> String {
    percent_decode_str(segment).decode_utf8_lossy().into_owned()
}

fn segments(path: &str) -> Vec<String> {
    path.split('/')
        .filter(|s| !s.is_empty())
        .map(decode)
        .collect()
}

fn error(err: CoreError) -> Response {
    Response::json(err.status, &json!({ "error": err.message }))
}

/// Serve `app` on `listener` until `shutdown` resolves, running its guard on
/// each request head before any body is read.
pub async fn serve(
    app: Arc<App>,
    listener: TcpListener,
    max_body: usize,
    shutdown: impl Future<Output = ()>,
) {
    let guard = {
        let app = Arc::clone(&app);
        Arc::new(move |req: &Request| app.guard(req))
    };
    let handler = Arc::new(move |req| {
        let app = Arc::clone(&app);
        async move { app.handle(req).await }
    });
    http::serve(listener, handler, guard, max_body, shutdown).await
}

impl App {
    /// `port` is the one actually bound: Host and Origin are checked against it.
    pub fn new(service: Service, web_dir: PathBuf, port: u16, token: String) -> Self {
        Self {
            service: Arc::new(service),
            web_dir: web_dir.into(),
            token,
            hosts: [format!("127.0.0.1:{port}"), format!("localhost:{port}")],
        }
    }

    pub async fn handle(&self, req: Request) -> Response {
        // `http::serve` has already run the guard on the head, before reading
        // the body; it runs again for anyone handing a whole request in.
        if let Some(refused) = self.guard(&req) {
            return refused.secured();
        }
        let path = req.path().to_string();
        let read = matches!(req.method.as_str(), "GET" | "HEAD");
        let response = if req.method == "POST" && path == "/api/upload_file" {
            self.upload(req).await
        } else if let Some(command) = path.strip_prefix("/api/").filter(|_| req.method == "POST") {
            self.api(decode(command), &req.body).await
        } else if read && (path.starts_with("/__pdf/") || path.starts_with("/__raw/")) {
            self.file(&path, req.header("range")).await
        } else if let Some(id) = path.strip_prefix("/__download/pdf/").filter(|_| read) {
            self.download_pdf(decode(id)).await
        } else if let Some(id) = path.strip_prefix("/__download/zip/").filter(|_| read) {
            self.download_zip(decode(id)).await
        } else if read {
            self.asset(&path).await
        } else {
            Response::text(405, "Method not allowed")
        };
        response.secured()
    }

    /// Host, Origin and the token, from the request head alone: the server
    /// runs this before reading a body, so nobody unauthenticated can make it
    /// buffer one.
    pub fn guard(&self, req: &Request) -> Option<Response> {
        if !req
            .header("host")
            .is_some_and(|h| self.hosts.iter().any(|a| a == h))
        {
            return Some(Response::text(403, "Forbidden host"));
        }
        let safe_method = matches!(req.method.as_str(), "GET" | "HEAD");
        // An Origin must be this server's own: http:// and one of its hosts.
        if let Some(origin) = req.header("origin") {
            let own = origin
                .strip_prefix("http://")
                .is_some_and(|host| self.hosts.iter().any(|a| a == host));
            if !safe_method && !own {
                return Some(Response::text(403, "Forbidden origin"));
            }
        }

        // Only the routes that reach projects need the token. The web UI's
        // files are the same for everyone, and the page has to load before
        // it can read the token from its URL.
        let path = req.path();
        if !(path.starts_with("/api/") || path.starts_with("/__")) {
            return None;
        }
        if !req
            .header(TOKEN_HEADER)
            .is_some_and(|t| same(t, &self.token))
        {
            return Some(Response::text(
                401,
                "Open the URL texlocal-server printed at startup",
            ));
        }
        None
    }

    /// Run file-system work (tree walks, searches, whole-file reads and writes,
    /// ZIP builds) on the blocking pool, so a large project cannot stall the
    /// async workers every other request, pdf.js's range fetches included,
    /// waits on.
    async fn blocking<T: Send + 'static>(
        &self,
        work: impl FnOnce(&Service) -> Result<T, CoreError> + Send + 'static,
    ) -> Result<T, CoreError> {
        let service = Arc::clone(&self.service);
        tokio::task::spawn_blocking(move || work(&service))
            .await
            .unwrap_or_else(|_| Err(CoreError::internal("The request panicked")))
    }

    async fn api(&self, command: String, body: &[u8]) -> Response {
        let args: Value = if body.is_empty() {
            json!({})
        } else {
            match serde_json::from_slice(body) {
                Ok(v) => v,
                Err(e) => return error(CoreError::bad_request(format!("Invalid JSON: {e}"))),
            }
        };
        // A command may mix blocking file work with async process work, so
        // the blocking thread drives it to completion on the runtime's handle.
        let runtime = tokio::runtime::Handle::current();
        self.blocking(move |service| runtime.block_on(service.call(&command, &args)))
            .await
            .map_or_else(error, |value| Response::json(200, &value))
    }

    /// One file per request, body raw, metadata percent-encoded in headers —
    /// the same shape as Tauri's `upload_file` invoke; `X-Replace: true`
    /// moves an entry in its place to the Trash.
    async fn upload(&self, req: Request) -> Response {
        let header = |name: &str| {
            req.header(name)
                .map(decode)
                .ok_or_else(|| CoreError::bad_request(format!("Missing {name} header")))
        };
        let names = (|| Ok((header("x-project")?, header("x-dir")?, header("x-path")?)))();
        let (id, dir, path) = match names {
            Ok(names) => names,
            Err(e) => return error(e),
        };
        // The answer to Replace in the host's Replace / Keep Both / Stop.
        let replace = req.header("x-replace") == Some("true");
        let body = req.body;
        self.blocking(move |service| service.upload_file(&id, &dir, &path, &body, replace))
            .await
            .map_or_else(error, |rel| Response::json(200, &json!({ "saved": [rel] })))
    }

    /// Path resolution runs on the blocking pool with everything else that
    /// touches the disk.
    async fn file(&self, path: &str, range: Option<&str>) -> Response {
        let segments = segments(path);
        match self
            .blocking(move |service| serve::resolve(service, &segments))
            .await
        {
            Ok(resolved) => served(serve::respond(&resolved.path, range, resolved.sandboxed).await),
            Err(e) => Response::text(e.status, &e.message),
        }
    }

    /// The web UI. Its files go through the same lexical boundary as project
    /// files, so a crafted path cannot leave the web directory.
    async fn asset(&self, path: &str) -> Response {
        let rel = segments(path).join("/");
        let web_dir = Arc::clone(&self.web_dir);
        let located = tokio::task::spawn_blocking(move || {
            let rel = if rel.is_empty() { "index.html" } else { &rel };
            paths::safe_path(&web_dir, rel).ok()
        })
        .await;
        match located {
            Ok(Some(abs)) => served(serve::respond(&abs, None, false).await),
            _ => Response::text(404, "Not found"),
        }
    }

    async fn download_pdf(&self, id: String) -> Response {
        let name = format!("{id}.pdf");
        self.blocking(move |service| {
            let pdf = service.pdf_path(&id)?;
            std::fs::read(pdf).map_err(|_| CoreError::not_found("No compiled PDF yet"))
        })
        .await
        .map_or_else(error, |bytes| attachment(bytes, &name, "application/pdf"))
    }

    async fn download_zip(&self, id: String) -> Response {
        let name = format!("{id}.zip");
        self.blocking(move |service| {
            let root = service.project_root(&id)?;
            let dir = tempfile::tempdir()?;
            let dest = dir.path().join("export.zip");
            zipexport::export_zip(&root, &dest)?;
            Ok(std::fs::read(dest)?)
        })
        .await
        .map_or_else(error, |bytes| attachment(bytes, &name, "application/zip"))
    }
}

fn served(file: serve::Served) -> Response {
    Response {
        status: file.status,
        headers: file.headers,
        body: file.body,
    }
}

fn attachment(bytes: Vec<u8>, name: &str, mime: &str) -> Response {
    let encoded = utf8_percent_encode(name, NON_ALPHANUMERIC);
    Response::new(200, mime, bytes).with(
        "Content-Disposition",
        format!("attachment; filename*=UTF-8''{encoded}"),
    )
}
