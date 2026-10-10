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
    let handler = Arc::new(move |req, route| {
        let app = Arc::clone(&app);
        async move { app.route(req, route).await }
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
            Ok(route) => self.route(req, route).await,
            Err(refused) => refused,
        }
        .secured()
    }

    /// A request the guard has passed, where the guard found it goes.
    async fn route(&self, req: Request, route: Route) -> Response {
        match route {
            Route::Upload => self.upload(req).await,
            Route::Command(command) => self.api(command, req.body).await,
            Route::File(segments) => self.file(segments, req.header("range")).await,
            Route::Download(id, zip) => self.download(id, zip).await,
            Route::Asset(rel) => self.asset(rel).await,
            Route::NotFound => Response::text(404, "Not found"),
            Route::NotAllowed => Response::text(405, "Method not allowed"),
        }
    }

    /// Host, Origin and the token, from the request head alone: the server
    /// runs this before reading a body, so nobody unauthenticated can make it
    /// buffer one. A request let through comes with its route.
    pub fn guard(&self, req: &Request) -> Result<Route, Response> {
        if !req
            .header("host")
            .is_some_and(|h| self.hosts.iter().any(|a| a == h))
        {
            return Err(Response::text(403, "Forbidden host"));
        }
        // An Origin must be this server's own: http:// and one of its hosts.
        if let Some(origin) = req.header("origin") {
            let own = origin
                .strip_prefix("http://")
                .is_some_and(|host| self.hosts.iter().any(|a| a == host));
            if !matches!(req.method.as_str(), "GET" | "HEAD") && !own {
                return Err(Response::text(403, "Forbidden origin"));
            }
        }
        // Only the web UI's own files go without the token: they are the
        // same for everyone, and the page has to load before it can read the
        // token from its URL.
        let route = Route::of(&req.method, req.path());
        let token = req.header("x-texlocal-token");
        if matches!(route, Route::Asset(_)) || token.is_some_and(|t| same(t, &self.token)) {
            return Ok(route);
        }
        Err(Response::text(
            401,
            "Open the URL texlocal-server printed at startup",
        ))
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
    async fn file(&self, segments: Vec<String>, range: Option<&str>) -> Response {
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
    async fn asset(&self, rel: String) -> Response {
        let web_dir = Arc::clone(&self.web_dir);
        match self
            .blocking(move |_| {
                paths::safe_path(&web_dir, if rel.is_empty() { "index.html" } else { &rel })
            })
            .await
        {
            Ok(abs) => served(serve::respond(&abs, None, false).await),
            Err(_) => Response::text(404, "Not found"),
        }
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

/// Where a request goes, by its method and decoded path segments, so that
/// no spelling of a path (`/%5F%5Fraw/…`, `//__raw/…`) reads differently to
/// the guard and to the dispatch.
pub enum Route {
    Upload,
    Command(String),
    /// `__pdf/<id>` or `__raw/<id>/<rel…>`.
    File(Vec<String>),
    /// A project's id, and whether it's the zip (else the PDF).
    Download(String, bool),
    /// One of the web UI's files, by its path in the web directory.
    Asset(String),
    NotFound,
    NotAllowed,
}

impl Route {
    pub fn of(method: &str, path: &str) -> Self {
        let segments = segments(path);
        let read = matches!(method, "GET" | "HEAD");
        let post = method == "POST";
        let named = |i: usize| segments.get(i).map(String::as_str);
        match (named(0), named(1), segments.len()) {
            (Some("api"), Some("upload_file"), 2) if post => Route::Upload,
            (Some("api"), Some(_), _) if post => Route::Command(segments[1..].join("/")),
            (Some("__pdf" | "__raw"), Some(_), _) if read => Route::File(segments),
            (Some("__download"), Some(kind @ ("pdf" | "zip")), 3) if read => {
                Route::Download(segments[2].clone(), kind == "zip")
            }
            _ if !read => Route::NotAllowed,
            // Project routes' names are never the web UI's.
            (Some(first), _, _) if first == "api" || first.starts_with("__") => Route::NotFound,
            _ => Route::Asset(segments.join("/")),
        }
    }
}

fn served(file: serve::Served) -> Response {
    Response {
        status: file.status,
        headers: file.headers,
        body: file.body,
    }
}
