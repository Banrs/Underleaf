//! Bringing outside files into the library: a Finder drop onto a project,
//! and File › Open of a folder, a .zip or a .tex made a new project. Both read
//! host-chosen absolute paths and block on the disk; hosts call them off
//! their UI thread, as they do every `tl_call`.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::json;
use zip::ZipArchive;

use crate::paths::{self, fold_case, normalize_segments, rel_key, sanitize_name};
use crate::projects::{self, ProjectInfo};
use crate::service::Service;
use crate::settings::write_settings;
use crate::{BUILD_DIR, CoreError, atomic, templates};

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

/// The largest file an import takes.
const UPLOAD_MAX_BYTES: u64 = 100 * 1024 * 1024;

fn too_large() -> CoreError {
    CoreError::bad_request(format!(
        "File exceeds the {} MB upload limit",
        UPLOAD_MAX_BYTES / 1024 / 1024
    ))
}

/// A file to bring: its project-relative path, and its size as found.
struct Incoming {
    path: String,
    size: u64,
}

impl Incoming {
    fn new(path: String, size: u64) -> Self {
        Self { path, size }
    }
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
    bytes: UPLOAD_MAX_BYTES,
};

impl Allowance {
    fn file(&mut self, size: u64) -> Result<(), CoreError> {
        spend(&mut self.files, 1, TOO_MANY)?;
        spend(&mut self.bytes, size, TOO_BIG)
    }

