//! SyncTeX queries: editor line to PDF position, and back. SyncTeX's boxes
//! are coarse, so a word is placed by matching the text round it (`Letters`).

use std::cmp::Reverse;
use std::ops::Range;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::BUILD_DIR;
use crate::compile::{PROBE_TIMEOUT, run};
use crate::error::CoreError;
use crate::paths::{rel_to_root, safe_path, safe_rel_file};
use crate::settings::compiled_pdf_path;

/// Only `page` is required. The rest are omitted when synctex didn't report
/// them, because the PDF viewer falls back with `??` — which fires on an
/// absent field but not on a zero, and a zero-size highlight is invisible.
#[derive(Clone, Debug, Serialize)]
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
    pub matches: Vec<ForwardLoc>,
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
#[derive(Debug, PartialEq, Serialize)]
pub struct PdfHit {
    pub page: u32,
    pub start: usize,
    pub end: usize,
}

/// The PDF to sync with: `live`, TeXpresso's (with its live.synctex beside it), or the build's.
fn pdf_for(root: &Path, live: Option<&Path>) -> Result<std::path::PathBuf, CoreError> {
    if let Some(live) = live {
        return Ok(live.to_path_buf());
    }
    let pdf = compiled_pdf_path(root)?;
    if !pdf.exists() {
        return Err(CoreError::not_found("No compiled PDF yet"));
    }
    Ok(pdf)
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
    let pdf_str = pdf.to_string_lossy();
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
    parse_forward(&stdout)
}

