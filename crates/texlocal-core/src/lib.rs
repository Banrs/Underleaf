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
pub mod settings;
pub mod synctex;
pub mod templates;
pub mod zipexport;

pub use error::CoreError;

pub const BUILD_DIR: &str = "build";
pub const SETTINGS_FILE: &str = ".texlocal.json";
