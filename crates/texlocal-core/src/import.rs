//! Bringing outside files into the library: a Finder drop onto a project,
//! and File › Open of a folder, a .zip or a .tex made a new project. Both read
//! host-chosen absolute paths and block on the disk; hosts call them off
//! their UI thread, as they do every `tl_call`.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::json;
use zip::ZipArchive;
use zip::result::ZipError;

use crate::paths::{self, after_entry, fold_case, normalize_segments, rel_key};
use crate::projects::{self, ProjectInfo, Trash};
use crate::service::Service;
use crate::settings::write_settings;
use crate::zipexport::left_out;
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

/// A .tex brings its folder only while that is no larger than a project:
/// Overleaf's limit on a project's files, and 100 MB.
const TEX_FOLDER_ENTRIES: usize = 2000;
const TEX_FOLDER_BYTES: u64 = 100 << 20;

/// `name` in the project folder `dir` ("" is the project's own).
fn in_folder(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    }
}

/// Files under a dropped path, with project-relative names that keep a
/// dropped folder's own name (none for an empty `rel`), failing past
/// `entries_left`. Inside a folder, what `is_litter` and symlinks stay
/// behind, not followed: a drop imports what was dropped, never what a link
/// inside it points at.
fn collect(
    abs: &Path,
    rel: String,
    meta: &fs::Metadata,
    files: &mut Vec<Incoming>,
    entries_left: &mut usize,
) -> Result<(), CoreError> {
    if meta.is_file() {
        let source = Source::File(abs.to_path_buf());
        files.push(Incoming { path: rel, source });
    } else if meta.is_dir() {
        for entry in fs::read_dir(abs).map_err(CoreError::at(abs))? {
            *entries_left = (entries_left.checked_sub(1))
                .ok_or_else(|| CoreError::bad_request("Too many files"))?;
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !projects::is_litter(&name)
                && !(rel.is_empty() && name.eq_ignore_ascii_case(BUILD_DIR))
            {
                // DirEntry::metadata does not follow links.
                let meta = entry.metadata()?;
                let rel = in_folder(&rel, &name);
                collect(&entry.path(), rel, &meta, files, entries_left)?;
            }
        }
    }
    Ok(())
}

/// Import dropped files and folders into the project folder `dir`: a bad
/// path fails the drop before anything lands.
/// Without `conflict`, a drop that would land on existing entries writes
/// nothing and reports them, for the host to ask about.
pub fn import_files(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
) -> Result<Imported, CoreError> {
    import_files_within(service, id, dir, paths, conflict, projects::discard)
}

/// `import_files`, with `trash` to discard what Replace replaces.
fn import_files_within(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<Conflict>,
    trash: Trash,
) -> Result<Imported, CoreError> {
    let mut files = Vec::new();
    for abs in paths {
        let name = abs.file_name().unwrap_or_default().to_string_lossy();
        // A dropped link is followed: dropping it names what it points at.
        let meta = fs::metadata(abs).map_err(CoreError::at(abs))?;
        collect(abs, name.into_owned(), &meta, &mut files, &mut {
            usize::MAX
        })?;
    }
    let root = service.project_root(id)?;
    let rels = validate(&root, dir, files.iter().map(|file| file.path.as_str()))?;
    let base = root.join(rel_key(dir).unwrap_or_default());
    let existing = clashes(&base, &rels);
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported { existing });
    }
    let replace = (conflict == Some(Conflict::Replace)).then_some(trash);
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
        save(service, id, &rel, &source, replace)?;
    }
    Ok(Imported { existing })
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
        if !seen.insert(key.clone())
            || folders.contains(&key)
            || parents().any(|parent| seen.contains(parent))
        {
            return Err(CoreError::bad_request(
                "Two of the files to import would take the same place.",
            ));
        }
        folders.extend(parents().map(str::to_string));
        rels.push(rel);
    }
    Ok(rels)
}