fn parse_forward(stdout: &str) -> Result<ForwardLoc, CoreError> {
    // The box the clients draw. synctex also prints x: and y:, a point no
    // client uses.
    const KEYS: [&str; 5] = ["Page", "h", "v", "W", "H"];
    let mut matches = Vec::new();
    let mut values = [None; 5];
    let finish = |values: [Option<f64>; 5], matches: &mut Vec<ForwardLoc>| {
        let [page, h, v, width, height] = values;
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
    for ln in stdout.split('\n') {
        let Some((key, value)) = ln.split_once(':') else {
            continue;
        };
        if let Some(i) = KEYS.iter().position(|k| *k == key) {
            if i == 0 {
                finish(std::mem::take(&mut values), &mut matches);
            }
            values[i] = value
                .trim()
                .parse::<f64>()
                .ok()
                .filter(|value| value.is_finite());
        }
    }
    finish(values, &mut matches);
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
    matches.dedup_by(|a, b| {
        a.page == b.page && a.h == b.h && a.v == b.v && a.width == b.width && a.height == b.height
    });
    first.matches = matches;
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
        return Err(CoreError::not_found(
            "Nothing in the source matches this spot.",
        ));
    };

    let abs = root.join(file);
    // Generated files (.toc/.aux in the build dir) and anything outside the
    // project aren't real sources — report "no match" so the UI shows a toast.
    // TeX records the physical working directory, even if root is a link.
    let no_source = || CoreError::not_found("No source file at this location");
    let canonical_root = dunce::canonicalize(root)?;
    let rel = rel_to_root(root, &abs)
        .or_else(|| rel_to_root(&canonical_root, &abs))
        // A moved project can retain TeX's old "<folder>/./<file>" spelling.
        .or_else(|| safe_rel_file(root, file.split_once("/./")?.1).ok())
        .ok_or_else(no_source)?;
    let rel = safe_rel_file(root, &rel).map_err(|_| no_source())?;
    let source = dunce::canonicalize(root.join(&rel)).map_err(|_| no_source())?;
    let physical = rel_to_root(&canonical_root, &source)
        .and_then(|rel| safe_rel_file(root, &rel).ok())
        .ok_or_else(no_source)?;
    // Links within the project can still lead to generated output, and the
    // reserved build name is case-insensitive on every platform.
    if !source.is_file()
        || [&rel, &physical].iter().any(|path| {
            path.split('/')
                .next()
                .is_some_and(|top| top.eq_ignore_ascii_case(BUILD_DIR))
        })
    {
        return Err(no_source());
    }
    let found = click.and_then(|(text, at)| {
        let source = crate::lossy_string(std::fs::read(&source).ok()?);
        find_in_source(&source, line, text, at)
    });
    let (line, column) = found.map_or((line, None), |(line, column)| (line, Some(column)));
    Ok(InverseLoc {
        file: rel,
        line,
        column,
    })
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

// ---------- word matching ----------

const LIGATURES: [(char, &str); 5] = [
    ('ﬀ', "ff"),
    ('ﬁ', "fi"),
    ('ﬂ', "fl"),
    ('ﬃ', "ffi"),
    ('ﬄ', "ffl"),
];
/// Source lines either side of SyncTeX's that a clicked word is looked for on:
/// TeX may be reading a later one as it sets the text.
const LINE_REACH: u32 = 3;
/// How far from a SyncTeX box, in letters (about two lines), a word may stand
/// when its context doesn't reach both ends of the source line.
const BOX_REACH: usize = 150;
/// The distance from no box at all, far enough to lose to any box.
const FAR: usize = usize::MAX / 4;

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
        let mut at = 0;
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            let start = at;
            at += c.len_utf16() as u32;
            if tex && c == '%' {
                break;
            }
            if tex && c == '\\' {
                // A command's name, or the one symbol it escapes.
                let name = chars.peek().is_some_and(|n| n.is_alphabetic());
                while let Some(n) = chars.next_if(|n| !name || n.is_alphabetic()) {
                    at += n.len_utf16() as u32;
                    if !name {
                        break;
                    }
                }
                continue;
            }
            if c.is_alphanumeric() {
                let spelt = LIGATURES.iter().find(|(l, _)| *l == c).map(|(_, s)| *s);
                for letter in spelt.map_or_else(|| c.to_string(), str::to_owned).chars() {
                    self.chars.push(letter);
                    self.spans.push(Span {
                        group,
                        start,
                        end: at,
                    });
                }
            }
        }
    }

    /// Whether letter `i + 1` follows `i` with nothing between: one word's.
    fn joined(&self, i: usize) -> bool {
        self.spans.get(i + 1).is_some_and(|b| {
            let a = self.spans[i];
            a.group == b.group && (b.start == a.end || b.start == a.start)
        })
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
        let i = self
            .spans
            .iter()
            .position(|s| s.end as usize > pos)
            .or(self.chars.len().checked_sub(1))?;
        let after_word = i > 0 && self.spans[i].start as usize > pos;
        Some(if after_word && self.spans[i - 1].end as usize == pos {
            i - 1
        } else {
            i
        })
    }

    /// The letters of text `group` within UTF-16 range `from..to`.
    fn between(&self, group: u32, from: usize, to: usize) -> Range<usize> {
        let lo = self
            .spans
            .partition_point(|s| (s.group, s.end as usize) <= (group, from));
        let hi = self
            .spans
            .partition_point(|s| (s.group, s.start as usize) < (group, to));
        lo..hi
    }

    /// How many of the occurrence of `n` letters at `k` have a word's edge
    /// at their ends (0 to 2).
    fn edges(&self, k: usize, n: usize) -> usize {
        usize::from(k == 0 || !self.joined(k - 1)) + usize::from(!self.joined(k + n - 1))
    }
}

fn occurrences<'a>(text: &'a [char], word: &'a [char]) -> impl Iterator<Item = usize> + 'a {
    (0..=text.len().saturating_sub(word.len()))
        .filter(move |&k| text.len() >= word.len() && text[k..k + word.len()] == *word)
}

/// How many letters either side of `word` in `from` repeat in `to` round the
/// occurrence at `k`, and the occurrence's word edges (`Letters::edges`).
fn evidence(from: &Letters, word: &Range<usize>, to: &Letters, k: usize) -> (usize, usize, usize) {
    let common = |a: &[char], b: &[char], rev: bool| {
        if rev {
            a.iter()
                .rev()
                .zip(b.iter().rev())
                .take_while(|(a, b)| a == b)
                .count()
        } else {
            a.iter().zip(b).take_while(|(a, b)| a == b).count()
        }
    };
    let before = common(&from.chars[..word.start], &to.chars[..k], true);
    let after = common(&from.chars[word.end..], &to.chars[k + word.len()..], false);
    (before, after, to.edges(k, word.len()))
}

