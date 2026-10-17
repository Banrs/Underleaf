//! SyncTeX queries: editor line to PDF position, and back. SyncTeX's boxes
//! are coarse, so a word is placed by matching the text round it (`Letters`).

use std::cmp::{Ordering, Reverse};
use std::ops::Range;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::BUILD_DIR;
use crate::compile::{PROBE_TIMEOUT, run};
use crate::error::CoreError;
use crate::paths::{rel_to_root, safe_path, safe_rel_file};
use crate::settings::compiled_pdf_path;
use crate::syntax::headings::uncommented;

/// Only `page` is required. The rest are omitted when synctex didn't report
/// them, because the PDF viewer falls back with `??` — which fires on an
/// absent field but not on a zero, and a zero-size highlight is invisible.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct ForwardLoc {
    pub page: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub h: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub v: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<f64>,
    /// All matching boxes in reading order. The top-level fields retain the
    /// CLI's first match for clients that do not refine a word selection.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub matches: Vec<Self>,
}

#[derive(Debug, Serialize)]
pub struct InverseLoc {
    pub file: String,
    pub line: u32,
    /// The clicked letter's place in the line, in UTF-16 units (the hosts'
    /// strings), when the host sent the page text and the word was found.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
}

/// One page of a forward match: its number and text, and the UTF-16 ranges of
/// that text which lie in SyncTeX's boxes.
#[derive(Debug, Deserialize)]
pub struct PdfPage {
    pub page: u32,
    pub text: String,
    #[serde(default)]
    pub near: Vec<(usize, usize)>,
}

/// The word's place in a page's text, in UTF-16 units.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct PdfHit {
    pub page: u32,
    pub start: usize,
    pub end: usize,
}

/// The PDF to sync with: `live`, TeXpresso's (with its live.synctex beside it), or the build's.
fn pdf_for(root: &Path, live: Option<&Path>) -> Result<PathBuf, CoreError> {
    if let Some(live) = live {
        return Ok(live.to_path_buf());
    }
    let pdf = compiled_pdf_path(root)?;
    if !pdf.exists() {
        return Err(CoreError::not_found("No compiled PDF yet"));
    }
    Ok(pdf)
}

/// What synctex prints for `args` ("view …" or "edit …"), run in the project.
async fn synctex(root: &Path, args: &[&str], path_env: &str) -> Result<String, CoreError> {
    let (code, stdout) = run("synctex", args, Some(root), PROBE_TIMEOUT, path_env).await;
    if code != 0 {
        return Err(CoreError::internal(format!("synctex {} failed", args[0])));
    }
    Ok(stdout)
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
    // synctex expects the input path as TeX saw it (relative to cwd,
    // ./-prefixed, forward slashes).
    let rel = safe_rel_file(root, file)?;
    if line < 1 {
        return Err(CoreError::bad_request("Invalid source line"));
    }
    let column = column.unwrap_or(0).saturating_add(1);
    let input = format!("{line}:{column}:./{rel}");
    let args: [&str; 5] = ["view", "-i", &input, "-o", &pdf.to_string_lossy()];
    parse_forward(&synctex(root, &args, path_env).await?)
}

/// The boxes synctex prints, each from its "Page:" (one before any is
/// none). synctex also prints x: and y:, a point no client uses.
fn parse_forward(stdout: &str) -> Result<ForwardLoc, CoreError> {
    let mut boxes = vec![ForwardLoc::default()];
    for (key, value) in stdout.split('\n').filter_map(|ln| ln.split_once(':')) {
        let value = value.trim().parse().ok().filter(|v: &f64| v.is_finite());
        let last = boxes.last_mut().unwrap();
        match key {
            "Page" => boxes.push(ForwardLoc {
                page: value.unwrap_or(0.0),
                ..Default::default()
            }),
            "h" => last.h = value,
            "v" => last.v = value,
            "W" => last.width = value,
            "H" => last.height = value,
            _ => {}
        }
    }
    boxes.retain(|b| b.page >= 1.0);
    let mut first = boxes
        .first()
        .cloned()
        .ok_or_else(|| CoreError::not_found("Nothing in the PDF matches this line."))?;
    let order = |b: &ForwardLoc| [b.page, b.v.unwrap_or(0.0), b.h.unwrap_or(0.0)];
    boxes.sort_by(|a, b| {
        let pairs = order(a).into_iter().zip(order(b));
        pairs.fold(Ordering::Equal, |o, (a, b)| o.then(a.total_cmp(&b)))
    });
    // Each box's own matches are empty: the boxes alone compare.
    boxes.dedup();
    first.matches = boxes;
    Ok(first)
}

