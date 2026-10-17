//! Project ZIP export via the zip crate. The archive is completed in a sibling
//! temporary file and moved into place only after success, so a destination
//! inside the project cannot archive itself and failures never leave a partial
//! ZIP at the requested path.

use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::atomic::{create_temp, persist};
use crate::error::CoreError;
use crate::{BUILD_DIR, SETTINGS_FILE};

pub fn export_zip(root: &Path, dest: &Path) -> Result<(), CoreError> {
    let root = dunce::canonicalize(root)?;
    let (temp, file) = create_temp(dest, None)?;
    // Resolved as the walk resolves the project, so a destination spelled
    // through a link is still recognised there.
    let parent = dest.parent().filter(|p| !p.as_os_str().is_empty());
    let archive_dir = dunce::canonicalize(parent.unwrap_or(Path::new(".")))?;
    let mut export = Export {
        writer: ZipWriter::new(file),
        options: SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        skip: [dest.file_name(), temp.file_name()]
            .map(|name| name.map(|name| archive_dir.join(name))),
        root: &root,
    };
    export.add_dir(&root, "")?;
    export.writer.finish()?.sync_all()?;
    Ok(persist(temp, dest)?)
}

struct Export<'a> {
    writer: ZipWriter<File>,
    options: SimpleFileOptions,
    root: &'a Path,
    /// The destination and its temporary sibling, which must not end up in it.
    skip: [Option<PathBuf>; 2],
}

impl Export<'_> {
    /// `dir` is resolved, which is what the archive's own place is compared with.
    fn add_dir(&mut self, dir: &Path, prefix: &str) -> Result<(), CoreError> {
        let mut entries = fs::read_dir(dir)?.collect::<io::Result<Vec<_>>>()?;
        entries.sort_by_key(fs::DirEntry::file_name);
        for entry in entries {
            let file_name = entry.file_name();
            let name = file_name.to_string_lossy();
            let top = prefix.is_empty();
            // Finder's folder metadata is not project content.
            if name.eq_ignore_ascii_case(".DS_Store")
                || top && (name.eq_ignore_ascii_case(BUILD_DIR) || name == SETTINGS_FILE)
                || self.skip.contains(&Some(dir.join(&file_name)))
            {
                continue;
            }
            let rel = if top {
                name.into_owned()
            } else {
                format!("{prefix}/{name}")
            };
            let path = entry.path();
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                // Unresolvable (dangling, a loop), there is nothing to export, as
                // in the project walks; and never data reached through a link
                // outside the project. Directory links are skipped too: following
                // them creates cycles and duplicates.
                let inside = dunce::canonicalize(&path).is_ok_and(|to| to.starts_with(self.root));
                if inside && fs::metadata(&path)?.is_file() {
                    self.add_file(&rel, &path)?;
                }
            } else if kind.is_dir() {
                let resolved = dunce::canonicalize(&path)?;
                if resolved.starts_with(self.root) {
                    let options = dated(self.options, entry.metadata().and_then(|m| m.modified()));
                    self.writer.add_directory(format!("{rel}/"), options)?;
                    self.add_dir(&resolved, &rel)?;
                }
            } else if kind.is_file() {
                self.add_file(&rel, &path)?;
            }
        }
        Ok(())
    }

    fn add_file(&mut self, rel: &str, path: &Path) -> Result<(), CoreError> {
        let mut file = File::open(path)?;
        let meta = file.metadata()?;
        let options = dated(self.options, meta.modified()).large_file(needs_zip64(meta.len()));
        self.writer.start_file(rel, options)?;
        // No flush per file: on a deflated entry that forces a sync block
        // into the stream, and the next start_file or finish ends it anyway.
        io::copy(&mut file, &mut self.writer)?;
        Ok(())
    }
}

/// Past 4 GiB (a video, a data set), sizes need ZIP64's fields; and from
/// 3 GiB a file gets them too, as one that doesn't compress is stored a
/// little larger than it is, deflate's blocks each adding their header.
fn needs_zip64(len: u64) -> bool {
    len >= 3 << 30
}

/// `options` with the entry dated as `modified`. ZIP stores local time, as
/// unzipping tools show it; undated, every entry would say 1 January 1980.
fn dated(options: SimpleFileOptions, modified: io::Result<SystemTime>) -> SimpleFileOptions {
    let Ok(modified) = modified else {
        return options;
    };
    let local = chrono::DateTime::<chrono::Local>::from(modified).naive_local();
    // Outside ZIP's 1980–2107, the entry keeps the default.
    zip::DateTime::try_from(local).map_or(options, |date| options.last_modified_time(date))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn a_file_that_could_deflate_past_4_gib_is_written_as_zip64() {
        assert!(!needs_zip64(0));
        assert!(!needs_zip64((3 << 30) - 1));
        // Deflate stores what it can't compress in blocks of at most 65,535
        // bytes, 5 more each: under 4 GiB itself, over it once stored.
        let len: u64 = (1 << 32) - 1_000;
        assert!(len + len.div_ceil(65_535) * 5 > u32::MAX as u64);
        assert!(needs_zip64(len));
        assert!(needs_zip64(1 << 32));
    }

    #[test]
    fn the_archive_holds_the_project_but_not_itself_nor_build_nor_settings() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("ch")).unwrap();
        fs::create_dir(root.join(BUILD_DIR)).unwrap();
        fs::write(root.join("main.tex"), "main").unwrap();
        fs::write(root.join("ch/a.tex"), "a").unwrap();
        fs::write(root.join(BUILD_DIR).join("main.pdf"), "pdf").unwrap();
        fs::write(root.join(SETTINGS_FILE), "{}").unwrap();
        fs::write(root.join(".DS_Store"), "").unwrap();
        // The destination is inside the project and exists already.
        let dest = root.join("out.zip");
        fs::write(&dest, "old").unwrap();
        export_zip(root, &dest).unwrap();

        let mut zip = zip::ZipArchive::new(File::open(&dest).unwrap()).unwrap();
        let mut names: Vec<_> = zip.file_names().map(String::from).collect();
        names.sort();
        assert_eq!(names, ["ch/", "ch/a.tex", "main.tex"]);
        let mut text = String::new();
        zip.by_name("ch/a.tex")
            .unwrap()
            .read_to_string(&mut text)
            .unwrap();
        assert_eq!(text, "a");
    }
}
