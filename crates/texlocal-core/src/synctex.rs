use std::collections::HashMap;
use std::io::{Error, ErrorKind};
use std::ops::RangeInclusive;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use texlocal_latex::synctex::{Shown, SyncTex};
use texlocal_latex::syntax::{SyncLines, sync_lines};
use texlocal_latex::utf16;
use texlocal_latex::wordmatch::find_in_source;
use tokio::task::JoinHandle;

use crate::error::CoreError;
use crate::messages;
use crate::paths::{Project, disk_spelling, source_rel};
use crate::stamp::Kept;

#[derive(Clone, Debug, PartialEq, Serialize, JsonSchema)]
pub struct ForwardLoc {
    pub page: f64,
    pub h: Option<f64>,
    pub v: Option<f64>,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub matches: Vec<Self>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PageClick {
    text: String,
    at: usize,
}

#[derive(Debug, Serialize, JsonSchema)]
pub struct InverseLoc {
    pub file: String,
    pub line: u32,
    pub column: Option<u32>,
}

fn sync_for(project: &Project, live: Option<&Path>) -> Result<Arc<SyncTex>, CoreError> {
    let pdf = match live {
        Some(live) => live.to_path_buf(),
        None => project
            .built_pdf()
            .ok_or_else(|| CoreError::not_found(messages::no_pdf_yet()))?,
    };
    beside(&pdf).map_err(|_| CoreError::not_found(messages::no_synctex()))
}

/// The SyncTeX file beside a PDF. A build writes it plain, since gzipping it took the engine a sixth as long again on a
/// 400-page book, and an earlier build or another tool may have left a gzipped one: the one written last is the PDF's.
pub(crate) fn synctex_file(pdf: &Path) -> Option<PathBuf> {
    let written = |file: &PathBuf| {
        let meta = std::fs::metadata(file).ok().filter(|meta| meta.is_file())?;
        Some(meta.modified().ok())
    };
    let files = ["synctex.gz", "synctex"].map(|ext| pdf.with_extension(ext));
    let files = files
        .into_iter()
        .filter_map(|file| Some((written(&file)?, file)));
    files
        .max_by_key(|(written, _)| *written)
        .map(|(_, file)| file)
}

static PARSED: Kept<SyncTex> = Kept::new();

fn beside(pdf: &Path) -> std::io::Result<Arc<SyncTex>> {
    let file = synctex_file(pdf).ok_or(ErrorKind::NotFound)?;
    PARSED.get(&file, |file| {
        let bytes = std::fs::read(file)?;
        SyncTex::read(bytes).ok_or_else(|| Error::new(ErrorKind::InvalidData, "not a SyncTeX file"))
    })
}

pub(crate) fn warm(pdf: PathBuf) -> JoinHandle<()> {
    tokio::task::spawn_blocking(move || drop(beside(&pdf)))
}

/// Drops what was parsed for the PDFs in a folder but one, which nothing asks for again once a project closes, a Live
/// Preview ends or a live revision is superseded: a 400-page book's is 62 MB, and four would stay.
pub(crate) fn forget(folder: &Path, but: Option<&Path>) {
    let kept = but.map(|pdf| ["synctex", "synctex.gz"].map(|ext| pdf.with_extension(ext)));
    let kept = kept.as_ref().map_or(&[][..], |kept| kept);
    PARSED.forget(|file| file.starts_with(folder) && !kept.iter().any(|kept| kept == file));
}

fn source_file(project: &Project, name: &str) -> Option<String> {
    source_rel(project, name).and_then(|rel| disk_spelling(&project.root, &rel))
}

pub(crate) fn forward(
    project: &Project,
    file: &str,
    lines: &SyncLines,
    live: Option<&Path>,
) -> Result<ForwardLoc, CoreError> {
    let (sync, tag) = tagged(project, file, live)?;
    let mut matches: Vec<_> = (sync.forward(tag, lines).into_iter())
        .filter(|shown| shown.page >= 1)
        .map(located)
        .collect();
    let mut first = matches
        .first()
        .cloned()
        .ok_or_else(|| CoreError::not_found(messages::no_output_here()))?;
    matches.sort_by(|a, b| {
        a.page
            .total_cmp(&b.page)
            .then_with(|| a.v.unwrap_or(0.0).total_cmp(&b.v.unwrap_or(0.0)))
            .then_with(|| a.h.unwrap_or(0.0).total_cmp(&b.h.unwrap_or(0.0)))
    });
    matches.dedup();
    first.matches = matches;
    Ok(first)
}

/// Where lines were typeset on one page, as one box, and how far they run past the width TeX set them to, in points.
pub(crate) type PageArea = (ForwardLoc, f64);

/// Finds where lines of a file were typeset, as one box on each page they're on from the first, reading the SyncTeX
/// file and matching its inputs to the project's files once for every lookup.
pub(crate) fn areas(
    project: &Project,
    live: Option<&Path>,
) -> Result<impl Fn(&str, RangeInclusive<u32>) -> Vec<PageArea> + use<>, CoreError> {
    let sync = sync_for(project, live)?;
    let mut tags = HashMap::new();
    for (tag, name) in sync.inputs() {
        if let Some(file) = source_file(project, name) {
            tags.entry(file).or_insert(tag);
        }
    }
    Ok(move |file: &str, lines| {
        let Some(&tag) = tags.get(file) else {
            return Vec::new();
        };
        let areas = sync.areas(tag, lines).into_iter();
        let shown = areas.filter(|(shown, _)| shown.page >= 1);
        shown
            .map(|(shown, over)| (located(shown), f64::from(over)))
            .collect()
    })
}

fn tagged(
    project: &Project,
    file: &str,
    live: Option<&Path>,
) -> Result<(Arc<SyncTex>, i32), CoreError> {
    let sync = sync_for(project, live)?;
    let tag = sync
        .inputs()
        .find(|(_, name)| source_file(project, name).as_deref() == Some(file))
        .map(|(tag, _)| tag)
        .ok_or_else(|| CoreError::not_found(messages::no_match_in_pdf()))?;
    Ok((sync, tag))
}

fn located(shown: Shown) -> ForwardLoc {
    let finite = |value: f32| Some(f64::from(value)).filter(|value| value.is_finite());
    ForwardLoc {
        page: f64::from(shown.page),
        h: finite(shown.h),
        v: finite(shown.v),
        width: finite(shown.width),
        height: finite(shown.height),
        matches: Vec::new(),
    }
}

pub(crate) fn inverse(
    project: &Project,
    page: f64,
    x: f64,
    y: f64,
    click: Option<PageClick>,
    live: Option<&Path>,
    typeset: &dyn Fn(&str) -> Option<String>,
) -> Result<InverseLoc, CoreError> {
    if !(page.is_finite() && x.is_finite() && y.is_finite()) || page < 1.0 {
        return Err(CoreError::bad_request(messages::invalid_pdf_place()));
    }
    let root = &project.root;
    let sync = sync_for(project, live)?;
    let (name, line) = sync
        .inverse(page as i32, x as f32, y as f32)
        .and_then(|(name, line)| Some((name, u32::try_from(line).ok()?)))
        .ok_or_else(|| CoreError::not_found(messages::no_match_in_source()))?;
    let rel = source_file(project, name)
        .ok_or_else(|| CoreError::not_found(messages::no_source_file()))?;
    let disk = || Some(crate::lossy_string(std::fs::read(root.join(&rel)).ok()?));
    let source = typeset(&rel).or_else(disk);
    if let Some(text) = source.as_deref()
        && let SyncLines::Whole(picture) = sync_lines(text, line)
    {
        let line = *picture.start();
        let begin = text.lines().nth(line as usize - 1).unwrap_or_default();
        let column = begin
            .find("\\begin")
            .map(|byte| utf16::len(&begin[..byte]) as u32);
        return Ok(InverseLoc {
            file: rel,
            line,
            column,
        });
    }
    let found = click
        .and_then(|PageClick { text, at }| find_in_source(source.as_deref()?, line, &text, at));
    Ok(InverseLoc {
        file: rel,
        line: found.map_or(line, |(line, _)| line),
        column: found.map(|(_, column)| column),
    })
}

#[cfg(test)]
mod tests {
    use std::fs::{self, File};
    use std::io::Write;

