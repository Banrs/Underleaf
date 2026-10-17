//! Project and file management. Every project is a directory under the data
//! dir; all returned paths use forward slashes.
//!
//! The work is in the modules below, by what each is about: the `library` of
//! projects, the `tree` a project shows, the `files` the author makes and
//! moves, `search` across the text files, and the `symbols` they define. They
//! are re-exported here, so callers name `projects::` alone.

mod files;
mod library;
mod search;
mod symbols;
#[cfg(test)]
pub(crate) mod testing;
mod tree;

use std::io::ErrorKind::{NotFound, PermissionDenied};

use crate::error::CoreError;

pub use files::{RenameResult, create_file, create_free, rename_entry};
pub(crate) use files::{Trash, copy_paths, discard, discard_replaced, write_creating};
pub use library::{
    Located, ProjectInfo, UNTITLED, create_project, create_project_with_engine, free_project_name,
    list_projects, locate, rename_project,
};
pub(crate) use library::{Staging, guess_main_file};
pub use search::{SearchGroup, SearchHit, search_groups, search_project};
pub use symbols::{SymbolScan, Symbols};
pub use tree::{TreeNode, file_kind, file_tree};

/// A vanished or unreadable entry is skipped without failing a project scan.
fn skip_unreadable<T>(result: std::io::Result<T>) -> Result<Option<T>, CoreError> {
    match result {
        Err(err) if matches!(err.kind(), NotFound | PermissionDenied) => Ok(None),
        result => Ok(Some(result?)),
    }
}

/// Names a project folder holds that are not the author's work, at any depth:
/// version-control folders, what macOS leaves in a folder or a zip, and the
/// temporary files the core writes beside a document. An import leaves them
/// behind and an export doesn't take them; every other dotfile (.latexmkrc)
/// is the author's, though the file tree hides it.
pub(crate) fn is_litter(name: &str) -> bool {
    name.starts_with("._")
        || name.starts_with(".texlocal-")
        || matches!(
            name.to_ascii_lowercase().as_str(),
            ".git" | ".hg" | ".svn" | ".ds_store" | "__macosx"
        )
}