/// PDF location (page, x, y in TeX points from top-left) -> source file:line,
/// and with `click`, the page's text and the UTF-16 index of the clicked
/// character in it, the column of that letter (`find_in_source`).
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
    let input = field("Input:").map(str::trim).filter(|s| !s.is_empty());
    let line = field("Line:").and_then(|s| s.trim().parse::<u32>().ok());
    let (Some(input), Some(line)) = (input, line) else {
        return Err(CoreError::not_found(
            "Nothing in the source matches this spot.",
        ));
    };

    // Generated files (.toc/.aux in the build dir) and anything outside the
    // project aren't real sources — report "no match" so the UI shows a toast.
    // TeX records the physical working directory, even if root is a link.
    let no_source = || CoreError::not_found("No source file at this location");
    let (abs, canonical_root) = (root.join(input), dunce::canonicalize(root)?);
    let file = rel_to_root(root, &abs)
        .or_else(|| rel_to_root(&canonical_root, &abs))
        // A moved project can retain TeX's old "<folder>/./<file>" spelling.
        .or_else(|| safe_rel_file(root, input.split_once("/./")?.1).ok())
        .ok_or_else(no_source)?;
    let file = safe_rel_file(root, &file).map_err(|_| no_source())?;
    let source = dunce::canonicalize(root.join(&file)).map_err(|_| no_source())?;
    let physical = rel_to_root(&canonical_root, &source)
        .and_then(|rel| safe_rel_file(root, &rel).ok())
        .ok_or_else(no_source)?;
    // Links within the project can still lead to generated output, and the
    // reserved build name is case-insensitive on every platform.
    let generated = |path: &str| {
        path.split('/')
            .next()
            .unwrap()
            .eq_ignore_ascii_case(BUILD_DIR)
    };
    if !source.is_file() || generated(&file) || generated(&physical) {
        return Err(no_source());
    }
    let found = click.and_then(|(text, at)| {
        let source = crate::lossy_string(std::fs::read(&source).ok()?);
        find_in_source(&source, line, text, at)
    });
    let (line, column) = found.map_or((line, None), |(line, column)| (line, Some(column)));
    Ok(InverseLoc { file, line, column })
}

/// Where the word at `column` (UTF-16) of a source line is in the PDF, given
/// the pages SyncTeX's boxes are on. None when the word can't be told from its
/// twins; the host then shows SyncTeX's own box.
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

/// Source lines either side of SyncTeX's that a clicked word is looked for on:
/// TeX may be reading a later one as it sets the text.
const LINE_REACH: u32 = 3;
/// How far from a SyncTeX box, in letters (about two lines), a word may stand
/// when its context doesn't reach both ends of the source line.
const BOX_REACH: usize = 150;

/// A letter's place: its text (a source line number, or a PDF page's index)
/// and its UTF-16 range there.
#[derive(Clone, Copy)]
struct Span {
    group: u32,
    start: u32,
    end: u32,
}

/// What the matcher compares of a text: its letters and digits in order, with
/// ligatures spelt out and everything else (spaces, line breaks, hyphens,
/// punctuation, and in TeX source commands and comments) dropped. PDF text
/// spaces words, wraps lines and hyphenates unlike the source, but not its letters.
#[derive(Default)]
struct Letters {
    chars: Vec<char>,
    spans: Vec<Span>,
}

