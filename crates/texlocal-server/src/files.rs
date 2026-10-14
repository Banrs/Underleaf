//! Files as HTTP answers: the compiled PDF (pdf.js fetches it in ranges), raw
//! project files (image previews) and the web UI's own files. The sandbox
//! rule for project files lives here; `App` finds the file.

use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

use crate::Response;

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
/// are here because browsers may choose either. RFC 9110 §14.2 has a
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

/// The headers every answer starts with: a sandboxed one's CSP.
fn csp(sandboxed: bool) -> Vec<(&'static str, String)> {
    let mut headers = Vec::new();
    if sandboxed {
        headers.push((
            "Content-Security-Policy",
            "sandbox; default-src 'none'".into(),
        ));
    }
    headers
}

fn text(status: u16, message: &str, mut headers: Vec<(&'static str, String)>) -> Response {
    headers.push(("Content-Type", "text/plain; charset=utf-8".into()));
    Response {
        status,
        headers,
        body: message.into(),
    }
}

/// `path` as an HTTP response, whole or the part a `Range` header asks for:
/// its length, the range and the bytes, all read in the one trip to the
/// blocking pool its caller makes. tokio::fs would make one per operation
/// (metadata, open, seek, each read) and copy through its own buffer, and
/// pdf.js fetches a large PDF as many small ranges. A sandboxed response
/// carries its CSP whatever the status, so no answer about a project file can
/// run as a document.
pub fn serve(path: &Path, range: Option<&str>, sandboxed: bool) -> Response {
    let mut headers = csp(sandboxed);
    let len = match fs::metadata(path) {
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
    let Ok(body) = read_file_range(path, range) else {
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
    Response {
        status,
        headers,
        body,
    }
}

fn read_file_range(path: &Path, range: Option<(u64, u64)>) -> io::Result<Vec<u8>> {
    let Some((start, end)) = range else {
        return fs::read(path);
    };
    let size = usize::try_from(end - start + 1)
        .map_err(|_| io::Error::other("requested range is too large"))?;
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = vec![0; size];
    file.read_exact(&mut bytes)?;
    Ok(bytes)
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

    #[test]
    fn reads_whole_files_and_ranges() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file");
        let data: Vec<u8> = (0..=255).cycle().take(100_000).collect();
        std::fs::write(&path, &data).unwrap();
        let whole = read_file_range(&path, None).unwrap();
        let part = read_file_range(&path, Some((10, 19))).unwrap();
        let last = read_file_range(&path, Some((99_999, 99_999))).unwrap();
        let past_end = read_file_range(&path, Some((99_990, 100_009)));
        assert_eq!(whole, data);
        assert_eq!(part, data[10..20]);
        assert_eq!(last, data[99_999..]);
        // A file that shrank after its length was read: an error, not padding.
        assert!(past_end.is_err());
    }
}
