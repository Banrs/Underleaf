use std::cmp::Reverse;
use std::ops::Range;

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct PdfPage {
    pub(crate) page: u32,
    pub(crate) text: String,
    #[serde(default)]
    pub(crate) near: Vec<(usize, usize)>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct PdfHit {
    pub(crate) page: u32,
    pub(crate) start: usize,
    pub(crate) end: usize,
}

const LIGATURES: [(char, &str); 5] = [
    ('ﬀ', "ff"),
    ('ﬁ', "fi"),
    ('ﬂ', "fl"),
    ('ﬃ', "ffi"),
    ('ﬄ', "ffl"),
];
const LINE_REACH: u32 = 3;
const BOX_REACH: usize = 150;
const FAR: usize = usize::MAX / 4;

#[derive(Clone, Copy)]
struct Span {
    group: u32,
    start: u32,
    end: u32,
}

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

fn unique<K: Ord, T>(mut ranked: Vec<(K, T)>) -> Option<T> {
    ranked.sort_by(|a, b| a.0.cmp(&b.0));
    let mut ranked = ranked.into_iter();
    let (best, found) = ranked.next()?;
    ranked
        .next()
        .is_none_or(|(next, _)| next != best)
        .then_some(found)
}

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
            let near = (n.abs_diff(line), n > line);
            ((Reverse(before + after), Reverse(edges), near), k)
        })
        .collect();
    let found = src.spans[unique(ranked)? + clicked - word.start];
    Some((found.group, found.start))
}
