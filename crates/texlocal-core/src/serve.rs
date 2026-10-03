// Serving project files as URLs: the compiled PDF (pdf.js fetches it in
// ranges) and raw project files (image previews). Shared by every host that
// serves them — Tauri's texlocal:// scheme and the browser server — so
// the route table and the sandbox rule exist once.

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use crate::service::Service;
use crate::CoreError;

/// A file to serve, and whether it is untrusted project content that must be
/// sent with a sandboxing CSP and `nosniff`.
pub struct Resolved {
    pub path: PathBuf,
    pub sandboxed: bool,
}

/// Route percent-decoded path segments: `__pdf/<id>` or `__raw/<id>/<rel…>`.
pub fn resolve(service: &Service, segments: &[String]) -> Result<Resolved, CoreError> {
    let id = segments.get(1).map(String::as_str).unwrap_or_default();
    match segments.first().map(String::as_str) {
        Some("__pdf") => Ok(Resolved {
            path: service.pdf_path(id)?,
            sandboxed: false,
        }),
        Some("__raw") => Ok(Resolved {
            path: service.raw_path(id, &segments.get(2..).unwrap_or_default().join("/"))?,
            sandboxed: true,
        }),
        _ => Err(CoreError::not_found("Not found")),
    }
}

fn mime_for(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_lowercase)
        .as_deref()
    {
        Some("html") => "text/html",
        Some("css") => "text/css",
        Some("js" | "mjs") => "text/javascript",
        Some("map" | "json") => "application/json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        Some("ico") => "image/x-icon",
        Some("pdf") => "application/pdf",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

/// A `Range` header that cannot be served: answer 416.
#[derive(Debug, PartialEq, Eq)]
struct Unsatisfiable;

/// The one byte range a `Range` header asks for, or None to send the whole
/// file. pdf.js fetches large PDFs in ranges; the suffix and open-ended forms
/// are here because WebView engines may choose either. RFC 9110 §14.2 has a
/// server ignore a unit it doesn't know and lets it ignore several ranges
/// (which would need multipart/byteranges), so those, and a header that
/// doesn't parse, get the whole file. Only a well-formed range that starts
/// past the end is refused.
fn parse_range(header: &str, len: u64) -> Result<Option<(u64, u64)>, Unsatisfiable> {
    let spec = header
        .strip_prefix("bytes=")
        .filter(|spec| !spec.contains(','));
    let Some((start, end)) = spec.and_then(|spec| spec.split_once('-')) else {
        return Ok(None);
    };
    let (first, last) = match (start.parse::<u64>(), end.parse::<u64>()) {
        // The last n bytes.
        (Err(_), Ok(n)) if start.is_empty() => {
            if n == 0 || len == 0 {
                return Err(Unsatisfiable);
            }
            (len - n.min(len), len - 1)
        }
        (Ok(first), Err(_)) if end.is_empty() => (first, u64::MAX),
        (Ok(first), Ok(last)) if first <= last => (first, last),
        _ => return Ok(None),
    };
    if first >= len {
        return Err(Unsatisfiable);
    }
    Ok(Some((first, last.min(len - 1))))
}

/// A file as an HTTP response, for a host to wrap in its own type.
pub struct Served {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

/// `path` as an HTTP response, whole or the part a `Range` header asks for.
/// A sandboxed response carries its CSP whatever the status, so no answer
/// about a project file can run as a document.
pub async fn respond(path: &Path, range: Option<&str>, sandboxed: bool) -> Served {
    let mut headers = Vec::new();
    if sandboxed {
        headers.push((
            "Content-Security-Policy",
            "sandbox; default-src 'none'".into(),
        ));
    }
    let text = |status, message: &str, mut headers: Vec<_>| {
        headers.push(("Content-Type", "text/plain; charset=utf-8".into()));
        Served {
            status,
            headers,
            body: message.into(),
        }
    };
    let len = match tokio::fs::metadata(path).await {
        Ok(meta) if meta.is_file() => meta.len(),
        _ => return text(404, "Not found", headers),
    };
    let range = match range.map(|header| parse_range(header, len)).transpose() {
        Ok(range) => range.flatten(),
        Err(Unsatisfiable) => {
            headers.push(("Content-Range", format!("bytes */{len}")));
            return text(416, "Range not satisfiable", headers);
        }
    };
    let Ok(body) = read_file_range(path, range).await else {
        return text(404, "Not found", headers);
    };
    headers.extend([
        ("Content-Type", mime_for(path).into()),
        ("Cache-Control", "no-store".into()),
        ("Accept-Ranges", "bytes".into()),
    ]);
    if let Some((start, end)) = range {
        headers.push(("Content-Range", format!("bytes {start}-{end}/{len}")));
    }
    let status = if range.is_some() { 206 } else { 200 };
    Served {
        status,
        headers,
        body,
    }
}

async fn read_file_range(path: &Path, range: Option<(u64, u64)>) -> std::io::Result<Vec<u8>> {
    // One trip to the blocking pool per request. tokio::fs::File makes one per
    // operation (open, seek, each read) and copies through its own buffer;
    // pdf.js fetches a large PDF as many small ranges.
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let Some((start, end)) = range else {
            return std::fs::read(path);
        };
        let size = usize::try_from(end - start + 1)
            .map_err(|_| std::io::Error::other("requested range is too large"))?;
        let mut file = std::fs::File::open(path)?;
        file.seek(SeekFrom::Start(start))?;
        let mut bytes = vec![0; size];
        file.read_exact(&mut bytes)?;
        Ok(bytes)
    })
    .await
    .map_err(std::io::Error::other)?
}

#[cfg(test)]
mod tests {
    use super::{parse_range, read_file_range, Unsatisfiable};

    #[test]
    fn parses_closed_open_and_suffix_ranges() {
        assert_eq!(parse_range("bytes=10-19", 100), Ok(Some((10, 19))));
        assert_eq!(parse_range("bytes=90-", 100), Ok(Some((90, 99))));
        assert_eq!(parse_range("bytes=-10", 100), Ok(Some((90, 99))));
        assert_eq!(parse_range("bytes=90-200", 100), Ok(Some((90, 99))));
    }

    #[test]
    fn ignores_ranges_it_cannot_serve_and_refuses_those_past_the_end() {
        // RFC 9110: an unknown unit, several ranges or a malformed one get
        // the whole file.
        for header in [
            "items=0-1",
            "bytes=0-1,4-5",
            "bytes=20-10",
            "bytes=x-",
            "bytes",
        ] {
            assert_eq!(parse_range(header, 100), Ok(None), "{header}");
        }
        for (header, len) in [("bytes=100-", 100), ("bytes=-0", 100), ("bytes=0-", 0)] {
            assert_eq!(parse_range(header, len), Err(Unsatisfiable), "{header}");
        }
    }

    #[tokio::test]
    async fn reads_whole_files_and_ranges() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");
        let data: Vec<u8> = (0..=255).cycle().take(100_000).collect();
        std::fs::write(&path, &data).unwrap();
        let whole = read_file_range(&path, None).await.unwrap();
        let part = read_file_range(&path, Some((10, 19))).await.unwrap();
        let last = read_file_range(&path, Some((99_999, 99_999)))
            .await
            .unwrap();
        let past_end = read_file_range(&path, Some((99_990, 100_009))).await;
        assert_eq!(whole, data);
        assert_eq!(part, data[10..20]);
        assert_eq!(last, data[99_999..]);
        // A file that shrank after its length was read: an error, not padding.
        assert!(past_end.is_err());
    }
}
