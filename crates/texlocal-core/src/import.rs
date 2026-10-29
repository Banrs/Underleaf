use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufRead, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use texlocal_latex::analyze::{self, Facts};
use texlocal_latex::templates::ProjectTemplate;
use texlocal_latex::{FileKind, file_kind};
use zip::ZipArchive;
use zip::result::ZipError;

use crate::messages;
use crate::paths::{self, after_entry, fold_case, in_folder, normalize_segments, rel_key};
use crate::projects::{self, ProjectInfo, is_litter, walk};
use crate::service::Service;
use crate::settings::{Engine, SettingsPatch, write_settings};
use crate::zipexport::left_out;
use crate::{CoreError, SETTINGS_FILE, atomic};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImportConflict {
    Replace,
    KeepBoth,
}

#[derive(Debug, Serialize, JsonSchema)]
pub struct Imported {
    pub existing: Vec<Clash>,
}

#[derive(Debug, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Clash {
    pub path: String,
    pub keep_both: String,
}

enum Source {
    File(PathBuf),
    Zip(usize),
}

const MAX_UNZIPPED: u64 = 1 << 30;

const ENGINE_PACKAGES: [(Engine, &[&str]); 2] = [
    (
        Engine::Xelatex,
        &[
            "fontspec",
            "unicode-math",
            "polyglossia",
            "xeCJK",
            "mathspec",
        ],
    ),
    (Engine::Lualatex, &["luacode", "luatexja", "luaotfload"]),
];

pub(crate) fn import_files(
    service: &Service,
    id: &str,
    dir: &str,
    paths: &[PathBuf],
    conflict: Option<ImportConflict>,
) -> Result<Imported, CoreError> {
    let mut files = Vec::new();
    for abs in paths {
        let name = abs.file_name().unwrap_or_default().to_string_lossy();
        let meta = fs::metadata(abs).map_err(CoreError::at(abs))?;
        if meta.is_file() {
            files.push((name.into_owned(), abs.clone()));
        } else if meta.is_dir() {
            walk(
                abs,
                &|rel| !rel.split('/').any(is_litter),
                true,
                &mut |entry| {
                    if !entry.dir && !entry.link {
                        files.push((in_folder(&name, &entry.rel), entry.path.clone()));
                    }
                    Ok(true)
                },
            )?;
        }
    }
    let root = service.project(id)?.root;
    let (rels, taken) = validate(&root, dir, files.iter().map(|(path, _)| path.as_str()))?;
    let existing = clashes(&root.join(rel_key(dir).unwrap_or_default()), &rels, taken);
    if conflict.is_none() && !existing.is_empty() {
        return Ok(Imported { existing });
    }
    let replace = conflict == Some(ImportConflict::Replace);
    for (path, source) in files {
        let path = match conflict {
            Some(ImportConflict::KeepBoth) => keep_both(&path, &existing),
            _ => path,
        };
        save(service, id, &root, &in_folder(dir, &path), &source, replace)?;
    }
    Ok(Imported { existing })
}

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
            return Err(CoreError::bad_request(messages::same_place()));
        }
        folders.extend(parents().map(str::to_string));
        rels.push(rel);
    }
    seen.extend(folders);
    Ok((rels, seen))
}

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

fn occupant(base: &Path, rel: &str) -> Option<String> {
    let mut end = 0;
    loop {
        end = rel[end..].find('/').map_or(rel.len(), |i| end + i);
        let abs = base.join(&rel[..end]);
        let meta = fs::symlink_metadata(&abs).ok()?;
        if end == rel.len() || !(meta.is_dir() || abs.is_dir()) {
            return Some(rel[..end].to_string());
        }
        end += 1;
    }
}

fn save(
    service: &Service,
    id: &str,
    root: &Path,
    rel: &str,
    source: &Path,
    replace: bool,
) -> Result<(), CoreError> {
    let abs = paths::safe_write_path(root, rel)?;
    let folder = abs.ancestors().skip(1).find(|dir| dir.is_dir());
    let (mut file, temp) = atomic::create_temp(folder.unwrap_or(root))?;
    let mut origin = File::open(source).map_err(CoreError::at(source))?;
    io::copy(&mut origin, &mut file)?;
    file.sync_all()?;
    drop(file);
    service.with_project(id, |project| {
        let root = &project.root;
        let abs = paths::safe_write_path(root, rel)?;
        if let Some(taken) = occupant(root, &rel_key(rel)?) {
            if !replace {
                return Err(CoreError::conflict(messages::exists_already(taken)));
            }
            projects::discard_replaced(project, &taken)?;
        }
        fs::create_dir_all(abs.parent().unwrap_or(root))?;
        atomic::rename_exclusive(&temp, &abs)?;
        let _ = temp.keep();
        Ok(())
    })
}

struct Opened {
    base: String,
    zip: Option<ZipArchive<File>>,
    files: Vec<(String, Source)>,
    main: Option<String>,
}