    /// Copy `source` to `sink`, taking the bytes actually read, and never
    /// more than one upload's.
    fn copy(&mut self, source: impl Read, sink: &mut impl Write) -> Result<(), CoreError> {
        let cap = self.bytes.min(UPLOAD_MAX_BYTES);
        let copied = io::copy(&mut source.take(cap + 1), sink)?;
        if copied > UPLOAD_MAX_BYTES {
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
    meta: &fs::Metadata,
    files: &mut Vec<(Incoming, PathBuf)>,
    allowance: &mut Allowance,
) -> Result<(), CoreError> {
    if meta.is_file() {
        allowance.file(meta.len())?;
        files.push((Incoming::new(rel, meta.len()), abs.to_path_buf()));
    } else if meta.is_dir() {
        for entry in fs::read_dir(abs)? {
            spend(&mut allowance.entries, 1, TOO_MANY)?;
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !hidden(&name) && !(rel.is_empty() && name.eq_ignore_ascii_case(BUILD_DIR)) {
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
        collect(abs, name.into_owned(), &meta, &mut files, &mut found)?;
    }
    let (incoming, sources): (Vec<_>, Vec<_>) = files.into_iter().unzip();
    let existing = clashes(&service.project_root(id)?, dir, &incoming)?;
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported {
            saved: Vec::new(),
            existing,
        });
    }
    let replace = conflict == Some(Conflict::Replace);
    let mut saved = Vec::new();
    for (file, source) in incoming.into_iter().zip(sources) {
        let path = if conflict == Some(Conflict::KeepBoth) {
            keep_both(&file.path, &existing)
        } else {
            file.path
        };
        let rel = in_folder(dir, &path);
        save(service, id, &rel, &source, replace, &mut allowance)?;
        saved.push(rel);
    }
    Ok(Imported { saved, existing })
}

/// `name` in the project folder `dir` ("" is the project's own).
fn in_folder(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    }
}

/// Checks the whole batch before anything is written, so a late unsafe or
/// oversize entry cannot cause a predictable partial import. Returns the
/// entries it would land on, with free Keep Both names, for the host's
/// Replace, Keep Both or Stop choice.
fn clashes(root: &Path, dir: &str, files: &[Incoming]) -> Result<Vec<Clash>, CoreError> {
    let base = root.join(paths::rel_key(dir).unwrap_or_default());
    let mut seen = HashSet::new();
    let mut folders = HashSet::new();
    let mut rels = Vec::new();
    for file in files {
        if file.size > UPLOAD_MAX_BYTES {
            return Err(too_large());
        }
        paths::safe_write_path(root, &in_folder(dir, &file.path))?;
        // Relative to `dir`, as the host names the files.
        let rel = paths::rel_key(&file.path)?;
        let key = fold_case(&rel);
        if seen.contains(&key) {
            return Err(CoreError::bad_request(
                "The upload contains duplicate paths",
            ));
        }
        if folders.contains(&key)
            || key
                .match_indices('/')
                .any(|(i, _)| seen.contains(&key[..i]))
        {
            return Err(CoreError::bad_request(
                "The upload contains conflicting paths",
            ));
        }
        folders.extend(key.match_indices('/').map(|(i, _)| key[..i].to_string()));
        seen.insert(key);
        rels.push(rel);
    }
    // Names a Keep Both may not take: every path the import creates.
    seen.extend(folders);
    let mut taken = seen;
    let mut existing: Vec<Clash> = Vec::new();
    for rel in &rels {
        let Some(path) = occupant(&base, rel) else {
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
    Ok(existing)
}

/// A file's path once Keep Both has renamed the clash it lies under.
fn keep_both(path: &str, clashes: &[Clash]) -> String {
    clashes
        .iter()
        .find(|c| paths::within(path, &c.path))
        .map_or_else(
            || path.to_string(),
            |c| format!("{}{}", c.keep_both, &path[c.path.len()..]),
        )
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
/// whole. An occupied path conflicts unless `replace` first moves it to the
/// Trash.
fn save(
    service: &Service,
    id: &str,
    rel: &str,
    source: &Path,
    replace: bool,
    allowance: &mut Allowance,
) -> Result<(), CoreError> {
    let root = service.project_root(id)?;
    // In the target's folder, or the nearest on its way while that is to be made, so the
    // rename stays on one volume; any name there, as the temporary file is made beside it.
    let abs = paths::safe_write_path(&root, rel)?;
    let folder = abs.ancestors().skip(1).find(|dir| dir.is_dir());
    let (temp, mut file) = atomic::create_temp(&folder.unwrap_or(&root).join("incoming"), None)?;
    allowance.copy(File::open(source)?, &mut file)?;
    file.sync_all()?;
    drop(file);
    service.with_project(id, |root| {
        let abs = paths::safe_write_path(root, rel)?;
        if let Some(taken) = occupant(root, &rel_key(rel)?) {
            if !replace {
                return Err(CoreError::conflict(format!("“{taken}” already exists")));
            }
            projects::discard_replaced(root, &taken)?;
        }
        if let Some(parent) = abs.parent() {
            fs::create_dir_all(parent)?;
        }
        Ok(atomic::persist(temp, &abs)?)
    })
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
) -> Result<Vec<(Incoming, Source)>, CoreError> {
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
            let spec = Incoming::new(segments.join("/"), entry.size());
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
) -> Result<Vec<(Incoming, Source)>, CoreError> {
    let meta = fs::metadata(dir)?;
    let mut found = Vec::new();
    collect(dir, String::new(), &meta, &mut found, &mut allowance)?;
    Ok(found
        .into_iter()
        .map(|(s, p)| (s, Source::File(p)))
        .collect())
}

/// File › Open: a folder, a .zip or a single file from anywhere, copied into
/// a new project named after it ("Name 2" when that is taken). A .tex brings its folder,
/// for what it inputs, includes and cites, unless that folder can't be read, is larger
/// than a project (more than 2000 files or one upload's bytes) or has no name a project
/// can take: then the .tex comes alone. Only visible files come, and a top-level `build`
/// stays behind. The main file is the chosen .tex, else the likeliest top-level one, else
/// the blank template's main.tex.
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
        let spec = Incoming::new(named(src.file_name()), meta.len());
        let found = vec![(spec, Source::File(src.into()))];
        (named(src.file_stem()), None, found)
    };
    files.retain(|(spec, _)| {
        let top = spec.path.split('/').next().unwrap_or_default();
        !top.eq_ignore_ascii_case(BUILD_DIR)
    });

    // Made in a hidden folder beside the projects, which no listing or scan
    // shows, then moved into place whole: a failure or panic, which drops
    // the folder, leaves no project behind, and a crash a hidden folder only,
    // which a later import sweeps away.
    fs::create_dir_all(&service.data_dir)?;
    sweep_staging(&service.data_dir);
    let mut staging = tempfile::Builder::new();
    staging.prefix(STAGING);
    // A new folder's usual mode, not tempfile's private one.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        staging.permissions(fs::Permissions::from_mode(0o777));
    }
    let staging = staging.tempdir_in(&service.data_dir)?;
    let staged = staging.path();
    let (specs, sources): (Vec<_>, Vec<_>) = files.into_iter().unzip();
    clashes(staged, "", &specs)?;
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

const STAGING: &str = ".texlocal-import-";

/// Removes the staging folders that crashed imports left behind. A folder
/// untouched for a day is no running import's, whose allowance is minutes of
/// writing.
fn sweep_staging(data_dir: &Path) {
    const STALE: Duration = Duration::from_secs(24 * 60 * 60);
    for entry in fs::read_dir(data_dir).into_iter().flatten().flatten() {
        let age = entry.metadata().and_then(|meta| meta.modified()).ok();
        if entry.file_name().to_string_lossy().starts_with(STAGING)
            && age.and_then(|time| time.elapsed().ok()) > Some(STALE)
        {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
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

    /// A zip of `files`, deflated as most are.
    fn zip_of(path: &Path, files: &[(&str, &str)]) {
        zip_with(path, files, zip::CompressionMethod::Deflated);
    }

    /// A zip of `files` written with `method`: stored, a test can find and change their bytes.
    fn zip_with(path: &Path, files: &[(&str, &str)], method: zip::CompressionMethod) {
        let mut zip = zip::ZipWriter::new(File::create(path).unwrap());
        let options = zip::write::SimpleFileOptions::default().compression_method(method);
        for (name, text) in files {
            zip.start_file(*name, options).unwrap();
            zip.write_all(text.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
    }

    fn projects(service: &Service) -> usize {
        fs::read_dir(&service.data_dir).unwrap().count()
    }

    /// A library with one blank project, "P".
    fn with_project() -> (tempfile::TempDir, Service) {
        let (dir, service) = library();
        projects::create_project(&service.data_dir, "P", "blank").unwrap();
        (dir, service)
    }

    /// A project's files, by path.
    fn files_in(root: &Path) -> Vec<String> {
        fn walk(nodes: Vec<projects::TreeNode>, out: &mut Vec<String>) {
            for node in nodes {
                match node.children {
                    Some(children) => walk(children, out),
                    None => out.push(node.path),
                }
            }
        }
        let mut out = Vec::new();
        walk(projects::file_tree(root).unwrap(), &mut out);
        out.sort();
        out
    }

    fn saved(imported: &Imported) -> Vec<String> {
        let mut saved = imported.saved.clone();
        saved.sort();
        saved
    }

    fn incoming(path: &str, size: u64) -> Incoming {
        Incoming::new(path.into(), size)
    }

    /// Saves `bytes` as the file `rel` of project "P".
    fn put(service: &Service, rel: &str, bytes: &[u8], replace: bool) -> Result<(), CoreError> {
        let source = tempfile::NamedTempFile::new().unwrap();
        fs::write(source.path(), bytes).unwrap();
        save(service, "P", rel, source.path(), replace, &mut { IMPORT })
    }

    #[test]
    fn files_are_validated_as_a_batch_before_any_write() {
        let (_dir, service) = with_project();
        let root = service.project_root("P").unwrap();

        assert!(clashes(&root, "img", &[incoming("a.png", 1), incoming("b.png", 1)]).is_ok());
        for batch in [
            [incoming("a.png", 1), incoming("a.png", 1)],
            [incoming("notes", 1), incoming("notes/ch.tex", 1)],
            [incoming("notes/ch.tex", 1), incoming("notes", 1)],
            [
                incoming("a.png", 1),
                incoming("b.png", UPLOAD_MAX_BYTES + 1),
            ],
            [incoming("a.png", 1), incoming("../x.png", 1)],
        ] {
            assert_eq!(clashes(&root, "", &batch).unwrap_err().status, 400);
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
            incoming("main.tex", 1),
            incoming("figs/a.png", 1),
            incoming("figs/b.png", 1),
            incoming("notes/x.tex", 1),
            incoming("notes/y.tex", 1),
            // Keep Both must not pick a name the import itself brings.
            incoming("main 2.tex", 1),
        ];
        let existing = clashes(&root, "", &batch).unwrap();
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
    #[ignore = "leaves a file in the user's Trash"]
    fn a_replaced_file_goes_to_the_trash_without_asking_finder() {
        let (_dir, service) = with_project();
        let rel = "replaced by import.txt";
        let file = service.project_root("P").unwrap().join(rel);
        fs::write(&file, "old").unwrap();
        put(&service, rel, b"new", true).unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"new");
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_a_folder_in_the_project_is_a_folder_a_file_goes_into() {
        let (_dir, service) = with_project();
        let root = service.project_root("P").unwrap();
        fs::create_dir(root.join("figs")).unwrap();
        std::os::unix::fs::symlink(root.join("figs"), root.join("link")).unwrap();
        let found = clashes(&root, "", &[incoming("link/a.png", 1)]).unwrap();
        assert!(found.is_empty());
        put(&service, "link/a.png", b"png", false).unwrap();
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"png");
    }

    #[test]
    fn an_import_sweeps_away_only_a_staging_folder_a_day_old() {
        let (dir, service) = library();
        let staged = |name: &str, age: u64| {
            let folder = service.data_dir.join(name);
            fs::create_dir_all(folder.join("sub")).unwrap();
            fs::write(folder.join("sub/main.tex"), "x").unwrap();
            let when = std::time::SystemTime::now() - Duration::from_secs(age);
            // Windows opens a folder only for its backup semantics, and to
            // date it, for its attributes.
            #[cfg(windows)]
            let handle = {
                use std::os::windows::fs::OpenOptionsExt;
                fs::OpenOptions::new()
                    .access_mode(0x100)
                    .custom_flags(0x0200_0000)
                    .open(&folder)
            };
            #[cfg(not(windows))]
            let handle = File::open(&folder);
            handle.unwrap().set_modified(when).unwrap();
            folder
        };
        let crashed = staged(".texlocal-import-crashed", 25 * 60 * 60);
        let running = staged(".texlocal-import-running", 23 * 60 * 60);
        let other = staged(".hidden", 25 * 60 * 60);
        let src = dir.path().join("paper.zip");
        zip_of(&src, &[("main.tex", "x")]);

        import_project(&service, &src).unwrap();
        assert!(!crashed.exists());
        assert!(running.exists() && other.exists());
        assert!(service.data_dir.join("paper/main.tex").exists());
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
    fn a_folder_past_the_file_or_entry_limit_makes_no_project_and_its_drop_writes_nothing() {
        let (dir, service) = with_project();
        let src = dir.path().join("Many");
        fs::create_dir_all(&src).unwrap();
        for name in ["a.tex", "b.tex", "c.tex", "d.tex"] {
            fs::write(src.join(name), "x").unwrap();
        }
        let err = import_project_within(&service, &src, SMALL).unwrap_err();
        assert_eq!(err.status, 400);
        let drop = [src];
        assert!(import_files_within(&service, "P", "", &drop, None, SMALL).is_err());
        assert!(!service.data_dir.join("P/Many").exists());
        // Empty folders cost a walk too.
        let src = dir.path().join("Hollow");
        for i in 0..10 {
            fs::create_dir_all(src.join(format!("d{i}"))).unwrap();
        }
        fs::write(src.join("main.tex"), "x").unwrap();
        assert!(import_project_within(&service, &src, SMALL).is_err());
        assert_eq!(projects(&service), 1);
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
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&root), mode(&service.data_dir));
        }
        assert_eq!(files_in(&root), ["a/b.tex", "a/d.tex", "main.tex"]);
    }

    #[test]
    fn a_folder_brings_its_visible_files_and_its_name() {
        // Into a library folder that doesn't exist yet, as on a first import.
        let dir = tempfile::tempdir().unwrap();
        let service = Service::new(dir.path().join("data"));
        let src = dir.path().join("Thesis");
        for (path, text) in [
            ("main.tex", "\\documentclass{book}"),
            ("figs/a.png", "png"),
            ("figs/.DS_Store", "x"),
            (".git/HEAD", "ref"),
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
            ("__MACOSX/paper/._doc.tex", "fork"),
        ];
        zip_of(&src, &files);

        let info = import_project(&service, &src).unwrap();
        // No main.tex: the first file that starts a document.
        assert_eq!([info.id, info.main_file], ["paper", "doc.tex"]);
        let root = service.data_dir.join("paper");
        assert_eq!(files_in(&root), ["aaa.tex", "doc.tex", "figs/b.png"]);
        assert_eq!(fs::read_to_string(root.join("figs/b.png")).unwrap(), "png");
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
            assert!(import_project(&service, &src).is_err());
            assert_eq!(projects(&service), 0);
        }
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
        // Hidden files inside a dropped folder stay behind.
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
