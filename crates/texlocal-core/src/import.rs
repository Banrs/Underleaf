//! Bringing outside files into the library, for in-process hosts: a Finder
//! drop onto a project, and File › Open of a folder, a .zip or a .tex made a
//! new project. Both read host-chosen absolute paths, so neither is in
//! `Service::call`, which the browser server exposes. Both block on the
//! disk; hosts call them off their UI thread, as they do every `tl_call`.

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::json;
use zip::ZipArchive;

use crate::paths::{rel_key, sanitize_name};
use crate::projects::{self, ProjectInfo};
use crate::service::{keep_both, too_large, Clash, Service, UploadSpec, UPLOAD_MAX_BYTES};
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

/// How much one import may bring.
#[derive(Debug, Clone, Copy)]
struct Limits {
    /// Files brought.
    files: usize,
    /// Entries looked at: what a folder holds, hidden or not, or a zip's
    /// entries, folders included.
    entries: usize,
    /// Bytes, both as declared and as actually read: a zip's sizes can lie,
    /// and a file can grow while it is read.
    bytes: u64,
}

/// Far past any real project, so only a dropped home folder or a zip bomb
/// meets them, before it has filled the disk.
const IMPORT_LIMITS: Limits = Limits {
    files: 50_000,
    entries: 500_000,
    bytes: 4 << 30,
};

/// A .tex brings its folder only while that is no larger than a project:
/// Overleaf's limit on a project's files, and one upload's bytes.
const TEX_FOLDER_LIMITS: Limits = Limits {
    files: 2000,
    entries: 20_000,
    bytes: UPLOAD_MAX_BYTES as u64,
};

/// The limit an import met.
#[derive(Debug, Clone, Copy)]
enum Over {
    /// Too many files, or entries.
    Files,
    /// Too many bytes in all.
    Bytes,
    /// One file past the upload limit.
    File,
}

impl Over {
    fn error(self, limits: &Limits) -> CoreError {
        match self {
            Over::Files => CoreError::bad_request(format!(
                "There are too many files to import (the limit is {}).",
                limits.files
            )),
            Over::Bytes => CoreError::bad_request(format!(
                "The files to import come to more than the {} GB limit.",
                limits.bytes >> 30
            )),
            Over::File => too_large(),
        }
    }
}

/// Files found for an import, with project-relative names and where to read
/// each, until a limit stopped the search.
struct Found<S> {
    files: Vec<(UploadSpec, S)>,
    entries: usize,
    bytes: u64,
    over: Option<Over>,
}

impl<S> Found<S> {
    fn new() -> Self {
        Self {
            files: Vec::new(),
            entries: 0,
            bytes: 0,
            over: None,
        }
    }

    /// Count one entry looked at; false once a limit is met.
    fn visit(&mut self, limits: &Limits) -> bool {
        self.entries += 1;
        if self.over.is_none() && self.entries > limits.entries {
            self.over = Some(Over::Files);
        }
        self.over.is_none()
    }

    fn add(&mut self, spec: UploadSpec, source: S, limits: &Limits) {
        if self.over.is_some() {
            return;
        }
        // Saturating, so a size past u64 still fails the limits.
        self.bytes = self
            .bytes
            .saturating_add(u64::try_from(spec.size).unwrap_or(u64::MAX));
        self.over = if spec.size > UPLOAD_MAX_BYTES {
            Some(Over::File)
        } else if self.files.len() >= limits.files {
            Some(Over::Files)
        } else if self.bytes > limits.bytes {
            Some(Over::Bytes)
        } else {
            self.files.push((spec, source));
            None
        };
    }

    /// The files, unless a limit stopped the search.
    fn within(self, limits: &Limits) -> Result<Vec<(UploadSpec, S)>, CoreError> {
        match self.over {
            Some(over) => Err(over.error(limits)),
            None => Ok(self.files),
        }
    }
}

/// What an import may still read, counting the bytes actually read.
struct Budget {
    left: u64,
    limits: Limits,
}

impl Budget {
    fn new(limits: &Limits) -> Self {
        Self {
            left: limits.bytes,
            limits: *limits,
        }
    }

