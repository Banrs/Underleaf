//! Bringing outside files into the library: a Finder drop onto a project,
//! and File › Open of a folder, a .zip or a .tex made a new project. Both read
//! host-chosen absolute paths and block on the disk; hosts call them off
//! their UI thread, as they do every `tl_call`.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::json;
use zip::ZipArchive;
use zip::result::ZipError;

use crate::paths::{self, after_entry, fold_case, normalize_segments, rel_key};
use crate::projects::{self, ProjectInfo, Staging, Trash};
use crate::service::Service;
use crate::settings::write_settings;
use crate::{BUILD_DIR, CoreError, SETTINGS_FILE, atomic, templates};

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

/// An incoming file's occupied path or blocking parent file, relative to its
/// target folder. `keep_both` names a free sibling.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Clash {
    pub path: String,
    pub keep_both: String,
}

/// Where an incoming file is read from.
enum Source {
    File(PathBuf),
    /// An entry of the chosen zip, by index.
    Zip(usize),
}

/// A file to bring: its path (in the target folder, or the new project), and
/// where to read it.
struct Incoming {
    path: String,
    source: Source,
}

/// What an import may still bring. `entries` are what a folder holds, hidden
/// or not, and a zip's entries: a hollow tree costs a walk too. Bytes are
/// taken as declared while the files are found, and again as read, since a
/// zip's sizes can lie and a file can grow while it is read.
///
/// It is `Copy` on purpose: finding the files and copying them each spend
/// their own copy of one allowance, the first on the sizes declared, the
/// second on the bytes read.
#[derive(Debug, Clone, Copy)]
struct Allowance {
    entries: u64,
    bytes: u64,
    /// The most any one file may be.
    per_file: u64,
}

const TOO_MANY: &str = "There are too many files to import.";
const TOO_BIG: &str = "The files to import are too large.";

/// The largest file a drop takes.
const UPLOAD_MAX_BYTES: u64 = 100 * 1024 * 1024;
const IMPORT_MAX_BYTES: u64 = 4 << 30;

/// Far past any real project, so only a dropped home folder or a zip bomb
/// meets it, before it has filled the disk.
const DROP: Allowance = Allowance {
    entries: 100_000,
    bytes: IMPORT_MAX_BYTES,
    per_file: UPLOAD_MAX_BYTES,
};

/// What File › Open takes: a folder chosen to be a project may hold a data
/// set or a video, so one file may be as large as the whole.
const OPEN: Allowance = Allowance {
    per_file: IMPORT_MAX_BYTES,
    ..DROP
};

/// A .tex brings its folder only while that is no larger than a project:
/// Overleaf's limit on a project's files, and one upload's bytes.
const TEX_FOLDER: Allowance = Allowance {
    entries: 2000,
    bytes: UPLOAD_MAX_BYTES,
    per_file: UPLOAD_MAX_BYTES,
};

impl Allowance {
    fn entry(&mut self) -> Result<(), CoreError> {
        self.entries = self
            .entries
            .checked_sub(1)
            .ok_or_else(|| CoreError::bad_request(TOO_MANY))?;
        Ok(())
    }

    /// Take `n` bytes from what is left.
    fn spend(&mut self, n: u64) -> Result<(), CoreError> {
        self.bytes = self
            .bytes
            .checked_sub(n)
            .ok_or_else(|| CoreError::bad_request(TOO_BIG))?;
        Ok(())
    }

    /// A file of `size`, as declared, that is to come.
    fn file(&mut self, name: &str, size: u64) -> Result<(), CoreError> {
        if size > self.per_file {
            return Err(self.too_large(name));
        }
        self.spend(size)
    }

    fn too_large(&self, name: &str) -> CoreError {
        let megabytes = self.per_file / 1024 / 1024;
        CoreError::bad_request(format!(
            "“{name}” is larger than the {megabytes} MB one file may be."
        ))
    }

    /// Copy `source`, the file `name`, to `sink`, taking the bytes actually
    /// read, and never more than one file may be.
    fn copy(
        &mut self,
        name: &str,
        source: impl Read,
        sink: &mut impl Write,
    ) -> Result<(), CoreError> {
        let cap = self.bytes.min(self.per_file);
        let copied = io::copy(&mut source.take(cap + 1), sink)?;
        if copied > self.per_file {
            return Err(self.too_large(name));
        }
        self.spend(copied)
    }
}

/// `name` in the project folder `dir` ("" is the project's own).
fn in_folder(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    }
}

/// Files under a dropped path, with project-relative names that keep a
/// dropped folder's own name (none for an empty `rel`), failing once
/// `allowance` runs out. Inside a folder, what `is_litter` and symlinks stay
/// behind, not followed: a drop imports what was dropped, never what a link
/// inside it points at.
fn collect(
    abs: &Path,
    rel: String,
    meta: &fs::Metadata,
    files: &mut Vec<Incoming>,
    allowance: &mut Allowance,
) -> Result<(), CoreError> {
    if meta.is_file() {
        allowance.file(&rel, meta.len())?;
        let source = Source::File(abs.to_path_buf());
        files.push(Incoming { path: rel, source });
    } else if meta.is_dir() {
        for entry in fs::read_dir(abs).map_err(CoreError::at(abs))? {
            allowance.entry()?;
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !projects::is_litter(&name)
                && !(rel.is_empty() && name.eq_ignore_ascii_case(BUILD_DIR))
            {
                // DirEntry::metadata does not follow links.
                let meta = entry.metadata()?;
                let rel = in_folder(&rel, &name);
                collect(&entry.path(), rel, &meta, files, allowance)?;
            }
        }
    }
    Ok(())
}

