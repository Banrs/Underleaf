//! Bringing outside files into the library, for in-process hosts: a Finder
//! drop onto a project, and File › Open of a folder, a .zip or a .tex made a
//! new project. Both read host-chosen absolute paths, so neither is in
//! `Service::call`, which the browser server exposes. Both block on the
//! disk; hosts call them off their UI thread, as they do every `tl_call`.

use std::fs::{self, File};
use std::io::{self, BufWriter, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::json;
use zip::ZipArchive;

use crate::paths::{normalize_segments, rel_key, sanitize_name};
use crate::projects::{self, ProjectInfo};
use crate::service::{keep_both, too_large, Clash, Service, UploadSpec, UPLOAD_MAX_BYTES};
use crate::settings::write_settings;
use crate::{templates, CoreError, BUILD_DIR};

/// What to do with incoming files that land on existing entries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Conflict {
    /// Move the existing entries to the Trash.
    Replace,
    /// Give the incoming files free names beside them.
    KeepBoth,
}

#[derive(Debug, Serialize)]
pub struct Imported {
    pub saved: Vec<String>,
    pub existing: Vec<Clash>,
}

/// What an import may still bring: files, entries looked at (what a folder
/// holds, hidden or not, or a zip's entries) and bytes. Bytes are taken as
/// declared while the files are found, and again as read, since a zip's
/// sizes can lie and a file can grow while it is read.
#[derive(Debug, Clone, Copy)]
struct Allowance {
    files: u64,
    entries: u64,
    bytes: u64,
}

const TOO_MANY: &str = "There are too many files to import.";
const TOO_BIG: &str = "The files to import are too large.";

/// Take `n` from what is `left`, failing with `too_much` past it.
fn spend(left: &mut u64, n: u64, too_much: &str) -> Result<(), CoreError> {
    *left = left
        .checked_sub(n)
        .ok_or_else(|| CoreError::bad_request(too_much))?;
    Ok(())
}

/// Far past any real project, so only a dropped home folder or a zip bomb
/// meets it, before it has filled the disk.
const IMPORT: Allowance = Allowance {
    files: 50_000,
    entries: 500_000,
    bytes: 4 << 30,
};

/// A .tex brings its folder only while that is no larger than a project:
/// Overleaf's limit on a project's files, and one upload's bytes.
const TEX_FOLDER: Allowance = Allowance {
    files: 2000,
    entries: 20_000,
    bytes: UPLOAD_MAX_BYTES as u64,
};

impl Allowance {
    fn file(&mut self, size: u64) -> Result<(), CoreError> {
        spend(&mut self.files, 1, TOO_MANY)?;
        spend(&mut self.bytes, size, TOO_BIG)
    }

    /// Copy `source` to `sink`, taking the bytes actually read, and never
    /// more than one upload's.
    fn copy(&mut self, source: impl Read, sink: &mut impl Write) -> Result<(), CoreError> {
        let cap = self.bytes.min(UPLOAD_MAX_BYTES as u64);
        let copied = io::copy(&mut source.take(cap + 1), sink)?;
        if copied > UPLOAD_MAX_BYTES as u64 {
            return Err(too_large());
        }
        spend(&mut self.bytes, copied, TOO_BIG)
    }
}

/// Dotfiles (.git, .DS_Store) and the resource forks of a Mac-made zip: the
/// project walks hide them, so an import that brought them would bring files
/// nobody sees.
fn hidden(name: &str) -> bool {
    name.starts_with('.') || name == "__MACOSX"
}

