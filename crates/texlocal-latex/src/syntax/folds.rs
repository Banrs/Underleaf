use std::ops::Range;

use schemars::JsonSchema;
use serde::Serialize;

use super::scan::{Group, Scanner, Visit, tex_space};
use super::{SourceDocument, headings, is};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, JsonSchema)]
pub(crate) struct Fold {
    pub(crate) line: u32,
    pub(crate) end: u32,
}

#[derive(Default)]
struct Found {
    environments: Vec<(usize, usize)>,
    headings: Vec<(usize, usize, usize)>,
    document_end: Option<usize>,
    comments: Vec<usize>,
}

impl Visit for Found {
    fn command(&mut self, name: &str, start: usize, name_end: usize) {
        if let Some(depth) = headings::LEVELS.iter().position(|level| level.0 == name) {
            self.headings.push((start, name_end, depth));
        }
    }

    fn closed(&mut self, group: &Group, close: Range<usize>) {
        match group.end.strip_prefix("env:") {
            Some("document") => self.document_end = Some(close.start),
            Some(_) => self.environments.push((group.open, close.start)),
            None => {}
        }
    }

    fn literal(&mut self, open: usize, close: Range<usize>) {
        self.environments.push((open, close.start));
    }

    fn comment(&mut self, from: usize, _: usize) {
        self.comments.push(from);
    }
}

impl SourceDocument {
    pub(crate) fn folds(&self) -> Vec<Fold> {
        let units = &self.text.units;
        let mut found = Found::default();
        Scanner::default().run(units, units.len(), &[], &mut found);
        let line = |offset: usize| self.line_at(offset as u32);
        let blank = |line: u32| {
            let bounds = self.text.bounds(line as usize - 1);
            units[bounds.start..bounds.end]
                .iter()
                .all(|&u| tex_space(u))
        };
        let mut folds = Vec::new();
        let mut add = |line: u32, mut end: u32| {
            while end > line && blank(end) {
                end -= 1;
            }
            if end > line {
                folds.push(Fold { line, end });
            }
        };
        for &(open, close) in &found.environments {
            add(line(open), line(close) - 1);
        }
        let headings: Vec<_> = (found.headings.iter())
            .filter(|&&(_, name_end, _)| {
                let next = units[name_end..].iter().find(|&&u| !tex_space(u));
                next.is_some_and(|&u| is(u, '{') || is(u, '[') || is(u, '*'))
            })
            .collect();
        let last = found
            .document_end
            .map_or(self.line_count(), |end| line(end) - 1);
        for (i, &&(start, _, depth)) in headings.iter().enumerate() {
            let next = headings[i + 1..].iter().find(|heading| heading.2 <= depth);
            let end = next.map_or(last, |&&(next, _, _)| line(next) - 1);
            add(line(start), end.min(last.max(line(start))));
        }
        let mut lines: Vec<u32> = (found.comments.iter())
            .filter(|&&at| {
                let start = self.text.bounds(line(at) as usize - 1).start;
                units[start..at].iter().all(|&u| tex_space(u))
            })
            .map(|&at| line(at))
            .collect();
        lines.dedup();
        for run in lines.chunk_by(|a, b| b - a == 1) {
            add(run[0], run[run.len() - 1]);
        }
        folds.sort_by_key(|fold| (fold.line, std::cmp::Reverse(fold.end)));
        folds.dedup_by_key(|fold| fold.line);
        folds
    }
}
