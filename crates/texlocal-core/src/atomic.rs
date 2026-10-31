use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;

use tempfile::TempPath;

use crate::stamp::Stamp;
use crate::sys::{self, copy_xattrs};

pub(crate) use sys::rename_exclusive;

pub(crate) enum Flush {
    Full,
    Ordered,
}

pub(crate) fn temp_builder() -> tempfile::Builder<'static, 'static> {
    let mut builder = tempfile::Builder::new();
    builder.prefix(".texlocal-");
    builder
}

pub(crate) fn create_temp(dir: &Path) -> io::Result<(File, TempPath)> {
    let mut builder = temp_builder();
    sys::default_permissions(&mut builder);
    Ok(builder.tempfile_in(dir)?.into_parts())
}

pub(crate) fn write(path: &Path, bytes: &[u8], flush: Flush) -> io::Result<Stamp> {
    let target = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => fs::canonicalize(path)?,
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
    sys::flush(&file, flush)?;
    let stamp = Stamp::at(&temp)?;
    temp.persist(&target)?;
    Ok(stamp)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::*;

    #[test]
    fn a_write_replaces_the_file_a_link_points_to_and_keeps_its_mode() {
        let dir = tempfile::tempdir().unwrap();
        let (file, link) = (dir.path().join("main.tex"), dir.path().join("link.tex"));
        fs::write(&file, "old").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).unwrap();
        symlink(&file, &link).unwrap();
        let stamp = write(&link, b"new", Flush::Ordered).unwrap();
        assert!(fs::symlink_metadata(&link).unwrap().is_symlink());
        assert_eq!(fs::read_to_string(&file).unwrap(), "new");
        let meta = fs::metadata(&file).unwrap();
        assert_eq!(meta.permissions().mode() & 0o777, 0o640);
        assert!(stamp == Stamp::at(&file).unwrap());
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 2);
        fs::set_permissions(&file, fs::Permissions::from_mode(0o440)).unwrap();
        let refused = write(&file, b"newer", Flush::Full)
            .err()
            .map(|err| err.kind());
        assert_eq!(refused, Some(io::ErrorKind::PermissionDenied));
        assert_eq!(fs::read_to_string(&file).unwrap(), "new");
    }
}