/// Files under a dropped path, with project-relative names that keep a
/// dropped folder's own name (none for an empty `rel`), and where to read
/// each, failing once `allowance` runs out. Inside a folder, hidden entries
/// stay behind and symlinks are skipped, not followed: a drop imports what
/// was dropped, never what a link inside it points at.
fn collect(
    abs: &Path,
    rel: String,
    meta: fs::Metadata,
    files: &mut Vec<(UploadSpec, PathBuf)>,
    allowance: &mut Allowance,
) -> Result<(), CoreError> {
    if meta.is_file() {
        allowance.file(meta.len())?;
        let spec = UploadSpec {
            path: rel,
            size: meta.len() as usize,
        };
        files.push((spec, abs.to_path_buf()));
    } else if meta.is_dir() {
        for entry in fs::read_dir(abs)? {
            spend(&mut allowance.entries, 1, TOO_MANY)?;
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !hidden(&name) && !(rel.is_empty() && name.eq_ignore_ascii_case(BUILD_DIR)) {
                // DirEntry::metadata does not follow links.
                let meta = entry.metadata()?;
                let rel = if rel.is_empty() {
                    name
                } else {
                    format!("{rel}/{name}")
                };
                collect(&entry.path(), rel, meta, files, allowance)?;
            }
        }
    }
    Ok(())
}

/// Import dropped files and folders into the project folder `dir`, with the
/// same validate-then-write rule as a browser upload: a bad path or oversize
/// file fails the drop before anything lands. Without `conflict`, a drop that
/// would land on existing entries writes nothing and reports them, for the
/// host to ask about.
pub fn import_files(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
) -> Result<Imported, CoreError> {
    import_files_within(service, id, dir, paths, conflict, IMPORT)
}

fn import_files_within(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
    mut allowance: Allowance,
) -> Result<Imported, CoreError> {
    let mut files = Vec::new();
    let mut found = allowance;
    for abs in paths {
        let name = abs.file_name().unwrap_or_default().to_string_lossy();
        // A dropped link is followed: dropping it names what it points at.
        let meta = fs::metadata(abs)?;
        collect(abs, name.into_owned(), meta, &mut files, &mut found)?;
    }
    let (specs, sources): (Vec<_>, Vec<_>) = files.into_iter().unzip();
    let existing = service.validate_uploads(id, dir, &specs)?.existing;
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported {
            saved: Vec::new(),
            existing,
        });
    }
    let replace = conflict == Some(Conflict::Replace);
    let mut saved = Vec::new();
    for (spec, abs) in specs.into_iter().zip(sources) {
        let path = if conflict == Some(Conflict::KeepBoth) {
            keep_both(&spec.path, &existing)
        } else {
            spec.path
        };
        let mut bytes = Vec::new();
        allowance.copy(File::open(abs)?, &mut bytes)?;
        saved.push(service.upload_file(id, dir, &path, &bytes, replace)?);
    }
    Ok(Imported { saved, existing })
}

/// Where an imported project's file comes from.
enum Source {
    File(PathBuf),
    /// An entry of the chosen zip, by index.
    Zip(usize),
}

/// A zip's visible files; the contents of its one top folder if it has one,
/// as a zipped project folder unpacks.
fn zip_files(
    archive: &mut ZipArchive<File>,
    mut allowance: Allowance,
) -> Result<Vec<(UploadSpec, Source)>, CoreError> {
    spend(&mut allowance.entries, archive.len() as u64, TOO_MANY)?;
    let mut files = Vec::new();
    for i in 0..archive.len() {
        // Its name and size only: nothing is decompressed yet.
        let entry = archive.by_index_raw(i)?;
        // No folders, links or NULs, and no name that would leave the project,
        // read as a project path is ("./a" is "a"); a backslash separates, as
        // Windows tools have written it where the format allows only '/'.
        let name = entry.name().replace('\\', "/");
        let segments = match normalize_segments(&name, "") {
            Ok(s) if entry.is_file() && !s.is_empty() && !name.contains('\0') => s,
            _ => continue,
        };
        if !segments.iter().any(|s| hidden(s)) {
            allowance.file(entry.size())?;
            let spec = UploadSpec {
                path: segments.join("/"),
                size: entry.size() as usize,
            };
            files.push((spec, Source::Zip(i)));
        }
    }
    let top = files
        .first()
        .and_then(|(spec, _)| Some(format!("{}/", spec.path.split_once('/')?.0)));
    if let Some(top) = top.filter(|top| files.iter().all(|(s, _)| s.path.starts_with(top))) {
        for (spec, _) in &mut files {
            spec.path.drain(..top.len());
        }
    }
    Ok(files)
}

