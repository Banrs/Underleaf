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
use std::time::UNIX_EPOCH;

use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};
use serde_json::{json, Value};
use texlocal_core::service::{Service, UPLOAD_MAX_BYTES};
use texlocal_core::{paths, serve, zipexport, CoreError};

pub use http::{Bytes, Request, Response};
use tokio::net::TcpListener;

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
    let service = Arc::clone(&app.service);
    // The transport has run the guard and secures every response itself.
    let handler = Arc::new(move |req| {
        let app = Arc::clone(&app);
        async move { app.route(req).await }
    });
    http::serve(listener, handler, guard, max_body, shutdown).await;
    service.texpresso.kill_all();
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

    /// A whole request, guard and all. `serve` runs the guard on the head
    /// before reading the body, then `route`.
    pub async fn handle(&self, req: Request) -> Response {
        match self.guard(&req) {
            Some(refused) => refused,
            None => self.route(req).await,
        }
        .secured()
    }

    /// A request the guard has passed.
    async fn route(&self, req: Request) -> Response {
        let path = req.path();
        let read = matches!(req.method.as_str(), "GET" | "HEAD");
        if req.method == "POST" && path == "/api/upload_file" {
            self.upload(req).await
        } else if let Some(command) = path.strip_prefix("/api/").filter(|_| req.method == "POST") {
            self.api(decode(command), req.body.clone()).await
        } else if read && (path.starts_with("/__pdf/") || path.starts_with("/__raw/")) {
            self.file(path, req.header("range")).await
        } else if let Some(id) = path.strip_prefix("/__download/pdf/").filter(|_| read) {
            self.download(decode(id), false).await
        } else if let Some(id) = path.strip_prefix("/__download/zip/").filter(|_| read) {
            self.download(decode(id), true).await
        } else if read {
            self.asset(path, req.header("if-none-match")).await
        } else {
            Response::text(405, "Method not allowed")
        }
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

        // Only reads of the web UI's own files go without the token: they
        // are the same for everyone, and the page has to load before it can
        // read the token from its URL. Every other method needs it, and so
        // does every path whose first segment, decoded, is a project route's
        // (`/%5F%5Fraw/…` and `//__raw/…` as much as `/__raw/…`).
        let first = req.path().split('/').find(|s| !s.is_empty()).map(decode);
        if safe_method && first.is_none_or(|first| first != "api" && !first.starts_with("__")) {
            return None;
        }
        if !req
            .header("x-texlocal-token")
            .is_some_and(|t| same(t, &self.token))
        {
            return Some(Response::text(
                401,
                "Open the URL texlocal-server printed at startup",
            ));
        }
        None
    }

    /// Keep disk work off the async workers, including PDF range fetches.
    async fn blocking<T: Send + 'static>(
        &self,
        work: impl FnOnce(&Service) -> Result<T, CoreError> + Send + 'static,
    ) -> Result<T, CoreError> {
        let service = Arc::clone(&self.service);
        tokio::task::spawn_blocking(move || work(&service))
            .await
            .unwrap_or_else(|_| Err(CoreError::internal("The request panicked")))
    }

    /// The JSON is read and written on the blocking pool too: a whole
    /// document's save or read can be tens of megabytes.
    async fn api(&self, command: String, body: Bytes) -> Response {
        // A command may mix blocking file work with async process work, so
        // the blocking thread drives it to completion on the runtime's handle.
        let runtime = tokio::runtime::Handle::current();
        self.blocking(move |service| {
            let args: Value = if body.is_empty() {
                json!({})
            } else {
                serde_json::from_slice(&body)
                    .map_err(|e| CoreError::bad_request(format!("Invalid JSON: {e}")))?
            };
            let value = runtime.block_on(service.call(&command, &args))?;
            Ok(value.to_string())
        })
        .await
        .map_or_else(error, |json| Response::new(200, "application/json", json))
    }

    /// One file per request, body raw, metadata percent-encoded in headers —
    /// `X-Replace: true` moves an entry in its place to the Trash.
    async fn upload(&self, req: Request) -> Response {
        self.blocking(move |service| {
            let header = |name: &str| {
                req.header(name)
                    .map(decode)
                    .ok_or_else(|| CoreError::bad_request(format!("Missing {name} header")))
            };
            service.upload_file(
                &header("x-project")?,
                &header("x-dir")?,
                &header("x-path")?,
                &req.body,
                req.header("x-replace") == Some("true"),
            )
        })
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
    /// files, so a crafted path cannot leave the web directory. The browser
    /// revalidates each (`no-cache`) by an ETag of its length and modified
    /// time: an unchanged file costs a stat and a 304, and a rebuild shows
    /// on the next load.
    async fn asset(&self, path: &str, if_none_match: Option<&str>) -> Response {
        let rel = segments(path).join("/");
        let web_dir = Arc::clone(&self.web_dir);
        let Ok((abs, tag)) = self
            .blocking(move |_| {
                let abs =
                    paths::safe_path(&web_dir, if rel.is_empty() { "index.html" } else { &rel })?;
                // Taken before the read, so the tag is never newer than the body.
                let meta = std::fs::metadata(&abs)?;
                let modified = meta
                    .modified()?
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default();
                Ok((
                    abs,
                    format!("W/\"{:x}-{:x}\"", meta.len(), modified.as_nanos()),
                ))
            })
            .await
        else {
            return Response::text(404, "Not found");
        };
        // Weak comparison, as RFC 9110 has it for If-None-Match.
        let opaque = |t: &str| t.trim().trim_start_matches("W/").to_owned();
        if if_none_match
            .is_some_and(|h| h.trim() == "*" || h.split(',').any(|t| opaque(t) == opaque(&tag)))
        {
            let unchanged = Response {
                status: 304,
                headers: vec![("Cache-Control", "no-cache".into())],
                body: vec![],
            };
            return unchanged.with("ETag", tag);
        }
        let mut response = served(serve::respond(&abs, None, false).await);
        if response.status == 200 {
            for (name, value) in &mut response.headers {
                if *name == "Cache-Control" {
                    *value = "no-cache".into();
                }
            }
            response = response.with("ETag", tag);
        }
        response
    }

    async fn download(&self, id: String, zip: bool) -> Response {
        let (ext, mime) = if zip {
            ("zip", "application/zip")
        } else {
            ("pdf", "application/pdf")
        };
        let name = format!("{id}.{ext}");
        self.blocking(move |service| {
            if !zip {
                return std::fs::read(service.pdf_path(&id)?)
                    .map_err(|_| CoreError::not_found("No compiled PDF yet"));
            }
            let root = service.project_root(&id)?;
            let dir = tempfile::tempdir()?;
            let dest = dir.path().join("export.zip");
            zipexport::export_zip(&root, &dest)?;
            Ok(std::fs::read(dest)?)
        })
        .await
        .map_or_else(error, |bytes| {
            let encoded = utf8_percent_encode(&name, NON_ALPHANUMERIC);
            Response::new(200, mime, bytes).with(
                "Content-Disposition",
                format!("attachment; filename*=UTF-8''{encoded}"),
            )
        })
    }
}

fn served(file: serve::Served) -> Response {
    Response {
        status: file.status,
        headers: file.headers,
        body: file.body,
    }
}
