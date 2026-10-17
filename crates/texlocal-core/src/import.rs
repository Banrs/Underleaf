//! Bringing outside files into the library: a Finder drop onto a project,
//! and File › Open of a folder, a .zip or a .tex made a new project. Both read
//! host-chosen absolute paths and block on the disk; hosts call them off
//! their UI thread, as they do every `tl_call`.

use std::collections::HashSet;
use std::ffi::OsStr;
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
const TOO_MANY: &str = "There are too many files to import.";
const TOO_BIG: &str = "The files to import are too large.";

/// A file to bring: its path relative to where it lands, and where it is read.
struct Incoming {
    path: String,
    from: Source,
}

enum Source {
    File(PathBuf),
    /// An entry of the chosen zip, by index.
    Zip(usize),
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
    /// Takes `files` files and `bytes` bytes, these one file's: no more than an upload's.
    fn take(&mut self, files: u64, bytes: u64) -> Result<(), CoreError> {
        if bytes > UPLOAD_MAX_BYTES {
            let mb = UPLOAD_MAX_BYTES >> 20;
            return Err(CoreError::bad_request(format!(
                "File exceeds the {mb} MB upload limit"
            )));
        }
        let files = self.files.checked_sub(files);
        self.files = files.ok_or_else(|| CoreError::bad_request(TOO_MANY))?;
        let bytes = self.bytes.checked_sub(bytes);
        self.bytes = bytes.ok_or_else(|| CoreError::bad_request(TOO_BIG))?;
        Ok(())
    }

    /// Takes `entries` entries looked at.
    fn look(&mut self, entries: u64) -> Result<(), CoreError> {
        let left = self.entries.checked_sub(entries);
        self.entries = left.ok_or_else(|| CoreError::bad_request(TOO_MANY))?;
        Ok(())
    }

    /// Copy `from` to `sink`, taking the bytes actually read, and never more
    /// than one upload's.
    fn copy(
        &mut self,
        from: &Source,
        zip: Option<&mut ZipArchive<File>>,
        sink: &mut impl Write,
    ) -> Result<(), CoreError> {
        let source: Box<dyn Read> = match from {
            Source::File(path) => Box::new(File::open(path)?),
            Source::Zip(i) => Box::new(zip.expect("a zip source").by_index(*i)?),
        };
        let copied = io::copy(&mut source.take(self.bytes.min(UPLOAD_MAX_BYTES) + 1), sink)?;
        self.take(0, copied)
    }
}

/// Dotfiles (.git, .DS_Store) and the resource forks of a Mac-made zip: the
/// project walks hide them, so an import that brought them would bring files
/// nobody sees.
fn hidden(name: &str) -> bool {
    name.starts_with('.') || name == "__MACOSX"
}

/// The files at `abs`, a file or a folder, named from `rel` (a folder's
/// files from "" without its name), failing once `allowance` runs out.
/// Inside a folder, hidden entries and a top-level `build` stay behind and
/// links are skipped, not followed: a drop imports what was dropped, never
/// what a link inside it points at.
fn collect(
    abs: &Path,
    rel: String,
    meta: &fs::Metadata,
    allowance: &mut Allowance,
) -> Result<Vec<Incoming>, CoreError> {
    if meta.is_file() {
        allowance.take(1, meta.len())?;
        let from = Source::File(abs.to_path_buf());
        return Ok(vec![Incoming { path: rel, from }]);
    }
    let mut files = Vec::new();
    if !meta.is_dir() {
        return Ok(files);
    }
    for entry in fs::read_dir(abs)? {
        allowance.look(1)?;
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !hidden(&name) && !(rel.is_empty() && name.eq_ignore_ascii_case(BUILD_DIR)) {
            // DirEntry::metadata does not follow links.
            let (abs, rel) = (entry.path(), in_folder(&rel, &name));
            files.extend(collect(&abs, rel, &entry.metadata()?, allowance)?);
        }
    }
    Ok(files)
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
    let (mut files, mut found) = (Vec::new(), IMPORT);
    for abs in paths {
        let name = abs.file_name().unwrap_or_default().to_string_lossy();
        // A dropped link is followed: dropping it names what it points at.
        files.extend(collect(abs, name.into(), &fs::metadata(abs)?, &mut found)?);
    }
    let existing = clashes(&service.project_root(id)?, dir, &files)?;
    let mut saved = Vec::new();
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported { saved, existing });
    }
    let mut allowance = IMPORT;
    for file in files {
        let path = match conflict {
            Some(Conflict::KeepBoth) => keep_both(&file.path, &existing),
            _ => file.path,
        };
        let rel = in_folder(dir, &path);
        let replace = conflict == Some(Conflict::Replace);
        save(service, id, &rel, &file.from, replace, &mut allowance)?;
        saved.push(rel);
    }
    Ok(Imported { saved, existing })
}

