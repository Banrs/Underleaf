// TeXLocal's core: projects, compilation, the path rules that keep both
// inside the data directory, project sessions, and the editors' LaTeX logic
// (`syntax`). Deliberately GUI-free, so it tests on any host.
//
// Path convention: every project-relative path this crate RETURNS or STORES
// uses forward slashes — the hosts and SyncTeX both expect '/'.

mod analyze;
mod atomic;
pub mod compile;
pub mod error;
pub mod events;
mod import;
pub mod logparse;
pub mod paths;
pub mod projects;
pub mod service;
pub mod session;
pub mod settings;
mod synctex;
pub mod syntax;
mod templates;
pub mod texpresso;
mod zipexport;

pub use error::CoreError;

pub(crate) const BUILD_DIR: &str = "build";
pub(crate) const SETTINGS_FILE: &str = ".texlocal.json";

/// The crate's mutexes guard bookkeeping that no panic leaves half-written,
/// or nothing at all, so a poisoned one is still good: it must not fail
/// every later edit, nor panic in a Drop or at quit, where that aborts the host.
pub(crate) fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
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

/// What the unit tests share.
#[cfg(test)]
pub(crate) mod testing {
    use std::{fs, path::Path};

    use crate::service::Service;

    /// A library in a folder of its own, which leaves room beside it for what
    /// a test brings in, holding the blank projects `ids`.
    pub(crate) fn library(ids: &[&str]) -> (tempfile::TempDir, Service) {
        let dir = tempfile::tempdir().unwrap();
        let service = Service::new(dir.path().join("data"));
        fs::create_dir_all(&service.data_dir).unwrap();
        for id in ids {
            crate::projects::create_project(&service.data_dir, id, "blank").unwrap();
        }
        (dir, service)
    }

    /// Writes `files`, each a path and its text, under `dir`.
    pub(crate) fn write_files(dir: &Path, files: &[(&str, &str)]) {
        for (path, text) in files {
            let path = dir.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        }
    }
}
