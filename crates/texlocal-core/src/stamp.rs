use std::collections::HashMap;
use std::fs;
use std::hash::{BuildHasherDefault, DefaultHasher};
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
    pub(crate) fn trusted(&self) -> bool {
        self.modified % 1_000_000_000 != 0
    }
}

type Paths<T> = HashMap<PathBuf, T, BuildHasherDefault<DefaultHasher>>;

pub(crate) struct Kept<T> {
    capacity: usize,
    /// How many values were used, how many times some were forgotten, and the values.
    held: Mutex<(u64, u64, Paths<Held<T>>)>,
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
            held: Mutex::new((0, 0, HashMap::with_hasher(BuildHasherDefault::new()))),
        }
    }

    pub(crate) fn get<E>(
        &self,
        path: &Path,
        read: impl FnOnce(&Path) -> Result<T, E>,
    ) -> Result<Arc<T>, E> {
        self.get_since(None, path, read)
    }

    /// How many times values were forgotten, for a reader to note before it starts.
    pub(crate) fn forgets(&self) -> u64 {
        lock(&self.held).1
    }

    /// As `get`, for a reader that noted `forgets` before it started, or does now. What it reads isn't kept if
    /// anything was forgotten since, as the value may be what was: forgetting it before the read ended would
    /// otherwise leave it kept for good.
    pub(crate) fn get_since<E>(
        &self,
        noted: Option<u64>,
        path: &Path,
        read: impl FnOnce(&Path) -> Result<T, E>,
    ) -> Result<Arc<T>, E> {
        let stamp = Stamp::at(path).ok();
        let noted = {
            let (uses, forgets, held) = &mut *lock(&self.held);
            if let Some(kept) = held.get_mut(path)
                && stamp.is_some_and(|stamp| stamp == kept.stamp && stamp.trusted())
            {
                *uses += 1;
                kept.used = *uses;
                return Ok(Arc::clone(&kept.value));
            }
            noted.unwrap_or(*forgets)
        };
        let value = Arc::new(read(path)?);
        if let Some(stamp) = stamp {
            let (uses, forgets, held) = &mut *lock(&self.held);
            if *forgets != noted {
                return Ok(value);
            }
            *uses += 1;
            let kept = Held {
                stamp,
                used: *uses,
                value: Arc::clone(&value),
            };
            held.insert(path.to_owned(), kept);
            if held.len() > self.capacity {
                // An eighth goes at once, so a full cache isn't scanned on every read.
                let keep = self.capacity - self.capacity / 8;
                let mut uses: Vec<u64> = held.values().map(|kept| kept.used).collect();
                let (_, &mut oldest_kept, _) = uses.select_nth_unstable(held.len() - keep);
                held.retain(|_, kept| kept.used >= oldest_kept);
            }
        }
        Ok(value)
    }

    /// Drops the values kept for the paths chosen, which would otherwise stay until as many others as it holds were read.
    pub(crate) fn forget(&self, chosen: impl Fn(&Path) -> bool) {
        let dropped: Vec<_> = {
            let (_, forgets, held) = &mut *lock(&self.held);
            *forgets += 1;
            held.extract_if(|path, _| chosen(path)).collect()
        };
        drop(dropped);
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
        get(one).unwrap();
        assert_eq!(reads.get(), 8);
        kept.forget(|path| path == two);
        get(one).unwrap();
        assert_eq!(reads.get(), 8);
        kept.forget(|path| path == one);
        get(one).unwrap();
        assert_eq!(reads.get(), 9);
    }

    #[test]
    fn a_value_forgotten_while_it_was_read_or_before_its_reader_started_is_not_kept() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("file");
        fs::write(&file, "a").unwrap();
        let (kept, reads) = (Kept::new(), std::cell::Cell::new(0));
        let read = |path: &Path| {
            reads.set(reads.get() + 1);
            fs::read_to_string(path)
        };
        let forgotten = |path: &Path| {
            kept.forget(|chosen| chosen == path);
            read(path)
        };
        assert_eq!(*kept.get(&file, forgotten).unwrap(), "a");
        let waiting = kept.forgets();
        assert_eq!(*kept.get(&file, read).unwrap(), "a");
        assert_eq!(*kept.get(&file, read).unwrap(), "a");
        assert_eq!(
            reads.get(),
            2,
            "the first read wasn't kept and the second was"
        );
        kept.forget(|chosen| chosen == file);
        assert_eq!(*kept.get_since(Some(waiting), &file, read).unwrap(), "a");
        assert_eq!(*kept.get(&file, read).unwrap(), "a");
        assert_eq!(*kept.get_since(Some(waiting), &file, read).unwrap(), "a");
        assert_eq!(
            reads.get(),
            4,
            "a late reader's isn't kept, and it is given what is"
        );
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
