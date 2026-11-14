use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use std::time::SystemTime;

use serde_json::json;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::error::CoreError;
use crate::messages;
use crate::paths::{Project, fold_case, relative, safe_rel_file, same_folded};
use crate::projects::{is_litter, real_path, walk};
use crate::settings::{Engine, granted, read_settings};
use crate::{SETTINGS_FILE, atomic, sys};

pub(crate) fn export_zip(project: &Project, dest: &Path, for_arxiv: bool) -> Result<(), CoreError> {
    let added = match for_arxiv {
        true => arxiv_files(project)?,
        false => Vec::new(),
    };
    let folder = dest.parent().unwrap_or(Path::new("."));
    let (file, temp) = atomic::create_temp(folder).map_err(CoreError::at(dest))?;
    let replaced = |rel: &str| added.iter().any(|(path, _)| same_folded(path, rel));
    let own = dest
        .file_name()
        .and_then(|name| relative(&project.root, &real_path(folder).join(name)));
    let mut writer = ZipWriter::new(file);
    walk(
        &project.root,
        &|rel| !left_out(project, rel) && !replaced(rel) && own.as_deref() != Some(rel),
        true,
        &mut |entry| {
            if entry.dir {
                let modified = fs::metadata(&entry.path).and_then(|meta| meta.modified());
                writer.add_directory(format!("{}/", entry.rel), options(modified))?;
            } else {
                match add_file(&mut writer, &entry.rel, &entry.path) {
                    Err(err) if err.kind == crate::ErrorKind::NotFound => {}
                    added => added?,
                }
            }
            Ok(true)
        },
    )?;
    for (rel, bytes) in &added {
        writer.start_file(rel, options(Ok(SystemTime::now())))?;
        writer.write_all(bytes)?;
    }
    writer.finish()?;
    temp.persist(dest)
        .map_err(|err| CoreError::at(dest)(err.error))?;
    Ok(())
}

fn add_file(writer: &mut ZipWriter<File>, rel: &str, path: &Path) -> Result<(), CoreError> {
    let mut file = File::open(path)?;
    let meta = file.metadata()?;
    let options = options(meta.modified()).large_file(meta.len() >= 3 << 30);
    writer.start_file(rel, options)?;
    io::copy(&mut file, writer)?;
    Ok(())
}

fn arxiv_files(project: &Project) -> Result<Vec<(String, Vec<u8>)>, CoreError> {
    let settings = read_settings(&project.settings);
    if granted(project) {
        return Err(CoreError::conflict(messages::arxiv_shell_escape()));
    }
    if settings.engine == Engine::Lualatex {
        return Err(CoreError::conflict(messages::arxiv_lualatex()));
    }
    let main = safe_rel_file(&settings.main_file)?;
    let readme = json!({
        "spec_version": 1,
        "process": { "compiler": settings.engine },
        "sources": [{ "filename": main, "usage": "toplevel" }],
    });
    let readme = serde_json::to_vec_pretty(&readme).expect("JSON from JSON");
    let mut added = vec![("00README.json".to_owned(), readme)];
    for ext in ["ind", "gls", "acr", "nls", "glstex"] {
        let output = settings.output(&project.build, ext)?;
        match fs::read(&output) {
            Ok(bytes) => {
                let name = output.file_name().unwrap_or_default().to_string_lossy();
                added.push((name.into_owned(), bytes));
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => return Err(err.into()),
        }
    }
    Ok(added)
}

pub(crate) fn left_out(project: &Project, rel: &str) -> bool {
    project.builds_in(rel) || private(rel)
}

pub(crate) fn private(rel: &str) -> bool {
    fold_case(rel) == SETTINGS_FILE || rel.split('/').any(is_litter)
}

fn options(modified: io::Result<SystemTime>) -> SimpleFileOptions {
    fn local(modified: SystemTime) -> Option<zip::DateTime> {
        let (year, month, day, hour, minute, second) = sys::local_time(modified)?;
        zip::DateTime::from_date_and_time(year, month, day, hour, minute, second).ok()
    }
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    let date = modified.ok().and_then(local);
    date.map_or(options, |date| options.last_modified_time(date))
}