/// `name` in the project folder `dir` ("" is the project's own).
fn in_folder(dir: &str, name: &str) -> String {
    match dir.trim_end_matches('/') {
        "" => name.to_string(),
        dir => format!("{dir}/{name}"),
    }
}

/// Checks the whole batch before anything is written, so a late unsafe entry
/// cannot cause a predictable partial import. Returns the entries it would
/// land on, with free Keep Both names, for the host's Replace, Keep Both or
/// Stop choice.
fn clashes(root: &Path, dir: &str, files: &[Incoming]) -> Result<Vec<Clash>, CoreError> {
    let bad = |message| Err(CoreError::bad_request(message));
    // Paths relative to `dir`, as the host names the files, and as the
    // volume compares them.
    let (mut rels, mut taken) = (Vec::new(), HashSet::new());
    for file in files {
        paths::safe_write_path(root, &in_folder(dir, &file.path))?;
        let rel = rel_key(&file.path)?;
        if !taken.insert(fold_case(&rel)) {
            return bad("The upload contains duplicate paths");
        }
        rels.push(rel);
    }
    // No file may lie where another's folder is; Keep Both may not take any
    // name the import makes.
    let mut folders = Vec::new();
    for key in rels.iter().map(|rel| fold_case(rel)) {
        for (i, _) in key.match_indices('/') {
            if taken.contains(&key[..i]) {
                return bad("The upload contains conflicting paths");
            }
            folders.push(key[..i].to_owned());
        }
    }
    taken.extend(folders);
    let base = root.join(rel_key(dir).unwrap_or_default());
    let mut existing: Vec<Clash> = Vec::new();
    for path in rels.iter().filter_map(|rel| occupant(&base, rel)) {
        if existing.iter().all(|c| c.path != path) {
            let mut copies = projects::copy_paths(&path).skip(1);
            let free = |copy: &String| {
                fs::symlink_metadata(base.join(copy)).is_err() && taken.insert(fold_case(copy))
            };
            let keep_both = copies.find(free).expect("a free name");
            existing.push(Clash { path, keep_both });
        }
    }
    Ok(existing)
}

