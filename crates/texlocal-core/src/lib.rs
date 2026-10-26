mod analyze;
mod atomic;
mod checks;
mod compile;
mod error;
pub mod events;
mod import;
mod logparse;
mod packages;
mod paths;
mod process;
mod projects;
pub mod service;
pub mod session;
mod settings;
mod stamp;
mod synctex;
pub mod syntax;
mod templates;
mod tex;
mod texpresso;
mod tinytex;
mod wordmatch;
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

pub(crate) fn utf16_lossy(units: &[u16]) -> String {
    let mut bytes = Vec::with_capacity(units.len());
    let mut rest = units;
    while !rest.is_empty() {
        let ascii = rest.iter().position(|&u| u >= 0x80).unwrap_or(rest.len());
        bytes.extend(rest[..ascii].iter().map(|&u| u as u8));
        rest = &rest[ascii..];
        let other = rest.iter().position(|&u| u < 0x80).unwrap_or(rest.len());
        let mut buf = [0; 4];
        for c in char::decode_utf16(rest[..other].iter().copied()) {
            let c = c.unwrap_or(char::REPLACEMENT_CHARACTER);
            bytes.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
        rest = &rest[other..];
    }
    String::from_utf8(bytes).expect("ASCII and encoded chars are UTF-8")
}
