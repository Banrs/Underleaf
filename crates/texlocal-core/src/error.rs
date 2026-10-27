use std::fmt;
use std::io;
use std::path::Path;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
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

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
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
