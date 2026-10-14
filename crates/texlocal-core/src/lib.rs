// TeXLocal's core: projects, compilation, and the path rules that keep both
// inside the data directory. Deliberately GUI-free, so it tests on any host
// without a webview.
//
// Path convention: every project-relative path this crate RETURNS or STORES
// uses forward slashes — the frontend and SyncTeX both expect '/'.

pub mod analyze;
mod atomic;
pub mod compile;
pub mod error;
pub mod import;
pub mod logparse;
pub mod paths;
pub mod projects;
pub mod service;
pub mod settings;
pub mod synctex;
pub mod templates;
pub mod texpresso;
pub mod zipexport;

pub use error::CoreError;

pub const BUILD_DIR: &str = "build";
pub const SETTINGS_FILE: &str = ".texlocal.json";

/// Where projects live: `TEXLOCAL_DATA` when set, else ~/TeXLocal — visible in
/// the file manager, syncable, and (unlike ~/Documents on macOS) not behind a
/// privacy gate, so no host hangs waiting on a folder-permission prompt. The
/// browser server opens it, and the Mac app the folder its Swift finds by the
/// same rule (Core.libraryFolder, which Home names when it can't be opened),
/// so both see one library.
pub fn default_data_dir() -> std::path::PathBuf {
    if let Some(dir) = std::env::var_os("TEXLOCAL_DATA").filter(|v| !v.is_empty()) {
        return dir.into();
    }
    std::env::home_dir()
        .map(|home| home.join("TeXLocal"))
        .unwrap_or_else(|| "TeXLocal".into())
}

/// `bytes` bytes from the system's random source, as lowercase hex: the
/// browser server's token and each live preview session's.
pub fn random_hex(bytes: usize) -> Result<String, CoreError> {
    let mut random = vec![0u8; bytes];
    getrandom::fill(&mut random).map_err(|err| CoreError::internal(err.to_string()))?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

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
