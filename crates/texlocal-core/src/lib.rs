// TeXLocal's core: projects, compilation, the path rules that keep both
// inside the data directory, project sessions, and the editors' LaTeX logic
// (`syntax`). Deliberately GUI-free, so it tests on any host.
//
// Path convention: every project-relative path this crate RETURNS or STORES
// uses forward slashes — the hosts and SyncTeX both expect '/'.

pub mod analyze;
mod atomic;
pub mod compile;
pub mod error;
pub mod events;
pub mod import;
pub mod logparse;
pub mod paths;
pub mod projects;
pub mod service;
pub mod session;
pub mod settings;
pub mod synctex;
pub mod syntax;
pub mod templates;
pub mod texpresso;
pub mod zipexport;

pub use error::CoreError;

pub const BUILD_DIR: &str = "build";
pub const SETTINGS_FILE: &str = ".texlocal.json";

/// The crate's mutexes guard bookkeeping that no panic leaves half-written,
/// or nothing at all, so a poisoned one is still good: it must not fail
/// every later edit, nor panic in a Drop or at quit, where that aborts the host.
pub(crate) fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The end of `text`, at most `max` bytes, from a character boundary.
pub(crate) fn tail(text: &str, max: usize) -> &str {
    &text[text.ceil_char_boundary(text.len().saturating_sub(max))..]
}

/// Bytes as text, replacing invalid UTF-8. Valid input, the usual case,
/// becomes the String without a second copy.
pub(crate) fn lossy_string(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes)
        .unwrap_or_else(|err| String::from_utf8_lossy(err.as_bytes()).into_owned())
}
