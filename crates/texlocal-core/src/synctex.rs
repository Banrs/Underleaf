//! SyncTeX queries, ported from server/compile.js.

use std::path::Path;

use serde::Serialize;

use crate::compile::{run, PROBE_TIMEOUT};
use crate::error::CoreError;
use crate::paths::{rel_to_root, safe_rel_file};
use crate::settings::compiled_pdf_path;
use crate::BUILD_DIR;

#[derive(Debug, Serialize)]
pub struct ForwardLoc {
    pub page: f64,
    pub x: f64,
    pub y: f64,
    pub h: f64,
    pub v: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Serialize)]
pub struct InverseLoc {
    pub file: String,
    pub line: u32,
}

fn pdf_for(root: &Path) -> Result<std::path::PathBuf, CoreError> {
    let pdf = compiled_pdf_path(root)?;
    if !pdf.exists() {
        return Err(CoreError::not_found("No compiled PDF yet"));
    }
    Ok(pdf)
}

/// source (file:line) -> PDF location
pub async fn synctex_forward(
    root: &Path,
    file: &str,
    line: u32,
    path_env: &str,
) -> Result<ForwardLoc, CoreError> {
    let pdf = pdf_for(root)?;
    // synctex expects the input path as TeX saw it (relative to cwd,
    // ./-prefixed, forward slashes).
    let rel = safe_rel_file(root, file)?;
    if line < 1 {
        return Err(CoreError::bad_request("Invalid source line"));
    }
    let input = format!("{line}:1:./{rel}");
    let pdf_str = pdf.to_string_lossy().into_owned();
    let out = run(
        "synctex",
        &["view", "-i", &input, "-o", &pdf_str],
        Some(root),
        PROBE_TIMEOUT,
        path_env,
    )
    .await;
    if out.code != 0 {
        return Err(CoreError::internal("synctex view failed"));
    }
    let mut page = None;
    let mut x = None;
    let mut y = None;
    let mut h = None;
    let mut v = None;
    let mut w = None;
    let mut hh = None;
    for ln in out.stdout.split('\n') {
        let Some((key, value)) = ln.split_once(':') else {
            continue;
        };
        let slot = match key {
            "Page" => &mut page,
            "x" => &mut x,
            "y" => &mut y,
            "h" => &mut h,
            "v" => &mut v,
            "W" => &mut w,
            "H" => &mut hh,
            _ => continue,
        };
        if slot.is_none() {
            *slot = value.trim().parse::<f64>().ok();
        }
    }
    let page = page.ok_or_else(|| CoreError::not_found("No SyncTeX match"))?;
    Ok(ForwardLoc {
        page,
        x: x.unwrap_or(0.0),
        y: y.unwrap_or(0.0),
        h: h.unwrap_or(0.0),
        v: v.unwrap_or(0.0),
        width: w.unwrap_or(0.0),
        height: hh.unwrap_or(0.0),
    })
}

/// PDF location (page, x, y in TeX points from top-left) -> source file:line
pub async fn synctex_inverse(
    root: &Path,
    page: f64,
    x: f64,
    y: f64,
    path_env: &str,
) -> Result<InverseLoc, CoreError> {
    if !(page.is_finite() && x.is_finite() && y.is_finite()) || page < 1.0 {
        return Err(CoreError::bad_request("Invalid PDF location"));
    }
    let pdf = pdf_for(root)?;
    let target = format!("{page}:{x}:{y}:{}", pdf.to_string_lossy());
    let out = run(
        "synctex",
        &["edit", "-o", &target],
        Some(root),
        PROBE_TIMEOUT,
        path_env,
    )
    .await;
    if out.code != 0 {
        return Err(CoreError::internal("synctex edit failed"));
    }
    let file = out
        .stdout
        .split('\n')
        .find_map(|ln| ln.strip_prefix("Input:"))
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let line = out
        .stdout
        .split('\n')
        .find_map(|ln| ln.strip_prefix("Line:"))
        .and_then(|s| s.trim().parse::<u32>().ok());
    let (Some(file), Some(line)) = (file, line) else {
        return Err(CoreError::not_found("No SyncTeX match"));
    };

    let abs = if Path::new(file).is_absolute() {
        std::path::PathBuf::from(file)
    } else {
        root.join(file)
    };
    // Generated files (.toc/.aux in the build dir) and anything outside the
    // project aren't real sources — report "no match" so the UI shows a toast.
    let rel = rel_to_root(root, &abs)
        .ok_or_else(|| CoreError::not_found("No source file at this location"))?;
    if rel == BUILD_DIR || rel.starts_with(&format!("{BUILD_DIR}/")) || !root.join(&rel).exists() {
        return Err(CoreError::not_found("No source file at this location"));
    }
    Ok(InverseLoc { file: rel, line })
}
