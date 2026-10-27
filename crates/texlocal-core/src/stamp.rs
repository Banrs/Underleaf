use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

use crate::{lock, sys};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    pub inode: Option<u64>,
    pub size: u64,
    pub modified: i128,
}

impl Stamp {
    pub fn of(meta: &Metadata) -> Self {
        let inode = sys::inode(meta);
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

pub(crate) struct Kept<T>(Mutex<Option<(Read, Arc<T>)>>);

type Read = (PathBuf, Option<Stamp>);

impl<T> Kept<T> {
    pub(crate) const fn new() -> Self {
        Self(Mutex::new(None))
    }

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
