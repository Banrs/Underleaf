//! Placing a word by the text round it: SyncTeX's boxes are coarse, so letters are compared, forward in the PDF's page text and inverse in the source. Pure text.

use std::cmp::Reverse;
use std::ops::Range;

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct PdfPage {
    pub page: u32,
    pub text: String,
    #[serde(default)]
    pub near: Vec<(usize, usize)>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct PdfHit {
    pub page: u32,
    pub start: usize,
    pub end: usize,
}

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

#[derive(Clone, Copy)]
struct Span {
    group: u32,
    start: u32,
    end: u32,
}

/// What the matcher compares of a text: its letters and digits, ligatures spelt out; PDF text spaces, wraps and hyphenates unlike the source, but not its letters.
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

    fn joined(&self, i: usize) -> bool {
        self.spans.get(i + 1).is_some_and(|b| {
            let a = self.spans[i];
            a.group == b.group && (b.start == a.end || b.start == a.start)
        })
    }

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

    fn between(&self, group: u32, from: usize, to: usize) -> Range<usize> {
        let lo = self
            .spans
            .partition_point(|s| (s.group, s.end as usize) <= (group, from));
        let hi = self
            .spans
            .partition_point(|s| (s.group, s.start as usize) < (group, to));
        lo..hi
    }

    fn edges(&self, k: usize, n: usize) -> usize {
        usize::from(k == 0 || !self.joined(k - 1)) + usize::from(!self.joined(k + n - 1))
    }
}

fn occurrences<'a>(text: &'a [char], word: &'a [char]) -> impl Iterator<Item = usize> + 'a {
    (0..=text.len().saturating_sub(word.len()))
        .filter(move |&k| text.len() >= word.len() && text[k..k + word.len()] == *word)
}

fn evidence(from: &Letters, word: &Range<usize>, to: &Letters, k: usize) -> (usize, usize, usize) {
    let before = from.chars[..word.start]
        .iter()
        .rev()
        .zip(to.chars[..k].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let after = from.chars[word.end..]
        .iter()
        .zip(&to.chars[k + word.len()..])
        .take_while(|(a, b)| a == b)
        .count();
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

/// Forward: the word at UTF-16 `column` of a source `line`, found in `pages`. Candidates rank by surrounding text, then word edges, then nearness to the boxes.
pub(crate) fn find_in_pdf(line: &str, column: usize, pages: &[PdfPage]) -> Option<PdfHit> {
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

/// Inverse: the letter at UTF-16 index `at` of a PDF page's text, found in `source` as (line, UTF-16 column). SyncTeX's line isn't always the word's own, so a few lines either side are searched too.
pub(crate) fn find_in_source(
    source: &str,
    line: u32,
    page_text: &str,
    at: usize,
) -> Option<(u32, u32)> {
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
            let near = (n.abs_diff(line), n > line);
            ((Reverse(before + after), Reverse(edges), near), k)
        })
        .collect();
    let found = src.spans[unique(ranked)? + clicked - word.start];
    Some((found.group, found.start))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inverse(source: &str, line: u32, pdf: &str, pdf_at: usize) -> Option<(u32, u32)> {
        let at = pdf[..pdf_at].encode_utf16().count();
        find_in_source(source, line, pdf, at)
    }

    fn column(source: &str, byte: usize) -> u32 {
        source[..byte].encode_utf16().count() as u32
    }

    #[test]
    fn inverse_tells_repeated_words_apart_across_pdf_line_wraps_and_formatting() {
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
        let source = "well-known first. well-known second.";
        let pdf = "well-\nknown first. well-known second.";
        assert_eq!(
            inverse(source, 1, pdf, pdf.rfind("second").unwrap()),
            Some((1, source.find("second").unwrap() as u32))
        );
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

    fn nth(text: &str, needle: &str, n: usize) -> (usize, usize) {
        let at = text.match_indices(needle).nth(n).unwrap().0;
        let start = text[..at].encode_utf16().count();
        (start, start + needle.encode_utf16().count())
    }

    #[test]
    fn forward_picks_the_copy_whose_surroundings_match_the_source_line() {
        let text =
            "Intro. The echo repeats. Next, the echo repeats here. Last: the echo repeats there.";
        let line = "Next, the \\emph{echo} repeats here.";
        for near in [vec![], vec![nth(text, "Last", 0)]] {
            let hit = find_in_pdf(line, 16, &[page(3, text, &near)]).unwrap();
            assert_eq!(hit.page, 3);
            assert_eq!((hit.start, hit.end), nth(text, "echo", 1));
        }
    }

    #[test]
    fn forward_uses_the_boxes_for_a_partial_match_and_gives_up_on_a_tie() {
        let text = format!("echo a. {}echo b.", "filler ".repeat(60));
        let line = "echo \\cite{k} tw";
        for n in [0, 1] {
            let near = nth(&text, "echo", n);
            let hit = find_in_pdf(line, 1, &[page(1, &text, &[near])]).unwrap();
            assert_eq!((hit.start, hit.end), near);
        }
        let middle = nth(&text, "filler", 30);
        assert_eq!(find_in_pdf(line, 1, &[page(1, &text, &[middle])]), None);
        let twins = "same words here. same words here.";
        let both = page(1, twins, &[(0, 33)]);
        assert_eq!(find_in_pdf("same words here.", 1, &[both]), None);
    }

    #[test]
    fn forward_follows_the_pages_and_utf16_units_of_the_text() {
        let first = "Nothing like it here.";
        let second = "🙂 Some echo in the middle.";
        let line = "Some \\textbf{echo} in the middle.";
        let hit = find_in_pdf(line, 14, &[page(4, first, &[]), page(5, second, &[])]).unwrap();
        assert_eq!((hit.page, hit.start, hit.end), (5, 8, 12));
        assert_eq!(find_in_pdf("\\emph", 2, &[page(1, "emph", &[])]), None);
        let hit = find_in_pdf("say echo", 8, &[page(1, "say echo", &[])]).unwrap();
        assert_eq!((hit.start, hit.end), (4, 8));
    }
}
