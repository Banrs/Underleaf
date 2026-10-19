//! The maths at the caret, to preview: read by the scanner the spelling and
//! symbols use, so maths in a comment, an escaped dollar or a listing is
//! none, and display maths is paired as TeX pairs it.

use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use super::Text;
use super::catalog::CATALOG;
use super::scan::{Group, Visit, environment_name};
use super::scans::Scans;

/// Maths to preview: where it starts, its TeX as KaTeX reads it, and
/// whether it's displayed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct MathPreview {
    pub start: u32,
    pub tex: String,
    pub display: bool,
}

static LABELS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\(?:label|tag)\{[^}]*\}").unwrap());
static NUMBERING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\(?:nonumber|notag)(?-u:\b)").unwrap());

/// How far past the caret its maths' close is looked for.
const AHEAD: usize = 20_000;

/// Displayed maths: $$…$$, \[…\], or an environment the preview renders.
fn display(group: &Group) -> bool {
    matches!(group.end.as_ref(), "$$" | "\\]")
        || environment(group).is_some_and(|name| CATALOG.preview_environments.contains(name))
}

fn inline(group: &Group) -> bool {
    matches!(group.end.as_ref(), "$" | "\\)")
}

/// An environment group's name, without its star.
fn environment(group: &Group) -> Option<&str> {
    let name = group.end.strip_prefix("env:")?;
    Some(name.strip_suffix('*').unwrap_or(name))
}

/// The close a scan meets of the maths opened at `open`, or without one, of
/// displayed maths whose close ends at `at`.
struct Close {
    open: Option<usize>,
    at: usize,
    found: Option<(Group, Range<usize>)>,
}

impl Visit for Close {
    fn closed(&mut self, group: &Group, close: Range<usize>) {
        let wanted = match self.open {
            Some(open) => group.open == open,
            None => close.end == self.at && display(group),
        };
        if wanted && self.found.is_none() {
            self.found = Some((group.clone(), close));
        }
    }
}

/// The maths the caret is in: the outermost display that holds it, else the
/// innermost inline maths; or the display it is just after. None when its
/// close isn't within 20,000 units, or it holds no TeX.
pub(crate) fn math_at(text: &Text, scans: &mut Scans, caret: u32) -> Option<MathPreview> {
    let (units, caret) = (&text.units, caret as usize);
    let ahead = (caret + AHEAD).min(units.len());
    let mut scanner = scans.resume(text, caret, ahead).scanner;
    let mut close = Close {
        open: None,
        at: caret,
        found: None,
    };
    scanner.run(units, caret, &[], &mut close);
    let groups = scanner.groups();
    let open = groups.iter().find(|g| display(g));
    if let Some(group) = open.or_else(|| groups.iter().rev().find(|g| inline(g))) {
        close = Close {
            open: Some(group.open),
            at: caret,
            found: None,
        };
        // In steps, to stop at the close.
        while close.found.is_none() && scanner.i < ahead {
            scanner.run(units, (scanner.i + 1024).min(ahead), &[], &mut close);
        }
    }
    let (group, close) = close.found?;
    let body = match group.end.as_ref() {
        "$" => group.open + 1,
        "$$" | "\\)" | "\\]" => group.open + 2,
        _ => environment_name(units, group.open + "\\begin".len())?.1,
    };
    let tex = preview_tex(
        environment(&group),
        &crate::utf16_lossy(&units[body..close.start]),
    );
    (!tex.is_empty()).then(|| MathPreview {
        start: group.open as u32,
        tex,
        display: display(&group),
    })
}

/// What KaTeX shows of maths: no labels or numbering, and an environment's
/// body as the aligned or cases block it can render.
fn preview_tex(environment: Option<&str>, body: &str) -> String {
    let body = LABELS.replace_all(body, "");
    let body = NUMBERING.replace_all(&body, "");
    let clean = body.trim();
    let environment = match environment {
        None | Some("equation" | "multline") => return clean.to_string(),
        Some("cases") => "cases",
        Some("gather") => "gathered",
        Some(_) => "aligned",
    };
    format!("\\begin{{{environment}}}{clean}\\end{{{environment}}}")
}

#[cfg(test)]
mod tests {
    use crate::syntax::SourceDocument;

    /// The maths previewed at "|", as its start and TeX, "" for none.
    fn preview(marked: &str) -> (u32, String) {
        let at = marked.find('|').unwrap();
        let mut doc = SourceDocument::new(&marked.replacen('|', "", 1));
        let found = doc.math_at(at as u32);
        found.map_or((0, String::new()), |m| (m.start, m.tex))
    }

    #[test]
    fn maths_is_what_the_scanner_reads_as_maths() {
        // Not in a comment, nor between escaped dollars, nor in a listing.
        assert_eq!(preview("% costs $5 and $|6"), (0, String::new()));
        assert_eq!(preview("\\$5 and \\$|6"), (0, String::new()));
        let listing = "\\begin{lstlisting}\n$ make |all $\n\\end{lstlisting}";
        assert_eq!(preview(listing), (0, String::new()));
        // A display block the read starts within pairs as ever: the caret
        // between two is in prose.
        let between = format!("{}$$ a $$ prose| $$ b $$", "x ".repeat(15_000));
        assert_eq!(preview(&between), (0, String::new()));
        // Inline maths may wrap onto the next line, as TeX reads it.
        assert_eq!(preview("$a\n|b$"), (0, "a\nb".into()));
        assert_eq!(preview("\\(x|\\)"), (0, "x".into()));
        // An unclosed $$ while typing goes no further than its paragraph.
        assert_eq!(preview("$$ x|\n\nprose $$ y $$"), (0, String::new()));
    }
}
