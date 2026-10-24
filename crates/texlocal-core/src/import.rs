//! Bringing files into the library: a Finder drop onto a project, and a .zip, a file whose folder
//! doesn't open where it is (`open_path`) or a library project's files made a new project. They
//! read host-chosen absolute paths and block on the disk; hosts call them off their UI thread, as
//! they do every `tl_call`.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufRead, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zip::ZipArchive;
use zip::result::ZipError;

use crate::analyze::Facts;
use crate::paths::{self, after_entry, fold_case, in_folder, normalize_segments, rel_key};
use crate::projects::{self, ProjectInfo, Trash, is_litter, walk};
use crate::service::Service;
use crate::settings::write_settings;
use crate::zipexport::left_out;
use crate::{CoreError, SETTINGS_FILE, atomic, templates};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Conflict {
    Replace,
    KeepBoth,
}

#[derive(Debug, Serialize)]
pub struct Imported {
    pub existing: Vec<Clash>,
}

/// `path` is relative to its target folder; `keep_both` names a free sibling.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Clash {
    pub path: String,
    pub keep_both: String,
}

/// Where a file a new project is made of comes from: the disk, or the zip's entry at an index.
enum Source {
    File(PathBuf),
    Zip(usize),
}

static MAGIC_COMMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\s*%\s*!\s*TeX\s+(root|(?:TS-)?program)\s*=\s*(.*?)\s*$").unwrap()
});

/// Past a document's: a zip that unpacks to more is a mistake, or made to fill the disk.
const MAX_UNZIPPED: u64 = 1 << 30;
const TOO_LARGE: &str = "This zip unpacks to more than 1 GB, which is more than a project holds.";

/// Packages that build only with XeLaTeX or LuaLaTeX, which a new project's engine follows.
const ENGINE_PACKAGES: [(&str, &[&str]); 2] = [
    (
        "xelatex",
        &[
            "fontspec",
            "unicode-math",
            "polyglossia",
            "xeCJK",
            "mathspec",
        ],
    ),
    ("lualatex", &["luacode", "luatexja", "luaotfload"]),
];

/// A bad path fails the drop before anything lands. Without `conflict`, a drop onto existing
/// entries writes nothing and reports them, for the host to ask about; with Replace, `trash`
/// discards them.
pub fn import_files(
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
        // A dropped link is followed: dropping it names what it points at. A link inside a
        // dropped folder is left behind, as what was dropped is imported.
        let meta = fs::metadata(abs).map_err(CoreError::at(abs))?;
        if meta.is_file() {
            files.push((name.into_owned(), abs.clone()));
        } else if meta.is_dir() {
            walk(abs, &|rel| !rel.split('/').any(is_litter), &mut |entry| {
                if !entry.dir && !entry.link {
                    files.push((in_folder(&name, &entry.rel), entry.path.clone()));
                }
                Ok(true)
            })?;
        }
    }
    let root = service.project(id)?.root;
    let (rels, taken) = validate(&root, dir, files.iter().map(|(path, _)| path.as_str()))?;
    let existing = clashes(&root.join(rel_key(dir).unwrap_or_default()), &rels, taken);
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported { existing });
    }
    let replace = (conflict == Some(Conflict::Replace)).then_some(trash);
    for (path, source) in files {
        let path = match conflict {
            Some(Conflict::KeepBoth) => keep_both(&path, &existing),
            _ => path,
        };
        save(service, id, &in_folder(dir, &path), &source, replace)?;
    }
    Ok(Imported { existing })
}

/// The whole batch is checked before anything is written: none twice, and none a file where
/// another needs a folder. With its paths comes every path it creates, folded.
fn validate<'a>(
    root: &Path,
    dir: &str,
    files: impl Iterator<Item = &'a str>,
) -> Result<(Vec<String>, HashSet<String>), CoreError> {
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
    seen.extend(folders);
    Ok((rels, seen))
}

