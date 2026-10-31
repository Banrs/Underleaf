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
            identity: sys::identity(path, &meta)?,
            size: meta.len(),
            modified,
        })
    }
}

pub(crate) struct Kept<T>(Mutex<Vec<(Read, Arc<T>)>>);

type Read = (PathBuf, Option<Stamp>);

const KEPT: usize = 4;

impl<T> Kept<T> {
    pub(crate) const fn new() -> Self {
        Self(Mutex::new(Vec::new()))
    }

    pub(crate) fn get<E>(
        &self,
        path: &Path,
        read: impl FnOnce(&Path) -> Result<T, E>,
    ) -> Result<Arc<T>, E> {
        let stamp = Stamp::at(path).ok();
        let read_as = (path.to_owned(), stamp);
        let mut kept = lock(&self.0);
        if let Some(at) = kept.iter().position(|(was, _)| *was == read_as) {
            kept[..=at].rotate_right(1);
            return Ok(Arc::clone(&kept[0].1));
        }
        drop(kept);
        let value = Arc::new(read(path)?);
        let mut kept = lock(&self.0);
        kept.retain(|((was, _), _)| was != path);
        kept.truncate(KEPT - 1);
        kept.insert(0, (read_as, Arc::clone(&value)));
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