impl Letters {
    fn push(&mut self, text: &str, group: u32, tex: bool) {
        let text = if tex { uncommented(text) } else { text };
        let (mut end, mut chars) = (0, text.chars().peekable());
        while let Some(c) = chars.next() {
            let start = end;
            end += c.len_utf16() as u32;
            if tex && c == '\\' {
                // A command's name, or the one symbol it escapes.
                let name = chars.peek().is_some_and(|n| n.is_alphabetic());
                while let Some(n) = chars.next_if(|n| !name || n.is_alphabetic()) {
                    end += n.len_utf16() as u32;
                    if !name {
                        break;
                    }
                }
            } else if c.is_alphanumeric() {
                let mut one = [0; 4];
                let spelt = match c {
                    'ﬀ' => "ff",
                    'ﬁ' => "fi",
                    'ﬂ' => "fl",
                    'ﬃ' => "ffi",
                    'ﬄ' => "ffl",
                    _ => c.encode_utf8(&mut one),
                };
                for letter in spelt.chars() {
                    self.chars.push(letter);
                    self.spans.push(Span { group, start, end });
                }
            }
        }
    }

    /// Whether letter `i + 1` follows `i` with nothing between: one word's.
    fn joined(&self, i: usize) -> bool {
        let (a, b) = (self.spans[i], self.spans.get(i + 1));
        b.is_some_and(|b| a.group == b.group && (b.start == a.end || b.start == a.start))
    }

    /// The word round letter `i`.
    fn run(&self, i: usize) -> Range<usize> {
        let (mut start, mut end) = (i, i + 1);
        while start > 0 && self.joined(start - 1) {
            start -= 1;
        }
        while self.joined(end - 1) {
            end += 1;
        }
        start..end
    }

    /// The letter at UTF-16 index `pos` of a one-text `Letters`, or the word
    /// the index follows, or the next letter after it.
    fn at(&self, pos: usize) -> Option<usize> {
        let spans = &self.spans;
        let i = spans.iter().position(|s| s.end as usize > pos);
        let i = i.or(spans.len().checked_sub(1))?;
        let after_word = i > 0 && spans[i].start as usize > pos && spans[i - 1].end as usize == pos;
        Some(i - usize::from(after_word))
    }

    /// The letters of text `group` within UTF-16 range `from..to`.
    fn between(&self, group: u32, from: usize, to: usize) -> Range<usize> {
        let spans = &self.spans;
        let lo = spans.partition_point(|s| (s.group, s.end as usize) <= (group, from));
        lo..spans.partition_point(|s| (s.group, s.start as usize) < (group, to))
    }

    /// Where the letters of `word` in `from` occur in these, each with how
    /// many letters either side of the word repeat round it and how many of
    /// its ends are a word's edge (0 to 2).
    fn occurrences<'a>(
        &'a self,
        from: &'a Self,
        word: &'a Range<usize>,
    ) -> impl Iterator<Item = (usize, usize, usize, usize)> + 'a {
        let (n, target) = (word.len(), &from.chars[word.clone()]);
        let windows = self.chars.windows(n).enumerate();
        windows
            .filter(move |(_, w)| *w == target)
            .map(move |(k, _)| {
                let back = from.chars[..word.start]
                    .iter()
                    .rev()
                    .zip(self.chars[..k].iter().rev());
                let before = back.take_while(|(a, b)| a == b).count();
                let ahead = from.chars[word.end..].iter().zip(&self.chars[k + n..]);
                let after = ahead.take_while(|(a, b)| a == b).count();
                let edges = usize::from(k == 0 || !self.joined(k - 1))
                    + usize::from(!self.joined(k + n - 1));
                (k, before, after, edges)
            })
    }
}

