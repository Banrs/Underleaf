//! Telling whether a file has changed without reading it.

use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

use crate::lock;

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

/// What was last read from a file, kept until the file changes: a large file read on many a
/// click or save.
pub(crate) struct Kept<T>(Mutex<Option<(Read, Arc<T>)>>);

/// A file, and what stat gave as it was read.
type Read = (PathBuf, Option<Stamp>);

impl<T> Kept<T> {
    pub(crate) const fn new() -> Self {
        Self(Mutex::new(None))
    }

    /// The value kept of `path`, or `read`'s once the file is another or has changed.
    pub(crate) fn get<E>(
        &self,
        path: &Path,
        read: impl FnOnce(&Path) -> Result<T, E>,
    ) -> Result<Arc<T>, E> {
        let now = (
            path.to_owned(),
            fs::metadata(path).ok().map(|meta| Stamp::of(&meta)),
        );
        let mut kept = lock(&self.0);
        if let Some((was, value)) = &*kept
            && *was == now
        {
            return Ok(Arc::clone(value));
        }
        let value = Arc::new(read(path)?);
        *kept = Some((now, Arc::clone(&value)));
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[test]
    fn a_kept_value_is_read_again_only_once_its_file_changes() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("main.synctex");
        fs::write(&file, "one").unwrap();
        let (kept, reads) = (Kept::new(), Cell::new(0));
        let read = |path: &Path| {
            reads.set(reads.get() + 1);
            fs::read_to_string(path)
        };
        for _ in 0..2 {
            assert_eq!(*kept.get(&file, read).unwrap(), "one");
        }
        fs::write(&file, "three").unwrap();
        assert_eq!(*kept.get(&file, read).unwrap(), "three");
        assert_eq!(reads.get(), 2);
    }
}
