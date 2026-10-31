use std::fs::{self, File};
use std::io::{self, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::error::CoreError;
use crate::sys;

pub(crate) fn trash_in(trash: &Path, path: &Path) -> Result<PathBuf, CoreError> {
    let (files, info) = (trash.join("files"), trash.join("info"));
    fs::create_dir_all(&files)?;
    fs::create_dir_all(&info)?;
    let date = sys::local_time(SystemTime::now())
        .map(|(y, mo, d, h, mi, s)| format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}"));
    let record = format!(
        "[Trash Info]\nPath={}\nDeletionDate={}\n",
        escaped(path),
        date.unwrap_or_default()
    );
    let name = path.file_name().unwrap_or(path.as_os_str());
    for n in 1.. {
        let mut named = name.to_owned();
        if n > 1 {
            named.push(format!(".{n}"));
        }
        let mut info_name = named.clone();
        info_name.push(".trashinfo");
        let info = info.join(info_name);
        let mut file = match File::create_new(&info) {
            Err(err) if err.kind() == ErrorKind::AlreadyExists => continue,
            created => created?,
        };
        let trashed = files.join(named);
        let moved = file
            .write_all(record.as_bytes())
            .and_then(|()| sys::rename_exclusive(path, &trashed));
        if let Err(err) = moved {
            let _ = fs::remove_file(info);
            if err.kind() == ErrorKind::AlreadyExists {
                continue;
            }
            return Err(err.into());
        }
        return Ok(trashed);
    }
    unreachable!("a free name")
}

pub(crate) fn untrash(trashed: &Path, to: &Path) -> io::Result<()> {
    sys::rename_exclusive(trashed, to)?;
    if let (Some(files), Some(name)) = (trashed.parent(), trashed.file_name()) {
        let mut info = name.to_owned();
        info.push(".trashinfo");
        let _ = fs::remove_file(files.with_file_name("info").join(info));
    }
    Ok(())
}

fn escaped(path: &Path) -> String {
    let escape = |&byte: &u8| match byte.is_ascii_alphanumeric() || b"-_.~/".contains(&byte) {
        true => char::from(byte).to_string(),
        false => format!("%{byte:02X}"),
    };
    let bytes = path.as_os_str().as_encoded_bytes();
    bytes.iter().map(escape).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_trashed_item_is_named_apart_from_its_twin_and_its_record_goes_when_it_comes_back() {
        let dir = tempfile::tempdir().unwrap();
        let (trash, inner) = (dir.path().join("Trash"), dir.path().join("in"));
        fs::create_dir(&inner).unwrap();
        let (one, two) = (dir.path().join("my notes"), inner.join("my notes"));
        fs::write(&one, "1").unwrap();
        fs::write(&two, "2").unwrap();
        let first = trash_in(&trash, &one).unwrap();
        let second = trash_in(&trash, &two).unwrap();
        assert_eq!(first, trash.join("files/my notes"));
        assert_eq!(second, trash.join("files/my notes.2"));
        let record = trash.join("info/my notes.2.trashinfo");
        let path = format!("Path={}/in/my%20notes\n", dir.path().display());
        assert!(fs::read_to_string(&record).unwrap().contains(&path));
        untrash(&second, &two).unwrap();
        assert_eq!(fs::read_to_string(&two).unwrap(), "2");
        assert!(!record.exists() && trash.join("info/my notes.trashinfo").exists());
        fs::write(trash.join("files/notes"), "left").unwrap();
        let notes = dir.path().join("notes");
        fs::write(&notes, "3").unwrap();
        assert_eq!(
            trash_in(&trash, &notes).unwrap(),
            trash.join("files/notes.2")
        );
        assert!(!trash.join("info/notes.trashinfo").exists());
    }
}
