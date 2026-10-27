use std::ops::Range;

use crate::analyze::Place;
use crate::utf16;

const WORD_START: i64 = 8;
const RUN: i64 = 4;

fn fold(c: char) -> char {
    if c.is_ascii() {
        c.to_ascii_lowercase()
    } else {
        c.to_lowercase().next().unwrap_or(c)
    }
}

fn fold_into(s: &str, match_case: bool, out: &mut String) {
    out.clear();
    out.extend(s.chars().map(|c| if match_case { c } else { fold(c) }));
}

pub struct Query {
    text: String,
    chars: usize,
    match_case: bool,
    whole_word: bool,
}

impl Query {
    pub fn new(text: &str, match_case: bool, whole_word: bool) -> Self {
        let mut folded = String::new();
        fold_into(text, match_case, &mut folded);
        Self {
            chars: folded.chars().count(),
            text: folded,
            match_case,
            whole_word,
        }
    }

    fn in_line(&self, line: &str, folded: &mut String) -> Vec<Range<usize>> {
        let mut found = Vec::new();
        if self.text.is_empty() {
            return found;
        }
        fold_into(line, self.match_case, folded);
        let word = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
        let (mut from, mut chars) = (0, 0);
        while let Some(at) = folded[from..].find(&self.text) {
            let (start, end) = (from + at, from + at + self.text.len());
            chars += folded[from..start].chars().count();
            if self.whole_word
                && (word(folded[..start].chars().next_back()) || word(folded[end..].chars().next()))
            {
                let next = folded[start..].chars().next().map_or(1, char::len_utf8);
                (from, chars) = (start + next, chars + 1);
                continue;
            }
            found.push(chars..chars + self.chars);
            (from, chars) = (end, chars + self.chars);
        }
        found
    }

    pub fn places(&self, text: &str) -> Vec<Place> {
        let (mut places, mut folded) = (Vec::new(), String::new());
        for (i, line) in text.split('\n').enumerate() {
            let found = self.in_line(line, &mut folded);
            if found.is_empty() {
                continue;
            }
            let starts: Vec<usize> = line.char_indices().map(|(at, _)| at).collect();
            let byte = |chars: usize| starts.get(chars).copied().unwrap_or(line.len());
            let units = |at: Range<usize>| utf16::len(&line[byte(at.start)..byte(at.end)]) as u32;
            places.extend(found.into_iter().map(|at| Place {
                line: i as u32 + 1,
                column: units(0..at.start),
                length: units(at),
            }));
        }
        places
    }
}

pub fn score(query: &str, text: &str) -> Option<i64> {
    let text: Vec<char> = text.chars().collect();
    let word_start = |at: usize| {
        at == 0
            || "/-_:. ".contains(text[at - 1])
            || text[at - 1].is_lowercase() && text[at].is_uppercase()
    };
    let mut best: Vec<Option<i64>> = Vec::new();
    for (i, wanted) in query.chars().map(fold).enumerate() {
        let mut earlier = None;
        let mut next = vec![None; text.len()];
        for (at, &c) in text.iter().enumerate() {
            if fold(c) == wanted {
                let bonus = if word_start(at) { WORD_START } else { 0 };
                let before = match i {
                    0 => Some(0),
                    _ => {
                        let run = at.checked_sub(1).and_then(|k| best[k]).map(|s| s + RUN);
                        run.max(earlier)
                    }
                };
                next[at] = before.map(|score| score + bonus);
            }
            if i > 0 {
                earlier = earlier.max(best[at]);
            }
        }
        best = next;
    }
    best.into_iter().flatten().max()
}