/// A file's path once Keep Both has renamed the clash it lies under.
fn keep_both(path: &str, clashes: &[Clash]) -> String {
    match clashes.iter().find(|c| paths::within(path, &c.path)) {
        Some(c) => format!("{}{}", c.keep_both, &path[c.path.len()..]),
        None => path.to_string(),
    }
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

/// Write the file `from` to the project path `rel`. It is copied to a
/// temporary file beside the target first, so a source that fails or
/// outgrows the allowance part-way replaces nothing, then renamed into place
/// whole. An occupied path conflicts unless `replace` first moves it to the
/// Trash.
fn save(
    service: &Service,
    id: &str,
    rel: &str,
    from: &Source,
    replace: bool,
    allowance: &mut Allowance,
) -> Result<(), CoreError> {
    let root = service.project_root(id)?;
    // In the target's folder, or the nearest on its way while that is to be made, so the
    // rename stays on one volume; any name there, as the temporary file is made beside it.
    let abs = paths::safe_write_path(&root, rel)?;
    let folder = abs.ancestors().skip(1).find(|dir| dir.is_dir());
    let (temp, mut file) = atomic::create_temp(&folder.unwrap_or(&root).join("incoming"), None)?;
    allowance.copy(from, None, &mut file)?;
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

/// A zip's visible files; the contents of its one top folder if it has one,
/// as a zipped project folder unpacks.
fn zip_files(
    zip: &mut ZipArchive<File>,
    mut allowance: Allowance,
) -> Result<Vec<Incoming>, CoreError> {
    allowance.look(zip.len() as u64)?;
    let mut files = Vec::new();
    for i in 0..zip.len() {
        // Its name and size only: nothing is decompressed yet.
        let entry = zip.by_index_raw(i)?;
        // No folders, links or NULs, and no name that would leave the project,
        // read as a project path is ("./a" is "a"); a backslash separates, as
        // Windows tools have written it where the format allows only '/'.
        let name = entry.name().replace('\\', "/");
        let segments = match normalize_segments(&name, "") {
            Ok(s) if entry.is_file() && !s.is_empty() && !name.contains('\0') => s,
            _ => continue,
        };
        if !segments.iter().any(|s| hidden(s)) {
            allowance.take(1, entry.size())?;
            let (path, from) = (segments.join("/"), Source::Zip(i));
            files.push(Incoming { path, from });
        }
    }
    let top = files
        .first()
        .and_then(|f| Some(format!("{}/", f.path.split_once('/')?.0)));
    if let Some(top) = top.filter(|top| files.iter().all(|f| f.path.starts_with(top))) {
        files
            .iter_mut()
            .for_each(|f| drop(f.path.drain(..top.len())));
    }
    Ok(files)
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
    let named = |name: Option<&OsStr>| name.unwrap_or_default().to_string_lossy().into_owned();
    let ext = named(src.extension()).to_lowercase();
    let tex = (!meta.is_dir() && ext == "tex").then(|| named(src.file_name()));
    let folder = if meta.is_dir() {
        Some((src, collect(src, String::new(), &meta, &mut { allowance })?))
    } else {
        src.parent().zip(tex.as_ref()).and_then(|(dir, tex)| {
            let found = collect(dir, String::new(), &fs::metadata(dir).ok()?, &mut {
                TEX_FOLDER
            });
            let files = found
                .ok()
                .filter(|files| files.iter().any(|f| &f.path == tex))?;
            sanitize_name(&named(dir.file_name()))
                .ok()
                .map(|_| (dir, files))
        })
    };
    let (base, mut zip, mut files) = if let Some((dir, files)) = folder {
        (named(dir.file_name()), None, files)
    } else if ext == "zip" {
        let mut zip = ZipArchive::new(File::open(src)?)?;
        let files = zip_files(&mut zip, allowance)?;
        (named(src.file_stem()), Some(zip), files)
    } else {
        let files = collect(src, named(src.file_name()), &meta, &mut { allowance })?;
        (named(src.file_stem()), None, files)
    };
    files.retain(|f| {
        !f.path
            .split('/')
            .next()
            .unwrap_or_default()
            .eq_ignore_ascii_case(BUILD_DIR)
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
    staging.permissions(std::os::unix::fs::PermissionsExt::from_mode(0o777));
    let staging = staging.tempdir_in(&service.data_dir)?;
    let staged = staging.path();
    clashes(staged, "", &files)?;
    for file in &files {
        // The folder holds only what the import wrote, so there is no clash
        // or file to replace: each is written in place, with no temporary
        // file or sync of its own, and gets a new file's usual mode.
        let abs = staged.join(rel_key(&file.path)?);
        fs::create_dir_all(abs.parent().unwrap_or(staged))?;
        let mut dest = BufWriter::new(File::create_new(abs)?);
        allowance.copy(&file.from, zip.as_mut(), &mut dest)?;
        dest.flush()?;
    }
    let main = if tex.is_some() {
        tex
    } else {
        projects::guess_main_file(staged)?
    };
    let main = main.map_or_else(
        || {
            let (file, content) = templates::files("blank")[0];
            fs::write(staged.join(file), content).map(|()| file.to_string())
        },
        Ok,
    )?;
    write_settings(staged, &json!({ "mainFile": main }))?;
    // The name is held by an empty folder, which the project takes the
    // place of in one rename.
    let (id, root) = projects::new_project_dir(&service.data_dir, &base)?;
    if let Err(err) = fs::rename(staged, &root) {
        let _ = fs::remove_dir(&root);
        return Err(err.into());
    }
    Ok(projects::project_info(id, &root, &fs::metadata(&root)?))
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

    /// A library with one blank project, "P", and its folder.
    fn with_project() -> (tempfile::TempDir, Service, PathBuf) {
        let (dir, service) = library();
        projects::create_project(&service.data_dir, "P", "blank").unwrap();
        let root = service.project_root("P").unwrap();
        (dir, service, root)
    }

    /// A zip of `files`, deflated, or stored for a test to find their bytes.
    fn zip_of(path: &Path, files: &[(&str, &str)], stored: bool) {
        use zip::CompressionMethod::{Deflated, Stored};
        let mut zip = zip::ZipWriter::new(File::create(path).unwrap());
        let method = if stored { Stored } else { Deflated };
        let options = zip::write::SimpleFileOptions::default().compression_method(method);
        for (name, text) in files {
            zip.start_file(*name, options).unwrap();
            zip.write_all(text.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
    }

    /// Writes `files` under `dir`.
    fn folder(dir: &Path, files: &[(&str, &str)]) {
        for (path, text) in files {
            fs::create_dir_all(dir.join(path).parent().unwrap()).unwrap();
            fs::write(dir.join(path), text).unwrap();
        }
    }

    fn projects(service: &Service) -> usize {
        fs::read_dir(&service.data_dir).unwrap().count()
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

    fn sorted(imported: Imported) -> Vec<String> {
        let mut saved = imported.saved;
        saved.sort();
        saved
    }

    fn incoming(paths: &[&str]) -> Vec<Incoming> {
        let file = |path: &&str| Incoming {
            path: path.to_string(),
            from: Source::Zip(0),
        };
        paths.iter().map(file).collect()
    }

    /// Saves `bytes` as the file `rel` of project "P".
    fn put(service: &Service, rel: &str, bytes: &[u8], replace: bool) -> Result<(), CoreError> {
        let source = tempfile::NamedTempFile::new().unwrap();
        fs::write(source.path(), bytes).unwrap();
        let from = Source::File(source.path().into());
        save(service, "P", rel, &from, replace, &mut { IMPORT })
    }

    #[test]
    fn a_batch_is_checked_whole_and_reports_what_it_would_land_on() {
        let (_dir, service, root) = with_project();
        for batch in [
            ["a.png", "a.png"],
            ["notes", "notes/ch.tex"],
            ["notes/ch.tex", "notes"],
            ["a.png", "../x.png"],
        ] {
            let err = clashes(&root, "", &incoming(&batch)).unwrap_err();
            assert_eq!(err.status, 400);
        }
        let old = [
            ("figs/a.png", "old"),
            ("figs/a 2.png", "older"),
            ("notes", "file"),
        ];
        folder(&root, &old);
        let batch = [
            "main.tex",
            "figs/a.png",
            "figs/b.png",
            "notes/x.tex",
            "notes/y.tex",
        ];
        assert!(
            clashes(&root, "img/", &incoming(&batch))
                .unwrap()
                .is_empty()
        );
        // Keep Both must not pick a name the import itself brings.
        let batch = incoming(&[&batch[..], &["main 2.tex"]].concat());
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
        assert_eq!(renamed("notesy/x.tex"), "notesy/x.tex");

        let err = put(&service, "figs/a.png", b"new", false).unwrap_err();
        let refusal = (err.status, err.message.as_str());
        assert_eq!(refusal, (409, "“figs/a.png” already exists"));
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
        // A link to a folder in the project is a folder a file goes into.
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.join("figs"), root.join("link")).unwrap();
            assert!(
                clashes(&root, "", &incoming(&["link/c.png"]))
                    .unwrap()
                    .is_empty()
            );
            put(&service, "link/c.png", b"png", false).unwrap();
            assert_eq!(fs::read(root.join("figs/c.png")).unwrap(), b"png");
        }
    }

    #[test]
    fn a_drop_imports_into_its_folder_and_asks_before_landing_on_anything() {
        let (dir, service, root) = with_project();
        let drop = dir.path().join("drop");
        let files = [
            ("figs/a.png", "a"),
            ("figs/sub/b.png", "b"),
            ("figs/.git/HEAD", "ref"),
            ("figs/.DS_Store", "x"),
            ("main.tex", "new"),
        ];
        folder(&drop, &files);
        let paths = [drop.join("figs"), drop.join("main.tex")];
        // Hidden files inside a dropped folder stay behind.
        let out = import_files(&service, "P", "in", &paths, None).unwrap();
        assert_eq!(
            sorted(out),
            ["in/figs/a.png", "in/figs/sub/b.png", "in/main.tex"]
        );
        assert_eq!(fs::read(root.join("in/figs/sub/b.png")).unwrap(), b"b");
        // A batch that would collide writes nothing.
        let twice = [drop.join("main.tex"), drop.join("main.tex")];
        let refused = import_files(&service, "P", "again", &twice, None);
        assert_eq!(refused.unwrap_err().status, 400);
        assert!(!root.join("again").exists());

        // Without an answer nothing is written; the clash is reported.
        let paths = [drop.join("main.tex")];
        let asked = import_files(&service, "P", "", &paths, None).unwrap();
        assert_eq!(
            serde_json::to_value(&asked).unwrap(),
            json!({ "saved": [], "existing": [{ "path": "main.tex", "keepBoth": "main 2.tex" }] })
        );
        let original = fs::read(root.join("main.tex")).unwrap();
        let kept = import_files(&service, "P", "", &paths, Some(Conflict::KeepBoth)).unwrap();
        assert_eq!(kept.saved, ["main 2.tex"]);
        assert_eq!(fs::read(root.join("main.tex")).unwrap(), original);
        assert_eq!(fs::read(root.join("main 2.tex")).unwrap(), b"new");

        // A dropped link names what it points at; links inside a folder are left.
        #[cfg(unix)]
        {
            let files = [("elsewhere/plot.png", "p"), ("linked/pics/real.png", "r")];
            folder(dir.path(), &files);
            let (plot, drop) = (dir.path().join(files[0].0), dir.path().join("linked"));
            std::os::unix::fs::symlink(&plot, drop.join("plot-link.png")).unwrap();
            std::os::unix::fs::symlink(&plot, drop.join("pics/inner.png")).unwrap();
            let paths = [drop.join("plot-link.png"), drop.join("pics")];
            let out = import_files(&service, "P", "", &paths, None).unwrap();
            assert_eq!(sorted(out), ["pics/real.png", "plot-link.png"]);
            assert_eq!(fs::read(root.join("plot-link.png")).unwrap(), b"p");
        }
    }

    #[test]
    fn an_import_sweeps_away_only_a_staging_folder_a_day_old() {
        let (dir, service) = library();
        let staged = |name: &str, age: u64| {
            let path = service.data_dir.join(name);
            folder(&path, &[("sub/main.tex", "x")]);
            let when = std::time::SystemTime::now() - Duration::from_secs(age);
            // Windows opens a folder only for its backup semantics, and to
            // date it, for its attributes.
            #[cfg(windows)]
            let handle = {
                use std::os::windows::fs::OpenOptionsExt;
                let mut options = fs::OpenOptions::new();
                options
                    .access_mode(0x100)
                    .custom_flags(0x0200_0000)
                    .open(&path)
            };
            #[cfg(not(windows))]
            let handle = File::open(&path);
            handle.unwrap().set_modified(when).unwrap();
            path
        };
        let crashed = staged(".texlocal-import-crashed", 25 * 60 * 60);
        let running = staged(".texlocal-import-running", 23 * 60 * 60);
        let other = staged(".hidden", 25 * 60 * 60);
        let src = dir.path().join("paper.zip");
        zip_of(&src, &[("main.tex", "x")], false);
        import_project(&service, &src).unwrap();
        assert!(!crashed.exists());
        assert!(running.exists() && other.exists());
        assert!(service.data_dir.join("paper/main.tex").exists());
    }

    #[test]
    fn an_import_past_its_allowance_or_that_fails_makes_no_project() {
        let (dir, service) = library();
        let small = Allowance {
            files: 3,
            entries: 8,
            bytes: 25,
        };
        let fails = |src: &Path| {
            import_project_within(&service, src, small)
                .unwrap_err()
                .message
        };
        let many = dir.path().join("many.zip");
        zip_of(
            &many,
            &[
                ("a.tex", "a"),
                ("b.tex", "b"),
                ("c.tex", "c"),
                ("d.tex", "d"),
            ],
            false,
        );
        assert_eq!(fails(&many), TOO_MANY);
        let large = dir.path().join("large.zip");
        let text = "0123456789";
        zip_of(
            &large,
            &[("a.tex", text), ("b.tex", text), ("c.tex", text)],
            false,
        );
        assert_eq!(fails(&large), TOO_BIG);

        // A zip whose headers both say its file is 1 byte stops at the bytes
        // read: the uncompressed size is 22 bytes into a local header, 24
        // into a central one.
        let lying = dir.path().join("lying.zip");
        zip_of(&lying, &[("a.tex", "x".repeat(40).as_str())], false);
        let mut bytes = fs::read(&lying).unwrap();
        for (signature, at) in [(b"PK\x03\x04", 22), (b"PK\x01\x02", 24)] {
            let header = bytes.windows(4).position(|w| w == signature).unwrap();
            bytes[header + at..header + at + 4].copy_from_slice(&1u32.to_le_bytes());
        }
        fs::write(&lying, bytes).unwrap();
        assert_eq!(fails(&lying), TOO_BIG);
        // As does a file that says it is empty.
        #[cfg(target_os = "linux")]
        assert_eq!(fails(Path::new("/proc/self/status")), TOO_BIG);

        // A folder's files count, and so do its entries, even empty folders.
        let src = dir.path().join("Many");
        folder(
            &src,
            &[("a.tex", ""), ("b.tex", ""), ("c.tex", ""), ("d.tex", "")],
        );
        assert_eq!(fails(&src), TOO_MANY);
        for i in 0..10 {
            fs::create_dir_all(dir.path().join(format!("Hollow/d{i}"))).unwrap();
        }
        assert_eq!(fails(&dir.path().join("Hollow")), TOO_MANY);

        // A zip whose second file's bytes no longer match its checksum.
        let broken = dir.path().join("broken.zip");
        zip_of(
            &broken,
            &[("a.tex", "fine"), ("b.tex", "CORRUPTED-LATER")],
            true,
        );
        let mut bytes = fs::read(&broken).unwrap();
        let at = bytes.windows(15).position(|w| w == b"CORRUPTED-LATER");
        bytes[at.unwrap()] = b'X';
        fs::write(&broken, bytes).unwrap();
        assert!(import_project(&service, &broken).is_err());
        // A folder holding a file that can't be read, where permissions bind.
        #[cfg(unix)]
        if unsafe { libc::geteuid() } != 0 {
            use std::os::unix::fs::PermissionsExt;
            let locked = fs::Permissions::from_mode(0o000);
            fs::set_permissions(src.join("b.tex"), locked).unwrap();
            assert!(import_project(&service, &src).is_err());
        }
        assert_eq!(projects(&service), 0);

        // Within the limits, it imports.
        zip_of(&large, &[("a.tex", text), ("b.tex", text)], false);
        import_project_within(&service, &large, small).unwrap();
        assert_eq!(projects(&service), 1);
    }

    #[test]
    fn a_zip_brings_its_visible_files_named_as_paths_that_stay_in_the_project() {
        let (dir, service) = library();
        let src = dir.path().join("names.zip");
        let names = [
            "./main.tex",
            "a\\b.tex",
            "a/./c/../d.tex",
            "/etc/x.tex",
            "\\y.tex",
            "../z.tex",
            "a/../../w.tex",
            "./",
            "n\0.tex",
            "build/main.pdf",
            ".git/HEAD",
        ];
        zip_of(&src, &names.map(|name| (name, "x")), false);
        let info = import_project(&service, &src).unwrap();
        let root = service.data_dir.join(&info.id);
        // Made hidden, it has a new folder's usual mode all the same.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&root), mode(&service.data_dir));
        }
        assert_eq!(files_in(&root), ["a/b.tex", "a/d.tex", "main.tex"]);
        assert!(!root.join("build").exists() && !root.join(".git").exists());

        // One folder's zip brings that folder's contents.
        let src = dir.path().join("paper.zip");
        let files = [
            ("paper/aaa.tex", "\\section{Intro}"),
            ("paper\\doc.tex", "\\documentclass{article}"),
            ("paper/figs/b.png", "png"),
            ("__MACOSX/paper/._doc.tex", "fork"),
        ];
        zip_of(&src, &files, false);
        let info = import_project(&service, &src).unwrap();
        // No main.tex: the first file that starts a document.
        assert_eq!([info.id, info.main_file], ["paper", "doc.tex"]);
        let root = service.data_dir.join("paper");
        assert_eq!(files_in(&root), ["aaa.tex", "doc.tex", "figs/b.png"]);
        assert_eq!(fs::read_to_string(root.join("figs/b.png")).unwrap(), "png");
    }

    #[test]
    fn a_folder_brings_its_visible_files_and_its_name() {
        let (dir, service) = library();
        let src = dir.path().join("Thesis");
        let files = [
            ("main.tex", "\\documentclass{book}"),
            ("figs/a.png", "png"),
            ("figs/.DS_Store", "x"),
            (".git/HEAD", "ref"),
            ("build/main.pdf", "old output"),
        ];
        folder(&src, &files);
        let info = import_project(&service, &src).unwrap();
        assert_eq!([info.id, info.main_file], ["Thesis", "main.tex"]);
        let root = service.data_dir.join("Thesis");
        assert_eq!(files_in(&root), ["figs/a.png", "main.tex"]);
        assert!(!root.join(".git").exists() && !root.join("build").exists());
        // A taken name gets a number, as Finder's copies do.
        assert_eq!(import_project(&service, &src).unwrap().id, "Thesis 2");
    }

    #[test]
    fn a_tex_brings_its_folder_no_larger_than_a_project_and_is_its_main_file() {
        let (dir, service) = library();
        let src = dir.path().join("Paper");
        let files = [
            ("main.tex", "\\documentclass{article}"),
            ("paper.tex", "\\documentclass{article}\\input{chapters/a}"),
            ("chapters/a.tex", "\\section{A}"),
            ("refs.bib", "@book{k,}"),
            ("Build/main.pdf", ""),
        ];
        folder(&src, &files);
        // Output, past a project's bytes but sparse, neither comes nor counts.
        let big = |path: PathBuf| File::create(path).unwrap().set_len(UPLOAD_MAX_BYTES + 1);
        big(src.join("Build/main.pdf")).unwrap();
        let info = import_project(&service, &src.join("paper.tex")).unwrap();
        assert_eq!([info.id, info.main_file], ["Paper", "paper.tex"]);
        let files = ["chapters/a.tex", "main.tex", "paper.tex", "refs.bib"];
        assert_eq!(files_in(&service.data_dir.join("Paper")), files);

        // Any other file comes alone; without TeX, the blank template's main
        // file joins it.
        let info = import_project(&service, &src.join("refs.bib")).unwrap();
        assert_eq!(info.main_file, "main.tex");
        assert_eq!(
            files_in(&service.data_dir.join("refs")),
            ["main.tex", "refs.bib"]
        );

        // In a folder larger than a project, by its bytes or by more than 2000
        // files, a .tex comes alone.
        big(src.join("big.dmg")).unwrap();
        // Named for the file: "paper", or "paper 2" where the volume takes it for "Paper".
        let info = import_project(&service, &src.join("paper.tex")).unwrap();
        assert!(info.id.starts_with("paper"), "{}", info.id);
        assert_eq!(info.main_file, "paper.tex");
        assert_eq!(files_in(&service.data_dir.join(&info.id)), ["paper.tex"]);
        fs::remove_file(src.join("big.dmg")).unwrap();
        for i in 0..2000 {
            fs::write(src.join(format!("{i}.txt")), "").unwrap();
        }
        let info = import_project(&service, &src.join("paper.tex")).unwrap();
        assert_eq!(files_in(&service.data_dir.join(&info.id)), ["paper.tex"]);
    }
}
