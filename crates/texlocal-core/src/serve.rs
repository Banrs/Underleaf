// Serving project files as URLs: the compiled PDF (pdf.js fetches it in
// ranges) and raw project files (image previews). Shared by every host that
// serves them — the desktop's texlocal:// scheme and the browser server — so
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

pub fn mime_for(path: &Path) -> &'static str {
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

/// A `Range` header that cannot be served: answer 416.
#[derive(Debug, PartialEq, Eq)]
pub struct Unsatisfiable;

// A single RFC 7233 byte range. pdf.js uses this to fetch large PDFs in chunks;
// suffix and open-ended forms are included because WebView engines may choose
// either. Multiple ranges would need multipart/byteranges and are rejected.
pub fn parse_range(header: &str, len: u64) -> Result<Option<(u64, u64)>, Unsatisfiable> {
    let Some(spec) = header.strip_prefix("bytes=") else {
        return Err(Unsatisfiable);
    };
    if len == 0 || spec.contains(',') {
        return Err(Unsatisfiable);
    }
    let Some((start, end)) = spec.split_once('-') else {
        return Err(Unsatisfiable);
    };

    if start.is_empty() {
        let suffix = end.parse::<u64>().map_err(|_| Unsatisfiable)?;
        if suffix == 0 {
            return Err(Unsatisfiable);
        }
        let take = suffix.min(len);
        return Ok(Some((len - take, len - 1)));
    }

    let start = start.parse::<u64>().map_err(|_| Unsatisfiable)?;
    if start >= len {
        return Err(Unsatisfiable);
    }
    let end = if end.is_empty() {
        len - 1
    } else {
        end.parse::<u64>().map_err(|_| Unsatisfiable)?.min(len - 1)
    };
    if end < start {
        return Err(Unsatisfiable);
    }
    Ok(Some((start, end)))
}

pub async fn read_file_range(path: &Path, range: Option<(u64, u64)>) -> std::io::Result<Vec<u8>> {
    // One trip to the blocking pool per request. tokio::fs::File makes one per
    // operation (open, seek, each read) and copies through its own buffer;
    // pdf.js fetches a large PDF as many small ranges.
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || read_range_blocking(&path, range))
        .await
        .map_err(std::io::Error::other)?
}

fn read_range_blocking(path: &Path, range: Option<(u64, u64)>) -> std::io::Result<Vec<u8>> {
    // fs::read sizes its buffer from the file's length up front.
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
}

#[cfg(test)]
mod tests {
    use super::{parse_range, read_file_range};

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

    #[tokio::test]
    async fn reads_whole_files_and_ranges() {
        let path = std::env::temp_dir().join(format!("texlocal-range-{}", std::process::id()));
        let data: Vec<u8> = (0..=255).cycle().take(100_000).collect();
        std::fs::write(&path, &data).unwrap();
        let whole = read_file_range(&path, None).await.unwrap();
        let part = read_file_range(&path, Some((10, 19))).await.unwrap();
        let last = read_file_range(&path, Some((99_999, 99_999)))
            .await
            .unwrap();
        let past_end = read_file_range(&path, Some((99_990, 100_009))).await;
        std::fs::remove_file(&path).unwrap();
        assert_eq!(whole, data);
        assert_eq!(part, data[10..20]);
        assert_eq!(last, data[99_999..]);
        // A file that shrank after its length was read: an error, not padding.
        assert!(past_end.is_err());
    }
}
