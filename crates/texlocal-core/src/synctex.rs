//! SyncTeX queries: editor line to PDF position and back; words are placed by `wordmatch`.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::analyze::disk_spelling;
use crate::error::CoreError;
use crate::paths::{safe_path, safe_rel_file, source_rel};
use crate::process::run;
use crate::settings::read_settings;
use crate::wordmatch::{PdfHit, PdfPage, find_in_pdf, find_in_source};

/// Only `page` is always given: the rest are null where synctex reported none,
/// for the host to fall back on rather than draw an invisible zero-size box.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ForwardLoc {
    pub page: f64,
    pub h: Option<f64>,
    pub v: Option<f64>,
    pub width: Option<f64>,
    pub height: Option<f64>,
    /// All matching boxes in reading order; the top-level fields keep the CLI's first match.
    pub matches: Vec<Self>,
}

#[derive(Debug, Serialize)]
pub struct InverseLoc {
    pub file: String,
    pub line: u32,
    pub column: Option<u32>,
}

fn pdf_for(root: &Path, live: Option<&Path>) -> Result<PathBuf, CoreError> {
    if let Some(live) = live {
        return Ok(live.to_path_buf());
    }
    let pdf = read_settings(root).output(root, "pdf")?;
    if !pdf.exists() {
        return Err(CoreError::not_found("No compiled PDF yet"));
    }
    Ok(pdf)
}

async fn synctex(root: &Path, args: &[&str], path_env: &str) -> Result<String, CoreError> {
    match run("synctex", args, Some(root), path_env).await {
        Ok((0, stdout)) => Ok(stdout),
        Ok(_) => Err(CoreError::internal(format!("synctex {} failed", args[0]))),
        // TeX's own program, which a TeX install brings: not a fault to report as one.
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Err(CoreError::not_found(
            "SyncTeX is not available: TeX's synctex program was not found.",
        )),
        Err(err) => Err(CoreError::internal(format!(
            "Couldn't start synctex: {err}"
        ))),
    }
}

/// The optional column is zero-based, as in an inverse result. Some TeX
/// engines only record lines, so retain every box even when given a column.
pub async fn synctex_forward_at(
    root: &Path,
    file: &str,
    line: u32,
    column: Option<u32>,
    live: Option<&Path>,
    path_env: &str,
) -> Result<ForwardLoc, CoreError> {
    let pdf = pdf_for(root, live)?;
    // synctex wants the input path as TeX saw it: ./-prefixed, forward slashes.
    let rel = safe_rel_file(file)?;
    if line < 1 {
        return Err(CoreError::bad_request("Invalid source line"));
    }
    let column = column.unwrap_or(0).saturating_add(1);
    let input = format!("{line}:{column}:./{rel}");
    let args: [&str; 5] = ["view", "-i", &input, "-o", &pdf.to_string_lossy()];
    parse_forward(&synctex(root, &args, path_env).await?)
}

fn parse_forward(stdout: &str) -> Result<ForwardLoc, CoreError> {
    const KEYS: [&str; 5] = ["Page", "h", "v", "W", "H"];
    let mut matches = Vec::new();
    let mut values = [None; 5];
    let mut finish = |[page, h, v, width, height]: [Option<f64>; 5]| {
        if let Some(page) = page.filter(|page| *page >= 1.0) {
            matches.push(ForwardLoc {
                page,
                h,
                v,
                width,
                height,
                matches: Vec::new(),
            });
        }
    };
    for (key, value) in stdout.split('\n').filter_map(|ln| ln.split_once(':')) {
        if let Some(i) = KEYS.iter().position(|k| *k == key) {
            if i == 0 {
                finish(std::mem::take(&mut values));
            }
            values[i] = value.trim().parse().ok().filter(|v: &f64| v.is_finite());
        }
    }
    finish(values);
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

pub async fn synctex_inverse(
    root: &Path,
    page: f64,
    x: f64,
    y: f64,
    click: Option<(&str, usize)>,
    live: Option<&Path>,
    path_env: &str,
) -> Result<InverseLoc, CoreError> {
    if !(page.is_finite() && x.is_finite() && y.is_finite()) || page < 1.0 {
        return Err(CoreError::bad_request("Invalid PDF location"));
    }
    let pdf = pdf_for(root, live)?;
    let target = format!("{page}:{x}:{y}:{}", pdf.to_string_lossy());
    let stdout = synctex(root, &["edit", "-o", &target], path_env).await?;
    let field = |key: &str| stdout.split('\n').find_map(|ln| ln.strip_prefix(key));
    let file = field("Input:").map(str::trim).filter(|s| !s.is_empty());
    let line = field("Line:").and_then(|s| s.trim().parse::<u32>().ok());
    let (Some(file), Some(line)) = (file, line) else {
        return Err(CoreError::not_found(
            "Nothing in the source matches this spot.",
        ));
    };

    // Generated files and anything outside the project report no match.
    let rel = source_rel(root, file)
        .and_then(|rel| disk_spelling(root, &rel))
        .ok_or_else(|| CoreError::not_found("No source file at this location"))?;
    let found = click.and_then(|(text, at)| {
        let source = crate::lossy_string(std::fs::read(root.join(&rel)).ok()?);
        find_in_source(&source, line, text, at)
    });
    let (line, column) = found.map_or((line, None), |(line, column)| (line, Some(column)));
    Ok(InverseLoc {
        file: rel,
        line,
        column,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn sync_without_a_synctex_program_says_it_is_not_available() {
        let pdf = Some(Path::new("live.pdf"));
        let err = synctex_inverse(Path::new("P"), 1.0, 1.0, 1.0, None, pdf, "/none").await;
        let err = err.unwrap_err();
        assert_eq!(err.status, 404);
        assert!(err.message.contains("not available"), "{err}");
    }

    #[test]
    fn forward_keeps_all_boxes_in_page_order_without_changing_the_legacy_match() {
        let output = "Page:2\nh:10\nv:80\nW:100\nH:9\nPage:1\nh:10\nv:60\nW:100\nH:9\nPage:2\nh:10\nv:40\nW:100\nH:9\nPage:2\nh:10\nv:40\nW:100\nH:9\n";
        let result = parse_forward(output).unwrap();
        assert_eq!((result.page, result.v), (2.0, Some(80.0)));
        let boxes: Vec<_> = result.matches.iter().map(|r| (r.page, r.v)).collect();
        assert_eq!(
            boxes,
            [(1.0, Some(60.0)), (2.0, Some(40.0)), (2.0, Some(80.0))]
        );
        assert!(result.matches.iter().all(|r| r.matches.is_empty()));
    }
}
