use serde::{Serialize, Serializer};
use texlocal_core::CoreError;

/// What a command rejects with. Serializes to a plain string so the JS side
/// sees `new Error(message)` — the same shape the Electron preload produced by
/// unwrapping its `{ value } / { error }` envelope.
#[derive(Debug)]
pub struct CmdError(pub String);

impl From<CoreError> for CmdError {
    fn from(err: CoreError) -> Self {
        Self(err.message)
    }
}

impl From<std::io::Error> for CmdError {
    fn from(err: std::io::Error) -> Self {
        Self(err.to_string())
    }
}

impl From<tauri::Error> for CmdError {
    fn from(err: tauri::Error) -> Self {
        Self(err.to_string())
    }
}

impl From<String> for CmdError {
    fn from(message: String) -> Self {
        Self(message)
    }
}

impl From<&str> for CmdError {
    fn from(message: &str) -> Self {
        Self(message.to_string())
    }
}

impl Serialize for CmdError {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0)
    }
}

pub type CmdResult<T> = Result<T, CmdError>;
