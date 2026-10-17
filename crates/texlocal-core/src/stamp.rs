//! Telling whether a file has changed without reading it.

use serde::Serialize;
use std::fs::Metadata;
use std::time::UNIX_EPOCH;

/// A file as written: which file it is, its length, and when it was last
/// written, to the nanosecond, as stat gives them (st_ino, st_size, and
/// st_mtime and its nanoseconds, from 0 up even before 1970). A client that
/// keeps it knows a change it is told of for the file is its own write's while
/// a stat still gives the same, without reading the file back. Windows has no
/// inode a stat gives, and the stamp none: there, length and date alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Stamp {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inode: Option<u64>,
    pub size: u64,
    pub seconds: i64,
    pub nanoseconds: i64,
}

impl Stamp {
    pub fn of(meta: &Metadata) -> Self {
        #[cfg(unix)]
        let inode = Some(std::os::unix::fs::MetadataExt::ino(meta));
        #[cfg(not(unix))]
        let inode = None;
        let nanos = match meta.modified().map(|time| time.duration_since(UNIX_EPOCH)) {
            Ok(Ok(after)) => after.as_nanos() as i128,
            Ok(Err(before)) => -(before.duration().as_nanos() as i128),
            Err(_) => 0,
        };
        // Before 1970 too, as a timespec has it: seconds down, then
        // nanoseconds up from them.
        const NANOS: i128 = 1_000_000_000;
        Self {
            inode,
            size: meta.len(),
            seconds: nanos.div_euclid(NANOS) as i64,
            nanoseconds: nanos.rem_euclid(NANOS) as i64,
        }
    }
}
