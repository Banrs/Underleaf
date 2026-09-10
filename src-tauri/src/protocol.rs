//! The `texlocal://` scheme, carrying the two routes the UI can't get through
//! a command: the compiled PDF (pdf.js fetches it as a URL) and raw project
//! files (image previews).

use std::borrow::Cow;
use std::io::SeekFrom;
use std::path::{Path, PathBuf};

use percent_encoding::percent_decode_str;
use tauri::{http, Manager, Runtime, UriSchemeContext, UriSchemeResponder};
use texlocal_core::{paths, settings};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::state::AppState;

pub const SCHEME: &str = "texlocal";

fn mime_for(path: &Path) -> &'static str {
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

// A single RFC 7233 byte range. pdf.js uses this to fetch large PDFs in chunks;
// suffix and open-ended forms are included because WebView engines may choose
// either. Multiple ranges would need multipart/byteranges and are rejected.
fn parse_range(header: &str, len: u64) -> Result<Option<(u64, u64)>, ()> {
    let Some(spec) = header.strip_prefix("bytes=") else {
        return Err(());
    };
    if len == 0 || spec.contains(',') {
        return Err(());
    }
    let Some((start, end)) = spec.split_once('-') else {
        return Err(());
    };

    if start.is_empty() {
        let suffix = end.parse::<u64>().map_err(|_| ())?;
        if suffix == 0 {
            return Err(());
        }
        let take = suffix.min(len);
        return Ok(Some((len - take, len - 1)));
    }

    let start = start.parse::<u64>().map_err(|_| ())?;
    if start >= len {
        return Err(());
    }
    let end = if end.is_empty() {
        len - 1
    } else {
        end.parse::<u64>().map_err(|_| ())?.min(len - 1)
    };
    if end < start {
        return Err(());
    }
    Ok(Some((start, end)))
}

async fn read_file_range(
    path: &Path,
    range: Option<(u64, u64)>,
) -> std::io::Result<(Vec<u8>, u64)> {
    let mut file = tokio::fs::File::open(path).await?;
    let len = file.metadata().await?.len();
    match range {
        Some((start, end)) => {
            file.seek(SeekFrom::Start(start)).await?;
            let count = end - start + 1;
            let size = usize::try_from(count)
                .map_err(|_| std::io::Error::other("requested range is too large"))?;
            let mut bytes = vec![0; size];
            file.read_exact(&mut bytes).await?;
            Ok((bytes, len))
        }
        None => {
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes).await?;
            Ok((bytes, len))
        }
    }
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

        let len = match tokio::fs::metadata(&abs).await {
            Ok(meta) if meta.is_file() => meta.len(),
            _ => {
                responder.respond(error(404, "Not found"));
                return;
            }
        };
        let range = match range_header.as_deref() {
            Some(header) => match parse_range(header, len) {
                Ok(value) => value,
                Err(()) => {
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

        let (bytes, _) = match read_file_range(&abs, range).await {
            Ok(value) => value,
            Err(_) => {
                responder.respond(error(404, "Not found"));
                return;
            }
        };

        let mut builder = http::Response::builder()
            .status(if range.is_some() { 206 } else { 200 })
            .header("Content-Type", mime_for(&abs))
            .header("Cache-Control", "no-store")
            .header("Accept-Ranges", "bytes")
            .header("Content-Length", bytes.len().to_string())
            // The page is served from the app protocol, so these responses are
            // cross-origin to it; pdf.js and <img> both need this to load them.
            .header("Access-Control-Allow-Origin", "*");
        if let Some((start, end)) = range {
            builder = builder.header("Content-Range", format!("bytes {start}-{end}/{len}"));
        }
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

#[cfg(test)]
mod tests {
    use super::parse_range;

    #[test]
    fn parses_closed_open_and_suffix_ranges() {
        assert_eq!(parse_range("bytes=10-19", 100), Ok(Some((10, 19))));
        assert_eq!(parse_range("bytes=90-", 100), Ok(Some((90, 99))));
        assert_eq!(parse_range("bytes=-10", 100), Ok(Some((90, 99))));
        assert_eq!(parse_range("bytes=90-200", 100), Ok(Some((90, 99))));
    }

    #[test]
    fn rejects_invalid_or_unsatisfiable_ranges() {
        assert!(parse_range("items=0-1", 100).is_err());
        assert!(parse_range("bytes=100-", 100).is_err());
        assert!(parse_range("bytes=20-10", 100).is_err());
        assert!(parse_range("bytes=0-1,4-5", 100).is_err());
        assert!(parse_range("bytes=-0", 100).is_err());
    }
}
