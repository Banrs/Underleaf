use std::ffi::CString;
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};

use tokio::process::Command;

use super::freedesktop::trash_in;
pub(crate) use super::freedesktop::untrash;
pub(crate) use super::unix::*;
use crate::atomic::Flush;
use crate::error::CoreError;
use crate::messages;

pub(crate) const TEX_DIRS: [&str; 2] = ["/usr/local/bin", "/usr/bin"];
pub(crate) const TINYTEX_BUNDLE: (&str, &str) = if cfg!(target_arch = "aarch64") {
    ("TinyTeX-1-linux-arm64-", ".tar.xz")
} else {
    ("TinyTeX-1-linux-x86_64-", ".tar.xz")
};

pub(crate) fn tinytex_root() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join(".TinyTeX"))
}

pub(crate) fn tinytex_bin(root: &Path) -> PathBuf {
    root.join(format!("bin/{}-linux", std::env::consts::ARCH))
}

pub(crate) fn trash(path: &Path) -> Result<PathBuf, CoreError> {
    let data = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from);
    let home = std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"));
    let Some(data) = data.filter(|data| data.is_absolute()).or(home) else {
        return Err(CoreError::unavailable(messages::no_trash()));
    };
    trash_in(&data.join("Trash"), path)
}

pub(crate) fn install_as_administrator(
    _: &Path,
    _: &str,
    _: &str,
) -> Option<(Command, &'static str)> {
    None
}

pub(crate) fn flush(file: &File, flush: Flush) -> io::Result<()> {
    match flush {
        Flush::Full => file.sync_all(),
        Flush::Ordered => file.sync_data(),
    }
}

pub(crate) fn copy_xattrs(_: &Path, _: &File) {}

pub(crate) fn rename_exclusive(from: &Path, to: &Path) -> io::Result<()> {
    let from = CString::new(from.as_os_str().as_encoded_bytes())?;
    let to = CString::new(to.as_os_str().as_encoded_bytes())?;
    let here = libc::AT_FDCWD;
    let flags = libc::RENAME_NOREPLACE;
    if unsafe { libc::renameat2(here, from.as_ptr(), here, to.as_ptr(), flags) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
