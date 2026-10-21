//! Writing a file whole or not at all: a temporary file beside it, then one rename, so a crash leaves the old file.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use tempfile::TempPath;

use crate::stamp::Stamp;

/// A new, empty temporary file in `dir` with a new file's mode (0666 less the umask); tempfile's 0600 would leave files unreadable to the accounts a project is shared with.
pub(crate) fn create_temp(dir: &Path) -> io::Result<(File, TempPath)> {
    let mut builder = tempfile::Builder::new();
    builder.prefix(".texlocal-");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        builder.permissions(fs::Permissions::from_mode(0o666));
    }
    Ok(builder.tempfile_in(dir)?.into_parts())
}

/// The extended attributes of `from` (Finder tags, quarantine) copied onto `to`, since the rename gives the file a new inode. Failure copies none and doesn't fail the save.
#[cfg(target_os = "macos")]
fn copy_xattrs(from: &Path, to: &File) {
    use std::os::fd::AsRawFd;
    if let Ok(from) = File::open(from) {
        // SAFETY: both descriptors are open for the call; no copy state is
        // asked for, and only the attributes are copied.
        unsafe {
            libc::fcopyfile(
                from.as_raw_fd(),
                to.as_raw_fd(),
                std::ptr::null_mut(),
                libc::COPYFILE_XATTR,
            );
        }
    }
}

/// Moves a finished temporary file into place with std's rename; tempfile's reaches no path past 260 characters on Windows.
/// There an indexer, antivirus or sync client holding the target refuses the
/// rename for a moment, so it is tried again for about 100 ms.
pub(crate) fn persist(temp: TempPath, path: &Path) -> io::Result<()> {
    let mut tries = 0;
    while let Err(error) = fs::rename(&temp, path) {
        tries += 1;
        if !cfg!(windows) || tries > 3 || error.kind() != io::ErrorKind::PermissionDenied {
            return Err(error);
        }
        std::thread::sleep(std::time::Duration::from_millis(33));
    }
    let _ = temp.keep();
    Ok(())
}

/// Replace `path`'s contents with `bytes`, or create it. A symlink is written through and permissions and xattrs kept; a read-only file is refused. The stamp is the temporary file's, taken once it is closed (Windows dates the last write then).
pub(crate) fn write(path: &Path, bytes: &[u8]) -> io::Result<Stamp> {
    let target = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => dunce::canonicalize(path)?,
        _ => path.to_path_buf(),
    };
    let permissions = fs::metadata(&target).ok().map(|meta| meta.permissions());
    if permissions.as_ref().is_some_and(fs::Permissions::readonly) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let (mut file, temp) = create_temp(target.parent().expect("a file is in a folder"))?;
    // Before the contents, so a private file's text is never readable under a new file's mode.
    if let Some(permissions) = permissions {
        file.set_permissions(permissions)?;
        #[cfg(target_os = "macos")]
        copy_xattrs(&target, &file);
    }
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
    use crate::projects::testing::names_in;
    use std::fs;

    #[test]
    fn a_save_creates_and_replaces_leaving_no_temporary_file_and_answers_the_files_stamp() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("main.tex");
        write(&file, b"one").unwrap();
        let written = write(&file, b"two").unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"two");
        assert_eq!(names_in(dir.path()), ["main.tex"]);
        assert_eq!(written, Stamp::of(&fs::metadata(&file).unwrap()));
        fs::write(&file, b"three").unwrap();
        assert_ne!(written, Stamp::of(&fs::metadata(&file).unwrap()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_save_keeps_the_extended_attributes_of_the_file_it_replaces() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("tagged.tex");
        fs::write(&file, "one").unwrap();
        let xattr = |args: &[&str]| {
            let mut command = std::process::Command::new("/usr/bin/xattr");
            let out = command.args(args).arg(&file).output().unwrap();
            assert!(out.status.success(), "{out:?}");
            out.stdout
        };
        let name = "com.example.texlocal-test";
        xattr(&["-w", name, "Red"]);
        write(&file, b"two").unwrap();
        assert_eq!(xattr(&["-p", name]).trim_ascii(), b"Red");
        assert_eq!(fs::read(&file).unwrap(), b"two");
    }

    #[test]
    fn a_save_that_cannot_complete_leaves_the_original_intact() {
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

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o555)).unwrap();
            let result = write(&file, b"new");
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
            assert!(result.is_err());
            assert_eq!(fs::read_to_string(&file).unwrap(), "keep");
            assert_eq!(names_in(dir.path()), ["locked.tex"]);
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
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        write(&file, b"again").unwrap();
        assert_eq!(mode(&file), 0o600);
    }
}
