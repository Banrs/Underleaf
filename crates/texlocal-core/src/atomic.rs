//! Writing a file whole or not at all: the new contents go to a temporary file
//! beside it, reach the disk, then take its place in one rename. A full disk
//! or a crash part-way leaves the old file as it was, where writing in place
//! would leave it empty or cut short.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A fresh hidden name beside `path`, ending in `.{ext}`. Hidden, so the
/// project walks never show one left behind by a crash.
fn sibling(path: &Path, ext: &str) -> PathBuf {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    // Shortened, so a name near the volume's 255-byte limit still has room.
    let name: String = path
        .file_name()
        .map(|n| n.to_string_lossy().chars().take(64).collect())
        .unwrap_or_default();
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    parent.join(format!(".{name}.texlocal-{}-{n}.{ext}", std::process::id()))
}

/// A new, empty temporary file beside `path`, and its name.
pub(crate) fn create_temp(path: &Path) -> io::Result<(PathBuf, File)> {
    loop {
        let candidate = sibling(path, "tmp");
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => return Ok((candidate, file)),
            // Left by an earlier process with this pid; the counter moves on.
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }
}

/// Move the completed `temp` over `dest`. Windows refuses to rename over a
/// file some other program holds open without sharing; there the old file
/// steps aside first and comes back if the move still fails.
pub(crate) fn replace(temp: &Path, dest: &Path) -> io::Result<()> {
    match fs::rename(temp, dest) {
        #[cfg(windows)]
        Err(err)
            if dest.exists()
                && matches!(
                    err.kind(),
                    io::ErrorKind::AlreadyExists | io::ErrorKind::PermissionDenied
                ) =>
        {
            let backup = sibling(dest, "bak");
            fs::rename(dest, &backup)?;
            fs::rename(temp, dest).inspect_err(|_| {
                let _ = fs::rename(&backup, dest);
            })?;
            let _ = fs::remove_file(backup);
            Ok(())
        }
        result => result,
    }
}

/// Replace `path`'s contents with `bytes`, or create it. A symlinked file is
/// written through, so the link stays a link, and the file keeps its
/// permissions; a read-only file is refused, as writing it in place would be.
pub(crate) fn write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let target = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => fs::canonicalize(path)?,
        _ => path.to_path_buf(),
    };
    let old = fs::metadata(&target).ok();
    if old
        .as_ref()
        .is_some_and(|meta| meta.permissions().readonly())
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let (temp, mut file) = create_temp(&target)?;
    let result = (|| {
        // Before the contents, so a private file's text is never readable
        // under the temporary file's default mode.
        if let Some(meta) = &old {
            file.set_permissions(meta.permissions())?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        // Closed before the rename, which Windows needs.
        drop(file);
        replace(&temp, &target)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::write;
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

    #[cfg(unix)]
    #[test]
    fn a_failed_save_leaves_the_original_intact() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("main.tex");
        fs::write(&file, "original").unwrap();
        // No temporary file can be made beside it.
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o555)).unwrap();
        let result = write(&file, b"new");
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&file).unwrap(), "original");
        assert_eq!(names(dir.path()), ["main.tex"]);
    }

    #[cfg(unix)]
    #[test]
    fn a_save_through_a_symlink_writes_its_target_and_keeps_the_mode() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("real.tex");
        let link = dir.path().join("link.tex");
        fs::write(&target, "old").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o640)).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        write(&link, b"new").unwrap();
        assert!(fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(fs::read_to_string(&target).unwrap(), "new");
        let mode = fs::metadata(&target).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o640);
    }

    #[test]
    fn a_file_with_a_long_name_saves() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(format!("{}.tex", "n".repeat(240)));
        write(&file, b"one").unwrap();
        write(&file, b"two").unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"two");
        assert_eq!(names(dir.path()).len(), 1);
    }

    #[test]
    fn a_read_only_file_is_not_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("locked.tex");
        fs::write(&file, "keep").unwrap();
        let mut perms = fs::metadata(&file).unwrap().permissions();
        perms.set_readonly(true);
        fs::set_permissions(&file, perms.clone()).unwrap();
        assert!(write(&file, b"new").is_err());
        assert_eq!(fs::read_to_string(&file).unwrap(), "keep");
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        fs::set_permissions(&file, perms).unwrap();
    }
}
