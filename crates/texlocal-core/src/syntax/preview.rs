//! The maths at the caret, to preview: read by the scanner the spelling and
//! symbols use, so maths in a comment, an escaped dollar or a listing is
//! none, and display maths is paired as TeX pairs it.

use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use super::SourceDocument;
use super::catalog::CATALOG;
use super::scan::{Group, Visit, environment_name};

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

impl SourceDocument {
    /// The maths the caret is in, to preview: the outermost display that
    /// holds it, else the innermost inline maths; or the display it is just
    /// after. None when its close isn't within 20,000 units, or it holds no TeX.
    pub fn math_at(&mut self, caret: u32) -> Option<MathPreview> {
        let (units, caret) = (&self.text.units, caret.min(self.text.len()) as usize);
        let ahead = (caret + AHEAD).min(units.len());
        let mut scanner = self.scans.resume(&self.text, caret, ahead).scanner;
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
