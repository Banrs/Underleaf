#[cfg(target_vendor = "apple")]
mod apple;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(unix)]
mod unix;
#[cfg(windows)]
#[rustfmt::skip]
mod windows;

#[cfg(target_vendor = "apple")]
use apple as os;
#[cfg(target_os = "linux")]
use linux as os;
#[cfg(windows)]
use windows as os;

pub(crate) use os::{
    Group, TEX_DIRS, TEXLIVE, TINYTEX_BUNDLE, copy_xattrs, default_permissions, default_signals,
    download, executable, flush, identity, install_as_administrator, kill_group, latexmkrc,
    local_time, private, program, rename_exclusive, spawn_group, tinytex_bin, tinytex_root, trash,
    unpack, wait_exited,
};
