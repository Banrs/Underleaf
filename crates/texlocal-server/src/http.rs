//! Just enough HTTP/1.1 for one local browser: `httparse` reads the head,
//! bodies need a Content-Length (fetch never streams a request body here),
//! responses always carry one, and connections stay open for the next
//! request. Anything outside that is refused rather than half-supported.

use std::fmt::Write as _;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::Instant;

const MAX_HEAD: usize = 64 * 1024;
const READ_CHUNK: usize = 16 * 1024;
const MAX_HEADERS: usize = 64;
const IDLE: Duration = Duration::from_secs(60);
const HEAD_TIME: Duration = Duration::from_secs(10);
const LINGER: Duration = Duration::from_secs(2);
const LINGER_BYTES: usize = 16 * 1024 * 1024;

pub struct Request {
    pub method: String,
    /// Path and query, still percent-encoded.
    pub target: String,
    /// Names lowercased.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn path(&self) -> &str {
        self.target.split('?').next().unwrap_or_default()
    }

    pub fn query(&self) -> Option<&str> {
        self.target.split_once('?').map(|(_, q)| q)
    }
}

pub struct Response {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16, content_type: &str, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: vec![("Content-Type", content_type.to_string())],
            body: body.into(),
        }
    }

    pub fn text(status: u16, message: &str) -> Self {
        Self::new(status, "text/plain; charset=utf-8", message)
    }

    pub fn json(status: u16, value: &serde_json::Value) -> Self {
        Self::new(status, "application/json", value.to_string())
    }

    pub fn with(mut self, name: &'static str, value: impl Into<String>) -> Self {
        self.headers.push((name, value.into()));
        self
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        206 => "Partial Content",
        303 => "See Other",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Content Too Large",
        416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large",
        501 => "Not Implemented",
        _ => "Internal Server Error",
    }
}

/// Accept connections until `shutdown` resolves. `check` sees each request's
/// head, its body still empty, before any of the body is read: a response it
/// returns is sent instead, and `handler` never sees that request.
pub async fn serve<H, F, C>(
    listener: TcpListener,
    handler: Arc<H>,
    check: Arc<C>,
    max_body: usize,
    shutdown: impl Future<Output = ()>,
) where
    H: Fn(Request) -> F + Send + Sync + 'static,
    F: Future<Output = Response> + Send,
    C: Fn(&Request) -> Option<Response> + Send + Sync + 'static,
{
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            _ = &mut shutdown => return,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let handler = handler.clone();
                    let check = check.clone();
                    tokio::spawn(async move { connection(stream, handler, check, max_body).await });
                }
                // Out of file descriptors, say: accept fails again at once
                // until a connection closes, so pause rather than spin.
                Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
            }
        }
    }
}

enum Read {
    Request(Request, bool),
    /// Answered without reading a body.
    Refused {
        response: Response,
        head_only: bool,
        keep_alive: bool,
    },
    Closed,
}

fn refuse(status: u16, message: &str) -> Read {
    Read::Refused {
        response: Response::text(status, message),
        head_only: false,
        keep_alive: false,
    }
}

/// Read more of the connection straight into `buf`, with no copy through a
/// stack buffer: an upload is up to 100 MB.
async fn fill(stream: &mut TcpStream, buf: &mut Vec<u8>, wait: Duration) -> bool {
    buf.reserve(READ_CHUNK);
    matches!(
        tokio::time::timeout(wait, stream.read_buf(buf)).await,
        Ok(Ok(n)) if n > 0
    )
}

/// Whether newly read bytes, with the two before them, hold the blank line
/// that ends a head (`\n\n` covers bare-LF heads).
fn ends_head(fresh: &[u8]) -> bool {
    fresh.windows(2).any(|w| w == b"\n\n") || fresh.windows(3).any(|w| w == b"\n\r\n")
}

