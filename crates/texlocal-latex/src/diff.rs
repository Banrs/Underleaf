use schemars::JsonSchema;
use serde::Serialize;

use crate::syntax::TextEdit;
use crate::utf16;

#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum DiffLine {
    Same(String),
    Removed(String),
    Added(String),
    Skipped(usize),
}

const CONTEXT: usize = 3;

pub fn compare(old: &str, new: &str) -> Vec<DiffLine> {
    fn lines<'a>(text: &'a str, other: &str) -> Vec<&'a str> {
        let newline_only_here = text.ends_with('\n') && !other.ends_with('\n') && !other.is_empty();
        text.lines()
            .chain(newline_only_here.then_some(""))
            .collect()
    }
    let (a, b) = (lines(old, new), lines(new, old));
    let head = common(a.iter(), b.iter());
    let tail = common(a[head..].iter().rev(), b[head..].iter().rev());
    let (x, y) = (&a[head..a.len() - tail], &b[head..b.len() - tail]);
    let mut rows: Vec<DiffLine> = a[..head]
        .iter()
        .map(|&line| DiffLine::Same(line.into()))
        .collect();
    if let Some(changed) = myers(x, y) {
        rows.extend(changed);
    } else {
        rows.extend(x.iter().map(|&line| DiffLine::Removed(line.into())));
        rows.extend(y.iter().map(|&line| DiffLine::Added(line.into())));
    }
    rows.extend(
        a[a.len() - tail..]
            .iter()
            .map(|&line| DiffLine::Same(line.into())),
    );

    let mut shown = vec![false; rows.len()];
    for (i, row) in rows.iter().enumerate() {
        if !matches!(row, DiffLine::Same(_)) {
            shown[i.saturating_sub(CONTEXT)..rows.len().min(i + CONTEXT + 1)].fill(true);
        }
    }
    if !shown.contains(&true) {
        return vec![];
    }
    let mut folded = Vec::new();
    for (row, shown) in rows.into_iter().zip(shown) {
        match (shown, folded.last_mut()) {
            (true, _) => folded.push(row),
            (false, Some(DiffLine::Skipped(count))) => *count += 1,
            (false, _) => folded.push(DiffLine::Skipped(1)),
        }
    }
    folded
}

fn myers(a: &[&str], b: &[&str]) -> Option<Vec<DiffLine>> {
    if a.is_empty() || b.is_empty() {
        return None;
    }
    let mut trace: Vec<Vec<usize>> = Vec::new();
    // Bound both the search work and the retained trace when most lines differ.
    let mut remaining = 2_000_000usize;
    for d in 0..=a.len() + b.len() {
        let mut frontier = Vec::with_capacity(d + 1);
        for j in 0..=d {
            remaining = remaining.checked_sub(1)?;
            let mut x = if d == 0 {
                0
            } else {
                let previous = &trace[d - 1];
                if j == 0 || j < d && previous[j - 1] < previous[j] {
                    previous[j]
                } else {
                    previous[j - 1] + 1
                }
            };
            let mut y = x + d - 2 * j;
            while x < a.len() && y < b.len() && a[x] == b[y] {
                remaining = remaining.checked_sub(1)?;
                x += 1;
                y += 1;
            }
            frontier.push(x);
            if x == a.len() && y == b.len() {
                return Some(backtrack(a, b, &trace));
            }
        }
        trace.push(frontier);
    }
    None
}

fn backtrack(a: &[&str], b: &[&str], trace: &[Vec<usize>]) -> Vec<DiffLine> {
    let (mut x, mut y) = (a.len(), b.len());
    let mut rows = Vec::new();
    for d in (1..=trace.len()).rev() {
        let previous = &trace[d - 1];
        let j = (x + d - y) / 2;
        let inserted = j == 0 || j < d && previous[j - 1] < previous[j];
        let at = if inserted { j } else { j - 1 };
        let px = previous[at];
        let py = px + d - 1 - 2 * at;
        while x > px && y > py {
            x -= 1;
            y -= 1;
            rows.push(DiffLine::Same(a[x].into()));
        }
        if inserted {
            y -= 1;
            rows.push(DiffLine::Added(b[y].into()));
        } else {
            x -= 1;
            rows.push(DiffLine::Removed(a[x].into()));
        }
    }
    rows.extend(a[..x].iter().rev().map(|&line| DiffLine::Same(line.into())));
    rows.reverse();
    rows
}

pub fn edit_to(text: &str, to: &str) -> Option<TextEdit> {
    if text == to {
        return None;
    }
    let (start, length, inserted) = delta(text, to);
    let units = |s: &str| utf16::len(s) as u32;
    Some(TextEdit {
        start: units(&text[..start]),
        length: units(&text[start..start + length]),
        text: inserted.to_owned(),
    })
}

pub fn map_line(old: &str, new: &str, line: u32) -> u32 {
    let (a, b): (Vec<_>, Vec<_>) = (old.split('\n').collect(), new.split('\n').collect());
    let head = common(a.iter(), b.iter());
    let tail = common(a[head..].iter().rev(), b[head..].iter().rev());
    let line = line as usize;
    let mapped = if line <= head {
        line
    } else if line > b.len() - tail {
        line + a.len() - b.len()
    } else {
        line.min(a.len() - tail).max(head + 1).min(a.len())
    };
    mapped as u32
}

fn common<T: PartialEq>(a: impl Iterator<Item = T>, b: impl Iterator<Item = T>) -> usize {
    a.zip(b).take_while(|(a, b)| a == b).count()
}

pub fn delta<'a>(old: &str, new: &'a str) -> (usize, usize, &'a str) {
    let (a, b) = (old.as_bytes(), new.as_bytes());
    // Shared bytes have the same character boundaries in both strings.
    let start = old.floor_char_boundary(common(a.iter(), b.iter()));
    let suffix = common(a[start..].iter().rev(), b[start..].iter().rev());
    let end = old.ceil_char_boundary(old.len() - suffix);
    let new_end = new.len() - (old.len() - end);
    (start, end - start, &new[start..new_end])
}
