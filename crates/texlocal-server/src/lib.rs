//! TeXLocal in a browser: the web UI plus an HTTP adapter over
//! `texlocal_core::service`. Loopback only, and every request must carry the
//! token printed at startup. That is not optional hardening: a project can turn
//! on `-shell-escape`, so anything that can reach `/api/compile` can run
//! commands as this user. The Host check stops DNS rebinding, and the Origin
//! check and SameSite cookie stop another site's page from driving the API.

pub mod http;

use std::path::{Path, PathBuf};

use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};
use serde_json::{json, Value};
use texlocal_core::service::{Service, UPLOAD_MAX_BYTES};
use texlocal_core::{paths, serve, zipexport, CoreError};

pub use http::{Request, Response};

const COOKIE: &str = "texlocal_token";
/// Uploads and whole documents travel in one body.
pub const MAX_BODY: usize = UPLOAD_MAX_BYTES + 1024 * 1024;

pub struct App {
    pub service: Service,
    web_dir: PathBuf,
    token: String,
    hosts: [String; 2],
    origins: [String; 2],
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

impl App {
    /// `port` is the one actually bound: Host and Origin are checked against it.
    pub fn new(service: Service, web_dir: PathBuf, port: u16, token: String) -> Self {
        Self {
            service,
            web_dir,
            token,
            hosts: [format!("127.0.0.1:{port}"), format!("localhost:{port}")],
            origins: [
                format!("http://127.0.0.1:{port}"),
                format!("http://localhost:{port}"),
            ],
        }
    }

    pub async fn handle(&self, req: Request) -> Response {
        if let Some(refused) = self.guard(&req) {
            return refused;
        }
        let path = req.path().to_string();
        let read = matches!(req.method.as_str(), "GET" | "HEAD");
        let response = if req.method == "POST" && path == "/api/upload_file" {
            self.upload(&req)
        } else if let Some(command) = path.strip_prefix("/api/").filter(|_| req.method == "POST") {
            self.api(&decode(command), &req.body).await
        } else if read && (path.starts_with("/__pdf/") || path.starts_with("/__raw/")) {
            self.file(&path, req.header("range")).await
        } else if let Some(id) = path.strip_prefix("/__download/pdf/").filter(|_| read) {
            self.download_pdf(&decode(id))
        } else if let Some(id) = path.strip_prefix("/__download/zip/").filter(|_| read) {
            self.download_zip(&decode(id))
        } else if read {
            self.asset(&path).await
        } else {
            Response::text(405, "Method not allowed")
        };
        response.with("X-Content-Type-Options", "nosniff")
    }

    // ---------- access ----------

    fn guard(&self, req: &Request) -> Option<Response> {
        if !req
            .header("host")
            .is_some_and(|h| self.hosts.iter().any(|a| a == h))
        {
            return Some(Response::text(403, "Forbidden host"));
        }
        let safe_method = matches!(req.method.as_str(), "GET" | "HEAD");
        if let Some(origin) = req.header("origin") {
            if !safe_method && !self.origins.iter().any(|a| a == origin) {
                return Some(Response::text(403, "Forbidden origin"));
            }
        }

        // The printed URL carries the token once; trade it for a cookie and
        // drop it from the address bar.
        let offered = req
            .query()
            .and_then(|q| q.split('&').find_map(|p| p.strip_prefix("token=")));
        if let Some(offered) = offered {
            if !same(offered, &self.token) {
                return Some(Response::text(401, "Wrong token"));
            }
            return Some(Response::text(303, "").with("Location", req.path()).with(
                "Set-Cookie",
                format!("{COOKIE}={}; HttpOnly; SameSite=Strict; Path=/", self.token),
            ));
        }

        let cookie = req
            .headers
            .iter()
            .filter(|(n, _)| n == "cookie")
            .flat_map(|(_, v)| v.split(';'))
            .find_map(|pair| pair.trim().strip_prefix(COOKIE)?.strip_prefix('='));
        if !cookie.is_some_and(|t| same(t, &self.token)) {
            return Some(Response::text(
                401,
                "Open the URL texlocal-server printed at startup",
            ));
        }
        None
    }

    // ---------- commands ----------

