//! SyncTeX queries: editor line to PDF position and back, from the SyncTeX TeX writes beside the
//! PDF (`parser`); words are placed by `wordmatch`.

mod parser;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Serialize;

use crate::analyze::disk_spelling;
use crate::error::CoreError;
use crate::paths::{Project, safe_path, safe_rel_file, source_rel};
use crate::settings::read_settings;
use crate::wordmatch::{PdfHit, PdfPage, find_in_pdf, find_in_source};

use parser::SyncTex;

/// Only `page` is always given: the rest are null where SyncTeX has no finite value, for the
/// host to fall back on rather than draw an invisible zero-size box.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ForwardLoc {
    pub page: f64,
    pub h: Option<f64>,
    pub v: Option<f64>,
    pub width: Option<f64>,
    pub height: Option<f64>,
    /// All matching boxes in reading order; the top-level fields keep SyncTeX's first.
    pub matches: Vec<Self>,
}

#[derive(Debug, Serialize)]
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
    SyncTex::beside(&pdf_for(project, live)?)
        .map_err(|_| CoreError::not_found("This PDF has no SyncTeX: compile it again."))
}

/// The project's file TeX opened as `name`, as the disk spells it; generated files and anything
/// outside the project are none.
fn source_file(root: &Path, name: &str) -> Option<String> {
    source_rel(root, name).and_then(|rel| disk_spelling(root, &rel))
}

/// Every box of the line, as some TeX engines record lines but not columns.
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

