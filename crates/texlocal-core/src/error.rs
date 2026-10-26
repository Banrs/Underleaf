use std::fmt;
use std::io;
use std::path::Path;

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorKind {
    Invalid,
    Denied,
    NotFound,
    Conflict,
    Unfit,
    Unavailable,
    Internal,
}

#[derive(Debug, Clone)]
pub struct CoreError {
    pub kind: ErrorKind,
    pub message: String,
}

impl CoreError {
    pub(crate) fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Invalid, message)
    }
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::NotFound, message)
    }
    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Conflict, message)
    }
    pub fn unfit(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unfit, message)
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Internal, message)
    }

    pub(crate) fn at(path: &Path) -> impl FnOnce(io::Error) -> Self + '_ {
        move |err| {
            let Self { kind, message } = Self::from(err);
            Self::new(kind, format!("“{}”: {message}", path.display()))
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
        let kind = match err.kind() {
            io::ErrorKind::NotFound => ErrorKind::NotFound,
            io::ErrorKind::PermissionDenied => ErrorKind::Denied,
            io::ErrorKind::AlreadyExists => ErrorKind::Conflict,
            _ => ErrorKind::Internal,
        };
        let text = err.to_string();
        let words = text
            .split_once(" (os error ")
            .map_or(text.as_str(), |(words, _)| words);
        Self::new(kind, words)
    }
}

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
        assert_eq!(err.kind, ErrorKind::NotFound);
        assert!(!err.message.contains("os error"), "{}", err.message);
        for (io, kind) in [
            (io::ErrorKind::PermissionDenied, ErrorKind::Denied),
            (io::ErrorKind::AlreadyExists, ErrorKind::Conflict),
            (io::ErrorKind::InvalidData, ErrorKind::Internal),
        ] {
            assert_eq!(CoreError::from(io::Error::from(io)).kind, kind);
        }
        let named = CoreError::at(Path::new("/a/b.tex"))(io::Error::from(io::ErrorKind::NotFound));
        assert_eq!(
            (named.kind, named.message.as_str()),
            (ErrorKind::NotFound, "“/a/b.tex”: entity not found")
        );
    }
}