/// The best-ranked candidate, unless another ranks as well: equal evidence
/// can't say which was meant, and a guess would move the caret wrongly.
fn unique<K: Ord>(ranked: impl Iterator<Item = (K, usize)>) -> Option<usize> {
    let mut ranked: Vec<_> = ranked.collect();
    ranked.sort_by(|a, b| a.0.cmp(&b.0));
    let (best, next) = (ranked.first()?, ranked.get(1));
    next.is_none_or(|next| next.0 != best.0).then_some(best.1)
}

/// Forward: the word at UTF-16 `column` of a source `line`, found in the
/// `pages`. A candidate ranks by how much of the line's text surrounds it, then
/// by its word edges, then by nearness to the boxes: the whole line's text
/// settles it wherever it stands; a partial match only close to a box.
pub fn find_in_pdf(line: &str, column: usize, pages: &[PdfPage]) -> Option<PdfHit> {
    let mut source = Letters::default();
    source.push(line, 0, true);
    let word = source.run(source.at(column)?);
    let mut pdf = Letters::default();
    let mut boxes: Vec<Range<usize>> = Vec::new();
    for (group, page) in (0..).zip(pages) {
        pdf.push(&page.text, group, false);
        let near = page.near.iter().map(|&(f, t)| pdf.between(group, f, t));
        boxes.extend(near.filter(|r| r.start < r.end));
    }
    // Letters between a letter and the nearest box; from none, far enough to
    // lose to any box.
    let dist = |i: usize| {
        let gap = |r: &Range<usize>| r.start.saturating_sub(i).max((i + 1).saturating_sub(r.end));
        boxes.iter().map(gap).min().unwrap_or(usize::MAX / 4)
    };
    let (n, spans) = (word.len(), &pdf.spans);
    let ranked = pdf
        .occurrences(&source, &word)
        .filter_map(|(k, before, after, edges)| {
            let near = dist(k).min(dist(k + n - 1));
            let whole = before == word.start && after == source.chars.len() - word.end;
            // The two ends of the matched text apart tell identical sentences apart.
            let ends = dist(k - before) + dist(k + n + after - 1);
            let rank = (Reverse(before + after), Reverse(edges), near, ends);
            (spans[k].group == spans[k + n - 1].group && (whole || near <= BOX_REACH))
                .then_some((rank, k))
        });
    let k = unique(ranked)?;
    let page = pages[spans[k].group as usize].page;
    let (start, end) = (spans[k].start as usize, spans[k + n - 1].end as usize);
    Some(PdfHit { page, start, end })
}

