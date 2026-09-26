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

const MAX_HEAD: usize = 64 * 1024;
const READ_CHUNK: usize = 16 * 1024;
const MAX_HEADERS: usize = 64;
const IDLE: Duration = Duration::from_secs(60);

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

/// Accept connections until `shutdown` resolves.
pub async fn serve<H, F>(
    listener: TcpListener,
    handler: Arc<H>,
    max_body: usize,
    shutdown: impl Future<Output = ()>,
) where
    H: Fn(Request) -> F + Send + Sync + 'static,
    F: Future<Output = Response> + Send,
{
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            _ = &mut shutdown => return,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let handler = handler.clone();
                    tokio::spawn(async move { connection(stream, handler, max_body).await });
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
    Reject(Response),
    Closed,
}

/// Read more of the connection straight into `buf`, with no copy through a
/// stack buffer: an upload is up to 100 MB.
async fn fill(stream: &mut TcpStream, buf: &mut Vec<u8>) -> bool {
    buf.reserve(READ_CHUNK);
    matches!(
        tokio::time::timeout(IDLE, stream.read_buf(buf)).await,
        Ok(Ok(n)) if n > 0
    )
}

async fn read_request(stream: &mut TcpStream, buf: &mut Vec<u8>, max_body: usize) -> Read {
    let (mut request, keep_alive, head_len, body_len) = loop {
        let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
        let mut parsed = httparse::Request::new(&mut headers);
        match parsed.parse(buf) {
            Ok(httparse::Status::Complete(head_len)) => {
                let headers: Vec<(String, String)> = parsed
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
                    method: parsed.method.unwrap_or_default().to_string(),
                    target: parsed.path.unwrap_or_default().to_string(),
                    headers,
                    body: Vec::new(),
                };
                if request.header("transfer-encoding").is_some() {
                    return Read::Reject(Response::text(501, "Chunked bodies are not supported"));
                }
                let body_len = match request.header("content-length").map(str::parse::<usize>) {
                    None => 0,
                    Some(Ok(n)) if n <= max_body => n,
                    Some(Ok(_)) => return Read::Reject(Response::text(413, "Body too large")),
                    Some(Err(_)) => return Read::Reject(Response::text(400, "Bad Content-Length")),
                };
                let close = request
                    .header("connection")
                    .is_some_and(|v| v.eq_ignore_ascii_case("close"));
                let keep_alive = parsed.version == Some(1) && !close;
                break (request, keep_alive, head_len, body_len);
            }
            Ok(httparse::Status::Partial) if buf.len() < MAX_HEAD => {
                if !fill(stream, buf).await {
                    return Read::Closed;
                }
            }
            Ok(httparse::Status::Partial) | Err(httparse::Error::TooManyHeaders) => {
                return Read::Reject(Response::text(431, "Request head too large"));
            }
            Err(_) => return Read::Reject(Response::text(400, "Malformed request")),
        }
    };

    buf.drain(..head_len);
    while buf.len() < body_len {
        if !fill(stream, buf).await {
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
    stream.write_all(head.as_bytes()).await?;
    if !head_only {
        stream.write_all(&response.body).await?;
    }
    stream.flush().await
}

async fn connection<H, F>(mut stream: TcpStream, handler: Arc<H>, max_body: usize)
where
    H: Fn(Request) -> F,
    F: Future<Output = Response>,
{
    let mut buf = Vec::new();
    loop {
        match read_request(&mut stream, &mut buf, max_body).await {
            Read::Closed => return,
            Read::Reject(response) => {
                let _ = write_response(&mut stream, &response, false, false).await;
                return;
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