/// The best-ranked candidate, unless another ranks as well: equal evidence
/// can't say which was meant, and a guess would move the caret wrongly.
fn unique<K: Ord, T>(mut ranked: Vec<(K, T)>) -> Option<T> {
    ranked.sort_by(|a, b| a.0.cmp(&b.0));
    let mut ranked = ranked.into_iter();
    let (best, found) = ranked.next()?;
    ranked
        .next()
        .is_none_or(|(next, _)| next != best)
        .then_some(found)
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
        let near = page
            .near
            .iter()
            .map(|&(from, to)| pdf.between(group, from, to));
        boxes.extend(near.filter(|r| r.start < r.end));
    }
    // Letters between a letter and the nearest box.
    let dist = |i: usize| {
        let gap = |r: &Range<usize>| r.start.saturating_sub(i).max((i + 1).saturating_sub(r.end));
        boxes.iter().map(gap).min().unwrap_or(FAR)
    };
    let n = word.len();
    let ranked: Vec<_> = occurrences(&pdf.chars, &source.chars[word.clone()])
        .filter(|&k| pdf.spans[k].group == pdf.spans[k + n - 1].group)
        .filter_map(|k| {
            let (before, after, edges) = evidence(&source, &word, &pdf, k);
            let near = dist(k).min(dist(k + n - 1));
            let whole = before == word.start && after == source.chars.len() - word.end;
            // The two ends of the matched text apart tell identical sentences apart.
            let ends = dist(k - before) + dist(k + n + after - 1);
            (whole || near <= BOX_REACH)
                .then_some(((Reverse(before + after), Reverse(edges), near, ends), k))
        })
        .collect();
    let k = unique(ranked)?;
    let (first, last) = (pdf.spans[k], pdf.spans[k + n - 1]);
    Some(PdfHit {
        page: pages[first.group as usize].page,
        start: first.start as usize,
        end: last.end as usize,
    })
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
    let numbered =
        (first..=line.saturating_add(LINE_REACH)).zip(source.lines().skip(first as usize - 1));
    for (n, text) in numbered {
        src.push(text, n, true);
    }
    let ranked: Vec<_> = occurrences(&src.chars, &pdf.chars[word.clone()])
        .map(|k| {
            let (before, after, edges) = evidence(&pdf, &word, &src, k);
            let n = src.spans[k].group;
            let rank = (
                Reverse(before + after),
                Reverse(edges),
                n.abs_diff(line),
                n > line,
            );
            (rank, k)
        })
        .collect();
    let found = src.spans[unique(ranked)? + clicked - word.start];
    Some((found.group, found.start))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forward_keeps_all_boxes_in_page_order_without_changing_the_legacy_match() {
        let output = "Page:2\nh:10\nv:80\nW:100\nH:9\nPage:1\nh:10\nv:60\nW:100\nH:9\nPage:2\nh:10\nv:40\nW:100\nH:9\nPage:2\nh:10\nv:40\nW:100\nH:9\n";
        let result = parse_forward(output).unwrap();
        assert_eq!((result.page, result.v), (2.0, Some(80.0)));
        assert_eq!(
            result
                .matches
                .iter()
                .map(|r| (r.page, r.v))
                .collect::<Vec<_>>(),
            vec![(1.0, Some(60.0)), (2.0, Some(40.0)), (2.0, Some(80.0))]
        );
        assert!(result.matches.iter().all(|r| r.matches.is_empty()));
    }

    /// The inverse hit for `word` clicked `offset` letters in, where the page
    /// text is `pdf` and `pdf_at` is where the word starts there.
    fn inverse(source: &str, line: u32, pdf: &str, pdf_at: usize) -> Option<(u32, u32)> {
        let at = pdf[..pdf_at].encode_utf16().count();
        find_in_source(source, line, pdf, at)
    }

    fn column(source: &str, byte: usize) -> u32 {
        source[..byte].encode_utf16().count() as u32
    }

    #[test]
    fn inverse_tells_repeated_words_apart_across_pdf_line_wraps_and_formatting() {
        // The source and the page text it comes out as: the same, wrapped, or
        // with commands that print nothing and columns of UTF-16 units.
        let same = "echo first, echo second, echo third.";
        let cases = [
            (same, same),
            (
                "The same echo repeats. The same echo repeats. The same echo repeats.",
                "The same echo\nrepeats. The same\necho repeats. The same echo repeats.",
            ),
            (
                "🙂 \\emph{echo} first, echo second, \\textbf{echo} third.",
                "🙂 echo first, echo second, echo third.",
            ),
        ];
        for (source, pdf) in cases {
            for ((s, _), (p, _)) in source.match_indices("echo").zip(pdf.match_indices("echo")) {
                assert_eq!(inverse(source, 1, pdf, p), Some((1, column(source, s))));
            }
        }
        // Nothing round the word to tell the copies apart.
        assert_eq!(inverse("echo echo", 1, "echo", 0), None);
    }

    #[test]
    fn inverse_spells_out_ligatures_and_ignores_line_end_hyphens() {
        let source = "office first, office second.";
        let pdf = "oﬃce first, oﬃce second.";
        assert_eq!(
            inverse(source, 1, pdf, pdf.rfind("oﬃce").unwrap()),
            Some((1, 14))
        );
        // A hyphen the PDF breaks a line at, and one the source has.
        let source = "well-known first. well-known second.";
        let pdf = "well-\nknown first. well-known second.";
        assert_eq!(
            inverse(source, 1, pdf, pdf.rfind("second").unwrap()),
            Some((1, source.find("second").unwrap() as u32))
        );
        // Past the text, or in none.
        assert_eq!(find_in_source(source, 1, pdf, pdf.len() + 5), None);
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
                let at = pdf[..p + mid].encode_utf16().count();
                assert_eq!(
                    find_in_source(&source, 13, pdf, at),
                    Some((13, column(&source_line, s + mid))),
                    "{word} at {p}",
                );
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
        PdfPage {
            page,
            text: text.into(),
            near: near.to_vec(),
        }
    }

    /// The UTF-16 range of the `n`th (from 0) `needle` in `text`.
    fn nth(text: &str, needle: &str, n: usize) -> (usize, usize) {
        let at = text.match_indices(needle).nth(n).unwrap().0;
        let start = text[..at].encode_utf16().count();
        (start, start + needle.encode_utf16().count())
    }

    #[test]
    fn forward_picks_the_copy_whose_surroundings_match_the_source_line() {
        let text =
            "Intro. The echo repeats. Next, the echo repeats here. Last: the echo repeats there.";
        // The source line has more than the PDF's sentence in common with the second copy.
        let line = "Next, the \\emph{echo} repeats here.";
        for near in [vec![], vec![nth(text, "Last", 0)]] {
            let hit = find_in_pdf(line, 16, &[page(3, text, &near)]).unwrap();
            assert_eq!(hit.page, 3);
            assert_eq!((hit.start, hit.end), nth(text, "echo", 1));
        }
    }

    #[test]
    fn forward_uses_the_boxes_for_a_partial_match_and_gives_up_on_a_tie() {
        // The line has a citation the PDF prints differently: only "echo" and
        // its edges are left to match, so the copy nearest a box wins.
        let text = format!("echo a. {}echo b.", "filler ".repeat(60));
        let line = "echo \\cite{k} tw";
        for n in [0, 1] {
            let near = nth(&text, "echo", n);
            let hit = find_in_pdf(line, 1, &[page(1, &text, &[near])]).unwrap();
            assert_eq!((hit.start, hit.end), near);
        }
        // Far from every box, a partial match is not trusted.
        let middle = nth(&text, "filler", 30);
        assert_eq!(find_in_pdf(line, 1, &[page(1, &text, &[middle])]), None);
        // Two copies equally near, the same all round: no guess.
        let twins = "same words here. same words here.";
        let both = page(1, twins, &[(0, 33)]);
        assert_eq!(find_in_pdf("same words here.", 1, &[both]), None);
    }

    #[test]
    fn forward_follows_the_pages_and_utf16_units_of_the_text() {
        let first = "Nothing like it here.";
        let second = "🙂 Some echo in the middle.";
        let line = "Some \\textbf{echo} in the middle.";
        // The word is found on the second page, whole-line evidence needing no box.
        let hit = find_in_pdf(line, 14, &[page(4, first, &[]), page(5, second, &[])]).unwrap();
        assert_eq!(
            hit,
            PdfHit {
                page: 5,
                start: 8,
                end: 12
            }
        );
        // A caret in a command's name, or on no word, finds none; after a word, that word.
        assert_eq!(find_in_pdf("\\emph", 2, &[page(1, "emph", &[])]), None);
        let hit = find_in_pdf("say echo", 8, &[page(1, "say echo", &[])]).unwrap();
        assert_eq!((hit.start, hit.end), (4, 8));
    }
}
