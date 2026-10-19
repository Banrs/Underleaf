//! Writing a file whole or not at all: the new contents go to a temporary file
//! beside it, reach the disk, then take its place in one rename. A full disk
//! or a crash part-way leaves the old file as it was, where writing in place
//! would leave it empty or cut short.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use tempfile::TempPath;

use crate::stamp::Stamp;

/// A new, empty temporary file in `dir`, removed if it is not persisted, with
/// a new file's mode (0666 less the umask), as any other way of making a file
/// gives it. tempfile's own 0600 would leave every file the app made
/// unreadable to the accounts and tools a project is shared with.
pub(crate) fn create_temp(dir: &Path) -> io::Result<(TempPath, File)> {
    let mut builder = tempfile::Builder::new();
    builder.prefix(".texlocal-");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        builder.permissions(fs::Permissions::from_mode(0o666));
    }
    let (file, temp_path) = builder.tempfile_in(dir)?.into_parts();
    Ok((temp_path, file))
}

/// The extended attributes of `from` (a Finder tag, "where from", the
/// quarantine flag) copied onto `to`. The rename that follows a save gives the
/// file a new inode, which would otherwise start with none: a tagged file
/// would lose its tag on the first autosave. A volume without them, or a file
/// that can't be read, copies none, which a save need not fail for.
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
/// permissions, and on macOS its extended attributes; a read-only file is
/// refused, as writing it in place would be. The stamp is the temporary
/// file's, which the rename keeps: one taken after it could be another app's
/// write landing in between. It is taken once the file is closed, as Windows
/// dates the last write then.
pub(crate) fn write(path: &Path, bytes: &[u8]) -> io::Result<Stamp> {
    let target = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => dunce::canonicalize(path)?,
        _ => path.to_path_buf(),
    };
    let permissions = fs::metadata(&target).ok().map(|meta| meta.permissions());
    if permissions.as_ref().is_some_and(fs::Permissions::readonly) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let dir = target.parent().filter(|p| !p.as_os_str().is_empty());
    let (temp, mut file) = create_temp(dir.unwrap_or(Path::new(".")))?;
    // Before the contents, so a private file's text is never readable
    // under a new file's mode.
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
        // Another app's write in place keeps the file but not the stamp, once
        // the clock has moved: Windows dates writes in steps of up to 16 ms.
        std::thread::sleep(std::time::Duration::from_millis(20));
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
        // A Finder tag is one of these; any name stands for it.
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
        // A private file stays private when it is saved again.
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        write(&file, b"again").unwrap();
        assert_eq!(mode(&file), 0o600);
    }
}
