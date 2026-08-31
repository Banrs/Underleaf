//! The `texlocal://` scheme, carrying the two routes the UI can't get through
//! a command: the compiled PDF (pdf.js fetches it as a URL) and raw project
//! files (image previews). Ported from the protocol handler in
//! electron/main.mjs, minus the static-asset route — Tauri's own app protocol
//! serves `web/` now.

use std::borrow::Cow;

use std::path::PathBuf;

use percent_encoding::percent_decode_str;
use tauri::{http, Manager, Runtime, UriSchemeContext, UriSchemeResponder};
use texlocal_core::{paths, settings};

use crate::state::AppState;

pub const SCHEME: &str = "texlocal";

fn mime_for(path: &std::path::Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_lowercase)
        .as_deref()
    {
        Some("html") => "text/html",
        Some("css") => "text/css",
        Some("js") | Some("mjs") => "text/javascript",
        Some("map") | Some("json") => "application/json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        Some("ico") => "image/x-icon",
        Some("pdf") => "application/pdf",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn error(status: u16, message: &str) -> http::Response<Cow<'static, [u8]>> {
    http::Response::builder()
        .status(status)
        .header("Content-Type", "text/plain")
        .body(Cow::Owned(message.as_bytes().to_vec()))
        .expect("static error response")
}

pub fn handle<R: Runtime>(
    ctx: UriSchemeContext<'_, R>,
    request: http::Request<Vec<u8>>,
    responder: UriSchemeResponder,
) {
    let app = ctx.app_handle().clone();
    // The path is all we read: the host differs by platform (texlocal://localhost
    // on macOS, http://texlocal.localhost on Windows) and the query is only ever
    // the cache-busting ?t= stamp.
    let segments: Vec<String> = request
        .uri()
        .path()
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|s| percent_decode_str(s).decode_utf8_lossy().into_owned())
        .collect();

    tauri::async_runtime::spawn(async move {
        let state = app.state::<AppState>();
        // (file to serve, whether it is untrusted project content)
        let resolved: Result<(PathBuf, bool), (u16, String)> =
            match segments.first().map(String::as_str) {
                Some("__pdf") => {
                    let id = segments.get(1).map(String::as_str).unwrap_or_default();
                    paths::project_root(&state.data_dir, id)
                        .and_then(|root| settings::compiled_pdf_path(&root))
                        .map(|pdf| (pdf, false))
                        .map_err(|e| (e.status, e.message))
                }
                Some("__raw") => {
                    let id = segments.get(1).map(String::as_str).unwrap_or_default();
                    let rel = segments.get(2..).unwrap_or_default().join("/");
                    paths::project_root(&state.data_dir, id)
                        .and_then(|root| paths::safe_path(&root, &rel))
                        .map(|abs| (abs, true))
                        .map_err(|e| (e.status, e.message))
                }
                _ => Err((404, "Not found".to_string())),
            };

        let (abs, sandboxed) = match resolved {
            Ok(v) => v,
            Err((status, message)) => {
                responder.respond(error(status, &message));
                return;
            }
        };

        let bytes = match tokio::fs::read(&abs).await {
            Ok(b) => b,
            Err(_) => {
                responder.respond(error(404, "Not found"));
                return;
            }
        };

        let mut builder = http::Response::builder()
            .status(200)
            .header("Content-Type", mime_for(&abs))
            .header("Cache-Control", "no-store")
            // The page is served from the app protocol, so these responses are
            // cross-origin to it; pdf.js and <img> both need this to load them.
            .header("Access-Control-Allow-Origin", "*");
        if sandboxed {
            // A project file must never execute as a document.
            builder = builder
                .header("Content-Security-Policy", "sandbox; default-src 'none'")
                .header("X-Content-Type-Options", "nosniff");
        }

        match builder.body(Cow::Owned(bytes)) {
            Ok(response) => responder.respond(response),
            Err(err) => responder.respond(error(500, &err.to_string())),
        }
    });
}
