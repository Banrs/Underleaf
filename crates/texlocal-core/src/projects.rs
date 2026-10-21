//! Project and file management over the modules below; all returned paths use forward slashes.

mod files;
mod library;
mod opened;
mod search;
mod symbols;
#[cfg(test)]
pub(crate) mod testing;
#[cfg(test)]
mod tests;
mod tree;

use std::io::ErrorKind::{NotFound, PermissionDenied};

use crate::error::CoreError;

pub(crate) use files::{Trash, copy_paths, discard, discard_replaced, write_creating};
pub use files::{create_free, rename_entry};
pub use library::{
    ProjectInfo, create_project, free_project_name, list_projects, locate, rename_project,
};
pub(crate) use library::{guess_main_file, new_project};
pub(crate) use opened::{find as find_opened, is_opened};
pub use opened::{forget_folder, open_path};
pub(crate) use search::replace_in_files;
pub use search::{Query, search_groups, search_project};
pub use symbols::{Symbols, scan_symbols};
pub(crate) use tree::is_text;
pub use tree::{TreeNode, file_kind, file_tree};

fn skip_unreadable<T>(result: std::io::Result<T>) -> Result<Option<T>, CoreError> {
    match result {
        Err(err) if matches!(err.kind(), NotFound | PermissionDenied) => Ok(None),
        result => Ok(Some(result?)),
    }
}

/// Names a project folder holds that are not the author's work, at any depth: version control, what macOS leaves behind, and the core's temporary files. Other dotfiles (.latexmkrc) are the author's.
pub(crate) fn is_litter(name: &str) -> bool {
    name.starts_with("._")
        || name.starts_with(".texlocal-")
        || matches!(
            name.to_ascii_lowercase().as_str(),
            ".git" | ".hg" | ".svn" | ".ds_store" | "__macosx"
        )
}
