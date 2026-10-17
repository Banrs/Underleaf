//! Writing a file whole or not at all: the new contents go to a temporary file
//! beside it, reach the disk, then take its place in one rename. A full disk
//! or a crash part-way leaves the old file as it was, where writing in place
//! would leave it empty or cut short.

use serde::Serialize;
use std::fs::{self, File, Metadata, Permissions};
use std::io::{self, Write};
use std::path::Path;
use std::time::UNIX_EPOCH;
use tempfile::TempPath;

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

/// A new, empty temporary file beside `path`, removed if it is not persisted,
/// with the mode it should have once it takes `path`'s place: `existing`, a
/// replaced file's own, else a new file's (0666 less the umask), as any other
/// way of making a file gives it. tempfile's own 0600 would leave every file
/// the app made unreadable to the accounts and tools a project is shared with.
pub(crate) fn create_temp(
    path: &Path,
    existing: Option<Permissions>,
) -> io::Result<(TempPath, File)> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    let mut builder = tempfile::Builder::new();
    builder.prefix(".texlocal-");
    #[cfg(unix)]
    if existing.is_none() {
        use std::os::unix::fs::PermissionsExt;
        builder.permissions(Permissions::from_mode(0o666));
    }
    let temp = builder.tempfile_in(parent.unwrap_or(Path::new(".")))?;
    let (file, path) = temp.into_parts();
    // Before the contents, so a private file's text is never readable
    // under the temporary file's default mode.
    if let Some(permissions) = existing {
        file.set_permissions(permissions)?;
    }
    Ok((path, file))
}

/// Moves a finished temporary file into `path`'s place in one rename. std's
/// rather than tempfile's, which on Windows reaches no path past 260
/// characters.
pub(crate) fn persist(temp: TempPath, path: &Path) -> io::Result<()> {
    fs::rename(&temp, path)?;
    // Renamed, it is no longer there to remove.
    let _ = temp.keep();
    Ok(())
}

/// Replace `path`'s contents with `bytes`, or create it. A symlinked file is
/// written through, so the link stays a link, and the file keeps its
/// permissions; a read-only file is refused, as writing it in place would be.
/// The stamp is the temporary file's, which the rename keeps: one taken
/// after it could be another app's write landing in between. It is taken
/// once the file is closed, as Windows dates the last write then.
pub(crate) fn write(path: &Path, bytes: &[u8]) -> io::Result<Stamp> {
    let target = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => dunce::canonicalize(path)?,
        _ => path.to_path_buf(),
    };
    let permissions = fs::metadata(&target).ok().map(|meta| meta.permissions());
    if permissions.as_ref().is_some_and(fs::Permissions::readonly) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let (temp, mut file) = create_temp(&target, permissions)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    let stamp = Stamp::of(&fs::metadata(&temp)?);
    persist(temp, &target)?;
    Ok(stamp)
}

#[cfg(test)]
mod tests {
    use super::{Stamp, write};
    use std::fs;

    fn names(dir: &std::path::Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn a_save_creates_and_replaces_leaving_no_temporary_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("main.tex");
        write(&file, b"one").unwrap();
        write(&file, b"two").unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"two");
        assert_eq!(names(dir.path()), ["main.tex"]);
    }

    #[test]
    fn a_save_answers_the_stamp_the_file_then_has() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("main.tex");
        let written = write(&file, b"one").unwrap();
        assert_eq!(written, Stamp::of(&fs::metadata(&file).unwrap()));
        // Another app's write in place keeps the file but not the stamp, once
        // the clock has moved: Windows dates writes in steps of up to 16 ms.
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(&file, b"two").unwrap();
        assert_ne!(written, Stamp::of(&fs::metadata(&file).unwrap()));
    }

    #[test]
    fn a_save_that_cannot_complete_leaves_the_original_intact() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("locked.tex");
        fs::write(&file, "keep").unwrap();
        // A read-only file is refused, as writing it in place would be.
        let mut perms = fs::metadata(&file).unwrap().permissions();
        perms.set_readonly(true);
        fs::set_permissions(&file, perms.clone()).unwrap();
        assert!(write(&file, b"new").is_err());
        assert_eq!(fs::read_to_string(&file).unwrap(), "keep");
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        fs::set_permissions(&file, perms).unwrap();

        // No temporary file can be made beside it.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o555)).unwrap();
            let result = write(&file, b"new");
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
            assert!(result.is_err());
            assert_eq!(fs::read_to_string(&file).unwrap(), "keep");
            assert_eq!(names(dir.path()), ["locked.tex"]);
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_save_writes_through_a_symlink_keeps_a_mode_and_gives_a_new_file_the_usual_one() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mode = |path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        let target = dir.path().join("real.tex");
        let link = dir.path().join("link.tex");
        fs::write(&target, "old").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o640)).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        write(&link, b"new").unwrap();
        let kind = fs::symlink_metadata(&link).unwrap().file_type();
        assert!(kind.is_symlink());
        assert_eq!(fs::read_to_string(&target).unwrap(), "new");
        assert_eq!(mode(&target), 0o640);

        let usual = dir.path().join("usual.tex");
        fs::write(&usual, "").unwrap();
        let file = dir.path().join("main.tex");
        write(&file, b"new").unwrap();
        assert_eq!(mode(&file), mode(&usual));
        // A private file stays private when it is saved again.
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        write(&file, b"again").unwrap();
        assert_eq!(mode(&file), 0o600);
    }
}
