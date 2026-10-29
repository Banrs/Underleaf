use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

use crate::{lock, sys};

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    pub identity: (u64, u64),
    pub size: u64,
    pub modified: i128,
}

impl Stamp {
    pub fn of(meta: &Metadata) -> Self {
        let modified = match meta.modified().map(|time| time.duration_since(UNIX_EPOCH)) {
            Ok(Ok(after)) => after.as_nanos() as i128,
            Ok(Err(before)) => -(before.duration().as_nanos() as i128),
            Err(_) => 0,
        };
        Self {
            identity: sys::identity(meta),
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
        let stamp = fs::metadata(path).ok().map(|meta| Stamp::of(&meta));
        let mut kept = lock(&self.0);
        if let Some(((was, stamped), value)) = &*kept
            && was == path
            && *stamped == stamp
        {
            return Ok(Arc::clone(value));
        }
        let value = Arc::new(read(path)?);
        *kept = Some(((path.to_owned(), stamp), Arc::clone(&value)));
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kept_value_is_read_again_only_when_its_file_or_path_changes() {
        let dir = tempfile::tempdir().unwrap();
        let (one, two) = (dir.path().join("one"), dir.path().join("two"));
        fs::write(&one, "a").unwrap();
        fs::write(&two, "a").unwrap();
        let kept = Kept::new();
        let reads = std::cell::Cell::new(0);
        let get = |path: &Path| {
            let read = |path: &Path| {
                reads.set(reads.get() + 1);
                fs::read_to_string(path)
            };
            kept.get(path, read)
        };
        assert_eq!(*get(&one).unwrap(), "a");
        assert_eq!(*get(&one).unwrap(), "a");
        assert_eq!(reads.get(), 1);
        fs::write(&one, "bc").unwrap();
        assert_eq!(*get(&one).unwrap(), "bc");
        assert_eq!(*get(&two).unwrap(), "a");
        assert_eq!(reads.get(), 3);
        fs::remove_file(&two).unwrap();
        assert!(get(&two).is_err());
    }
}
