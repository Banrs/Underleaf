use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use tempfile::TempPath;

use crate::stamp::Stamp;

pub(crate) fn temp_builder(mode: u32) -> tempfile::Builder<'static, 'static> {
    let mut builder = tempfile::Builder::new();
    builder.prefix(".texlocal-");
    use std::os::unix::fs::PermissionsExt;
    builder.permissions(fs::Permissions::from_mode(mode));
    builder
}

pub(crate) fn create_temp(dir: &Path) -> io::Result<(File, TempPath)> {
    Ok(temp_builder(0o666).tempfile_in(dir)?.into_parts())
}

fn copy_xattrs(from: &Path, to: &File) {
    use std::os::fd::AsRawFd;
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
    let c_path = |path: &Path| {
        CString::new(path.as_os_str().as_encoded_bytes())
            .map_err(|err| io::Error::new(io::ErrorKind::InvalidInput, err))
    };
    let (from, to) = (c_path(from)?, c_path(to)?);
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

pub(crate) fn write(path: &Path, bytes: &[u8]) -> io::Result<Stamp> {
    let target = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => std::fs::canonicalize(path)?,
        _ => path.to_path_buf(),
    };
    let permissions = fs::metadata(&target).ok().map(|meta| meta.permissions());
    if permissions.as_ref().is_some_and(fs::Permissions::readonly) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let (mut file, temp) = create_temp(target.parent().expect("a file is in a folder"))?;
    if let Some(permissions) = permissions {
        file.set_permissions(permissions)?;
        copy_xattrs(&target, &file);
    }
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    let stamp = Stamp::of(&fs::metadata(&temp)?);
    fs::rename(&temp, &target)?;
    let _ = temp.keep();
    Ok(stamp)
}