    use super::*;

    const SYNCTEX: &str = "SyncTeX Version:1\nInput:1:main.tex\nOutput:pdf\nMagnification:1000\nUnit:1\nX Offset:0\nY Offset:0\nContent:\n{1\n[1,3:0,800:600,800,0\n(1,3:100,100:400,10,2\ng1,3:150,100\n)\n]\n}1\nPostamble:\n";

    #[tokio::test]
    async fn a_warmed_synctex_is_not_read_again_while_its_file_is_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let (pdf, file) = (dir.path().join("main.pdf"), dir.path().join("main.synctex"));
        fs::write(&file, SYNCTEX).unwrap();
        let modified = fs::metadata(&file).unwrap().modified().unwrap();
        warm(pdf.clone()).await.unwrap();
        let mut junk = File::options().write(true).open(&file).unwrap();
        junk.write_all(&vec![b'x'; SYNCTEX.len()]).unwrap();
        junk.set_modified(modified).unwrap();
        drop(junk);
        assert_eq!(beside(&pdf).unwrap().inputs().count(), 1);
        forget(dir.path(), Some(&pdf));
        assert_eq!(beside(&pdf).unwrap().inputs().count(), 1);
        forget(dir.path(), None);
        assert!(beside(&pdf).is_err(), "the junk is read");
    }

    #[test]
    fn the_synctex_written_last_is_the_pdfs_and_the_plain_one_when_both_were_written_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let pdf = dir.path().join("main.pdf");
        let (plain, gzipped) = (
            dir.path().join("main.synctex"),
            dir.path().join("main.synctex.gz"),
        );
        assert_eq!(synctex_file(&pdf), None);
        fs::write(&gzipped, "").unwrap();
        assert_eq!(synctex_file(&pdf).as_ref(), Some(&gzipped));
        fs::write(&plain, "").unwrap();
        let written = fs::metadata(&plain).unwrap().modified().unwrap();
        let at = |file: &Path, time| {
            File::options()
                .write(true)
                .open(file)
                .unwrap()
                .set_modified(time)
                .unwrap()
        };
        at(&gzipped, written);
        assert_eq!(synctex_file(&pdf).as_ref(), Some(&plain));
        at(&gzipped, written + std::time::Duration::from_secs(1));
        assert_eq!(synctex_file(&pdf).as_ref(), Some(&gzipped));
        at(&plain, written + std::time::Duration::from_secs(2));
        assert_eq!(synctex_file(&pdf).as_ref(), Some(&plain));
    }
}
