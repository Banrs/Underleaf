use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::SETTINGS_FILE;
use crate::error::CoreError;
use crate::paths::{Project, fold_case, in_build_dir, safe_rel_file};
use crate::projects::{is_litter, walk};
use crate::settings::{Engine, granted, read_settings};

pub fn export_zip(root: &Path, dest: &Path, added: &[(String, Vec<u8>)]) -> Result<(), CoreError> {
    let file = File::create(dest).map_err(CoreError::at(dest))?;
    let replaced = |rel: &str| added.iter().any(|(path, _)| path.eq_ignore_ascii_case(rel));
    let mut writer = ZipWriter::new(file);
    walk(
        root,
        &|rel| !left_out(rel) && !replaced(rel),
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
    for (rel, bytes) in added {
        writer.start_file(rel, options(Ok(SystemTime::now())))?;
        writer.write_all(bytes)?;
    }
    writer.finish()?.sync_all()?;
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
pub(crate) fn for_arxiv(project: &Project) -> Result<Vec<(String, Vec<u8>)>, CoreError> {
    let settings = read_settings(&project.settings);
    if granted(project) {
        return Err(CoreError::conflict(
            "arXiv compiles without shell escape. Turn Shell Escape off for this project, check that it still compiles, then export again.",
        ));
    }
    if settings.engine == Engine::Lualatex {
        return Err(CoreError::conflict(
            "arXiv doesn't compile with LuaLaTeX. Choose pdfLaTeX or XeLaTeX for this project, check that it still compiles, then export again.",
        ));
    }
    let main = safe_rel_file(&settings.main_file)?;
    let readme = json!({
        "spec_version": 1,
        "process": { "compiler": settings.engine },
        "sources": [{ "filename": main, "usage": "toplevel" }],
    });
    let readme = serde_json::to_vec_pretty(&readme).expect("JSON from JSON");
    let mut added = vec![("00README.json".to_owned(), readme)];
    let stem = Path::new(&main)
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy();
    for ext in ["ind", "gls", "acr", "nls", "glstex"] {
        match fs::read(settings.output(&project.build, ext)?) {
            Ok(bytes) => added.push((format!("{stem}.{ext}"), bytes)),
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => return Err(err.into()),
        }
    }
    Ok(added)
}

pub(crate) fn left_out(rel: &str) -> bool {
    in_build_dir(rel) || fold_case(rel) == SETTINGS_FILE || rel.split('/').any(is_litter)
}

fn options(modified: io::Result<SystemTime>) -> SimpleFileOptions {
    fn local(modified: SystemTime) -> Option<zip::DateTime> {
        let secs = modified.duration_since(UNIX_EPOCH).ok()?.as_secs();
        let secs = libc::time_t::try_from(secs).ok()?;
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        if unsafe { libc::localtime_r(&raw const secs, &raw mut tm) }.is_null() {
            return None;
        }
        let field = |value: libc::c_int| u8::try_from(value).ok();
        let year = u16::try_from(tm.tm_year + 1900).ok()?;
        let (month, day) = (field(tm.tm_mon + 1)?, field(tm.tm_mday)?);
        let (hour, minute, second) = (field(tm.tm_hour)?, field(tm.tm_min)?, field(tm.tm_sec)?);
        zip::DateTime::from_date_and_time(year, month, day, hour, minute, second).ok()
    }
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    let date = modified.ok().and_then(local);
    date.map_or(options, |date| options.last_modified_time(date))
}