/// The entries the validated `rels` would land on under `base`, with free
/// Keep Both names, for the host's Replace, Keep Both or Stop choice.
fn clashes(base: &Path, rels: &[String]) -> Vec<Clash> {
    // Names a Keep Both may not take: every path the import creates.
    let mut taken = HashSet::new();
    for rel in rels {
        let key = fold_case(rel);
        taken.extend(key.match_indices('/').map(|(i, _)| key[..i].to_string()));
        taken.insert(key);
    }
    let mut existing = Vec::new();
    for path in rels.iter().filter_map(|rel| occupant(base, rel)) {
        if existing.iter().all(|c: &Clash| c.path != path) {
            let keep_both = projects::copy_paths(&path)
                .skip(1)
                .find(|free| {
                    fs::symlink_metadata(base.join(free)).is_err() && taken.insert(fold_case(free))
                })
                .expect("a free name");
            existing.push(Clash { path, keep_both });
        }
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
/// temporary file beside the target first, so a source that fails part-way
/// replaces nothing, then renamed into place
/// whole. An occupied path conflicts unless `replace`, the means of
/// discarding it, first moves it to the Trash.
fn save(
    service: &Service,
    id: &str,
    rel: &str,
    source: &Path,
    replace: Option<Trash>,
) -> Result<(), CoreError> {
    let root = service.project_root(id)?;
    // In the target's folder, or the nearest on its way while that is to be made, so the
    // rename stays on one volume.
    let abs = paths::safe_write_path(&root, rel)?;
    let folder = abs.ancestors().skip(1).find(|dir| dir.is_dir());
    let (mut file, temp) = atomic::create_temp(folder.unwrap_or(&root))?;
    let mut origin = File::open(source).map_err(CoreError::at(source))?;
    io::copy(&mut origin, &mut file)?;
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
        fs::create_dir_all(abs.parent().unwrap_or(root))?;
        Ok(atomic::persist(temp, &abs)?)
    })
}

