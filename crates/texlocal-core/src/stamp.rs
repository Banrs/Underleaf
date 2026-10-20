//! Telling whether a file has changed without reading it.

use std::fs::Metadata;
use std::time::UNIX_EPOCH;

/// A file as written: inode, length and mtime (nanoseconds) as stat gives them, so a session can tell a change is its own write without reading back. Windows has no inode: length and date alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    pub inode: Option<u64>,
    pub size: u64,
    pub modified: i128,
}

impl Stamp {
    pub fn of(meta: &Metadata) -> Self {
        #[cfg(unix)]
        let inode = Some(std::os::unix::fs::MetadataExt::ino(meta));
        #[cfg(not(unix))]
        let inode = None;
        let modified = match meta.modified().map(|time| time.duration_since(UNIX_EPOCH)) {
            Ok(Ok(after)) => after.as_nanos() as i128,
            Ok(Err(before)) => -(before.duration().as_nanos() as i128),
            Err(_) => 0,
        };
        Self {
            inode,
            size: meta.len(),
            modified,
        }
    }
}
