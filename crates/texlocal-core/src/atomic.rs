use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;

use tempfile::TempPath;

use crate::stamp::Stamp;
use crate::sys::{self, copy_xattrs};

pub(crate) use sys::rename_exclusive;

pub(crate) fn temp_builder(mode: u32) -> tempfile::Builder<'static, 'static> {
    let mut builder = tempfile::Builder::new();
    builder.prefix(".texlocal-");
    builder.permissions(sys::permissions(mode));
    builder
}

pub(crate) fn create_temp(dir: &Path) -> io::Result<(File, TempPath)> {
    Ok(temp_builder(0o666).tempfile_in(dir)?.into_parts())
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
