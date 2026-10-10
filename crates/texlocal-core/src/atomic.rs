//! Writing a file whole or not at all: the new contents go to a temporary file
//! beside it, reach the disk, then take its place in one rename. A full disk
//! or a crash part-way leaves the old file as it was, where writing in place
//! would leave it empty or cut short.

use std::fs::{self, File, Permissions};
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use tempfile::TempPath;

/// A new, empty temporary file beside `path`, removed if it is not persisted,
/// with the mode `path` should have once it takes its place: the file's own
/// if it exists, else a new file's (0666 less the umask), as any other way of
/// making a file gives it. tempfile's own 0600 would leave every file the app
/// made unreadable to the other accounts and tools a project is shared with.
pub(crate) fn create_temp(path: &Path) -> io::Result<(TempPath, File)> {
    create_temp_with(path, fs::metadata(path).ok().map(|meta| meta.permissions()))
}

fn create_temp_with(path: &Path, existing: Option<Permissions>) -> io::Result<(TempPath, File)> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    let mut builder = tempfile::Builder::new();
    builder.prefix(".texlocal-");
    if existing.is_none() {
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

/// Replace `path`'s contents with `bytes`, or create it. A symlinked file is
/// written through, so the link stays a link, and the file keeps its
/// permissions; a read-only file is refused, as writing it in place would be.
pub(crate) fn write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let target = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => fs::canonicalize(path)?,
        _ => path.to_path_buf(),
    };
    let permissions = fs::metadata(&target).ok().map(|meta| meta.permissions());
    if permissions.as_ref().is_some_and(fs::Permissions::readonly) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let (temp, mut file) = create_temp_with(&target, permissions)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    temp.persist(&target).map_err(|err| err.error)
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

    #[cfg(unix)]
    #[test]
    fn a_new_file_gets_the_mode_any_new_file_gets() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let usual = dir.path().join("usual.tex");
        fs::write(&usual, "").unwrap();
        let file = dir.path().join("main.tex");
        write(&file, b"new").unwrap();
        let mode = |path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&file), mode(&usual));
        // A private file stays private when it is saved again.
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        write(&file, b"again").unwrap();
        assert_eq!(mode(&file), 0o600);
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
    fn a_file_with_a_long_unicode_name_saves() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(format!("{}.tex", "🦀".repeat(60)));
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
