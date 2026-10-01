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
    /// The clicked letter's place in the line, in UTF-16 units (the hosts'
    /// strings), when the host sent the word and it was found.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
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
    let (code, stdout) = run(
        "synctex",
        &["view", "-i", &input, "-o", &pdf_str],
        Some(root),
        PROBE_TIMEOUT,
        path_env,
    )
    .await;
    if code != 0 {
        return Err(CoreError::internal("synctex view failed"));
    }
    // The first value reported for each key: synctex lists every match.
    const KEYS: [&str; 7] = ["Page", "x", "y", "h", "v", "W", "H"];
    let mut values = [None; 7];
    for ln in stdout.split('\n') {
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

/// PDF location (page, x, y in TeX points from top-left) -> source file:line,
/// and the column of `word`, the word clicked `offset` in, as `find_word` finds it.
pub async fn synctex_inverse(
    root: &Path,
    page: f64,
    x: f64,
    y: f64,
    word: Option<&str>,
    offset: Option<usize>,
    path_env: &str,
) -> Result<InverseLoc, CoreError> {
    if !(page.is_finite() && x.is_finite() && y.is_finite()) || page < 1.0 {
        return Err(CoreError::bad_request("Invalid PDF location"));
    }
    let pdf = pdf_for(root)?;
    let target = format!("{page}:{x}:{y}:{}", pdf.to_string_lossy());
    let (code, stdout) = run(
        "synctex",
        &["edit", "-o", &target],
        Some(root),
        PROBE_TIMEOUT,
        path_env,
    )
    .await;
    if code != 0 {
        return Err(CoreError::internal("synctex edit failed"));
    }
    let file = stdout
        .split('\n')
        .find_map(|ln| ln.strip_prefix("Input:"))
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let line = stdout
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
        // A project renamed or moved since TeX ran, which latexmk doesn't run
        // again for: TeX wrote "<its old folder>/./<file>".
        .or_else(|| safe_rel_file(root, file.split_once("/./")?.1).ok())
        .ok_or_else(|| CoreError::not_found("No source file at this location"))?;
    if Path::new(&rel).starts_with(BUILD_DIR) || !root.join(&rel).exists() {
        return Err(CoreError::not_found("No source file at this location"));
    }
    let found = word.and_then(|word| {
        let text = crate::lossy_string(std::fs::read(root.join(&rel)).ok()?);
        find_word(&text, line, word, offset.unwrap_or(0))
    });
    let (line, column) = found.map_or((line, None), |(line, column)| (line, Some(column)));
    Ok(InverseLoc {
        file: rel,
        line,
        column,
    })
}

/// The clicked letter of `word`, clicked `offset` UTF-16 units in, found in the
/// source as (line, UTF-16 column). SyncTeX records a line, not always the
/// word's own: TeX may be reading a later one as it sets the text. So the
/// word is looked for a few lines either side too, the nearest match winning,
/// earlier first. PDF text runs together words TeX sets close, and spells
/// ligatures as one letter, so the match ignores the source's spaces and line
/// breaks, and needs a word's ends only at its own. A word hyphenated across
/// lines isn't found.
fn find_word(text: &str, line: u32, word: &str, offset: usize) -> Option<(u32, u32)> {
    const REACH: u32 = 3;
    const LIGATURES: [(char, &str); 5] = [
        ('ﬀ', "ff"),
        ('ﬁ', "fi"),
        ('ﬂ', "fl"),
        ('ﬃ', "ffi"),
        ('ﬄ', "ffl"),
    ];
    // The word's letters, and how many come before the clicked one.
    let (mut letters, mut clicked, mut units) = (Vec::new(), 0, 0);
    for c in word.chars() {
        if units <= offset {
            clicked = letters.len();
        }
        units += c.len_utf16();
        match LIGATURES.iter().find(|(l, _)| *l == c) {
            Some((_, spelt)) => letters.extend(spelt.chars()),
            None if !c.is_whitespace() => letters.push(c),
            None => {}
        }
    }
    // Without the punctuation round it.
    let lead = letters.iter().take_while(|c| !c.is_alphanumeric()).count();
    let end = letters.iter().rposition(|c| c.is_alphanumeric())? + 1;
    let (letters, clicked) = (&letters[lead..end], clicked.clamp(lead, end - 1) - lead);
    // The lines round `line` as (line, column, character), each ended by a break.
    let first = line.saturating_sub(REACH).max(1);
    let source: Vec<(u32, u32, char)> = text
        .lines()
        .zip(1..)
        .skip(first as usize - 1)
        .take_while(|&(_, n)| n <= line + REACH)
        .flat_map(|(text, n)| {
            text.chars().chain(['\n']).scan(0, move |at, c| {
                *at += c.len_utf16() as u32;
                Some((n, *at - c.len_utf16() as u32, c))
            })
        })
        .collect();
    let printed: Vec<usize> = (0..source.len())
        .filter(|&i| !source[i].2.is_whitespace())
        .collect();
    (0..=printed.len().checked_sub(letters.len())?)
        .filter(|&k| {
            let (from, to) = (printed[k], printed[k + letters.len() - 1]);
            printed[k..k + letters.len()].iter().map(|&i| source[i].2).eq(letters.iter().copied())
                // Not part of a longer word, nor a command's name.
                && (from == 0 || !(source[from - 1].2.is_alphanumeric() || source[from - 1].2 == '\\'))
                && !source.get(to + 1).is_some_and(|c| c.2.is_alphanumeric())
        })
        .map(|k| source[printed[k + clicked]])
        .min_by_key(|&(n, _, _)| (n.abs_diff(line), n > line))
        .map(|(n, column, _)| (n, column))
}
