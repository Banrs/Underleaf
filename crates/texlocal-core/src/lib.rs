mod atomic;
mod compile;
mod error;
mod events;
mod import;
pub mod messages;
mod packages;
mod paths;
mod process;
mod projects;
pub mod protocol;
pub mod service;
pub mod session;
mod settings;
mod stamp;
mod synctex;
mod sys;
mod tex;
mod texpresso;
mod tinytex;
mod zipexport;

pub use error::{CoreError, ErrorKind};

pub(crate) const BUILD_DIR: &str = "build";
pub(crate) const SETTINGS_FILE: &str = ".texlocal.json";
pub(crate) const HISTORY_DIR: &str = ".texlocal-history";

pub(crate) fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

pub(crate) fn tail(text: &str, max: usize) -> &str {
    &text[text.ceil_char_boundary(text.len().saturating_sub(max))..]
}

pub(crate) fn lf(text: String) -> String {
    if text.contains('\r') {
        text.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        text
    }
}

pub(crate) fn newline(text: &str) -> &'static str {
    let Some(at) = text.find(['\r', '\n']) else {
        return "\n";
    };
    match &text.as_bytes()[at..] {
        [b'\r', b'\n', ..] => "\r\n",
        [b'\r', ..] => "\r",
        _ => "\n",
    }
}

pub(crate) fn lossy_string(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes)
        .unwrap_or_else(|err| String::from_utf8_lossy(err.as_bytes()).into_owned())
}

pub(crate) fn sha256(bytes: &[u8]) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}