/// A folder's files, unless they are more than `allowance`.
fn folder_files(
    dir: &Path,
    mut allowance: Allowance,
) -> Result<Vec<(UploadSpec, Source)>, CoreError> {
    let mut found = Vec::new();
    collect(
        dir,
        String::new(),
        fs::metadata(dir)?,
        &mut found,
        &mut allowance,
    )?;
    Ok(found
        .into_iter()
        .map(|(s, p)| (s, Source::File(p)))
        .collect())
}

/// File › Open: a folder, a .zip or a single file from anywhere, copied into
/// a new project named after it ("Name 2" when that is taken), which is
/// returned. A .tex brings its folder, named after that, for what it inputs,
/// includes and cites, unless the folder can't be read, is larger than a
/// project (Downloads, a home folder: more than 2000 files or one upload's
/// bytes) or has no name a project can take: then the .tex comes alone. Only
/// visible files come, as a drop brings them, and a top-level `build` stays
/// behind as the old project's compile output. The main file is the chosen
/// .tex, else the likeliest top-level one; with no TeX at all, the blank
/// template's main.tex.
pub fn import_project(service: &Service, src: &Path) -> Result<ProjectInfo, CoreError> {
    import_project_within(service, src, IMPORT)
}

fn import_project_within(
    service: &Service,
    src: &Path,
    mut allowance: Allowance,
) -> Result<ProjectInfo, CoreError> {
    let meta = fs::metadata(src)?;
    let is_dir = meta.is_dir();
    let named =
        |name: Option<&std::ffi::OsStr>| name.unwrap_or_default().to_string_lossy().into_owned();
    let ext = named(src.extension()).to_lowercase();
    let tex = (!is_dir && ext == "tex").then(|| named(src.file_name()));
    let folder = if is_dir {
        Some((src, folder_files(src, allowance)?))
    } else {
        src.parent().zip(tex.as_ref()).and_then(|(dir, tex)| {
            let files = folder_files(dir, TEX_FOLDER).ok()?;
            (files.iter().any(|(s, _)| &s.path == tex)
                && sanitize_name(&named(dir.file_name())).is_ok())
            .then_some((dir, files))
        })
    };
    let (base, mut zip, mut files) = if let Some((dir, found)) = folder {
        (named(dir.file_name()), None, found)
    } else if ext == "zip" {
        let mut archive = ZipArchive::new(File::open(src)?)?;
        let found = zip_files(&mut archive, allowance)?;
        (named(src.file_stem()), Some(archive), found)
    } else {
        let spec = UploadSpec {
            path: named(src.file_name()),
            size: usize::try_from(meta.len()).unwrap_or(usize::MAX),
        };
        (
            named(src.file_stem()),
            None,
            vec![(spec, Source::File(src.into()))],
        )
    };
    files.retain(|(spec, _)| {
        let top = spec.path.split('/').next().unwrap_or_default();
        !top.eq_ignore_ascii_case(BUILD_DIR)
    });

    // Made in a hidden folder beside the projects, which no listing or scan
    // shows, then moved into place whole: a failure or panic, which drops
    // the folder, leaves no project behind, and a crash a hidden folder only.
    fs::create_dir_all(&service.data_dir)?;
    let staging = tempfile::Builder::new()
        .prefix(".texlocal-import-")
        .permissions(fs::Permissions::from_mode(0o777))
        .tempdir_in(&service.data_dir)?;
    let (staged, staged_id) = (staging.path(), staging.path().file_name().unwrap());
    let (specs, sources): (Vec<_>, Vec<_>) = files.into_iter().unzip();
    service.validate_uploads(&staged_id.to_string_lossy(), "", &specs)?;
    for (spec, source) in specs.iter().zip(sources) {
        // The folder holds only what the import wrote, so there is no clash
        // or file to replace: each is written in place, with no temporary
        // file or sync of its own, and gets a new file's usual mode.
        let abs = staged.join(rel_key(&spec.path)?);
        fs::create_dir_all(abs.parent().unwrap_or(staged))?;
        let mut dest = BufWriter::new(File::create_new(abs)?);
        match source {
            Source::File(path) => allowance.copy(File::open(path)?, &mut dest)?,
            Source::Zip(i) => {
                let entry = zip.as_mut().expect("a zip source").by_index(i)?;
                allowance.copy(entry, &mut dest)?;
            }
        }
        dest.flush()?;
    }
    let main = if let Some(main) = tex {
        main
    } else if let Some(main) = projects::guess_main_file(staged)? {
        main
    } else {
        let (file, content) = templates::files("blank")[0];
        fs::write(staged.join(file), content)?;
        file.to_string()
    };
    let main_file = write_settings(staged, &json!({ "mainFile": main }))?.main_file;
    // The name is held by an empty folder, which the project takes the
    // place of in one rename.
    let (id, root) = projects::new_project_dir(&service.data_dir, &base)?;
    if let Err(err) = fs::rename(staged, &root) {
        let _ = fs::remove_dir(&root);
        return Err(err.into());
    }
    projects::finish_project(id, &root, main_file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn library() -> (tempfile::TempDir, Service) {
        let dir = tempfile::tempdir().unwrap();
        let service = Service::new(dir.path().join("data"));
        fs::create_dir_all(&service.data_dir).unwrap();
        (dir, service)
    }

    fn zip_of(path: &Path, files: &[(&str, &str)]) {
        let mut zip = zip::ZipWriter::new(File::create(path).unwrap());
        for (name, text) in files {
            let options = zip::write::SimpleFileOptions::default();
            zip.start_file(*name, options).unwrap();
            zip.write_all(text.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
    }

    fn projects(service: &Service) -> usize {
        fs::read_dir(&service.data_dir).unwrap().count()
    }

    const SMALL: Allowance = Allowance {
        files: 3,
        entries: 8,
        bytes: 25,
    };

    #[test]
    fn a_zip_past_the_file_or_byte_limit_makes_no_project() {
        let (dir, service) = library();
        let many = dir.path().join("many.zip");
        let files = [
            ("a.tex", "a"),
            ("b.tex", "b"),
            ("c.tex", "c"),
            ("d.tex", "d"),
        ];
        zip_of(&many, &files);
        let err = import_project_within(&service, &many, SMALL).unwrap_err();
        assert_eq!(err.message, TOO_MANY);

        let large = dir.path().join("large.zip");
        let text = "0123456789";
        zip_of(&large, &[("a.tex", text), ("b.tex", text), ("c.tex", text)]);
        let err = import_project_within(&service, &large, SMALL).unwrap_err();
        assert_eq!(err.message, TOO_BIG);
        assert_eq!(projects(&service), 0);

        // Within the limits, it imports.
        zip_of(&large, &[("a.tex", text), ("b.tex", text)]);
        import_project_within(&service, &large, SMALL).unwrap();
        assert_eq!(projects(&service), 1);
    }

    #[test]
    fn a_zip_that_understates_its_sizes_stops_at_the_bytes_read() {
        let (dir, service) = library();
        let src = dir.path().join("lying.zip");
        let mut zip = zip::ZipWriter::new(File::create(&src).unwrap());
        let stored = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        zip.start_file("a.tex", stored).unwrap();
        zip.write_all(&[b'x'; 40]).unwrap();
        zip.finish().unwrap();
        // Both its headers say the file is 1 byte: the uncompressed size is
        // 22 bytes into a local header, 24 into a central one.
        let mut bytes = fs::read(&src).unwrap();
        for (signature, at) in [(b"PK\x03\x04", 22), (b"PK\x01\x02", 24)] {
            let header = bytes.windows(4).position(|w| w == signature).unwrap();
            bytes[header + at..header + at + 4].copy_from_slice(&1u32.to_le_bytes());
        }
        fs::write(&src, bytes).unwrap();
        // As declared it fits the allowance; as read, it doesn't.
        let err = import_project_within(&service, &src, SMALL).unwrap_err();
        assert_eq!(err.message, TOO_BIG);
        assert_eq!(projects(&service), 0);
    }

    #[test]
    fn a_folder_past_the_file_or_entry_limit_makes_no_project() {
        let (dir, service) = library();
        let src = dir.path().join("Many");
        fs::create_dir_all(&src).unwrap();
        for name in ["a.tex", "b.tex", "c.tex", "d.tex"] {
            fs::write(src.join(name), "x").unwrap();
        }
        let err = import_project_within(&service, &src, SMALL).unwrap_err();
        assert_eq!(err.status, 400);
        // Empty folders cost a walk too.
        let src = dir.path().join("Hollow");
        for i in 0..10 {
            fs::create_dir_all(src.join(format!("d{i}"))).unwrap();
        }
        fs::write(src.join("main.tex"), "x").unwrap();
        assert!(import_project_within(&service, &src, SMALL).is_err());
        assert_eq!(projects(&service), 0);
    }

    #[test]
    fn a_drop_past_the_limits_writes_nothing() {
        let (dir, service) = library();
        projects::create_project(&service.data_dir, "P", "blank").unwrap();
        let src = dir.path().join("Many");
        fs::create_dir_all(&src).unwrap();
        for name in ["a.tex", "b.tex", "c.tex", "d.tex"] {
            fs::write(src.join(name), "x").unwrap();
        }
        let drop = [src];
        assert!(import_files_within(&service, "P", "", &drop, None, SMALL).is_err());
        assert!(!service.data_dir.join("P/Many").exists());
    }

    #[test]
    fn the_budget_counts_the_bytes_read_not_those_declared() {
        let mut budget = SMALL;
        let mut sink = Vec::new();
        budget.copy(&[1u8; 20][..], &mut sink).unwrap();
        // A file that says it is small, or a zip entry that lies, still
        // stops at the budget.
        let err = budget.copy(&[1u8; 6][..], &mut sink).unwrap_err();
        assert_eq!(err.message, TOO_BIG);
        budget.copy(&[1u8; 5][..], &mut sink).unwrap();
        assert!(budget.copy(&[1u8; 1][..], &mut sink).is_err());
    }

    #[test]
    fn zip_names_are_read_as_paths_and_none_leaves_the_project() {
        let (dir, service) = library();
        let src = dir.path().join("names.zip");
        let mut names = vec!["./main.tex", "a\\b.tex", "a/./c/../d.tex"];
        names.extend([
            "/etc/x.tex",
            "\\y.tex",
            "../z.tex",
            "a/../../w.tex",
            "./",
            "n\0.tex",
        ]);
        let files: Vec<_> = names.iter().map(|name| (*name, "x")).collect();
        zip_of(&src, &files);
        let info = import_project_within(&service, &src, IMPORT).unwrap();
        let root = service.data_dir.join(&info.id);
        // Made hidden, it has a new folder's usual mode all the same.
        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&root), mode(&service.data_dir));
        let mut found = Vec::new();
        projects::visit_files(&root, &mut |_, rel| {
            found.push(rel.to_owned());
            Ok(true)
        })
        .unwrap();
        found.sort();
        assert_eq!(found, ["a/b.tex", "a/d.tex", "main.tex"]);
    }
}
