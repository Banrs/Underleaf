use std::collections::BTreeMap;
use std::fs;
use std::io;
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
    pub fn at(path: &Path) -> io::Result<Self> {
        let meta = fs::metadata(path)?;
        let modified = match meta.modified().map(|time| time.duration_since(UNIX_EPOCH)) {
            Ok(Ok(after)) => after.as_nanos() as i128,
            Ok(Err(before)) => -(before.duration().as_nanos() as i128),
            Err(_) => 0,
        };
        Ok(Self {
            identity: sys::identity(&meta),
            size: meta.len(),
            modified,
        })
    }

    // A time in whole seconds may come from a filesystem that keeps only seconds, where a file
    // written again within that second keeps its stamp.
    fn trusted(&self) -> bool {
        self.modified % 1_000_000_000 != 0
    }
}

/// Values read from files, read again when a file's stamp changes, keeping the most recently
/// used up to a capacity.
pub(crate) struct Kept<T> {
    capacity: usize,
    held: Mutex<(u64, BTreeMap<PathBuf, Held<T>>)>,
}

struct Held<T> {
    stamp: Stamp,
    used: u64,
    value: Arc<T>,
}

impl<T> Kept<T> {
    pub(crate) const fn new() -> Self {
        Self::holding(4)
    }

    pub(crate) const fn holding(capacity: usize) -> Self {
        Self {
            capacity,
            held: Mutex::new((0, BTreeMap::new())),
        }
    }

    pub(crate) fn get<E>(
        &self,
        path: &Path,
        read: impl FnOnce(&Path) -> Result<T, E>,
    ) -> Result<Arc<T>, E> {
        let stamp = Stamp::at(path).ok();
        {
            let (uses, held) = &mut *lock(&self.held);
            if let Some(kept) = held.get_mut(path)
                && stamp.is_some_and(|stamp| stamp == kept.stamp && stamp.trusted())
            {
                *uses += 1;
                kept.used = *uses;
                return Ok(Arc::clone(&kept.value));
            }
        }
        let value = Arc::new(read(path)?);
        if let Some(stamp) = stamp {
            let (uses, held) = &mut *lock(&self.held);
            *uses += 1;
            let kept = Held {
                stamp,
                used: *uses,
                value: Arc::clone(&value),
            };
            held.insert(path.to_owned(), kept);
            if held.len() > self.capacity {
                let oldest = held.iter().min_by_key(|(_, kept)| kept.used);
                let oldest = oldest.map(|(path, _)| path.clone());
                held.remove(&oldest.expect("over capacity, so not empty"));
            }
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kept_value_is_read_again_when_its_file_changes_or_four_others_were_used_since() {
        let dir = tempfile::tempdir().unwrap();
        let files = ["one", "two", "three", "four", "five"].map(|name| dir.path().join(name));
        for file in &files {
            fs::write(file, "a").unwrap();
        }
        let [one, two, ..] = &files;
        let kept = Kept::new();
        let reads = std::cell::Cell::new(0);
        let get = |path: &Path| {
            let read = |path: &Path| {
                reads.set(reads.get() + 1);
                fs::read_to_string(path)
            };
            kept.get(path, read)
        };
        assert_eq!(*get(one).unwrap(), "a");
        assert_eq!(*get(two).unwrap(), "a");
        assert_eq!(*get(one).unwrap(), "a");
        assert_eq!(reads.get(), 2);
        fs::write(one, "bc").unwrap();
        assert_eq!(*get(one).unwrap(), "bc");
        assert_eq!(*get(two).unwrap(), "a");
        assert_eq!(reads.get(), 3);
        for file in &files[2..] {
            get(file).unwrap();
        }
        get(two).unwrap();
        assert_eq!(reads.get(), 6);
        get(one).unwrap();
        assert_eq!(reads.get(), 7);
        fs::remove_file(two).unwrap();
        assert!(get(two).is_err());
    }

    #[test]
    fn two_readers_read_at_once_and_a_file_replaced_while_read_is_read_again() {
        use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
        use std::time::{Duration, Instant};
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("file");
        fs::write(&file, "a").unwrap();
        let (kept, reads) = (Kept::new(), AtomicUsize::new(0));
        let together = |path: &Path| {
            reads.fetch_add(1, SeqCst);
            let deadline = Instant::now() + Duration::from_secs(5);
            while reads.load(SeqCst) < 2 && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(1));
            }
            fs::read_to_string(path).map(|text| (text, reads.load(SeqCst)))
        };
        std::thread::scope(|scope| {
            let readers = [(); 2].map(|()| scope.spawn(|| kept.get(&file, together)));
            for reader in readers {
                assert_eq!(*reader.join().unwrap().unwrap(), ("a".to_owned(), 2));
            }
        });
        assert_eq!(*kept.get(&file, together).unwrap(), ("a".to_owned(), 2));
        fs::write(&file, "bc").unwrap();
        let replaced = kept.get(&file, |path| {
            fs::write(path, "def")?;
            together(path)
        });
        assert_eq!(*replaced.unwrap(), ("def".to_owned(), 3));
        assert_eq!(*kept.get(&file, together).unwrap(), ("def".to_owned(), 4));
    }
}
