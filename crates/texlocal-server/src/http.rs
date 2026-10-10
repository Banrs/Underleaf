//! HTTP/1.1 transport over Hyper. The application checks each request head
//! before reading its bounded body; project security stays in App::guard.

use std::convert::Infallible;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
pub use hyper::body::Bytes;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio_io_timeout::TimeoutStream;

const MAX_HEAD: usize = 64 * 1024;
const MAX_HEADERS: usize = 64;
const HEAD_TIME: Duration = Duration::from_secs(10);
const BODY_TIME: Duration = Duration::from_secs(60);
const LINGER: Duration = Duration::from_secs(2);
const LINGER_BYTES: usize = 16 * 1024 * 1024;
/// Connections served at once; more wait to be accepted. A browser opens
/// about six per host, so this only stops a runaway local client.
const MAX_CONNECTIONS: usize = 256;

pub struct Request {
    pub method: String,
    /// Path and query, still percent-encoded.
    pub target: String,
    /// Names lowercased.
    pub headers: Vec<(String, String)>,
    pub body: Bytes,
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

    pub fn secured(mut self) -> Self {
        for (name, value) in [
            ("Content-Security-Policy", "frame-ancestors 'none'"),
            ("X-Frame-Options", "DENY"),
            ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "no-referrer"),
        ] {
            if self.header(name).is_none() {
                self.headers.push((name, value.into()));
            }
        }
        self
    }
}

/// Accept connections until shutdown. The guard sees the head before the
/// application reads any body bytes.
pub async fn serve<H, F, C>(
    listener: TcpListener,
    handler: Arc<H>,
    check: Arc<C>,
    max_body: usize,
    shutdown: impl Future<Output = ()>,
) where
    H: Fn(Request) -> F + Send + Sync + 'static,
    F: Future<Output = Response> + Send + 'static,
    C: Fn(&Request) -> Option<Response> + Send + Sync + 'static,
{
    tokio::pin!(shutdown);
    let connections = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let accept = async {
            let permit = Arc::clone(&connections).acquire_owned().await;
            (permit, listener.accept().await)
        };
        tokio::select! {
            _ = &mut shutdown => return,
            (permit, accepted) = accept => match accepted {
                Ok((stream, _)) => {
                    let handler = Arc::clone(&handler);
                    let check = Arc::clone(&check);
                    tokio::spawn(async move {
                        let _permit = permit;
                        let mut stream = TimeoutStream::new(stream);
                        stream.set_write_timeout(Some(BODY_TIME));
                        let service = service_fn(|incoming| async {
                            Ok::<_, Infallible>(request(incoming, &*handler, &*check, max_body).await)
                        });
                        let connection = http1::Builder::new()
                            .timer(TokioTimer::new())
                            .header_read_timeout(HEAD_TIME)
                            .max_headers(MAX_HEADERS)
                            .max_buf_size(MAX_HEAD)
                            .serve_connection(TokioIo::new(Box::pin(stream)), service);
                        if let Ok(parts) = connection.without_shutdown().await {
                            linger(parts.io.into_inner()).await;
                        }
                    });
                }
                // A descriptor limit must not turn accept into a busy loop.
                Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
            }
        }
    }
}

fn response(response: Response, head_only: bool) -> hyper::Response<Full<Bytes>> {
    let response = response.secured();
    let mut builder = hyper::Response::builder().status(response.status);
    // A 304 has no content, so no length of its own to give.
    if response.status != 304 {
        builder = builder.header("Content-Length", response.body.len());
    }
    for (name, value) in response.headers {
        builder = builder.header(name, value);
    }
    let body = if head_only {
        Bytes::new()
    } else {
        response.body.into()
    };
    builder.body(Full::new(body)).unwrap_or_else(|_| {
        hyper::Response::builder()
            .status(500)
            .body(Full::new(Bytes::new()))
            .expect("valid empty response")
    })
}

async fn request<H, F, C>(
    incoming: hyper::Request<Incoming>,
    handler: &H,
    check: &C,
    max_body: usize,
) -> hyper::Response<Full<Bytes>>
where
    H: Fn(Request) -> F,
    F: Future<Output = Response>,
    C: Fn(&Request) -> Option<Response>,
{
    let (head, body) = incoming.into_parts();
    let head_only = head.method == hyper::Method::HEAD;
    let mut req = Request {
        method: head.method.to_string(),
        // An absolute-form target (`GET http://host/…`) is routed by its path.
        target: head
            .uri
            .path_and_query()
            .map_or_else(|| head.uri.path().to_owned(), |p| p.as_str().to_owned()),
        headers: head
            .headers
            .iter()
            .map(|(name, value)| {
                (
                    name.as_str().to_owned(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                )
            })
            .collect(),
        body: Bytes::new(),
    };
    // Browser requests use Content-Length. Do not accept a second framing mode.
    if req.header("transfer-encoding").is_some() {
        return response(
            Response::text(501, "Chunked bodies are not supported"),
            head_only,
        );
    }
    if req.header("content-length").is_some_and(|value| {
        value
            .parse::<usize>()
            .map_or(true, |length| length > max_body)
    }) {
        return response(Response::text(413, "Body too large"), head_only);
    }
    if let Some(refused) = check(&req) {
        return response(refused, head_only);
    }
    match tokio::time::timeout(BODY_TIME, Limited::new(body, max_body).collect()).await {
        Ok(Ok(body)) => {
            req.body = body.to_bytes();
            response(handler(req).await, head_only)
        }
        Ok(Err(_)) => response(Response::text(400, "Incomplete request body"), head_only),
        Err(_) => response(Response::text(408, "Request body timed out"), head_only),
    }
}

/// An unread rejected upload must not reset the socket before its response
/// arrives. Half-close, then discard input for a bounded time and amount.
async fn linger(mut stream: impl AsyncRead + AsyncWrite + Unpin) {
    if stream.shutdown().await.is_err() {
        return;
    }
    let mut input = stream.take(LINGER_BYTES as u64);
    let mut sink = tokio::io::sink();
    let drain = tokio::io::copy(&mut input, &mut sink);
    let _ = tokio::time::timeout(LINGER, drain).await;
}