/// Import dropped files and folders into the project folder `dir`: a bad
/// path or oversize file fails the drop before anything lands. Without
/// `conflict`, a drop that would land on existing entries writes nothing and
/// reports them, for the host to ask about.
pub fn import_files(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
) -> Result<Imported, CoreError> {
    import_files_within(service, id, dir, paths, conflict, DROP, projects::discard)
}

/// `import_files` under `allowance`, with `trash` to discard what Replace
/// replaces.
fn import_files_within(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
    mut allowance: Allowance,
    trash: Trash,
) -> Result<Imported, CoreError> {
    let mut files = Vec::new();
    let mut found = allowance;
    for abs in paths {
        let name = abs.file_name().unwrap_or_default().to_string_lossy();
        // A dropped link is followed: dropping it names what it points at.
        let meta = fs::metadata(abs).map_err(CoreError::at(abs))?;
        collect(abs, name.into_owned(), &meta, &mut files, &mut found)?;
    }
    let root = service.project_root(id)?;
    let rels = validate(&root, dir, files.iter().map(|file| file.path.as_str()))?;
    let base = root.join(rel_key(dir).unwrap_or_default());
    let existing = clashes(&base, &rels);
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported {
            saved: Vec::new(),
            existing,
        });
    }
    let replace = (conflict == Some(Conflict::Replace)).then_some(trash);
    let mut saved = Vec::new();
    for file in files {
        let path = if conflict == Some(Conflict::KeepBoth) {
            keep_both(&file.path, &existing)
        } else {
            file.path
        };
        let rel = in_folder(dir, &path);
        let Source::File(source) = file.source else {
            unreachable!("a drop is of files");
        };
        save(service, id, &rel, &source, replace, &mut allowance)?;
        saved.push(rel);
    }
    Ok(Imported { saved, existing })
}

/// Checks the whole batch before anything is written, so a late unsafe entry
/// cannot cause a predictable partial import: every path must be one that may
/// be written in the folder `dir` of `root`, none twice, and none a file
/// where another needs a folder. Returns the paths relative to `dir`, as the
/// host names the files.
fn validate<'a>(
    root: &Path,
    dir: &str,
    files: impl Iterator<Item = &'a str>,
) -> Result<Vec<String>, CoreError> {
    let mut seen = HashSet::new();
    let mut folders = HashSet::new();
    let mut rels = Vec::new();
    for file in files {
        paths::safe_write_path(root, &in_folder(dir, file))?;
        let rel = rel_key(file)?;
        let key = fold_case(&rel);
        let parents = || key.match_indices('/').map(|(i, _)| &key[..i]);
        if seen.contains(&key) {
            return Err(CoreError::bad_request(
                "The upload contains duplicate paths",
            ));
        }
        if folders.contains(&key) || parents().any(|parent| seen.contains(parent)) {
            return Err(CoreError::bad_request(
                "The upload contains conflicting paths",
            ));
        }
        folders.extend(parents().map(str::to_string));
        seen.insert(key.clone());
        rels.push(rel);
    }
    Ok(rels)
}

/// The entries the validated `rels` would land on under `base`, with free
/// Keep Both names, for the host's Replace, Keep Both or Stop choice.
fn clashes(base: &Path, rels: &[String]) -> Vec<Clash> {
    // Names a Keep Both may not take: every path the import creates.
    let mut taken: HashSet<String> = HashSet::new();
    for rel in rels {
        let key = fold_case(rel);
        taken.extend(key.match_indices('/').map(|(i, _)| key[..i].to_string()));
        taken.insert(key);
    }
    let mut existing: Vec<Clash> = Vec::new();
    for rel in rels {
        let Some(path) = occupant(base, rel) else {
            continue;
        };
        if existing.iter().any(|c| c.path == path) {
            continue;
        }
        let keep_both = projects::copy_paths(&path)
            .skip(1)
            .find(|free| {
                fs::symlink_metadata(base.join(free)).is_err() && taken.insert(fold_case(free))
            })
            .expect("a free name");
        existing.push(Clash { path, keep_both });
    }
    existing
}

/// A file's path once Keep Both has renamed the clash it lies under.
fn keep_both(path: &str, clashes: &[Clash]) -> String {
    let renamed = clashes.iter().find_map(|clash| {
        let rest = after_entry(path, &clash.path)?;
        Some(format!("{}{rest}", clash.keep_both))
    });
    renamed.unwrap_or_else(|| path.to_string())
}