    async fn api(&self, command: &str, body: &[u8]) -> Response {
        let args: Value = if body.is_empty() {
            json!({})
        } else {
            match serde_json::from_slice(body) {
                Ok(v) => v,
                Err(e) => return error(CoreError::bad_request(format!("Invalid JSON: {e}"))),
            }
        };
        match self.service.call(command, &args).await {
            Ok(value) => Response::json(200, &value),
            Err(e) => error(e),
        }
    }

    /// One file per request, body raw, metadata percent-encoded in headers —
    /// the same shape as the desktop's `upload_file` invoke.
    fn upload(&self, req: &Request) -> Response {
        let header = |name: &str| {
            req.header(name)
                .map(decode)
                .ok_or_else(|| CoreError::bad_request(format!("Missing {name} header")))
        };
        let saved = (|| {
            self.service.upload_file(
                &header("x-project")?,
                &header("x-dir")?,
                &header("x-path")?,
                &req.body,
            )
        })();
        match saved {
            Ok(rel) => Response::json(200, &json!({ "saved": [rel] })),
            Err(e) => error(e),
        }
    }

    // ---------- files ----------

    async fn file(&self, path: &str, range: Option<&str>) -> Response {
        match serve::resolve(&self.service, &segments(path)) {
            Ok(resolved) => {
                let response = send_file(&resolved.path, range).await;
                if resolved.sandboxed {
                    // A project file must never execute as a document.
                    response.with("Content-Security-Policy", "sandbox; default-src 'none'")
                } else {
                    response
                }
            }
            Err(e) => Response::text(e.status, &e.message),
        }
    }

    /// The web UI. Its files go through the same lexical boundary as project
    /// files, so a crafted path cannot leave the web directory.
    async fn asset(&self, path: &str) -> Response {
        let rel = segments(path).join("/");
        let rel = if rel.is_empty() {
            "index.html".into()
        } else {
            rel
        };
        match paths::safe_path(&self.web_dir, &rel) {
            Ok(abs) => send_file(&abs, None).await,
            Err(_) => Response::text(404, "Not found"),
        }
    }

    fn download_pdf(&self, id: &str) -> Response {
        let bytes = self.service.pdf_path(id).and_then(|pdf| {
            std::fs::read(pdf).map_err(|_| CoreError::not_found("No compiled PDF yet"))
        });
        match bytes {
            Ok(bytes) => attachment(bytes, &format!("{id}.pdf"), "application/pdf"),
            Err(e) => error(e),
        }
    }

    fn download_zip(&self, id: &str) -> Response {
        let build = |root: &Path| -> Result<Vec<u8>, CoreError> {
            let dir = tempfile::tempdir()?;
            let dest = dir.path().join("export.zip");
            zipexport::export_zip(root, &dest)?;
            Ok(std::fs::read(dest)?)
        };
        match self.service.project_root(id).and_then(|root| build(&root)) {
            Ok(bytes) => attachment(bytes, &format!("{id}.zip"), "application/zip"),
            Err(e) => error(e),
        }
    }
}

async fn send_file(path: &Path, range: Option<&str>) -> Response {
    let len = match tokio::fs::metadata(path).await {
        Ok(meta) if meta.is_file() => meta.len(),
        _ => return Response::text(404, "Not found"),
    };
    let range = match range.map(|h| serve::parse_range(h, len)) {
        Some(Ok(r)) => r,
        Some(Err(serve::Unsatisfiable)) => {
            return Response::text(416, "Range not satisfiable")
                .with("Content-Range", format!("bytes */{len}"))
        }
        None => None,
    };
    let Ok(bytes) = serve::read_file_range(path, range).await else {
        return Response::text(404, "Not found");
    };
    let response = Response::new(
        if range.is_some() { 206 } else { 200 },
        serve::mime_for(path),
        bytes,
    )
    .with("Cache-Control", "no-store")
    .with("Accept-Ranges", "bytes");
    match range {
        Some((start, end)) => response.with("Content-Range", format!("bytes {start}-{end}/{len}")),
        None => response,
    }
}

fn attachment(bytes: Vec<u8>, name: &str, mime: &str) -> Response {
    let encoded = utf8_percent_encode(name, NON_ALPHANUMERIC);
    Response::new(200, mime, bytes).with(
        "Content-Disposition",
        format!("attachment; filename*=UTF-8''{encoded}"),
    )
}