/// For the host's Replace, Keep Both or Stop choice. A Keep Both takes no name `taken` holds:
/// every path the import creates.
fn clashes(base: &Path, rels: &[String], mut taken: HashSet<String>) -> Vec<Clash> {
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

fn keep_both(path: &str, clashes: &[Clash]) -> String {
    let renamed = clashes.iter().find_map(|clash| {
        let rest = after_entry(path, &clash.path)?;
        Some(format!("{}{rest}", clash.keep_both))
    });
    renamed.unwrap_or_else(|| path.to_string())
}

/// The first entry in `rel`'s way under `base`: the file itself if it exists, or a folder on its
/// path that exists as something else.
fn occupant(base: &Path, rel: &str) -> Option<String> {
    let mut end = 0;
    loop {
        end = rel[end..].find('/').map_or(rel.len(), |i| end + i);
        let abs = base.join(&rel[..end]);
        let meta = fs::symlink_metadata(&abs).ok()?;
        // A link to a folder is a folder on the way.
        if end == rel.len() || !(meta.is_dir() || abs.is_dir()) {
            return Some(rel[..end].to_string());
        }
        end += 1;
    }
}

/// Copied to a temporary file beside the target first, so a source that fails part-way replaces
/// nothing. An occupied path conflicts unless `replace` first discards it.
fn save(
    service: &Service,
    id: &str,
    rel: &str,
    source: &Path,
    replace: Option<Trash>,
) -> Result<(), CoreError> {
    let root = service.project(id)?.root;
    // Beside the target, so the rename stays on one volume.
    let abs = paths::safe_write_path(&root, rel)?;
    let folder = abs.ancestors().skip(1).find(|dir| dir.is_dir());
    let (mut file, temp) = atomic::create_temp(folder.unwrap_or(&root))?;
    let mut origin = File::open(source).map_err(CoreError::at(source))?;
    io::copy(&mut origin, &mut file)?;
    file.sync_all()?;
    drop(file);
    service.with_project(id, |project| {
        let root = &project.root;
        let abs = paths::safe_write_path(root, rel)?;
        if let Some(taken) = occupant(root, &rel_key(rel)?) {
            let Some(trash) = replace else {
                return Err(CoreError::conflict(format!("“{taken}” already exists")));
            };
            projects::discard_replaced(project, &taken, trash)?;
        }
        fs::create_dir_all(abs.parent().unwrap_or(root))?;
        Ok(atomic::persist(temp, &abs)?)
    })
}

/// What File › Open makes a project of: the new project's name, its files and where each comes
/// from, and the .tex chosen, if one was.
struct Opened {
    base: String,
    zip: Option<ZipArchive<File>>,
    files: Vec<(String, Source)>,
    main: Option<String>,
}

impl Opened {
    /// A zip's visible files; the contents of its one top folder if it has one, as a zipped
    /// project folder unpacks.
    fn of_zip(base: String, mut zip: ZipArchive<File>) -> Result<Self, CoreError> {
        let mut files = Vec::new();
        for i in 0..zip.len() {
            let entry = zip.by_index_raw(i)?;
            // A backslash separates, as Windows tools have written it where the format allows
            // only '/'.
            let name = entry.name().replace('\\', "/");
            let segments = match normalize_segments(&name, "") {
                Ok(s) if entry.is_file() && !s.is_empty() && !name.contains('\0') => s,
                _ => continue,
            };
            if !segments.iter().any(|s| projects::is_litter(s)) {
                files.push((segments.join("/"), Source::Zip(i)));
            }
        }
        let top =
            (files.first()).and_then(|(path, _)| Some(format!("{}/", path.split_once('/')?.0)));
        if let Some(top) = top.filter(|top| files.iter().all(|(path, _)| path.starts_with(top))) {
            for (path, _) in &mut files {
                path.drain(..top.len());
            }
        }
        Ok(Self {
            base,
            zip: Some(zip),
            files,
            main: None,
        })
    }
}

/// A .zip's files, or any other file alone.
fn open(src: &Path) -> Result<Opened, CoreError> {
    let stem = src
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let ext = src
        .extension()
        .map(|ext| ext.to_string_lossy().to_lowercase());
    if ext.as_deref() == Some("zip") {
        let file = File::open(src).map_err(CoreError::at(src))?;
        let zip = ZipArchive::new(file).map_err(|err| match err {
            ZipError::Io(err) => CoreError::at(src)(err),
            err => {
                let name = file_name(src);
                CoreError::bad_request(format!("“{name}” can't be read as a zip ({err})"))
            }
        })?;
        return Opened::of_zip(stem, zip);
    }
    let path = file_name(src);
    Ok(Opened {
        base: stem,
        zip: None,
        main: (projects::file_kind(&path) == "tex").then(|| path.clone()),
        files: vec![(path, Source::File(src.to_path_buf()))],
    })
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

/// What a file's first lines say as TeXShop, TeXstudio and VS Code read them, in any case:
/// `% !TEX root = …` and `% !TEX program = …` (or `TS-program`).
fn magic_comments(file: &Path) -> (Option<String>, Option<String>) {
    let mut found = (None, None);
    let Ok(file) = File::open(file) else {
        return found;
    };
    for line in io::BufReader::new(file)
        .lines()
        .take(20)
        .map_while(Result::ok)
    {
        if let Some(m) = MAGIC_COMMENT.captures(&line) {
            let slot = if m[1].eq_ignore_ascii_case("root") {
                &mut found.0
            } else {
                &mut found.1
            };
            slot.get_or_insert_with(|| m[2].to_string());
        }
    }
    found
}

/// The settings a folder's sources name, `chosen` the top-level .tex opened: the main file is
/// the root that .tex names, else that .tex, else the likeliest top-level one, else none; the
/// engine is the one the chosen .tex or the main file names, else the one the main file's
/// packages need.
pub(crate) fn guessed_settings(root: &Path, chosen: Option<&str>) -> Result<Value, CoreError> {
    // latexmk would read a name starting with "-" as an option.
    let chosen = chosen.filter(|main| !main.starts_with('-'));
    let (named_root, program) = chosen
        .map(|chosen| magic_comments(&root.join(chosen)))
        .unwrap_or_default();
    let named_root = named_root
        .and_then(|named| paths::safe_rel_file(&named).ok())
        .filter(|rel| root.join(rel).is_file());
    let main = match named_root.or(chosen.map(str::to_owned)) {
        Some(main) => Some(main),
        None => projects::guess_main_file(root)?,
    };
    let main_path = main.as_ref().map(|main| root.join(main));
    let program = program.or_else(|| magic_comments(main_path.as_ref()?).1);
    let program = program.unwrap_or_default().to_lowercase();
    let named = ["xelatex", "lualatex", "pdflatex"]
        .into_iter()
        .find(|engine| program.contains(engine));
    let engine = named.or_else(|| {
        let facts = Facts::read(&fs::read_to_string(main_path?).ok()?, "tex");
        let loads = |names: &[&str]| facts.packages.iter().any(|p| names.contains(&p.as_str()));
        let needed = ENGINE_PACKAGES.into_iter().find(|(_, names)| loads(names));
        needed.map(|(engine, _)| engine)
    });
    let mut settings = json!({});
    if let Some(main) = main {
        settings["mainFile"] = main.into();
    }
    if let Some(engine) = engine {
        settings["engine"] = engine.into();
    }
    Ok(settings)
}

/// A .zip's files, or a file alone, made a new project, with the settings they name; a project
/// without a .tex gets the blank template's main file.
pub(crate) fn import_project(service: &Service, src: &Path) -> Result<ProjectInfo, CoreError> {
    let Opened {
        base,
        mut zip,
        mut files,
        main,
    } = open(src)?;
    // What an export leaves out stays behind: the project makes its own settings.
    files.retain(|(path, _)| !left_out(path));

    projects::new_project(&service.data_dir, &base, |root| {
        write_files(root, &files, zip.as_mut())?;
        let mut settings = guessed_settings(root, main.as_deref())?;
        if settings.get("mainFile").is_none() {
            let (file, content) = templates::files("blank")[0];
            fs::write(root.join(file), content)?;
            settings["mainFile"] = file.into();
        }
        write_settings(&root.join(SETTINGS_FILE), &settings)?;
        Ok(())
    })
}

/// A new project's files, each written at its path in `root` from where it comes. A zip's are
/// taken at the sizes it gives them, which may come to `MAX_UNZIPPED` at most.
fn write_files(
    root: &Path,
    files: &[(String, Source)],
    mut zip: Option<&mut ZipArchive<File>>,
) -> Result<(), CoreError> {
    validate(root, "", files.iter().map(|(path, _)| path.as_str()))?;
    if let Some(zip) = zip.as_deref_mut() {
        let mut unzipped = 0;
        for (_, source) in files {
            if let Source::Zip(i) = source {
                unzipped += zip.by_index_raw(*i)?.size();
            }
        }
        if unzipped > MAX_UNZIPPED {
            return Err(CoreError::bad_request(TOO_LARGE));
        }
    }
    for (path, source) in files {
        let abs = root.join(rel_key(path)?);
        fs::create_dir_all(abs.parent().unwrap_or(root))?;
        let mut dest = BufWriter::new(File::create_new(abs)?);
        match source {
            Source::File(path) => {
                let mut origin = File::open(path).map_err(CoreError::at(path))?;
                io::copy(&mut origin, &mut dest)?;
            }
            Source::Zip(i) => {
                let mut entry = zip.as_mut().expect("a zip source").by_index(*i)?;
                // A byte past its size, so a sound entry is read to its end, where its checksum is.
                let size = entry.size();
                if io::copy(&mut Read::take(&mut entry, size + 1), &mut dest)? > size {
                    return Err(CoreError::bad_request(TOO_LARGE));
                }
            }
        }
        dest.flush()?;
    }
    Ok(())
}

/// A library project's copy named `name`, made as an import is: what an export leaves out stays
/// behind (the build folder and the history among it), but the settings come along.
pub(crate) fn duplicate_project(
    service: &Service,
    id: &str,
    name: &str,
) -> Result<ProjectInfo, CoreError> {
    if projects::is_opened(id) {
        return Err(CoreError::conflict(
            "A folder opened where it is can't be duplicated here. Copy the folder itself, then open the copy.",
        ));
    }
    let root = service.project(id)?.root;
    let mut files = Vec::new();
    walk(&root, &|rel| !left_out(rel), &mut |entry| {
        if !entry.dir {
            files.push((entry.rel.clone(), Source::File(entry.path.clone())));
        }
        Ok(true)
    })?;
    projects::new_project(&service.data_dir, name, |copy| {
        write_files(copy, &files, None)?;
        // Copied apart, as the generic writes refuse it; a folder put in the library by hand may
        // have none.
        match fs::copy(root.join(SETTINGS_FILE), copy.join(SETTINGS_FILE)) {
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            copied => Ok(copied.map(drop)?),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::Project;
    use crate::projects::testing::{library, with_project};
    use crate::projects::{TreeNode, file_tree};

    fn files_in(root: &Path) -> Vec<String> {
        fn walk(nodes: Vec<TreeNode>, out: &mut Vec<String>) {
            for node in nodes {
                match node.children {
                    Some(children) => walk(children, out),
                    None => out.push(node.path),
                }
            }
        }
        let mut out = Vec::new();
        walk(file_tree(&Project::in_folder(root)).unwrap(), &mut out);
        out.sort();
        out
    }

    fn write_all(dir: &Path, files: &[(&str, &str)]) {
        for (path, text) in files {
            fs::create_dir_all(dir.join(path).parent().unwrap()).unwrap();
            fs::write(dir.join(path), text).unwrap();
        }
    }

    /// Stored, so a test can find and change the files' bytes.
    fn zip_of(path: &Path, files: &[(&str, &str)]) {
        let mut zip = zip::ZipWriter::new(File::create(path).unwrap());
        let stored = zip::CompressionMethod::Stored;
        let options = zip::write::SimpleFileOptions::default().compression_method(stored);
        for (name, text) in files {
            zip.start_file(*name, options).unwrap();
            zip.write_all(text.as_bytes()).unwrap();
        }
        zip.finish().unwrap();
    }

    fn remove(path: &Path) -> Result<(), CoreError> {
        if path.is_dir() {
            fs::remove_dir_all(path)?;
        } else {
            fs::remove_file(path)?;
        }
        Ok(())
    }

    fn put(service: &Service, rel: &str, bytes: &[u8], replace: bool) -> Result<(), CoreError> {
        let source = tempfile::NamedTempFile::new().unwrap();
        fs::write(source.path(), bytes).unwrap();
        let replace = replace.then_some(remove as Trash);
        save(service, "P", rel, source.path(), replace)
    }

    #[test]
    fn files_are_validated_as_a_batch_before_any_write() {
        let (_dir, service) = with_project();
        let root = service.project("P").unwrap().root;
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
        let root = service.project("P").unwrap().root;
        let there = [
            ("figs/a.png", "old"),
            ("figs/a 2.png", "older"),
            ("notes", "a file"),
        ];
        write_all(&root, &there);

        let batch = [
            "main.tex",
            "figs/a.png",
            "figs/b.png",
            "notes/x.tex",
            "notes/y.tex",
            // Keep Both must not pick a name the import itself brings.
            "main 2.tex",
        ];
        let (rels, taken) = validate(&root, "", batch.into_iter()).unwrap();
        let existing = clashes(&root, &rels, taken);
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
        // Replacing a folder that holds the main file is refused before the Trash, however the
        // import spells it on a volume that ignores case.
        fs::create_dir(root.join("ch")).unwrap();
        fs::rename(root.join("main.tex"), root.join("ch/main.tex")).unwrap();
        write_settings(
            &root.join(SETTINGS_FILE),
            &json!({ "mainFile": "ch/main.tex" }),
        )
        .unwrap();
        assert_eq!(put(&service, "ch", b"x", true).unwrap_err().status, 409);
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
        let root = service.project("P").unwrap().root;
        write_all(&root, &[("figs/a.png", "old")]);
        let drop = dir.path().join("drop");
        write_all(&drop, &[("figs/a.png", "new"), ("figs/b.png", "b")]);
        let paths = [drop.join("figs")];

        let replaced = Some(Conflict::Replace);
        let out = import_files(&service, "P", "", &paths, replaced, remove).unwrap();
        assert_eq!(files_in(&root), ["figs/a.png", "figs/b.png", "main.tex"]);
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"new");
        // The clash is reported all the same, for the host to say what it replaced.
        assert_eq!(out.existing.len(), 1);

        // A mover that fails leaves the old file and takes nothing in.
        fs::write(drop.join("figs/a.png"), "newer").unwrap();
        let refuse: Trash = |_| Err(CoreError::internal("no Trash"));
        let result = import_files(&service, "P", "", &paths, replaced, refuse);
        assert!(result.is_err());
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"new");
    }

    #[test]
    #[ignore = "leaves a file in the user's Trash"]
    fn a_replaced_file_goes_to_the_trash_without_asking_finder() {
        let (_dir, service) = with_project();
        let file = service
            .project("P")
            .unwrap()
            .root
            .join("replaced by import.txt");
        fs::write(&file, "old").unwrap();
        projects::discard(&file).unwrap();
        assert!(!file.exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_a_folder_in_the_project_is_a_folder_a_file_goes_into() {
        let (_dir, service) = with_project();
        let root = service.project("P").unwrap().root;
        fs::create_dir(root.join("figs")).unwrap();
        std::os::unix::fs::symlink(root.join("figs"), root.join("link")).unwrap();
        let (rels, taken) = validate(&root, "", ["link/a.png"].into_iter()).unwrap();
        assert!(clashes(&root, &rels, taken).is_empty());

        put(&service, "link/a.png", b"png", false).unwrap();
        assert_eq!(fs::read(root.join("figs/a.png")).unwrap(), b"png");
    }

    #[test]
    fn zip_names_are_read_as_paths_and_none_leaves_the_project() {
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
        ];
        zip_of(&src, &names.map(|name| (name, "x")));
        let info = import_project(&service, &src).unwrap();
        let root = service.data_dir.join(&info.id);
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
    fn a_zip_of_a_folder_brings_all_but_what_an_export_leaves_out() {
        // Into a library folder that doesn't exist yet, as on a first import.
        let dir = tempfile::tempdir().unwrap();
        let service = Service::new(dir.path().join("data"));
        let files = [
            (
                "Thesis/aaa.tex",
                "% \\documentclass{book}\n\\section{Intro}",
            ),
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
        zip_of(&dir.path().join("Thesis.zip"), &files);
        fs::create_dir_all(service.data_dir.join("Thesis")).unwrap();

        // A taken name gets a number, as Finder's copies do.
        let info = import_project(&service, &dir.path().join("Thesis.zip")).unwrap();
        // No main.tex: the first file that starts a document, not in a comment, in settings of
        // its own.
        assert_eq!([info.id, info.main_file], ["Thesis 2", "doc.tex"]);
        let root = service.data_dir.join("Thesis 2");
        assert_eq!(files_in(&root), ["aaa.tex", "doc.tex", "figs/a.png"]);
        // The author's own dotfile comes, though the tree hides it.
        let latexmkrc = fs::read_to_string(root.join(".latexmkrc")).unwrap();
        assert_eq!(latexmkrc, "$pdf_mode = 1;");
        for left in [".git", "build", "figs/.DS_Store"] {
            assert!(!root.join(left).exists(), "{left}");
        }
    }

    #[test]
    fn a_file_comes_alone_with_a_main_file() {
        let (dir, service) = library();
        let src = dir.path().join("Paper");
        write_all(
            &src,
            &[
                ("main.tex", "\\documentclass{article}"),
                ("paper.tex", "\\documentclass{article}\\input{chapters/a}"),
                ("-draft.tex", "\\documentclass{article}"),
                ("refs.bib", "@book{k,}"),
            ],
        );
        for (file, main, files) in [
            ("paper.tex", "paper.tex", &["paper.tex"][..]),
            // One whose name latexmk would read as an option comes but isn't the main file.
            ("-draft.tex", "main.tex", &["-draft.tex", "main.tex"]),
            // Any other file comes with the blank template's main file.
            ("refs.bib", "main.tex", &["main.tex", "refs.bib"]),
        ] {
            let info = import_project(&service, &src.join(file)).unwrap();
            assert_eq!(info.main_file, main, "{file}");
            assert_eq!(files_in(&service.data_dir.join(&info.id)), files, "{file}");
        }
    }

    #[test]
    fn the_settings_guessed_are_what_a_tex_names_else_the_engine_its_packages_need() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("Book");
        write_all(&src, &[("parts/book.tex", "\\documentclass{book}")]);
        fs::write(dir.path().join("main.tex"), "\\documentclass{book}").unwrap();
        for (chapter_head, main, engine) in [
            (
                "%!TEX TS-program = LuaLaTeX\n% !TeX root = parts/../parts/book.tex\n",
                "parts/book.tex",
                Some("lualatex"),
            ),
            // A root outside the folder, or not there, is ignored; the program still holds.
            (
                "% !TEX root = ../main.tex\n% !tex program = xelatex\n",
                "chapter.tex",
                Some("xelatex"),
            ),
            ("% !TEX root = gone.tex\n", "chapter.tex", None),
            // Without a program, the packages loaded name the engine they need.
            (
                "\\documentclass{book}\n% \\usepackage{luacode}\n\\usepackage{amsmath, fontspec}\n",
                "chapter.tex",
                Some("xelatex"),
            ),
            (
                "% !TEX program = pdflatex\n\\usepackage{fontspec}\n",
                "chapter.tex",
                Some("pdflatex"),
            ),
        ] {
            let chapter = format!("{chapter_head}\\chapter{{A}}");
            fs::write(src.join("chapter.tex"), chapter).unwrap();
            let settings = guessed_settings(&src, Some("chapter.tex")).unwrap();
            assert_eq!(settings["mainFile"], main);
            assert_eq!(settings.get("engine").and_then(Value::as_str), engine);
        }
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
        zip_of(&src, &[("a.tex", "fine"), ("b.tex", "CORRUPTED-LATER")]);
        let mut bytes = fs::read(&src).unwrap();
        let at = bytes.windows(15).position(|w| w == b"CORRUPTED-LATER");
        bytes[at.unwrap()] = b'X';
        fs::write(&src, bytes).unwrap();
        assert!(import_project(&service, &src).is_err());
        assert_eq!(fs::read_dir(&service.data_dir).unwrap().count(), 0);
    }

    #[test]
    fn a_zip_that_unpacks_past_a_gigabyte_makes_no_project() {
        let (dir, service) = library();
        let src = dir.path().join("large.zip");
        zip_of(&src, &[("main.tex", "x")]);
        // Its central directory's uncompressed size, which a reader goes by, made 2 GB.
        let mut bytes = fs::read(&src).unwrap();
        let header = bytes.windows(4).position(|w| w == b"PK\x01\x02").unwrap();
        bytes[header + 24..header + 28].copy_from_slice(&(2u32 << 30).to_le_bytes());
        fs::write(&src, bytes).unwrap();
        let err = import_project(&service, &src).unwrap_err();
        assert_eq!((err.status, err.message.as_str()), (400, TOO_LARGE));
        assert_eq!(fs::read_dir(&service.data_dir).unwrap().count(), 0);
    }

    #[test]
    fn dropped_files_and_folders_import_into_the_project() {
        let (dir, service) = with_project();
        let drop = dir.path().join("drop");
        write_all(
            &drop,
            &[
                ("figs/a.png", "a"),
                ("figs/sub/b.png", "b"),
                ("notes.tex", "n"),
            ],
        );

        let paths = [drop.join("figs"), drop.join("notes.tex")];
        import_files(&service, "P", "in", &paths, None, remove).unwrap();
        let root = service.data_dir.join("P/in");
        let files = ["figs/a.png", "figs/sub/b.png", "notes.tex"];
        assert_eq!(files_in(&root), files);
        assert_eq!(fs::read(root.join("figs/sub/b.png")).unwrap(), b"b");

        // A path that isn't there is named.
        let gone = [drop.join("gone.png")];
        let err = import_files(&service, "P", "", &gone, None, remove).unwrap_err();
        assert_eq!(err.status, 404);
        assert!(err.message.contains("gone.png"), "{}", err.message);
    }

    #[test]
    fn a_drop_onto_existing_files_asks_first_and_can_keep_both_and_a_dropped_link_is_followed() {
        let (dir, service) = with_project();
        let drop = dir.path().join("drop");
        let dropped = [
            ("figs/.git/HEAD", "ref"),
            ("figs/.DS_Store", "x"),
            ("figs/a.png", "a"),
            ("main.tex", "new"),
        ];
        write_all(&drop, &dropped);
        let paths = [drop.join("figs"), drop.join("main.tex")];

        // Without an answer nothing is written; the clash is reported.
        let asked = json!(import_files(&service, "P", "", &paths, None, remove).unwrap());
        let clash = json!({ "path": "main.tex", "keepBoth": "main 2.tex" });
        assert_eq!(asked, json!({ "existing": [clash] }));
        let root = service.data_dir.join("P");
        assert_eq!(files_in(&root), ["main.tex"]);
        let original = fs::read(root.join("main.tex")).unwrap();

        import_files(&service, "P", "", &paths, Some(Conflict::KeepBoth), remove).unwrap();
        assert_eq!(files_in(&root), ["figs/a.png", "main 2.tex", "main.tex"]);
        assert_eq!(fs::read(root.join("main.tex")).unwrap(), original);
        assert_eq!(fs::read(root.join("main 2.tex")).unwrap(), b"new");
        // Litter inside a dropped folder stays behind.
        assert!(!root.join("figs/.git").exists() && !root.join("figs/.DS_Store").exists());

        // A dropped link names what it points at; links inside a folder are left.
        #[cfg(unix)]
        {
            let plot = dir.path().join("elsewhere/plot.png");
            write_all(
                dir.path(),
                &[
                    ("elsewhere/plot.png", "p"),
                    ("linked-drop/pics/real.png", "r"),
                ],
            );
            let drop = dir.path().join("linked-drop");
            std::os::unix::fs::symlink(&plot, drop.join("plot-link.png")).unwrap();
            std::os::unix::fs::symlink(&plot, drop.join("pics/inner.png")).unwrap();
            let paths = [drop.join("plot-link.png"), drop.join("pics")];
            import_files(&service, "P", "", &paths, None, remove).unwrap();
            assert!(root.join("pics/real.png").is_file() && !root.join("pics/inner.png").exists());
            assert_eq!(fs::read(root.join("plot-link.png")).unwrap(), b"p");
        }
    }

    #[test]
    fn a_duplicate_leaves_the_build_and_history_keeps_the_settings_and_takes_a_free_name() {
        let (dir, service) = with_project();
        let root = service.data_dir.join("P");
        write_all(
            &root,
            &[
                ("chapters/a.tex", "a"),
                (".latexmkrc", "$pdf_mode = 1;"),
                ("build/main.pdf", "output"),
                (".texlocal-history/snapshots/1.json", "{}"),
            ],
        );
        write_settings(&root.join(SETTINGS_FILE), &json!({ "engine": "xelatex" })).unwrap();

        assert_eq!(
            duplicate_project(&service, "P", "P copy").unwrap().id,
            "P copy"
        );
        let copy = service.data_dir.join("P copy");
        assert_eq!(files_in(&copy), ["chapters/a.tex", "main.tex"]);
        assert!(copy.join(".latexmkrc").is_file());
        for left in ["build", crate::HISTORY_DIR] {
            assert!(!copy.join(left).exists(), "{left}");
        }
        let engine = crate::settings::read_settings(&copy.join(SETTINGS_FILE)).engine;
        assert_eq!(engine, crate::settings::Engine::Xelatex);
        assert_eq!(
            duplicate_project(&service, "P", "P copy").unwrap().id,
            "P copy 2"
        );

        let folder = dir.path().join("Elsewhere");
        write_all(&folder, &[("main.tex", "\\documentclass{article}")]);
        let opened = projects::open_path(&service, &folder).unwrap().project.id;
        let refused = duplicate_project(&service, &opened, "Elsewhere copy").unwrap_err();
        assert_eq!(refused.status, 409);

        // A link to a file, as to a shared .bib, is copied as what it points at.
        #[cfg(unix)]
        {
            let shared = dir.path().join("shared.bib");
            fs::write(&shared, "@book{k,}").unwrap();
            std::os::unix::fs::symlink(&shared, root.join("refs.bib")).unwrap();
            let linked = duplicate_project(&service, "P", "Linked").unwrap().id;
            let bib = fs::read(service.data_dir.join(linked).join("refs.bib"));
            assert_eq!(bib.unwrap(), b"@book{k,}");
        }
    }
}
