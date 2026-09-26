//! SyncTeX queries: editor line to PDF position, and back.

use std::path::Path;

use serde::Serialize;

use crate::compile::{run, PROBE_TIMEOUT};
use crate::error::CoreError;
use crate::paths::{rel_to_root, safe_rel_file};
use crate::settings::compiled_pdf_path;
use crate::BUILD_DIR;

/// Only `page` is required. The rest are omitted when synctex didn't report
/// them, because the PDF viewer falls back with `??` — which fires on an
/// absent field but not on a zero, and a zero-size highlight is invisible.
#[derive(Debug, Serialize)]
pub struct ForwardLoc {
    pub page: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub h: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub v: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<f64>,
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
    // The first value reported for each key: synctex lists every match.
    const KEYS: [&str; 7] = ["Page", "x", "y", "h", "v", "W", "H"];
    let mut values = [None; 7];
    for ln in out.stdout.split('\n') {
        let Some((key, value)) = ln.split_once(':') else {
            continue;
        };
        if let Some(i) = KEYS.iter().position(|k| *k == key) {
            values[i] = values[i].or_else(|| value.trim().parse::<f64>().ok());
        }
    }
    let [page, x, y, h, v, width, height] = values;
    let page = page.ok_or_else(|| CoreError::not_found("No SyncTeX match"))?;
    Ok(ForwardLoc {
        page,
        x,
        y,
        h,
        v,
        width,
        height,
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

    // join keeps an absolute `file` as it is.
    let abs = root.join(file);
    // Generated files (.toc/.aux in the build dir) and anything outside the
    // project aren't real sources — report "no match" so the UI shows a toast.
    // TeX records the input under the working directory as getcwd reported
    // it, with symlinks resolved. A data dir reached through a link (/tmp on
    // macOS, a library moved to another disk and linked back) therefore names
    // the project by its real path, not the one `root` spells.
    let rel = rel_to_root(root, &abs)
        .or_else(|| rel_to_root(&std::fs::canonicalize(root).ok()?, &abs))
        .ok_or_else(|| CoreError::not_found("No source file at this location"))?;
    if Path::new(&rel).starts_with(BUILD_DIR) || !root.join(&rel).exists() {
        return Err(CoreError::not_found("No source file at this location"));
    }
    Ok(InverseLoc { file: rel, line })
}