/// `typeset` gives a file's text where the PDF wasn't made from the disk's, as Live Preview's
/// is from the editor's.
pub fn synctex_inverse(
    project: &Project,
    page: f64,
    x: f64,
    y: f64,
    click: Option<(&str, usize)>,
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
    let found = click.and_then(|(text, at)| {
        let disk = || Some(crate::lossy_string(std::fs::read(root.join(&rel)).ok()?));
        let source = typeset(&rel).or_else(disk)?;
        find_in_source(&source, line, text, at)
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

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;
    use crate::projects::testing::project;

    /// main.tex's line 3 and chapter.tex's line 7, each an hbox of words, on page 1.
    const SYNCTEX: &str = "SyncTeX Version:1
Input:1:{root}/./main.tex
Input:2:{root}/./chapter.tex
Output:pdf
Magnification:1000
Unit:1
X Offset:0
Y Offset:0
Content:
!120
{1
[1,1:4736286,46220574:26673152,41484288,0
(1,3:8799518,8865054:22609920,655359,0
x1,3:9330359,8865054
g1,3:10392041,8865054
x1,3:11377265,8865054
)
(2,7:8799518,10300473:22609920,455111,127431
x2,7:10274081,10300473
g2,7:12000000,10300473
x2,7:14000000,10300473
)
]
}1
";
    const POSTAMBLE: &str = "Postamble:\nCount:12\n!600\nPost scriptum:\n";

    /// Whether `found` is `sp` scaled points, in PDF points.
    fn at(found: Option<f64>, sp: i32) -> bool {
        found.is_some_and(|found| (found - f64::from(sp) / 65781.76).abs() < 1e-3)
    }

    fn setup() -> (tempfile::TempDir, Project, String) {
        let (dir, root) = project();
        std::fs::write(
            root.join("chapter.tex"),
            "\n\n\n\nÜnï words \\word, the\nword next\nfinal\n",
        )
        .unwrap();
        std::fs::create_dir_all(root.join("build")).unwrap();
        std::fs::write(root.join("build/main.pdf"), "a PDF").unwrap();
        let synctex = SYNCTEX.replace("{root}", &root.to_string_lossy());
        (dir, Project::in_folder(&root), synctex)
    }

    #[test]
    fn a_line_and_a_spot_map_both_ways_through_the_zipped_synctex_beside_the_pdf() {
        let (_dir, project, synctex) = setup();
        let file = std::fs::File::create(project.build.join("main.synctex.gz")).unwrap();
        let mut gz = flate2::write::GzEncoder::new(file, flate2::Compression::default());
        gz.write_all(format!("{synctex}{POSTAMBLE}").as_bytes())
            .unwrap();
        gz.finish().unwrap();
        let shown = synctex_forward_at(&project, "chapter.tex", 7, None).unwrap();
        assert_eq!((shown.page, shown.matches.len()), (1.0, 1));
        let (bottom, height) = (10300473 + 127431, 455111 + 127431);
        assert!(at(shown.h, 8799518) && at(shown.v, bottom) && at(shown.height, height));
        // A line with nothing on the page shows the nearest that has something.
        let nearest = synctex_forward_at(&project, "main.tex", 4, None).unwrap();
        assert!(at(nearest.v, 8865054), "{nearest:?}");
        for (click, line, column) in [
            (None, 7, None),
            (Some(("theword", 4)), 6, Some(1)),
            (Some(("absent", 0)), 7, None),
        ] {
            let loc = synctex_inverse(&project, 1.0, 200.0, 155.0, click, None, &|_| None);
            let loc = loc.unwrap();
            assert_eq!(
                (loc.file.as_str(), loc.line, loc.column),
                ("chapter.tex", line, column)
            );
        }
    }

    /// TeX writes the Postamble at the end of its run, which Live Preview's may not have reached.
    #[test]
    fn a_synctex_without_its_postamble_answers_as_far_as_it_goes() {
        let (_dir, project, synctex) = setup();
        let live = project.build.join("live.pdf");
        std::fs::write(&live, "a PDF").unwrap();
        std::fs::write(live.with_extension("synctex"), synctex).unwrap();
        let loc = synctex_inverse(&project, 1.0, 200.0, 135.0, None, Some(&live), &|_| None);
        let loc = loc.unwrap();
        assert_eq!((loc.file.as_str(), loc.line), ("main.tex", 3));
    }

    /// Live Preview's PDF is made from the editor's text, saved or not.
    #[test]
    fn a_click_finds_its_word_in_the_text_the_pdf_was_made_from() {
        let (_dir, project, synctex) = setup();
        std::fs::write(project.build.join("main.synctex"), synctex).unwrap();
        let typeset = |rel: &str| (rel == "chapter.tex").then(|| "\n".repeat(6) + "new edited\n");
        let click = Some(("new edited", 4));
        let loc = synctex_inverse(&project, 1.0, 200.0, 155.0, click, None, &typeset).unwrap();
        assert_eq!((loc.line, loc.column), (7, Some(4)));
    }

    /// A damaged file's values needn't sum within i32 as TeX's do: with boxes, kerns, pages and
    /// lines at i32's ends, queries answer or fail without overflowing.
    #[test]
    fn a_damaged_synctex_answers_without_overflowing() {
        let (_dir, project, _) = setup();
        let damaged = DAMAGED.replace("{root}", &project.root.to_string_lossy());
        std::fs::write(project.build.join("main.synctex"), damaged).unwrap();
        for line in [1, u32::MAX] {
            let _ = synctex_forward_at(&project, "main.tex", line, None);
        }
        let _ = synctex_inverse(&project, 1.0, 0.0, 0.0, None, None, &|_| None);
    }

    const DAMAGED: &str = "SyncTeX Version:1
Input:1:{root}/./main.tex
Output:pdf
Magnification:1000
Unit:1
X Offset:0
Y Offset:0
Content:
{-2147483648
(1,1:0,0:0,0,0
x1,1:0,0
)
}-2147483648
{1
(1,2147483647:0,0:0,2147483647,2147483647
(1,1:2147483647,0:2147483647,2147483647,2147483647
g1,1:2147483647,0
k1,1:-2147483648,0:2147483647
h1,1:2147483647,0:2147483647,2147483647,2147483647
)
)
(1,1:2147483647,0:2147483647,0,0
)
(1,1:0,0:-2147483648,-2147483648,-2147483648
)
(1,1:0,0:-2147483648,-2147483648,-2147483648
)
}1
";
}