async fn read_request<C>(
    stream: &mut TcpStream,
    buf: &mut Vec<u8>,
    check: &C,
    max_body: usize,
) -> Read
where
    C: Fn(&Request) -> Option<Response>,
{
    // A head must arrive whole within HEAD_TIME of its first byte, so a
    // client dribbling it in cannot hold the connection indefinitely.
    let mut deadline = (!buf.is_empty()).then(|| Instant::now() + HEAD_TIME);
    // httparse has no incremental mode, so a head is only reparsed once it
    // may be complete or has doubled: reparsing after every read would make a
    // byte-at-a-time head cost quadratic work.
    let (mut parsed, mut scanned) = (0usize, 0usize);
    let (mut request, keep_alive, head_len, body_len) = loop {
        // Empty lines before a request line are allowed (RFC 9112 §2.2).
        // Dropped here, they cannot count as the blank line that ends a head.
        let blank = buf
            .iter()
            .take_while(|b| matches!(b, b'\r' | b'\n'))
            .count();
        if blank > 0 {
            buf.drain(..blank);
            (parsed, scanned) = (0, 0);
        }
        let ready = buf.len() >= 2 * parsed
            || buf.len() >= MAX_HEAD
            || ends_head(&buf[scanned.saturating_sub(2)..]);
        scanned = buf.len();
        let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
        let mut parsed_head = httparse::Request::new(&mut headers);
        let status = if ready {
            parsed = buf.len();
            parsed_head.parse(buf)
        } else {
            Ok(httparse::Status::Partial)
        };
        match status {
            Ok(httparse::Status::Complete(head_len)) => {
                let headers: Vec<(String, String)> = parsed_head
                    .headers
                    .iter()
                    .map(|h| {
                        (
                            h.name.to_ascii_lowercase(),
                            String::from_utf8_lossy(h.value).into_owned(),
                        )
                    })
                    .collect();
                let request = Request {
                    method: parsed_head.method.unwrap_or_default().to_string(),
                    target: parsed_head.path.unwrap_or_default().to_string(),
                    headers,
                    body: Vec::new(),
                };
                if request.header("transfer-encoding").is_some() {
                    return refuse(501, "Chunked bodies are not supported");
                }
                // One Content-Length, digits only: two that disagree, or a
                // sign, would frame the body differently to another reader.
                let mut lengths = request
                    .headers
                    .iter()
                    .filter(|(n, _)| n == "content-length")
                    .map(|(_, v)| v.as_str());
                let body_len = match (lengths.next(), lengths.next()) {
                    (None, _) => 0,
                    (Some(v), None) if !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()) => {
                        match v.parse::<usize>() {
                            Ok(n) if n <= max_body => n,
                            _ => return refuse(413, "Body too large"),
                        }
                    }
                    _ => return refuse(400, "Bad Content-Length"),
                };
                let close = request
                    .header("connection")
                    .is_some_and(|v| v.eq_ignore_ascii_case("close"));
                let keep_alive = parsed_head.version == Some(1) && !close;
                break (request, keep_alive, head_len, body_len);
            }
            Ok(httparse::Status::Partial) if buf.len() < MAX_HEAD => {
                // Checked here, not left to a zero wait: a timeout still
                // reads bytes already queued, and blank lines never reach
                // MAX_HEAD, so a client feeding them would never be cut off.
                let now = Instant::now();
                if deadline.is_some_and(|d| now >= d) {
                    return Read::Closed;
                }
                let wait = deadline.map_or(IDLE, |d| d - now);
                if !fill(stream, buf, wait).await {
                    return Read::Closed;
                }
                deadline.get_or_insert_with(|| Instant::now() + HEAD_TIME);
            }
            Ok(httparse::Status::Partial) | Err(httparse::Error::TooManyHeaders) => {
                return refuse(431, "Request head too large");
            }
            Err(_) => return refuse(400, "Malformed request"),
        }
    };

    if let Some(response) = check(&request) {
        let head_only = request.method == "HEAD";
        // A body that came in with its head (a small one usually does) is
        // skipped and the connection kept; any other is left unread and the
        // connection closed.
        let whole = head_len + body_len;
        let keep_alive = keep_alive && buf.len() >= whole;
        if keep_alive {
            buf.drain(..whole);
        }
        return Read::Refused {
            response,
            head_only,
            keep_alive,
        };
    }

    buf.drain(..head_len);
    while buf.len() < body_len {
        if !fill(stream, buf, IDLE).await {
            return Read::Closed;
        }
    }
    // Hand the buffer itself over as the body and keep only what follows it
    // (a pipelined request, usually nothing), rather than copying out an
    // upload of up to 100 MB.
    let rest = buf.split_off(body_len);
    request.body = std::mem::replace(buf, rest);
    Read::Request(request, keep_alive)
}

/// Gives up after IDLE, so a client that stops reading cannot hold the
/// connection open.
async fn write_response(
    stream: &mut TcpStream,
    response: &Response,
    head_only: bool,
    keep_alive: bool,
) -> std::io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {} {}\r\n",
        response.status,
        reason(response.status)
    );
    // Writing to a String cannot fail.
    for (name, value) in &response.headers {
        let _ = write!(head, "{name}: {value}\r\n");
    }
    let _ = write!(head, "Content-Length: {}\r\n", response.body.len());
    head.push_str(if keep_alive {
        "Connection: keep-alive\r\n\r\n"
    } else {
        "Connection: close\r\n\r\n"
    });
    let write = async {
        stream.write_all(head.as_bytes()).await?;
        if !head_only {
            stream.write_all(&response.body).await?;
        }
        stream.flush().await
    };
    tokio::time::timeout(IDLE, write)
        .await
        .unwrap_or_else(|_| Err(std::io::ErrorKind::TimedOut.into()))
}

/// Close a connection whose request was refused with its body unread. Closing
/// with unread input makes the kernel reset the connection, and a reset can
/// destroy the response before the client reads it. So stop sending, then
/// read and discard for a bounded time and amount, and only then close.
async fn linger(mut stream: TcpStream) {
    if stream.shutdown().await.is_err() {
        return;
    }
    let mut sink = vec![0; READ_CHUNK];
    let drain = async {
        let mut left = LINGER_BYTES;
        while left > 0 {
            match stream.read(&mut sink).await {
                Ok(0) | Err(_) => return,
                Ok(n) => left = left.saturating_sub(n),
            }
        }
    };
    let _ = tokio::time::timeout(LINGER, drain).await;
}

async fn connection<H, F, C>(mut stream: TcpStream, handler: Arc<H>, check: Arc<C>, max_body: usize)
where
    H: Fn(Request) -> F,
    F: Future<Output = Response>,
    C: Fn(&Request) -> Option<Response>,
{
    let mut buf = Vec::new();
    loop {
        match read_request(&mut stream, &mut buf, &*check, max_body).await {
            Read::Closed => return,
            Read::Refused {
                response,
                head_only,
                keep_alive,
            } => {
                let sent = write_response(&mut stream, &response, head_only, keep_alive).await;
                if sent.is_err() {
                    return;
                }
                if !keep_alive {
                    linger(stream).await;
                    return;
                }
            }
            Read::Request(request, keep_alive) => {
                let head_only = request.method == "HEAD";
                let response = handler(request).await;
                if write_response(&mut stream, &response, head_only, keep_alive)
                    .await
                    .is_err()
                    || !keep_alive
                {
                    return;
                }
            }
        }
    }
}