/// The first entry in `rel`'s way under `base`: the file itself if it
/// exists, or a folder on its path that exists as something else.
fn occupant(base: &Path, rel: &str) -> Option<String> {
    let mut end = 0;
    loop {
        end = rel[end..].find('/').map_or(rel.len(), |i| end + i);
        let abs = base.join(&rel[..end]);
        let meta = fs::symlink_metadata(&abs).ok()?;
        // A link to a folder is a folder on the way: the path checks have
        // already kept it inside the project.
        if end == rel.len() || !(meta.is_dir() || abs.is_dir()) {
            return Some(rel[..end].to_string());
        }
        end += 1;
    }
}

/// Write the file at `source` to the project path `rel`. It is copied to a
/// temporary file beside the target first, so a source that fails or
/// outgrows the allowance part-way replaces nothing, then renamed into place
/// whole. An occupied path conflicts unless `replace`, the means of
/// discarding it, first moves it to the Trash.
fn save(
    service: &Service,
    id: &str,
    rel: &str,
    source: &Path,
    replace: Option<Trash>,
    allowance: &mut Allowance,
) -> Result<(), CoreError> {
    let root = service.project_root(id)?;
    // In the target's folder, or the nearest on its way while that is to be made, so the
    // rename stays on one volume; any name there, as the temporary file is made beside it.
    let abs = paths::safe_write_path(&root, rel)?;
    let folder = abs.ancestors().skip(1).find(|dir| dir.is_dir());
    let (temp, mut file) = atomic::create_temp(&folder.unwrap_or(&root).join("incoming"), None)?;
    let origin = File::open(source).map_err(CoreError::at(source))?;
    allowance.copy(rel, origin, &mut file)?;
    file.sync_all()?;
    drop(file);
    service.with_project(id, |root| {
        let abs = paths::safe_write_path(root, rel)?;
        if let Some(taken) = occupant(root, &rel_key(rel)?) {
            let Some(trash) = replace else {
                return Err(CoreError::conflict(format!("“{taken}” already exists")));
            };
            projects::discard_replaced(root, &taken, trash)?;
        }
        if let Some(parent) = abs.parent() {
            fs::create_dir_all(parent)?;
        }
        Ok(atomic::persist(temp, &abs)?)
    })
}

/// A zip's visible files; the contents of its one top folder if it has one,
/// as a zipped project folder unpacks.
fn zip_files(
    archive: &mut ZipArchive<File>,
    mut allowance: Allowance,
) -> Result<Vec<Incoming>, CoreError> {
    for _ in 0..archive.len() {
        allowance.entry()?;
    }
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
        if !segments.iter().any(|s| projects::is_litter(s)) {
            allowance.file(&name, entry.size())?;
            files.push(Incoming {
                path: segments.join("/"),
                source: Source::Zip(i),
            });
        }
    }
    let top = files
        .first()
        .and_then(|file| Some(format!("{}/", file.path.split_once('/')?.0)));
    if let Some(top) = top.filter(|top| files.iter().all(|file| file.path.starts_with(top))) {
        for file in &mut files {
            file.path.drain(..top.len());
        }
    }
    Ok(files)
}

/// A folder's files, unless they are more than `allowance`.
fn folder_files(dir: &Path, mut allowance: Allowance) -> Result<Vec<Incoming>, CoreError> {
    let meta = fs::metadata(dir).map_err(CoreError::at(dir))?;
    let mut found = Vec::new();
    collect(dir, String::new(), &meta, &mut found, &mut allowance)?;
    Ok(found)
}

/// What File › Open brings: the new project's name, its files, the zip they
/// are in (if they are), and the main file chosen (if one is).
struct Opened {
    base: String,
    zip: Option<ZipArchive<File>>,
    files: Vec<Incoming>,
    main: Option<String>,
}

/// The folder a .tex is in, unless that can't be read, is larger than a
/// project, has no name a project can take, or lacks the .tex (it has just
/// been moved). The .tex is the main file.
fn tex_folder(tex: &Path) -> Option<Opened> {
    let dir = tex.parent()?;
    paths::sanitize_name(&file_name(dir)).ok()?;
    let files = folder_files(dir, TEX_FOLDER).ok()?;
    let main = file_name(tex);
    files.iter().any(|file| file.path == main).then(|| Opened {
        base: file_name(dir),
        zip: None,
        files,
        main: Some(main),
    })
}

