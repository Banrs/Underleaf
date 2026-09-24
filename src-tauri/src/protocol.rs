//! The `texlocal://` scheme, carrying the two routes the UI can't get through
//! a command: the compiled PDF (pdf.js fetches it as a URL) and raw project
//! files (image previews). Routing, ranges and MIME types live in
//! `texlocal_core::serve`, shared with the browser server; this is the Tauri
//! responder glue.

use std::borrow::Cow;

use percent_encoding::percent_decode_str;
use tauri::{http, Manager, Runtime, UriSchemeContext, UriSchemeResponder};
use texlocal_core::serve;

use crate::state::AppState;

pub const SCHEME: &str = "texlocal";

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
    let range_header = request
        .headers()
        .get(http::header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    // The path is all we otherwise read: the host differs by platform
    // (texlocal://localhost on macOS, http://texlocal.localhost on Windows).
    let segments: Vec<String> = request
        .uri()
        .path()
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|s| percent_decode_str(s).decode_utf8_lossy().into_owned())
        .collect();

    tauri::async_runtime::spawn(async move {
        let state = app.state::<AppState>();
        let resolved = match serve::resolve(&state.service, &segments) {
            Ok(v) => v,
            Err(e) => {
                responder.respond(error(e.status, &e.message));
                return;
            }
        };

        let len = match tokio::fs::metadata(&resolved.path).await {
            Ok(meta) if meta.is_file() => meta.len(),
            _ => {
                responder.respond(error(404, "Not found"));
                return;
            }
        };
        let range = match range_header.as_deref() {
            Some(header) => match serve::parse_range(header, len) {
                Ok(value) => value,
                Err(serve::Unsatisfiable) => {
                    let response = http::Response::builder()
                        .status(416)
                        .header("Content-Range", format!("bytes */{len}"))
                        .body(Cow::Borrowed(&b"Range not satisfiable"[..]))
                        .expect("static range error");
                    responder.respond(response);
                    return;
                }
            },
            None => None,
        };

        let bytes = match serve::read_file_range(&resolved.path, range).await {
            Ok(value) => value,
            Err(_) => {
                responder.respond(error(404, "Not found"));
                return;
            }
        };

        let mut builder = http::Response::builder()
            .status(if range.is_some() { 206 } else { 200 })
            .header("Content-Type", serve::mime_for(&resolved.path))
            .header("Cache-Control", "no-store")
            .header("Accept-Ranges", "bytes")
            .header("Content-Length", bytes.len().to_string())
            // The page is served from the app protocol, so these responses are
            // cross-origin to it; pdf.js and <img> both need this to load them.
            .header("Access-Control-Allow-Origin", "*");
        if let Some((start, end)) = range {
            builder = builder.header("Content-Range", format!("bytes {start}-{end}/{len}"));
        }
        if resolved.sandboxed {
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