/// Inverse: the letter at UTF-16 index `at` of a PDF page's text, found in
/// `source` as (line, UTF-16 column). SyncTeX records a line, not always the
/// word's own, so the word is looked for a few lines either side too, ranked
/// by the text round it, then its word edges, then nearness to the recorded
/// line, earlier first. Words the PDF runs together are found as one.
pub fn find_in_source(source: &str, line: u32, page_text: &str, at: usize) -> Option<(u32, u32)> {
    if at >= page_text.encode_utf16().count() {
        return None;
    }
    let mut pdf = Letters::default();
    pdf.push(page_text, 0, false);
    let clicked = pdf.at(at)?;
    let word = pdf.run(clicked);
    let mut src = Letters::default();
    let first = line.saturating_sub(LINE_REACH).max(1);
    let lines = source.lines().skip(first as usize - 1);
    for (n, text) in (first..=line.saturating_add(LINE_REACH)).zip(lines) {
        src.push(text, n, true);
    }
    let ranked = src
        .occurrences(&pdf, &word)
        .map(|(k, before, after, edges)| {
            let n = src.spans[k].group;
            (
                (
                    Reverse(before + after),
                    Reverse(edges),
                    n.abs_diff(line),
                    n > line,
                ),
                k,
            )
        });
    let found = src.spans[unique(ranked)? + clicked - word.start];
    Some((found.group, found.start))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forward_keeps_every_box_in_reading_order_after_the_first() {
        let boxes = [
            "Page:2\nv:80",
            "Page:1\nv:60\nh:x",
            "Page:2\nv:40",
            "Page:2\nv:40",
            "Page:0",
        ];
        let result = parse_forward(&format!("h:5\nW:100\n{}\n", boxes.join("\nW:9\n"))).unwrap();
        assert_eq!(
            (result.page, result.v, result.h, result.width),
            (2.0, Some(80.0), None, Some(9.0))
        );
        let order: Vec<_> = result
            .matches
            .iter()
            .map(|r| (r.page, r.v, r.matches.len()))
            .collect();
        assert_eq!(
            order,
            [
                (1.0, Some(60.0), 0),
                (2.0, Some(40.0), 0),
                (2.0, Some(80.0), 0)
            ]
        );
        assert!(parse_forward("Page:0\nOutput:x\n").is_err());
    }

    /// The UTF-16 length of `text`.
    fn utf16(text: &str) -> usize {
        text.encode_utf16().count()
    }

    #[test]
    fn inverse_tells_repeated_words_apart_across_pdf_line_wraps_ligatures_and_formatting() {
        // The source and the page text it comes out as: the same, wrapped, with
        // commands that print nothing and columns of UTF-16 units, with
        // ligatures, and hyphenated at a line's end.
        let same = "echo first, echo second, echo third.";
        let cases = [
            (same, same, "echo"),
            (
                "The same echo repeats. The same echo repeats. The same echo repeats.",
                "The same echo\nrepeats. The same\necho repeats. The same echo repeats.",
                "echo",
            ),
            (
                "🙂 \\emph{echo} first, echo second, \\textbf{echo} third.",
                "🙂 echo first, echo second, echo third.",
                "echo",
            ),
            (
                "office first, office second.",
                "oﬃce first, oﬃce second.",
                "office",
            ),
            (
                "well-known first. well-known second.",
                "well-\nknown first. well-known second.",
                "second",
            ),
        ];
        for (source, pdf, word) in cases {
            let in_pdf = pdf.match_indices(if word == "office" { "oﬃce" } else { word });
            for ((s, _), (p, _)) in source.match_indices(word).zip(in_pdf) {
                let at = utf16(&pdf[..p]);
                let found = find_in_source(source, 1, pdf, at);
                assert_eq!(found, Some((1, utf16(&source[..s]) as u32)), "{pdf} at {p}");
            }
        }
        // Nothing round the word to tell the copies apart; past the text.
        assert_eq!(find_in_source("echo echo", 1, "echo", 0), None);
        assert_eq!(find_in_source(same, 1, same, same.len()), None);
    }

    #[test]
    fn inverse_picks_each_of_eight_identical_sentences_through_a_hyphenation() {
        let sentence = "Native scrolling, selection and zoom should remain responsive.";
        let source_line = format!("{sentence} ").repeat(8);
        let source = format!("{}{}", "\n".repeat(12), source_line);
        let pdf = concat!(
            "2 Section 2\n",
            "Native scrolling, selection and zoom should remain responsive. Native scrolling,\n",
            "selection and zoom should remain responsive. Native scrolling, selection and\n",
            "zoom should remain responsive. Native scrolling, selection and zoom should re-\n",
            "main responsive. Native scrolling, selection and zoom should remain responsive.\n",
            "Native scrolling, selection and zoom should remain responsive. Native scrolling,\n",
            "selection and zoom should remain responsive. Native scrolling, selection and\n",
            "zoom should remain responsive.\n",
            "a2 + b2\n= c2\n3",
        );
        for word in ["Native", "zoom", "responsive"] {
            let in_source: Vec<_> = source_line.match_indices(word).collect();
            let in_pdf: Vec<_> = pdf.match_indices(word).collect();
            assert_eq!((in_source.len(), in_pdf.len()), (8, 8));
            for ((s, _), (p, _)) in in_source.into_iter().zip(in_pdf) {
                // A click midway through the word.
                let mid = word.len() / 2;
                let found = find_in_source(&source, 13, pdf, utf16(&pdf[..p + mid]));
                let column = utf16(&source_line[..s + mid]) as u32;
                assert_eq!(found, Some((13, column)), "{word} at {p}");
            }
        }
    }

    #[test]
    fn inverse_finds_the_clicked_letter_near_the_recorded_line() {
        // Whole words, not a command's name, run together with neighbours as
        // PDF text may be; on the line TeX recorded (7) or one near it.
        let source = "\n\n\n\nÜnï words \\word, the\nword next\nfinal\n";
        for (pdf, at, found) in [
            ("“word,”", 0, Some((6, 0))),
            ("theword", 0, Some((5, 17))),
            ("theword", 4, Some((6, 1))),
            ("wordnext", 5, Some((6, 6))),
            ("Ünï", 2, Some((5, 2))),
            ("ﬁnal", 1, Some((7, 2))),
            ("absent", 0, None),
        ] {
            assert_eq!(find_in_source(source, 7, pdf, at), found, "{pdf}");
        }
    }

    fn page(page: u32, text: &str, near: &[(usize, usize)]) -> PdfPage {
        let (text, near) = (text.into(), near.to_vec());
        PdfPage { page, text, near }
    }

    /// The UTF-16 range of the `n`th (from 0) `needle` in `text`.
    fn nth(text: &str, needle: &str, n: usize) -> (usize, usize) {
        let start = utf16(&text[..text.match_indices(needle).nth(n).unwrap().0]);
        (start, start + utf16(needle))
    }

    /// A forward hit's page and range.
    fn forward(line: &str, column: usize, pages: &[PdfPage]) -> Option<(u32, usize, usize)> {
        find_in_pdf(line, column, pages).map(|hit| (hit.page, hit.start, hit.end))
    }

    #[test]
    fn forward_picks_the_copy_whose_surroundings_match_the_source_line() {
        let text =
            "Intro. The echo repeats. Next, the echo repeats here. Last: the echo repeats there.";
        // The source line has more than the PDF's sentence in common with the second copy.
        let line = "Next, the \\emph{echo} repeats here.";
        let (start, end) = nth(text, "echo", 1);
        for near in [vec![], vec![nth(text, "Last", 0)]] {
            assert_eq!(
                forward(line, 16, &[page(3, text, &near)]),
                Some((3, start, end))
            );
        }
    }

    #[test]
    fn forward_uses_the_boxes_for_a_partial_match_and_gives_up_on_a_tie() {
        // The line has a citation the PDF prints differently: only "echo" and
        // its edges are left to match, so the copy nearest a box wins.
        let text = format!("echo a. {}echo b.", "filler ".repeat(60));
        let line = "echo \\cite{k} tw";
        for n in [0, 1] {
            let (start, end) = nth(&text, "echo", n);
            let pages = [page(1, &text, &[(start, end)])];
            assert_eq!(forward(line, 1, &pages), Some((1, start, end)));
        }
        // Far from every box, a partial match is not trusted.
        let middle = nth(&text, "filler", 30);
        assert_eq!(forward(line, 1, &[page(1, &text, &[middle])]), None);
        // Two copies equally near, the same all round: no guess.
        let twins = "same words here. same words here.";
        assert_eq!(
            forward("same words here.", 1, &[page(1, twins, &[(0, 33)])]),
            None
        );
    }

    #[test]
    fn forward_follows_the_pages_and_utf16_units_of_the_text() {
        let first = "Nothing like it here.";
        let second = "🙂 Some echo in the middle.";
        let line = "Some \\textbf{echo} in the middle.";
        // The word is found on the second page, whole-line evidence needing no box.
        let pages = [page(4, first, &[]), page(5, second, &[])];
        assert_eq!(forward(line, 14, &pages), Some((5, 8, 12)));
        // A caret in a command's name, or on no word, finds none; after a word, that word.
        assert_eq!(forward("\\emph", 2, &[page(1, "emph", &[])]), None);
        assert_eq!(
            forward("say echo", 8, &[page(1, "say echo", &[])]),
            Some((1, 4, 8))
        );
    }
}
