// TeXLocal's core: projects, compilation, and the path rules that keep both
// inside the data directory. Deliberately GUI-free, so it tests on any host
// without a webview.
//
// Path convention: every project-relative path this crate RETURNS or STORES
// uses forward slashes, on every platform — the frontend splits on '/', and
// SyncTeX wants '/' regardless of OS. Inputs are accepted with either
// separator.

pub mod compile;
pub mod error;
pub mod logparse;
pub mod paths;
pub mod projects;
pub mod serve;
pub mod service;
pub mod settings;
pub mod synctex;
pub mod templates;
pub mod zipexport;

pub use error::CoreError;

pub const BUILD_DIR: &str = "build";
pub const SETTINGS_FILE: &str = ".texlocal.json";

/// Where projects live: `TEXLOCAL_DATA` when set, else ~/TeXLocal — visible in
/// the file manager, syncable, and (unlike ~/Documents on macOS) not behind a
/// privacy gate, so no host hangs waiting on a folder-permission prompt. Every
/// host uses this, so the desktop app and the browser server see one library.
pub fn default_data_dir() -> std::path::PathBuf {
    if let Some(dir) = std::env::var_os("TEXLOCAL_DATA").filter(|v| !v.is_empty()) {
        return dir.into();
    }
    std::env::home_dir()
        .map(|home| home.join("TeXLocal"))
        .unwrap_or_else(|| "TeXLocal".into())
}
