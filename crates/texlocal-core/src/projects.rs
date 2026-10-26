mod files;
mod history;
mod library;
mod opened;
mod search;
mod symbols;
mod tree;

use std::fs::File;
use std::io::ErrorKind::{NotFound, PermissionDenied};
use std::io::Read;
use std::path::Path;

use crate::error::CoreError;

pub(crate) const MAX_FILES: usize = 20_000;

pub(crate) use files::{Trash, copy_paths, discard, discard_replaced, write_creating};
pub use files::{create_free, rename_entry};
pub(crate) use history::{History, Taken, put_back};
pub use library::{ProjectInfo, create_project, free_project_name, list_projects, rename_project};
pub(crate) use library::{guess_main_file, new_project};
pub(crate) use opened::{find as find_opened, is_opened};
pub use opened::{forget_folder, open_path};
pub(crate) use search::replace_in_files;
pub use search::{Query, search_groups, search_project};
pub use symbols::{Symbols, scan_symbols};
pub use tree::{TreeNode, file_kind, file_tree};
pub(crate) use tree::{is_text, listed, walk};

fn skip_unreadable<T>(result: std::io::Result<T>) -> Result<Option<T>, CoreError> {
    match result {
        Err(err) if matches!(err.kind(), NotFound | PermissionDenied) => Ok(None),
        result => Ok(Some(result?)),
    }
}

pub(crate) fn read_capped(path: &Path, cap: u64) -> Result<Option<Vec<u8>>, CoreError> {
    let Some(file) = skip_unreadable(File::open(path))? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    let read = skip_unreadable(file.take(cap.saturating_add(1)).read_to_end(&mut bytes))?;
    Ok(read.filter(|&len| len as u64 <= cap).map(|_| bytes))
}

pub(crate) fn is_litter(name: &str) -> bool {
    name.starts_with("._")
        || name.starts_with(".texlocal-")
        || matches!(
            name.to_ascii_lowercase().as_str(),
            ".git" | ".hg" | ".svn" | ".ds_store" | "__macosx"
        )
}
