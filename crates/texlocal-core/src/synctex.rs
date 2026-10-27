use std::io::{Error, ErrorKind};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use texlocal_latex::synctex::SyncTex;
use texlocal_latex::wordmatch::{PdfHit, PdfPage, find_in_pdf, find_in_source};

use crate::error::CoreError;
use crate::paths::{Project, disk_spelling, safe_path, safe_rel_file, source_rel};
use crate::settings::read_settings;
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

fn pdf_for(project: &Project, live: Option<&Path>) -> Result<PathBuf, CoreError> {
    if let Some(live) = live {
        return Ok(live.to_path_buf());
    }
    Some(read_settings(&project.settings).output(&project.build, "pdf")?)
        .filter(|pdf| pdf.exists())
        .ok_or_else(|| CoreError::not_found("No compiled PDF yet"))
}

fn sync_for(project: &Project, live: Option<&Path>) -> Result<Arc<SyncTex>, CoreError> {
    beside(&pdf_for(project, live)?)
        .map_err(|_| CoreError::not_found("This PDF has no SyncTeX: compile it again."))
}

fn beside(pdf: &Path) -> std::io::Result<Arc<SyncTex>> {
    static PARSED: Kept<SyncTex> = Kept::new();
    let plain = pdf.with_extension("synctex");
    let file = if plain.is_file() {
        plain
    } else {
        plain.with_extension("synctex.gz")
    };
    PARSED.get(&file, |file| {
        let bytes = std::fs::read(file)?;
        SyncTex::read(bytes).ok_or_else(|| Error::new(ErrorKind::InvalidData, "not a SyncTeX file"))
    })
}

fn source_file(root: &Path, name: &str) -> Option<String> {
    source_rel(root, name).and_then(|rel| disk_spelling(root, &rel))
}

pub fn synctex_forward_at(
    project: &Project,
    file: &str,
    line: u32,
    live: Option<&Path>,
) -> Result<ForwardLoc, CoreError> {
    let rel = safe_rel_file(file)?;
    if line < 1 {
        return Err(CoreError::bad_request("Invalid source line"));
    }
    let sync = sync_for(project, live)?;
    let tag = sync
        .inputs()
        .find(|(_, name)| source_file(&project.root, name).as_deref() == Some(rel.as_str()))
        .map(|(tag, _)| tag);
    let line = i32::try_from(line).unwrap_or(i32::MAX);
    let finite = |value: f32| Some(f64::from(value)).filter(|value| value.is_finite());
    let mut matches: Vec<_> = tag
        .map(|tag| sync.forward(tag, line))
        .unwrap_or_default()
        .into_iter()
        .filter(|shown| shown.page >= 1)
        .map(|shown| ForwardLoc {
            page: f64::from(shown.page),
            h: finite(shown.h),
            v: finite(shown.v),
            width: finite(shown.width),
            height: finite(shown.height),
            matches: Vec::new(),
        })
        .collect();
    let mut first = matches
        .first()
        .cloned()
        .ok_or_else(|| CoreError::not_found("Nothing in the PDF matches this line."))?;
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

pub fn synctex_inverse(
    project: &Project,
    page: f64,
    x: f64,
    y: f64,
    click: Option<PageClick>,
    live: Option<&Path>,
    typeset: &dyn Fn(&str) -> Option<String>,
) -> Result<InverseLoc, CoreError> {
    if !(page.is_finite() && x.is_finite() && y.is_finite()) || page < 1.0 {
        return Err(CoreError::bad_request("Invalid PDF location"));
    }
    let root = &project.root;
    let sync = sync_for(project, live)?;
    let (name, line) = sync
        .inverse(page as i32, x as f32, y as f32)
        .and_then(|(name, line)| Some((name, u32::try_from(line).ok()?)))
        .ok_or_else(|| CoreError::not_found("Nothing in the source matches this spot."))?;
    let rel = source_file(root, name)
        .ok_or_else(|| CoreError::not_found("No source file at this location"))?;
    let found = click.and_then(|PageClick { text, at }| {
        let disk = || Some(crate::lossy_string(std::fs::read(root.join(&rel)).ok()?));
        let source = typeset(&rel).or_else(disk)?;
        find_in_source(&source, line, &text, at)
    });
    Ok(InverseLoc {
        file: rel,
        line: found.map_or(line, |(line, _)| line),
        column: found.map(|(_, column)| column),
    })
}

pub fn match_forward(
    root: &Path,
    file: &str,
    line: u32,
    column: usize,
    pages: &[PdfPage],
) -> Result<Option<PdfHit>, CoreError> {
    let text = crate::lossy_string(std::fs::read(safe_path(root, file)?)?);
    let line = line
        .checked_sub(1)
        .and_then(|n| text.lines().nth(n as usize));
    Ok(line.and_then(|line| find_in_pdf(line, column, pages)))
}
