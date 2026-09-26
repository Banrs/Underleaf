use std::fmt;

/// An error with a status code attached. The code is not decoration: the
/// `texlocal://` protocol handler returns it verbatim, and the 4xx/5xx split
/// decides whether the UI blames the request or the app.
#[derive(Debug, Clone)]
pub struct CoreError {
    pub status: u16,
    pub message: String,
}

impl CoreError {
    fn new(status: u16, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(400, message)
    }
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(404, message)
    }
    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(409, message)
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(500, message)
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CoreError {}

impl From<std::io::Error> for CoreError {
    fn from(err: std::io::Error) -> Self {
        Self::internal(err.to_string())
    }
}

impl From<zip::result::ZipError> for CoreError {
    fn from(err: zip::result::ZipError) -> Self {
        Self::internal(err.to_string())
    }
}