/// Find the files File › Open brings from `src`, within `allowance`.
fn open(src: &Path, allowance: Allowance) -> Result<Opened, CoreError> {
    let meta = fs::metadata(src).map_err(CoreError::at(src))?;
    let ext = src
        .extension()
        .map(|ext| ext.to_string_lossy().to_lowercase());
    let stem = src
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    if meta.is_dir() {
        let files = folder_files(src, allowance)?;
        return Ok(Opened {
            base: file_name(src),
            zip: None,
            files,
            main: None,
        });
    }
    if ext.as_deref() == Some("zip") {
        let file = File::open(src).map_err(CoreError::at(src))?;
        let mut archive = ZipArchive::new(file).map_err(|err| match err {
            ZipError::Io(err) => CoreError::at(src)(err),
            err => {
                let name = file_name(src);
                CoreError::bad_request(format!("“{name}” can't be read as a zip ({err})"))
            }
        })?;
        let files = zip_files(&mut archive, allowance)?;
        return Ok(Opened {
            base: stem,
            zip: Some(archive),
            files,
            main: None,
        });
    }
    if ext.as_deref() == Some("tex")
        && let Some(opened) = tex_folder(src)
    {
        return Ok(opened);
    }
    // Any other file comes alone, and so does a .tex whose folder does not qualify.
    let path = file_name(src);
    let main = (projects::file_kind(&path) == "tex").then(|| path.clone());
    let source = Source::File(src.to_path_buf());
    Ok(Opened {
        base: stem,
        zip: None,
        files: vec![Incoming { path, source }],
        main,
    })
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

/// File › Open: a folder, a .zip or a single file from anywhere, copied into
/// a new project named after it ("Name 2" when that is taken). A .tex brings its folder,
/// for what it inputs, includes and cites, unless that folder can't be read, is larger
/// than a project (more than 2000 entries or one upload's bytes) or has no name a project
/// can take: then the .tex comes alone. Version-control folders and OS litter stay behind,
/// as does a top-level `build`; every other file comes, though the file tree hides dotfiles.
/// The main file is the chosen .tex, else the likeliest top-level one, else the blank
/// template's main.tex.
pub fn import_project(service: &Service, src: &Path) -> Result<ProjectInfo, CoreError> {
    import_project_within(service, src, OPEN)
}

fn import_project_within(
    service: &Service,
    src: &Path,
    mut allowance: Allowance,
) -> Result<ProjectInfo, CoreError> {
    let Opened {
        base,
        mut zip,
        mut files,
        main,
    } = open(src, allowance)?;
    // The compile output and the project's own settings are not brought.
    files.retain(|file| {
        let top = file.path.split('/').next().unwrap_or_default();
        !top.eq_ignore_ascii_case(BUILD_DIR) && !file.path.eq_ignore_ascii_case(SETTINGS_FILE)
    });

    let staging = Staging::new(&service.data_dir, &base)?;
    let staged = staging.path();
    validate(staged, "", files.iter().map(|file| file.path.as_str()))?;
    for file in &files {
        // The folder holds only what the import wrote, so there is no clash
        // or file to replace: each is written in place, with no temporary
        // file or sync of its own, and gets a new file's usual mode.
        let abs = staged.join(rel_key(&file.path)?);
        fs::create_dir_all(abs.parent().unwrap_or(staged))?;
        let mut dest = BufWriter::new(File::create_new(abs)?);
        match &file.source {
            Source::File(path) => {
                let origin = File::open(path).map_err(CoreError::at(path))?;
                allowance.copy(&file.path, origin, &mut dest)?;
            }
            Source::Zip(i) => {
                let entry = zip.as_mut().expect("a zip source").by_index(*i)?;
                allowance.copy(&file.path, entry, &mut dest)?;
            }
        }
        dest.flush()?;
    }
    let main = if let Some(main) = main {
        main
    } else if let Some(main) = projects::guess_main_file(staged)? {
        main
    } else {
        let (file, content) = templates::files("blank")[0];
        fs::write(staged.join(file), content)?;
        file.to_string()
    };
    write_settings(staged, &json!({ "mainFile": main }))?;
    staging.publish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::{files_in, library, with_project, zip_of, zip_with};

    fn projects(service: &Service) -> usize {
        fs::read_dir(&service.data_dir).unwrap().count()
    }

    fn saved(imported: &Imported) -> Vec<String> {
        let mut saved = imported.saved.clone();
        saved.sort();
        saved
    }

    /// Stands in for the platform's Trash, which a test can't look into.
    fn remove(path: &Path) -> Result<(), CoreError> {
        if path.is_dir() {
            fs::remove_dir_all(path)?;
        } else {
            fs::remove_file(path)?;
        }
        Ok(())
    }

    /// Saves `bytes` as the file `rel` of project "P"; `replace` removes what is there.
    fn put(service: &Service, rel: &str, bytes: &[u8], replace: bool) -> Result<(), CoreError> {
        let source = tempfile::NamedTempFile::new().unwrap();
        fs::write(source.path(), bytes).unwrap();
        let replace = replace.then_some(remove as Trash);
        save(service, "P", rel, source.path(), replace, &mut { DROP })
    }

    const SMALL: Allowance = Allowance {
        entries: 3,
        bytes: 25,
        per_file: 30,
    };

    #[test]
    fn files_are_validated_as_a_batch_before_any_write() {
        let (_dir, service) = with_project();
        let root = service.project_root("P").unwrap();

        assert!(validate(&root, "img", ["a.png", "b.png"].into_iter()).is_ok());
        for batch in [
            ["a.png", "a.png"],
            ["notes", "notes/ch.tex"],
            ["notes/ch.tex", "notes"],
            ["a.png", "../x.png"],
        ] {
            let err = validate(&root, "", batch.into_iter()).unwrap_err();
            assert_eq!(err.status, 400);
        }

        put(&service, "img/c.png", b"png", false).unwrap();
        assert_eq!(fs::read(root.join("img/c.png")).unwrap(), b"png");
    }

    #[test]
    fn a_file_reports_what_it_would_land_on_and_never_overwrites_unasked() {
        let (_dir, service) = with_project();
        let root = service.project_root("P").unwrap();
        fs::create_dir_all(root.join("figs")).unwrap();
        fs::write(root.join("figs/a.png"), "old").unwrap();
        fs::write(root.join("figs/a 2.png"), "older").unwrap();
        fs::write(root.join("notes"), "a file").unwrap();
        let batch = [
            "main.tex",
            "figs/a.png",
            "figs/b.png",
            "notes/x.tex",
            "notes/y.tex",
            // Keep Both must not pick a name the import itself brings.
            "main 2.tex",
        ];
        let rels = validate(&root, "", batch.into_iter()).unwrap();
        let existing = clashes(&root, &rels);
        assert_eq!(
            serde_json::to_value(&existing).unwrap(),
            json!([
                { "path": "main.tex", "keepBoth": "main 3.tex" },
                { "path": "figs/a.png", "keepBoth": "figs/a 3.png" },
                // A folder of the import that is a file here, once.
                { "path": "notes", "keepBoth": "notes 2" },
            ])
        );
        let renamed = |p: &str| keep_both(p, &existing);
        assert_eq!(renamed("notes/x.tex"), "notes 2/x.tex");
        assert_eq!(renamed("figs/b.png"), "figs/b.png");
        assert_eq!(renamed("notesy/x.tex"), "notesy/x.tex");

        let err = put(&service, "figs/a.png", b"new", false).unwrap_err();
        assert_eq!(
            (err.status, err.message.as_str()),
            (409, "“figs/a.png” already exists")
        );
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"old");
        // Replacing a folder that holds the main file is refused before the Trash.
        fs::create_dir(root.join("ch")).unwrap();
        fs::rename(root.join("main.tex"), root.join("ch/main.tex")).unwrap();
        write_settings(&root, &json!({ "mainFile": "ch/main.tex" })).unwrap();
        assert_eq!(put(&service, "ch", b"x", true).unwrap_err().status, 409);
        // However the import spells it, on a volume that ignores case.
        #[cfg(target_os = "macos")]
        assert_eq!(put(&service, "CH", b"x", true).unwrap_err().status, 409);
        assert!(root.join("ch/main.tex").is_file());
        // Nothing is left beside the project's files by the refused saves.
        for folder in ["", "figs"] {
            for entry in fs::read_dir(root.join(folder)).unwrap() {
                let name = entry.unwrap().file_name();
                assert!(!name.to_string_lossy().starts_with(".texlocal-"));
            }
        }
    }

    #[test]
    fn replace_discards_what_is_there_and_brings_the_incoming_file() {
        let (dir, service) = with_project();
        let root = service.project_root("P").unwrap();
        fs::create_dir_all(root.join("figs")).unwrap();
        fs::write(root.join("figs/a.png"), "old").unwrap();
        let drop = dir.path().join("drop");
        fs::create_dir_all(drop.join("figs")).unwrap();
        fs::write(drop.join("figs/a.png"), "new").unwrap();
        fs::write(drop.join("figs/b.png"), "b").unwrap();
        let paths = [drop.join("figs")];

        let replaced = Some(Conflict::Replace);
        let out = import_files_within(&service, "P", "", &paths, replaced, DROP, remove).unwrap();
        assert_eq!(saved(&out), ["figs/a.png", "figs/b.png"]);
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"new");
        // The clash is reported all the same, for the host to say what it replaced.
        assert_eq!(out.existing.len(), 1);

        // A mover that fails leaves the old file and takes nothing in.
        fs::write(drop.join("figs/a.png"), "newer").unwrap();
        let refuse: Trash = |_| Err(CoreError::internal("no Trash"));
        let result = import_files_within(&service, "P", "", &paths, replaced, DROP, refuse);
        assert!(result.is_err());
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"new");
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_a_folder_in_the_project_is_a_folder_a_file_goes_into() {
        let (_dir, service) = with_project();
        let root = service.project_root("P").unwrap();
        fs::create_dir(root.join("figs")).unwrap();
        std::os::unix::fs::symlink(root.join("figs"), root.join("link")).unwrap();
        let rels = validate(&root, "", ["link/a.png"].into_iter()).unwrap();
        assert!(clashes(&root, &rels).is_empty());
        put(&service, "link/a.png", b"png", false).unwrap();
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"png");
    }

    #[test]
    fn a_zip_or_folder_past_the_entry_or_byte_limit_makes_no_project() {
        let (dir, service) = with_project();
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
        assert_eq!(projects(&service), 1);

        // Within the limits, it imports.
        zip_of(&large, &[("a.tex", text), ("b.tex", text)]);
        import_project_within(&service, &large, SMALL).unwrap();
        assert_eq!(projects(&service), 2);

        // A folder is held to them too, empty folders included, and so is a drop of it,
        // which writes nothing.
        let src = dir.path().join("Hollow");
        for i in 0..4 {
            fs::create_dir_all(src.join(format!("d{i}"))).unwrap();
        }
        fs::write(src.join("main.tex"), "x").unwrap();
        let err = import_project_within(&service, &src, SMALL).unwrap_err();
        assert_eq!(err.message, TOO_MANY);
        let drop = [src];
        let attempt = import_files_within(&service, "P", "", &drop, None, SMALL, remove);
        assert_eq!(attempt.unwrap_err().message, TOO_MANY);
        assert!(!service.data_dir.join("P/Hollow").exists());
        assert_eq!(projects(&service), 2);
    }

    #[test]
    fn a_file_over_the_limit_is_named_and_a_drop_takes_less_than_an_open() {
        let (dir, service) = with_project();
        let src = dir.path().join("Thesis");
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("main.tex"), "\\documentclass{article}").unwrap();
        // Sparse: past a drop's largest file without writing it.
        let video = fs::File::create(src.join("talk.mov")).unwrap();
        video.set_len(UPLOAD_MAX_BYTES + 1).unwrap();

        let drop = [src.join("talk.mov")];
        let err = import_files(&service, "P", "", &drop, None).unwrap_err();
        assert_eq!(err.status, 400);
        assert!(err.message.contains("talk.mov"), "{}", err.message);
        assert!(
            !err.message.to_lowercase().contains("upload"),
            "{}",
            err.message
        );
        assert!(!service.data_dir.join("P/talk.mov").exists());

        // Opened as a project, the same file comes with the rest.
        let info = import_project(&service, &src).unwrap();
        let root = service.data_dir.join(&info.id);
        assert_eq!(files_in(&root), ["main.tex", "talk.mov"]);
        assert_eq!(
            fs::metadata(root.join("talk.mov")).unwrap().len(),
            UPLOAD_MAX_BYTES + 1
        );
    }

    #[test]
    fn a_zip_that_understates_its_sizes_stops_at_the_bytes_read() {
        let (dir, service) = library();
        let src = dir.path().join("lying.zip");
        zip_of(&src, &[("a.tex", "x".repeat(40).as_str())]);
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
    fn the_budget_counts_the_bytes_read_not_those_declared() {
        let mut budget = SMALL;
        let mut sink = Vec::new();
        budget.copy("a", &[1u8; 20][..], &mut sink).unwrap();
        // A file that says it is small, or a zip entry that lies, still
        // stops at the budget.
        let err = budget.copy("b", &[1u8; 6][..], &mut sink).unwrap_err();
        assert_eq!(err.message, TOO_BIG);
        budget.copy("c", &[1u8; 5][..], &mut sink).unwrap();
        assert!(budget.copy("d", &[1u8; 1][..], &mut sink).is_err());
        // And no one file passes its own limit, whatever is left.
        let mut roomy = Allowance {
            bytes: 100,
            per_file: 25,
            ..SMALL
        };
        let err = roomy
            .copy("big.dat", &[1u8; 30][..], &mut sink)
            .unwrap_err();
        assert!(err.message.contains("big.dat"), "{}", err.message);
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
        let info = import_project_within(&service, &src, OPEN).unwrap();
        let root = service.data_dir.join(&info.id);
        // Made hidden, it has a new folder's usual mode all the same.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&root), mode(&service.data_dir));
        }
        assert_eq!(files_in(&root), ["a/b.tex", "a/d.tex", "main.tex"]);
    }

    #[test]
    fn a_folder_brings_its_files_but_not_litter_build_output_or_another_projects_settings() {
        let (dir, service) = library();
        let src = dir.path().join("Thesis");
        for (path, text) in [
            ("main.tex", "\\documentclass{book}"),
            ("figs/a.png", "png"),
            ("figs/.DS_Store", "x"),
            (".git/HEAD", "ref"),
            (".latexmkrc", "$pdf_mode = 1;"),
            (".texlocal.json", "{\"mainFile\": \"elsewhere.tex\"}"),
            ("build/main.pdf", "old output"),
        ] {
            fs::create_dir_all(src.join(path).parent().unwrap()).unwrap();
            fs::write(src.join(path), text).unwrap();
        }

        let info = import_project(&service, &src).unwrap();
        assert_eq!([info.id, info.main_file], ["Thesis", "main.tex"]);
        let root = service.data_dir.join("Thesis");
        assert_eq!(files_in(&root), ["figs/a.png", "main.tex"]);
        assert!(!root.join(".git").exists() && !root.join("build").exists());
        assert!(!root.join("figs/.DS_Store").exists());
        // The author's own dotfile comes; the project's settings are made fresh.
        assert_eq!(
            fs::read_to_string(root.join(".latexmkrc")).unwrap(),
            "$pdf_mode = 1;"
        );
        assert_eq!(crate::settings::read_settings(&root).main_file, "main.tex");

        // A taken name gets a number, as Finder's copies do.
        assert_eq!(import_project(&service, &src).unwrap().id, "Thesis 2");
    }

    #[test]
    fn a_zip_of_one_folder_brings_that_folders_contents() {
        let (dir, service) = library();
        let src = dir.path().join("paper.zip");
        let files = [
            ("paper/aaa.tex", "\\section{Intro}"),
            ("paper/doc.tex", "\\documentclass{article}"),
            ("paper/figs/b.png", "png"),
            ("paper/.latexmkrc", "$pdf_mode = 1;"),
            ("paper/.git/HEAD", "ref"),
            ("__MACOSX/paper/._doc.tex", "fork"),
        ];
        zip_of(&src, &files);

        let info = import_project(&service, &src).unwrap();
        // No main.tex: the first file that starts a document.
        assert_eq!([info.id, info.main_file], ["paper", "doc.tex"]);
        let root = service.data_dir.join("paper");
        assert_eq!(files_in(&root), ["aaa.tex", "doc.tex", "figs/b.png"]);
        assert_eq!(fs::read_to_string(root.join("figs/b.png")).unwrap(), "png");
        assert!(root.join(".latexmkrc").is_file() && !root.join(".git").exists());
    }

    #[test]
    fn a_tex_brings_its_folder_and_is_its_main_file() {
        let (dir, service) = library();
        let src = dir.path().join("Paper");
        for (path, text) in [
            ("main.tex", "\\documentclass{article}"),
            ("paper.tex", "\\documentclass{article}\\input{chapters/a}"),
            ("chapters/a.tex", "\\section{A}"),
            ("refs.bib", "@book{k,}"),
        ] {
            fs::create_dir_all(src.join(path).parent().unwrap()).unwrap();
            fs::write(src.join(path), text).unwrap();
        }
        let info = import_project(&service, &src.join("paper.tex")).unwrap();
        assert_eq!([info.id, info.main_file], ["Paper", "paper.tex"]);
        let files = ["chapters/a.tex", "main.tex", "paper.tex", "refs.bib"];
        assert_eq!(files_in(&service.data_dir.join("Paper")), files);

        // Any other file comes alone; without TeX, the blank template's main
        // file joins it.
        let info = import_project(&service, &src.join("refs.bib")).unwrap();
        assert_eq!(info.main_file, "main.tex");
        let files = ["main.tex", "refs.bib"];
        assert_eq!(files_in(&service.data_dir.join("refs")), files);
    }

    #[test]
    fn a_tex_in_a_folder_larger_than_a_project_comes_alone() {
        let (dir, service) = library();
        let downloads = dir.path().join("Downloads");
        fs::create_dir_all(&downloads).unwrap();
        fs::write(downloads.join("notes.tex"), "\\documentclass{article}").unwrap();
        // Sparse: past one upload's bytes without writing them.
        let big = File::create(downloads.join("big.dmg")).unwrap();
        big.set_len(UPLOAD_MAX_BYTES + 1).unwrap();
        let info = import_project(&service, &downloads.join("notes.tex")).unwrap();
        assert_eq!([info.id, info.main_file], ["notes", "notes.tex"]);
        assert_eq!(files_in(&service.data_dir.join("notes")), ["notes.tex"]);

        // As is more than 2000 files.
        fs::remove_file(downloads.join("big.dmg")).unwrap();
        for i in 0..2000 {
            fs::write(downloads.join(format!("{i}.txt")), "").unwrap();
        }
        let info = import_project(&service, &downloads.join("notes.tex")).unwrap();
        assert_eq!(files_in(&service.data_dir.join(&info.id)), ["notes.tex"]);
    }

    #[test]
    fn excluded_build_output_does_not_count_towards_the_tex_folder_limit() {
        let (dir, service) = library();
        let src = dir.path().join("Paper");
        fs::create_dir_all(src.join("Build")).unwrap();
        fs::write(src.join("main.tex"), "\\input{chapter}").unwrap();
        fs::write(src.join("chapter.tex"), "\\section{Chapter}").unwrap();
        let pdf = File::create(src.join("Build/main.pdf")).unwrap();
        pdf.set_len(UPLOAD_MAX_BYTES + 1).unwrap();
        let info = import_project(&service, &src.join("main.tex")).unwrap();
        let files = ["chapter.tex", "main.tex"];
        assert_eq!(files_in(&service.data_dir.join(&info.id)), files);
    }

    #[test]
    fn a_failed_import_leaves_no_half_made_project() {
        let (dir, service) = library();
        // A zip whose second file's bytes no longer match its checksum.
        let src = dir.path().join("broken.zip");
        let files = [("a.tex", "fine"), ("b.tex", "CORRUPTED-LATER")];
        zip_with(&src, &files, zip::CompressionMethod::Stored);
        let mut bytes = fs::read(&src).unwrap();
        let at = bytes.windows(15).position(|w| w == b"CORRUPTED-LATER");
        bytes[at.unwrap()] = b'X';
        fs::write(&src, bytes).unwrap();
        assert!(import_project(&service, &src).is_err());
        assert_eq!(projects(&service), 0);

        // A folder holding a file that can't be read.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let src = dir.path().join("Locked");
            fs::create_dir_all(&src).unwrap();
            fs::write(src.join("a.tex"), "fine").unwrap();
            fs::write(src.join("b.tex"), "unreadable").unwrap();
            fs::set_permissions(src.join("b.tex"), fs::Permissions::from_mode(0o000)).unwrap();
            let err = import_project(&service, &src).unwrap_err();
            assert_eq!(projects(&service), 0);
            // Not a bug of the core's, and it says which file.
            if File::open(src.join("b.tex")).is_err() {
                assert_eq!(err.status, 403, "{}", err.message);
                assert!(err.message.contains("b.tex"), "{}", err.message);
            }
        }
    }

    #[test]
    fn what_cannot_be_opened_is_named_and_says_why() {
        let (dir, service) = library();
        let err = import_project(&service, &dir.path().join("gone.zip")).unwrap_err();
        assert_eq!(err.status, 404);
        assert!(err.message.contains("gone.zip"), "{}", err.message);
        assert!(!err.message.contains("os error"), "{}", err.message);

        // A file that is no zip is the file's fault.
        let src = dir.path().join("not.zip");
        fs::write(&src, "plain text").unwrap();
        let err = import_project(&service, &src).unwrap_err();
        assert_eq!(err.status, 400);
        assert!(err.message.contains("not.zip"), "{}", err.message);
        assert_eq!(projects(&service), 0);
    }

    #[test]
    fn zip_entries_named_from_the_current_folder_or_with_backslashes_arrive() {
        let (dir, service) = library();
        let dotted = dir.path().join("dotted.zip");
        let windows = dir.path().join("windows.zip");
        for (src, files) in [
            (&dotted, ["./main.tex", "./figs/a.png"]),
            (&windows, ["paper\\main.tex", "paper\\figs\\a.png"]),
        ] {
            zip_of(src, &files.map(|path| (path, "\\documentclass{article}")));
            let info = import_project(&service, src).unwrap();
            assert_eq!(info.main_file, "main.tex");
            let root = service.data_dir.join(&info.id);
            assert_eq!(files_in(&root), ["figs/a.png", "main.tex"]);
        }
    }

    #[test]
    fn dropped_files_and_folders_import_into_the_project() {
        let (dir, service) = with_project();
        let drop = dir.path().join("drop");
        fs::create_dir_all(drop.join("figs/sub")).unwrap();
        fs::write(drop.join("figs/a.png"), b"a").unwrap();
        fs::write(drop.join("figs/sub/b.png"), b"b").unwrap();
        fs::write(drop.join("notes.tex"), b"n").unwrap();

        let paths = [drop.join("figs"), drop.join("notes.tex")];
        let out = import_files(&service, "P", "in", &paths, None).unwrap();
        let files = ["in/figs/a.png", "in/figs/sub/b.png", "in/notes.tex"];
        assert_eq!(saved(&out), files);
        let root = service.data_dir.join("P");
        assert_eq!(fs::read(root.join("in/figs/sub/b.png")).unwrap(), b"b");

        // A batch that would collide fails before anything is written.
        let twice = [drop.join("notes.tex"), drop.join("notes.tex")];
        let refused = import_files(&service, "P", "again", &twice, None);
        assert_eq!(refused.unwrap_err().status, 400);
        assert!(!root.join("again").exists());

        // A path that isn't there is named.
        let gone = [drop.join("gone.png")];
        let err = import_files(&service, "P", "", &gone, None).unwrap_err();
        assert_eq!(err.status, 404);
        assert!(err.message.contains("gone.png"), "{}", err.message);
    }

    #[test]
    fn a_drop_onto_existing_files_asks_first_and_can_keep_both_and_a_dropped_link_is_followed() {
        let (dir, service) = with_project();
        let drop = dir.path().join("drop");
        fs::create_dir_all(drop.join("figs/.git")).unwrap();
        fs::write(drop.join("figs/.git/HEAD"), b"ref").unwrap();
        fs::write(drop.join("figs/.DS_Store"), b"x").unwrap();
        fs::write(drop.join("figs/a.png"), b"a").unwrap();
        fs::write(drop.join("main.tex"), b"new").unwrap();
        let paths = [drop.join("figs"), drop.join("main.tex")];

        // Without an answer nothing is written; the clash is reported.
        let asked = import_files(&service, "P", "", &paths, None).unwrap();
        assert_eq!(
            serde_json::to_value(&asked).unwrap(),
            json!({ "saved": [], "existing": [{ "path": "main.tex", "keepBoth": "main 2.tex" }] })
        );
        let root = service.data_dir.join("P");
        let original = fs::read(root.join("main.tex")).unwrap();

        let kept = import_files(&service, "P", "", &paths, Some(Conflict::KeepBoth)).unwrap();
        // Litter inside a dropped folder stays behind.
        assert_eq!(saved(&kept), ["figs/a.png", "main 2.tex"]);
        assert_eq!(fs::read(root.join("main.tex")).unwrap(), original);
        assert_eq!(fs::read(root.join("main 2.tex")).unwrap(), b"new");

        // A dropped link names what it points at; links inside a folder are left.
        #[cfg(unix)]
        {
            let elsewhere = dir.path().join("elsewhere");
            fs::create_dir_all(&elsewhere).unwrap();
            fs::write(elsewhere.join("plot.png"), b"p").unwrap();
            let drop = dir.path().join("linked-drop");
            fs::create_dir_all(drop.join("pics")).unwrap();
            let plot = elsewhere.join("plot.png");
            std::os::unix::fs::symlink(&plot, drop.join("plot-link.png")).unwrap();
            std::os::unix::fs::symlink(&plot, drop.join("pics/inner.png")).unwrap();
            fs::write(drop.join("pics/real.png"), b"r").unwrap();
            let paths = [drop.join("plot-link.png"), drop.join("pics")];
            let out = import_files(&service, "P", "", &paths, None).unwrap();
            assert_eq!(saved(&out), ["pics/real.png", "plot-link.png"]);
            assert_eq!(fs::read(root.join("plot-link.png")).unwrap(), b"p");
        }
    }
}