    /// Copy `source` to `sink`, refusing a file past the upload limit or the
    /// import past its budget, whatever their sizes were declared as.
    fn copy(&mut self, source: impl Read, sink: &mut impl Write) -> Result<(), CoreError> {
        let cap = (UPLOAD_MAX_BYTES as u64).min(self.left);
        let copied = io::copy(&mut source.take(cap + 1), sink)?;
        if copied > cap {
            let over = if copied > UPLOAD_MAX_BYTES as u64 {
                Over::File
            } else {
                Over::Bytes
            };
            return Err(over.error(&self.limits));
        }
        self.left -= copied;
        Ok(())
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
/// each, until a limit is met. Inside a folder, hidden entries stay behind
/// and symlinks are skipped, not followed: a drop imports what was dropped,
/// never what a link inside it points at.
fn collect(
    abs: &Path,
    rel: String,
    meta: fs::Metadata,
    found: &mut Found<PathBuf>,
    limits: &Limits,
) -> Result<(), CoreError> {
    if meta.is_file() {
        let spec = UploadSpec {
            path: rel,
            // Saturating, so a size past usize still fails the upload limit.
            size: usize::try_from(meta.len()).unwrap_or(usize::MAX),
        };
        found.add(spec, abs.to_path_buf(), limits);
    } else if meta.is_dir() {
        for entry in fs::read_dir(abs)? {
            if !found.visit(limits) {
                break;
            }
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
                collect(&entry.path(), rel, meta, found, limits)?;
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
    import_files_within(service, id, dir, paths, conflict, &IMPORT_LIMITS)
}

fn import_files_within(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
    limits: &Limits,
) -> Result<Imported, CoreError> {
    let mut found = Found::new();
    for abs in paths {
        let name = abs.file_name().unwrap_or_default().to_string_lossy();
        // A dropped link is followed: dropping it names what it points at.
        let meta = fs::metadata(abs)?;
        collect(abs, name.into_owned(), meta, &mut found, limits)?;
    }
    let (specs, sources): (Vec<_>, Vec<_>) = found.within(limits)?.into_iter().unzip();
    let existing = service.validate_uploads(id, dir, &specs)?.existing;
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported {
            saved: Vec::new(),
            existing,
        });
    }
    let replace = conflict == Some(Conflict::Replace);
    let mut budget = Budget::new(limits);
    let mut saved = Vec::new();
    for (spec, abs) in specs.into_iter().zip(sources) {
        let path = if conflict == Some(Conflict::KeepBoth) {
            keep_both(&spec.path, &existing)
        } else {
            spec.path
        };
        let mut bytes = Vec::new();
        budget.copy(File::open(abs)?, &mut bytes)?;
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

/// A zip entry's name as path segments, or None for one that is absolute,
/// leads out of the archive or holds a NUL. A backslash separates as a slash
/// does: the zip format allows only '/', but Windows tools have written '\'.
/// "." drops out and ".." goes back a folder.
fn zip_segments(name: &str) -> Option<Vec<&str>> {
    if name.contains('\0') || name.starts_with(['/', '\\']) {
        return None;
    }
    let mut segments = Vec::new();
    for segment in name.split(['/', '\\']) {
        match segment {
            "" | "." => {}
            ".." => {
                segments.pop()?;
            }
            segment => segments.push(segment),
        }
    }
    (!segments.is_empty()).then_some(segments)
}

/// A zip's visible files; the contents of its one top folder if it has one,
/// as a zipped project folder unpacks.
fn zip_files(
    archive: &mut ZipArchive<File>,
    limits: &Limits,
) -> Result<Vec<(UploadSpec, Source)>, CoreError> {
    if archive.len() > limits.entries {
        return Err(Over::Files.error(limits));
    }
    let mut found = Found::new();
    for i in 0..archive.len() {
        // Its name and size only: nothing is decompressed yet.
        let entry = archive.by_index_raw(i)?;
        // No folders or links, and no name that would leave the project.
        let Some(segments) = zip_segments(entry.name()).filter(|_| entry.is_file()) else {
            continue;
        };
        if !segments.iter().any(|s| hidden(s)) {
            let spec = UploadSpec {
                path: segments.join("/"),
                size: usize::try_from(entry.size()).unwrap_or(usize::MAX),
            };
            found.add(spec, Source::Zip(i), limits);
        }
    }
    let mut files = found.within(limits)?;
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

/// A folder's files, unless it passes `limits`.
fn folder_files(dir: &Path, limits: &Limits) -> Result<Vec<(UploadSpec, Source)>, CoreError> {
    let mut found = Found::new();
    collect(dir, String::new(), fs::metadata(dir)?, &mut found, limits)?;
    Ok(found
        .within(limits)?
        .into_iter()
        .map(|(s, p)| (s, Source::File(p)))
        .collect())
}

/// A file of a project being made, at a path `validate_uploads` has passed.
/// The folder is new and holds only what the import wrote, so there is no
/// clash to look for or file to replace, and a failed import removes it
/// whole: the file is written in place, with no temporary file or sync of
/// its own, and gets a new file's usual mode.
fn create_new(root: &Path, rel: &str) -> Result<BufWriter<File>, CoreError> {
    let abs = root.join(rel_key(rel)?);
    if let Some(parent) = abs.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = OpenOptions::new().write(true).create_new(true).open(abs)?;
    Ok(BufWriter::with_capacity(64 * 1024, file))
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
    import_project_within(service, src, &IMPORT_LIMITS)
}

fn import_project_within(
    service: &Service,
    src: &Path,
    limits: &Limits,
) -> Result<ProjectInfo, CoreError> {
    let meta = fs::metadata(src)?;
    let is_dir = meta.is_dir();
    let named =
        |name: Option<&std::ffi::OsStr>| name.unwrap_or_default().to_string_lossy().into_owned();
    let ext = named(src.extension()).to_lowercase();
    let tex = (!is_dir && ext == "tex").then(|| named(src.file_name()));
    let folder = if is_dir {
        Some((src, folder_files(src, limits)?))
    } else {
        src.parent().zip(tex.as_ref()).and_then(|(dir, tex)| {
            let files = folder_files(dir, &TEX_FOLDER_LIMITS).ok()?;
            (files.iter().any(|(s, _)| &s.path == tex)
                && sanitize_name(&named(dir.file_name())).is_ok())
            .then_some((dir, files))
        })
    };
    let (base, mut zip, mut files) = if let Some((dir, found)) = folder {
        (named(dir.file_name()), None, found)
    } else if ext == "zip" {
        let mut archive = ZipArchive::new(File::open(src)?)?;
        let found = zip_files(&mut archive, limits)?;
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

    let (id, root) = projects::new_project_dir(&service.data_dir, &base)?;
    let result = (|| {
        let (specs, sources): (Vec<_>, Vec<_>) = files.into_iter().unzip();
        service.validate_uploads(&id, "", &specs)?;
        let mut budget = Budget::new(limits);
        for (spec, source) in specs.iter().zip(sources) {
            let mut dest = create_new(&root, &spec.path)?;
            match source {
                Source::File(path) => budget.copy(File::open(path)?, &mut dest)?,
                Source::Zip(i) => {
                    let entry = zip.as_mut().expect("a zip source").by_index(i)?;
                    budget.copy(entry, &mut dest)?;
                }
            }
            dest.into_inner().map_err(io::IntoInnerError::into_error)?;
        }
        let main = if let Some(main) = tex {
            main
        } else if let Some(main) = projects::guess_main_file(&root)? {
            main
        } else {
            let (file, content) = templates::files("blank")[0];
            fs::write(root.join(file), content)?;
            file.to_string()
        };
        projects::finish_project(id, &root, &json!({ "mainFile": main }))
    })();
    if result.is_err() {
        // Only copies are lost: the folder is the one made above.
        let _ = fs::remove_dir_all(&root);
    }
    result
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

    const SMALL: Limits = Limits {
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
        let err = import_project_within(&service, &many, &SMALL).unwrap_err();
        assert_eq!(err.status, 400);
        assert!(err.message.contains("too many files"), "{}", err.message);

        let large = dir.path().join("large.zip");
        let text = "0123456789";
        zip_of(&large, &[("a.tex", text), ("b.tex", text), ("c.tex", text)]);
        let err = import_project_within(&service, &large, &SMALL).unwrap_err();
        assert_eq!(err.status, 400);
        assert!(err.message.contains("GB limit"), "{}", err.message);
        assert_eq!(projects(&service), 0);

        // Within the limits, it imports.
        zip_of(&large, &[("a.tex", text), ("b.tex", text)]);
        import_project_within(&service, &large, &SMALL).unwrap();
        assert_eq!(projects(&service), 1);
    }

    #[test]
    fn a_folder_past_the_file_or_entry_limit_makes_no_project() {
        let (dir, service) = library();
        let src = dir.path().join("Many");
        fs::create_dir_all(&src).unwrap();
        for name in ["a.tex", "b.tex", "c.tex", "d.tex"] {
            fs::write(src.join(name), "x").unwrap();
        }
        assert_eq!(
            import_project_within(&service, &src, &SMALL)
                .unwrap_err()
                .status,
            400
        );
        // Empty folders cost a walk too.
        let src = dir.path().join("Hollow");
        for i in 0..10 {
            fs::create_dir_all(src.join(format!("d{i}"))).unwrap();
        }
        fs::write(src.join("main.tex"), "x").unwrap();
        assert!(import_project_within(&service, &src, &SMALL).is_err());
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
        assert!(import_files_within(&service, "P", "", &drop, None, &SMALL).is_err());
        assert!(!service.data_dir.join("P/Many").exists());
    }

    #[test]
    fn the_budget_counts_the_bytes_read_not_those_declared() {
        let mut budget = Budget::new(&SMALL);
        let mut sink = Vec::new();
        budget.copy(&[1u8; 20][..], &mut sink).unwrap();
        // A file that says it is small, or a zip entry that lies, still
        // stops at the budget.
        let err = budget.copy(&[1u8; 6][..], &mut sink).unwrap_err();
        assert_eq!(err.status, 400);
        budget.copy(&[1u8; 5][..], &mut sink).unwrap();
        assert!(budget.copy(&[1u8; 1][..], &mut sink).is_err());
    }

    #[test]
    fn zip_names_are_read_as_paths_whatever_their_separators() {
        assert_eq!(zip_segments("./main.tex"), Some(vec!["main.tex"]));
        assert_eq!(
            zip_segments("paper\\figs\\a.png"),
            Some(vec!["paper", "figs", "a.png"])
        );
        assert_eq!(zip_segments("a/./b/../c.tex"), Some(vec!["a", "c.tex"]));
        for outside in ["/etc/passwd", "\\x", "../x", "a/../../x", "a\0b", "./", ""] {
            assert_eq!(zip_segments(outside), None, "{outside:?}");
        }
    }
}
