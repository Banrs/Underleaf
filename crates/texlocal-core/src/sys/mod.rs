mod apple;
mod unix;

use apple as os;

pub(crate) use os::{
    Group, TEX_DIRS, TEXLIVE, TINYTEX_BUNDLE, copy_xattrs, default_permissions, default_signals,
    download, flush, identity, install_as_administrator, kill_group, latexmkrc, local_time,
    private, program, rename_exclusive, spawn_group, tinytex_bin, tinytex_root, trash, unpack,
    untrash, wait_exited,
};
