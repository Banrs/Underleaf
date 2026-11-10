use std::ffi::{CString, OsStr};
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use texlocal_latex::percent_encoded;

use crate::atomic::Flush;
use crate::error::CoreError;
use crate::messages;

/// Moves the item to the home trash of the FreeDesktop trash specification, where file managers list it and put it
/// back from. An item on another volume than the home folder is refused, as a volume's own trash isn't used.
pub(crate) fn trash(path: &Path) -> Result<PathBuf, CoreError> {
    let trashed = home_trash().and_then(|trash| trash_in(&trash, path));
    trashed.map_err(|err| CoreError::internal(messages::trash_failed(err)))
}

fn home_trash() -> io::Result<PathBuf> {
    let dir = |key| {
        let dir = std::env::var_os(key).map(PathBuf::from);
        dir.filter(|dir| dir.is_absolute())
    };
    let data = dir("XDG_DATA_HOME").or_else(|| Some(dir("HOME")?.join(".local/share")));
    Ok(data.ok_or(io::ErrorKind::NotFound)?.join("Trash"))
}

fn record(trash: &Path, name: &OsStr) -> PathBuf {
    trash
        .join("info")
        .join(name)
        .with_added_extension("trashinfo")
}

fn trash_in(trash: &Path, path: &Path) -> io::Result<PathBuf> {
    let files = trash.join("files");
    fs::create_dir_all(&files)?;
    fs::create_dir_all(trash.join("info"))?;
    let name = path.file_name().ok_or(io::ErrorKind::InvalidInput)?;
    let from = percent_encoded(path.as_os_str().as_encoded_bytes());
    let (year, month, day, hour, minute, second) =
        super::local_time(SystemTime::now()).unwrap_or_default();
    let date = format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}");
    let mut copy = 0;
    loop {
        let mut free = name.to_owned();
        if copy > 0 {
            free.push(format!(".{copy}"));
        }
        copy += 1;
        // Making the record exclusively is how the specification reserves a name in the trash.
        let reserved = record(trash, &free);
        let mut info = match File::create_new(&reserved) {
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
            info => info?,
        };
        let to = files.join(&free);
        let moved = write!(info, "[Trash Info]\nPath={from}\nDeletionDate={date}\n")
            .and_then(|()| fs::rename(path, &to));
        return match moved {
            Ok(()) => Ok(to),
            Err(err) => {
                let _ = fs::remove_file(reserved);
                Err(err)
            }
        };
    }
}

pub(crate) fn put_back(trashed: &Path, to: &Path) -> io::Result<()> {
    rename_exclusive(trashed, to)?;
    let trash = trashed.parent().and_then(Path::parent);
    if let (Some(trash), Some(name)) = (trash, trashed.file_name()) {
        let _ = fs::remove_file(record(trash, name));
    }
    Ok(())
}

pub(crate) fn flush(file: &File, flush: Flush) -> io::Result<()> {
    match flush {
        Flush::Full => file.sync_all(),
        Flush::Ordered => file.sync_data(),
    }
}

pub(crate) fn copy_xattrs(from: &Path, to: &File) {
    let Ok(from) = File::open(from) else {
        return;
    };
    let (from, to) = (from.as_raw_fd(), to.as_raw_fd());
    // A length the kernel reports is negative on failure, and then nothing is read.
    let sized = |length: isize| vec![0_u8; usize::try_from(length).unwrap_or(0)];
    unsafe {
        let mut names = sized(libc::flistxattr(from, std::ptr::null_mut(), 0));
        let listed = libc::flistxattr(from, names.as_mut_ptr().cast(), names.len());
        names.truncate(usize::try_from(listed).unwrap_or(0));
        for name in names.split_inclusive(|&byte| byte == 0) {
            let name = name.as_ptr().cast();
            let mut value = sized(libc::fgetxattr(from, name, std::ptr::null_mut(), 0));
            let read = libc::fgetxattr(from, name, value.as_mut_ptr().cast(), value.len());
            if let Ok(read) = usize::try_from(read) {
                libc::fsetxattr(to, name, value.as_ptr().cast(), read, 0);
            }
        }
    }
}

pub(crate) fn rename_exclusive(from: &Path, to: &Path) -> io::Result<()> {
    let from = CString::new(from.as_os_str().as_encoded_bytes())?;
    let to = CString::new(to.as_os_str().as_encoded_bytes())?;
    let (here, flags) = (libc::AT_FDCWD, libc::RENAME_NOREPLACE);
    if unsafe { libc::renameat2(here, from.as_ptr(), here, to.as_ptr(), flags) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_trash_keeps_two_items_of_one_name_apart_and_forgets_one_put_back() {
        let dir = tempfile::tempdir().unwrap();
        let (trash, file) = (dir.path().join("Trash"), dir.path().join("a b.tex"));
        fs::write(&file, "first").unwrap();
        let first = trash_in(&trash, &file).unwrap();
        fs::write(&file, "second").unwrap();
        let second = trash_in(&trash, &file).unwrap();
        assert_eq!(first, trash.join("files/a b.tex"));
        assert_eq!(second, trash.join("files/a b.tex.1"));
        let info = fs::read_to_string(trash.join("info/a b.tex.1.trashinfo")).unwrap();
        let from = file.to_str().unwrap().replace(' ', "%20");
        let said = format!("[Trash Info]\nPath={from}\nDeletionDate=");
        assert!(info.starts_with(&said), "{info}");
        put_back(&second, &file).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "second");
        assert!(!trash.join("info/a b.tex.1.trashinfo").exists());
        assert!(trash.join("info/a b.tex.trashinfo").exists());
        let taken = put_back(&first, &file).unwrap_err();
        assert_eq!(taken.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read_to_string(&first).unwrap(), "first");
    }

    #[test]
    fn a_files_attributes_are_copied_where_the_volume_keeps_them() {
        let dir = tempfile::tempdir().unwrap();
        let (from, to) = (dir.path().join("from"), dir.path().join("to"));
        fs::write(&from, "").unwrap();
        let to = File::create(to).unwrap();
        let path = CString::new(from.as_os_str().as_encoded_bytes()).unwrap();
        let (name, value) = (c"user.texlocal", b"kept");
        let set = unsafe {
            let value = value.as_ptr().cast();
            libc::setxattr(path.as_ptr(), name.as_ptr(), value, 4, 0)
        };
        if set != 0 {
            // A volume without user attributes, such as some temporary ones, has nothing to copy.
            assert_eq!(
                io::Error::last_os_error().raw_os_error(),
                Some(libc::ENOTSUP)
            );
            return;
        }
        copy_xattrs(&from, &to);
        let mut read = [0_u8; 8];
        let length = unsafe {
            let read = read.as_mut_ptr().cast();
            libc::fgetxattr(to.as_raw_fd(), name.as_ptr(), read, 8)
        };
        assert_eq!(&read[..length as usize], value);
    }
}
