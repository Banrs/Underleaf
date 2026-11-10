use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

use objc2_foundation::{NSFileManager, NSURL};

use crate::atomic::Flush;
use crate::error::CoreError;
use crate::messages;

pub(crate) fn trash(path: &Path) -> Result<PathBuf, CoreError> {
    let failed = |said: String| CoreError::internal(messages::trash_failed(said));
    let unnamed = || failed(path.display().to_string());
    let url = NSURL::from_file_path(path).ok_or_else(unnamed)?;
    let mut trashed = None;
    NSFileManager::defaultManager()
        .trashItemAtURL_resultingItemURL_error(&url, Some(&mut trashed))
        .map_err(|err| failed(err.localizedDescription().to_string()))?;
    trashed
        .and_then(|url| url.to_file_path())
        .ok_or_else(unnamed)
}

pub(crate) fn put_back(trashed: &Path, to: &Path) -> io::Result<()> {
    rename_exclusive(trashed, to)
}

pub(crate) fn flush(file: &File, flush: Flush) -> io::Result<()> {
    match flush {
        Flush::Full => file.sync_all(),
        Flush::Ordered => match unsafe { libc::fcntl(file.as_raw_fd(), libc::F_BARRIERFSYNC) } {
            -1 => Err(io::Error::last_os_error()),
            _ => Ok(()),
        },
    }
}

pub(crate) fn copy_xattrs(from: &Path, to: &File) {
    if let Ok(from) = File::open(from) {
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

pub(crate) fn rename_exclusive(from: &Path, to: &Path) -> io::Result<()> {
    let from = CString::new(from.as_os_str().as_encoded_bytes())?;
    let to = CString::new(to.as_os_str().as_encoded_bytes())?;
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
