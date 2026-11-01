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
    let (a, b): (Vec<_>, Vec<_>) = (old.lines().collect(), new.lines().collect());
    let head = common(a.iter(), b.iter());
    let tail = common(a[head..].iter().rev(), b[head..].iter().rev());
    let (x, y) = (&a[head..a.len() - tail], &b[head..b.len() - tail]);
    let mut rows: Vec<DiffLine> = a[..head]
        .iter()
        .map(|&line| DiffLine::Same(line.into()))
        .collect();
    if x.len() * y.len() > 4_000_000 {
        rows.extend(x.iter().map(|&line| DiffLine::Removed(line.into())));
        rows.extend(y.iter().map(|&line| DiffLine::Added(line.into())));
    } else {
        let w = y.len() + 1;
        let mut common = vec![0u32; (x.len() + 1) * w];
        for i in (0..x.len()).rev() {
            for j in (0..y.len()).rev() {
                common[i * w + j] = if x[i] == y[j] {
                    common[(i + 1) * w + j + 1] + 1
                } else {
                    common[(i + 1) * w + j].max(common[i * w + j + 1])
                };
            }
        }
        let (mut i, mut j) = (0, 0);
        while i < x.len() || j < y.len() {
            if i < x.len() && j < y.len() && x[i] == y[j] {
                rows.push(DiffLine::Same(x[i].into()));
                (i, j) = (i + 1, j + 1);
            } else if j == y.len()
                || i < x.len() && common[(i + 1) * w + j] >= common[i * w + j + 1]
            {
                rows.push(DiffLine::Removed(x[i].into()));
                i += 1;
            } else {
                rows.push(DiffLine::Added(y[j].into()));
                j += 1;
            }
        }
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

/// The line of `old` that `line` of `new` stands for: lines before the change keep their number,
/// lines after it move with it, and lines in it land on the old lines it replaced.
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
    let mut start = common(a.iter(), b.iter());
    while !old.is_char_boundary(start) || !new.is_char_boundary(start) {
        start -= 1;
    }
    let mut suffix = common(a[start..].iter().rev(), b[start..].iter().rev());
    while !old.is_char_boundary(old.len() - suffix) || !new.is_char_boundary(new.len() - suffix) {
        suffix -= 1;
    }
    (
        start,
        old.len() - start - suffix,
        &new[start..new.len() - suffix],
    )
}