impl Opened {
    fn of_zip(base: String, mut zip: ZipArchive<File>) -> Result<Self, CoreError> {
        if zip.len() > projects::MAX_FILES {
            return Err(CoreError::bad_request(messages::zip_too_many_files(&base)));
        }
        let mut files = Vec::new();
        for i in 0..zip.len() {
            let entry = zip.by_index_raw(i)?;
            let name = entry.name().replace('\\', "/");
            let segments = match normalize_segments(&name, messages::path_escapes) {
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

fn open(src: &Path) -> Result<Opened, CoreError> {
    let stem = src
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let ext = src.extension().map(|ext| fold_case(&ext.to_string_lossy()));
    if ext.as_deref() == Some("zip") {
        let file = File::open(src).map_err(CoreError::at(src))?;
        let zip = ZipArchive::new(file).map_err(|err| match err {
            ZipError::Io(err) => CoreError::at(src)(err),
            err => {
                let name = file_name(src);
                CoreError::bad_request(messages::not_a_zip(name, err))
            }
        })?;
        return Opened::of_zip(stem, zip);
    }
    let path = file_name(src);
    if file_kind(&path) != FileKind::Tex {
        return Err(CoreError::bad_request(messages::not_a_project(&path)));
    }
    Ok(Opened {
        base: stem,
        zip: None,
        main: Some(path.clone()),
        files: vec![(path, Source::File(src.to_path_buf()))],
    })
}

pub(crate) fn no_tex(name: &str) -> CoreError {
    CoreError::bad_request(messages::no_tex(name))
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

fn magic_comments(file: &Path) -> (Option<String>, Option<String>) {
    let Ok(file) = File::open(file) else {
        return (None, None);
    };
    let lines = io::BufReader::new(file).lines().take(analyze::MAGIC_LINES);
    analyze::magic_comments(&lines.map_while(Result::ok).collect::<Vec<_>>().join("\n"))
}

pub(crate) fn guessed_settings(
    root: &Path,
    chosen: Option<&str>,
) -> Result<SettingsPatch, CoreError> {
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
    let named = [
        ("xelatex", Engine::Xelatex),
        ("lualatex", Engine::Lualatex),
        ("pdflatex", Engine::Pdflatex),
    ]
    .into_iter()
    .find_map(|(name, engine)| program.contains(name).then_some(engine));
    let engine = named.or_else(|| {
        let facts = Facts::read(&fs::read_to_string(main_path?).ok()?, FileKind::Tex);
        let loads = |names: &[&str]| facts.packages.iter().any(|p| names.contains(&p.as_str()));
        let needed = ENGINE_PACKAGES.into_iter().find(|(_, names)| loads(names));
        needed.map(|(engine, _)| engine)
    });
    Ok(SettingsPatch {
        main_file: main,
        engine,
        ..SettingsPatch::default()
    })
}

pub(crate) fn import_project(service: &Service, src: &Path) -> Result<ProjectInfo, CoreError> {
    let Opened {
        base,
        mut zip,
        mut files,
        main,
    } = open(src)?;
    files.retain(|(path, _)| !left_out(path));
    if !files
        .iter()
        .any(|(path, _)| file_kind(path) == FileKind::Tex)
    {
        return Err(no_tex(&file_name(src)));
    }

    projects::new_project(&service.data_dir, &base, |root| {
        write_files(root, &files, zip.as_mut())?;
        let mut settings = guessed_settings(root, main.as_deref())?;
        if settings.main_file.is_none() {
            let (file, content) = ProjectTemplate::Blank.files()[0];
            fs::write(root.join(file), content)?;
            settings.main_file = Some(file.into());
        }
        write_settings(&root.join(SETTINGS_FILE), &settings)?;
        Ok(())
    })
}

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
            return Err(CoreError::bad_request(messages::zip_too_large()));
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
                let size = entry.size();
                if io::copy(&mut Read::take(&mut entry, size + 1), &mut dest)? > size {
                    return Err(CoreError::bad_request(messages::zip_too_large()));
                }
            }
        }
        dest.flush()?;
    }
    Ok(())
}

pub(crate) fn duplicate_project(
    service: &Service,
    id: &str,
    name: &str,
) -> Result<ProjectInfo, CoreError> {
    if projects::is_opened(id) {
        return Err(CoreError::conflict(messages::opened_not_duplicated()));
    }
    let root = service.project(id)?.root;
    let mut files = Vec::new();
    walk(&root, &|rel| !left_out(rel), true, &mut |entry| {
        if !entry.dir {
            files.push((entry.rel.clone(), Source::File(entry.path.clone())));
        }
        Ok(true)
    })?;
    projects::new_project(&service.data_dir, name, |copy| {
        write_files(copy, &files, None)?;
        match fs::copy(root.join(SETTINGS_FILE), copy.join(SETTINGS_FILE)) {
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            copied => Ok(copied.map(drop)?),
        }
    })
}
