use std::fmt;
use std::io::{self, ErrorKind};
use std::path::Path;

/// An error with an HTTP status code, which the FFI reports as `status`.
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
    /// What was sent doesn't fit what is held; sending it whole puts it right.
    pub fn unfit(message: impl Into<String>) -> Self {
        Self::new(412, message)
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(500, message)
    }

    /// `err` as an error that names `path`, for the files a person chose: the
    /// OS's own words ("No such file or directory") leave an alert without one.
    pub(crate) fn at(path: &Path) -> impl FnOnce(io::Error) -> Self + '_ {
        move |err| {
            let Self { status, message } = Self::from(err);
            Self::new(status, format!("“{}”: {message}", path.display()))
        }
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CoreError {}

impl From<io::Error> for CoreError {
    fn from(err: io::Error) -> Self {
        let status = match err.kind() {
            ErrorKind::NotFound => 404,
            ErrorKind::PermissionDenied => 403,
            ErrorKind::AlreadyExists => 409,
            _ => 500,
        };
        let text = err.to_string();
        let words = text
            .split_once(" (os error ")
            .map_or(text.as_str(), |(words, _)| words);
        Self::new(status, words)
    }
}

/// A zip that can't be read is the file's fault, not the core's.
impl From<zip::result::ZipError> for CoreError {
    fn from(err: zip::result::ZipError) -> Self {
        match err {
            zip::result::ZipError::Io(err) => err.into(),
            other => Self::bad_request(other.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_system_errors_keep_their_kind_and_lose_the_os_number() {
        let err = CoreError::from(std::fs::read("/no/such/file/at/all").unwrap_err());
        assert_eq!(err.status, 404);
        assert!(!err.message.contains("os error"), "{}", err.message);
        for (kind, status) in [
            (ErrorKind::PermissionDenied, 403),
            (ErrorKind::AlreadyExists, 409),
            (ErrorKind::InvalidData, 500),
        ] {
            assert_eq!(CoreError::from(io::Error::from(kind)).status, status);
        }
        let named = CoreError::at(Path::new("/a/b.tex"))(io::Error::from(ErrorKind::NotFound));
        assert_eq!(
            (named.status, named.message.as_str()),
            (404, "“/a/b.tex”: entity not found")
        );
    }
}