/// A zip's visible files; the contents of its one top folder if it has one,
/// as a zipped project folder unpacks.
fn zip_files(archive: &mut ZipArchive<File>) -> Result<Vec<Incoming>, CoreError> {
    let mut files = Vec::new();
    for i in 0..archive.len() {
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

fn folder_files(dir: &Path, mut entries_left: usize) -> Result<Vec<Incoming>, CoreError> {
    let meta = fs::metadata(dir).map_err(CoreError::at(dir))?;
    let mut found = Vec::new();
    collect(dir, String::new(), &meta, &mut found, &mut entries_left)?;
    Ok(found)
}

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
    let files = folder_files(dir, TEX_FOLDER_ENTRIES).ok()?;
    let bytes: u64 = (files.iter())
        .filter_map(|file| match &file.source {
            Source::File(path) => fs::metadata(path).ok().map(|meta| meta.len()),
            Source::Zip(_) => None,
        })
        .sum();
    if bytes > TEX_FOLDER_BYTES {
        return None;
    }
    let main = file_name(tex);
    files.iter().any(|file| file.path == main).then(|| Opened {
        base: file_name(dir),
        zip: None,
        files,
        main: Some(main),
    })
}

fn open(src: &Path) -> Result<Opened, CoreError> {
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
        let files = folder_files(src, usize::MAX)?;
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
        let files = zip_files(&mut archive)?;
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
/// than a project (more than 2000 entries or 100 MB) or has no name a project can take:
/// then the .tex comes alone. Version-control folders and OS litter stay behind,
/// as does a top-level `build`; every other file comes, though the file tree hides dotfiles.
/// The main file is the chosen .tex, else the likeliest top-level one, else the blank
/// template's main.tex.
pub fn import_project(service: &Service, src: &Path) -> Result<ProjectInfo, CoreError> {
    let Opened {
        base,
        mut zip,
        mut files,
        main,
    } = open(src)?;
    // What an export leaves out stays behind: the project makes its own settings.
    files.retain(|file| !left_out(&file.path));

    projects::new_project(&service.data_dir, &base, |root| {
        validate(root, "", files.iter().map(|file| file.path.as_str()))?;
        for file in &files {
            // The folder holds only what the import wrote, so each is written
            // in place, with no temporary file or sync of its own.
            let abs = root.join(rel_key(&file.path)?);
            fs::create_dir_all(abs.parent().unwrap_or(root))?;
            let mut dest = BufWriter::new(File::create_new(abs)?);
            match &file.source {
                Source::File(path) => {
                    let mut origin = File::open(path).map_err(CoreError::at(path))?;
                    io::copy(&mut origin, &mut dest)?;
                }
                Source::Zip(i) => {
                    let mut entry = zip.as_mut().expect("a zip source").by_index(*i)?;
                    io::copy(&mut entry, &mut dest)?;
                }
            }
            dest.flush()?;
        }
        // latexmk would read a name starting with "-" as an option, so settings refuse it
        // as the main file and the import takes the likeliest other.
        let main = if let Some(main) = main.filter(|main| !main.starts_with('-')) {
            main
        } else if let Some(main) = projects::guess_main_file(root)? {
            main
        } else {
            let (file, content) = templates::files("blank")[0];
            fs::write(root.join(file), content)?;
            file.to_string()
        };
        write_settings(root, &json!({ "mainFile": main }))?;
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::{files_in, library, with_project, zip_of, zip_with};

    fn projects(service: &Service) -> usize {
        fs::read_dir(&service.data_dir).unwrap().count()
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
        save(service, "P", rel, source.path(), replace)
    }

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
        let out = import_files_within(&service, "P", "", &paths, replaced, remove).unwrap();
        assert_eq!(files_in(&root), ["figs/a.png", "figs/b.png", "main.tex"]);
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"new");
        // The clash is reported all the same, for the host to say what it replaced.
        assert_eq!(out.existing.len(), 1);

        // A mover that fails leaves the old file and takes nothing in.
        fs::write(drop.join("figs/a.png"), "newer").unwrap();
        let refuse: Trash = |_| Err(CoreError::internal("no Trash"));
        let result = import_files_within(&service, "P", "", &paths, replaced, refuse);
        assert!(result.is_err());
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"new");
    }

    #[test]
    #[ignore = "leaves a file in the user's Trash"]
    fn a_replaced_file_goes_to_the_trash_without_asking_finder() {
        let (_dir, service) = with_project();
        let file = service
            .project_root("P")
            .unwrap()
            .join("replaced by import.txt");
        fs::write(&file, "old").unwrap();
        projects::discard(&file).unwrap();
        assert!(!file.exists());
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

        // As Windows tools write them: one top folder, and backslashes.
        let src = dir.path().join("windows.zip");
        let files = ["paper\\main.tex", "paper\\figs\\a.png"];
        zip_of(&src, &files.map(|path| (path, "\\documentclass{article}")));
        let info = import_project(&service, &src).unwrap();
        assert_eq!(info.main_file, "main.tex");
        let root = service.data_dir.join(&info.id);
        assert_eq!(files_in(&root), ["figs/a.png", "main.tex"]);
    }

    #[test]
    fn a_folder_or_a_zip_of_one_brings_all_but_what_an_export_leaves_out() {
        // Into a library folder that doesn't exist yet, as on a first import.
        let dir = tempfile::tempdir().unwrap();
        let service = Service::new(dir.path().join("data"));
        let files = [
            ("Thesis/aaa.tex", "\\section{Intro}"),
            ("Thesis/doc.tex", "\\documentclass{book}"),
            ("Thesis/figs/a.png", "png"),
            ("Thesis/figs/.DS_Store", "x"),
            ("Thesis/.git/HEAD", "ref"),
            ("Thesis/.latexmkrc", "$pdf_mode = 1;"),
            ("Thesis/.texlocal.json", "{\"mainFile\": \"elsewhere.tex\"}"),
            ("Thesis/build/main.pdf", "old output"),
            // What macOS adds to a zip of it.
            ("__MACOSX/Thesis/._doc.tex", "fork"),
        ];
        for (path, text) in files {
            let file = dir.path().join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, text).unwrap();
        }
        zip_of(&dir.path().join("Thesis.zip"), &files);

        // A taken name gets a number, as Finder's copies do.
        for (src, id) in [("Thesis", "Thesis"), ("Thesis.zip", "Thesis 2")] {
            let info = import_project(&service, &dir.path().join(src)).unwrap();
            // No main.tex: the first file that starts a document, in settings of its own.
            assert_eq!([info.id, info.main_file], [id, "doc.tex"]);
            let root = service.data_dir.join(id);
            assert_eq!(files_in(&root), ["aaa.tex", "doc.tex", "figs/a.png"]);
            // The author's own dotfile comes, though the tree hides it.
            let latexmkrc = fs::read_to_string(root.join(".latexmkrc")).unwrap();
            assert_eq!(latexmkrc, "$pdf_mode = 1;");
            for left in [".git", "build", "figs/.DS_Store"] {
                assert!(!root.join(left).exists(), "{left}");
            }
        }
    }

    #[test]
    fn a_tex_brings_its_folder_while_that_is_no_larger_than_a_project() {
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
        // Sparse: past a project's bytes without writing them.
        let past_a_project = |path: &str| {
            let file = File::create(src.join(path)).unwrap();
            file.set_len(TEX_FOLDER_BYTES + 1).unwrap();
        };
        // Build output stays behind, and so doesn't count.
        fs::create_dir(src.join("Build")).unwrap();
        past_a_project("Build/main.pdf");
        let info = import_project(&service, &src.join("paper.tex")).unwrap();
        assert_eq!([info.id, info.main_file], ["Paper", "paper.tex"]);
        let files = ["chapters/a.tex", "main.tex", "paper.tex", "refs.bib"];
        assert_eq!(files_in(&service.data_dir.join("Paper")), files);

        // In a folder larger than a project, the .tex comes alone.
        past_a_project("big.dmg");
        let info = import_project(&service, &src.join("paper.tex")).unwrap();
        assert_eq!(info.main_file, "paper.tex");
        assert_eq!(files_in(&service.data_dir.join(&info.id)), ["paper.tex"]);

        // One whose name latexmk would read as an option comes but isn't the main file.
        fs::write(src.join("-draft.tex"), "\\documentclass{article}").unwrap();
        let info = import_project(&service, &src.join("-draft.tex")).unwrap();
        assert_eq!(info.main_file, "main.tex");
        let files = ["-draft.tex", "main.tex"];
        assert_eq!(files_in(&service.data_dir.join(&info.id)), files);

        // Any other file comes alone; without TeX, the blank template's main
        // file joins it.
        let info = import_project(&service, &src.join("refs.bib")).unwrap();
        assert_eq!(info.main_file, "main.tex");
        let files = ["main.tex", "refs.bib"];
        assert_eq!(files_in(&service.data_dir.join(&info.id)), files);
    }

    #[test]
    fn a_failed_import_makes_no_project_and_names_what_failed() {
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

        // A zip whose second file's bytes no longer match its checksum.
        let src = dir.path().join("broken.zip");
        let files = [("a.tex", "fine"), ("b.tex", "CORRUPTED-LATER")];
        zip_with(&src, &files, zip::CompressionMethod::Stored);
        let mut bytes = fs::read(&src).unwrap();
        let at = bytes.windows(15).position(|w| w == b"CORRUPTED-LATER");
        bytes[at.unwrap()] = b'X';
        fs::write(&src, bytes).unwrap();
        assert!(import_project(&service, &src).is_err());

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
            // Not a bug of the core's, and it says which file.
            if File::open(src.join("b.tex")).is_err() {
                assert_eq!(err.status, 403, "{}", err.message);
                assert!(err.message.contains("b.tex"), "{}", err.message);
            }
        }
        assert_eq!(projects(&service), 0);
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
        import_files(&service, "P", "in", &paths, None).unwrap();
        let root = service.data_dir.join("P/in");
        let files = ["figs/a.png", "figs/sub/b.png", "notes.tex"];
        assert_eq!(files_in(&root), files);
        assert_eq!(fs::read(root.join("figs/sub/b.png")).unwrap(), b"b");

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
        let asked = json!(import_files(&service, "P", "", &paths, None).unwrap());
        let clash = json!({ "path": "main.tex", "keepBoth": "main 2.tex" });
        assert_eq!(asked, json!({ "existing": [clash] }));
        let root = service.data_dir.join("P");
        assert_eq!(files_in(&root), ["main.tex"]);
        let original = fs::read(root.join("main.tex")).unwrap();

        import_files(&service, "P", "", &paths, Some(Conflict::KeepBoth)).unwrap();
        assert_eq!(files_in(&root), ["figs/a.png", "main 2.tex", "main.tex"]);
        assert_eq!(fs::read(root.join("main.tex")).unwrap(), original);
        assert_eq!(fs::read(root.join("main 2.tex")).unwrap(), b"new");
        // Litter inside a dropped folder stays behind.
        assert!(!root.join("figs/.git").exists() && !root.join("figs/.DS_Store").exists());

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
            import_files(&service, "P", "", &paths, None).unwrap();
            assert!(root.join("pics/real.png").is_file() && !root.join("pics/inner.png").exists());
            assert_eq!(fs::read(root.join("plot-link.png")).unwrap(), b"p");
        }
    }
}
