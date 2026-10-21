//! Scanners kept through the text every few thousand units, so a question reads from the nearest before it.

use super::prose::Names;
use super::scan::{Scanner, Visit};
use super::{Text, TextRange};

pub(crate) struct Scans(Vec<Point>);

#[derive(Clone, Default)]
pub(crate) struct Point {
    pub scanner: Scanner,
    pub run: Option<(usize, usize)>,
    pub names: Names,
}

struct Keeping<'a> {
    text: &'a Text,
    run: &'a mut Option<(usize, usize)>,
    names: &'a mut Names,
    scratch: Vec<TextRange>,
}

impl Visit for Keeping<'_> {
    fn range(&mut self, from: usize, to: usize) {
        *self.run = match *self.run {
            Some((start, end)) if from <= end => Some((start, end.max(to))),
            _ => Some((from, to)),
        };
    }

    fn command(&mut self, name: &str, command_start: usize, name_end: usize) {
        let end = self.text.units.len();
        let command = (name, command_start, name_end);
        self.names
            .command(self.text, command, end, &mut self.scratch);
        self.scratch.clear();
    }
}

pub(crate) const SPACING: usize = 4096;

impl Default for Scans {
    fn default() -> Self {
        Self(vec![Point::default()])
    }
}

impl Scans {
    pub fn forget_from(&mut self, at: usize) {
        let kept = self.0.partition_point(|p| p.scanner.reach <= at);
        self.0.truncate(kept);
    }

    /// The last point at or before `before` that has read nothing at or past `end`.
    pub fn resume(&mut self, text: &Text, before: usize, end: usize) -> Point {
        let mut point = self.0[self.0.len() - 1].clone();
        // Names were read from the text as it was when the point was kept, which an edit may have changed.
        point.names.resume(text, text.units.len(), &mut Vec::new());
        while point.scanner.i + SPACING <= before && point.scanner.i < text.units.len() {
            let until = point.scanner.i + SPACING;
            let mut keeping = Keeping {
                text,
                run: &mut point.run,
                names: &mut point.names,
                scratch: Vec::new(),
            };
            point.scanner.run(&text.units, until, &[], &mut keeping);
            self.0.push(point.clone());
        }
        let k = self
            .0
            .partition_point(|p| p.scanner.i <= before && p.scanner.reach <= end);
        self.0[k - 1].clone()
    }
}

#[cfg(test)]
mod tests {
    use super::SPACING;
    use crate::syntax::scan::READ;
    use crate::syntax::{Checker, SourceDocument, TextRange};

    /// Whether 20 spelling, style and preview questions near the end read it once to keep points, then only near each question.
    fn questions_near_the_end_read_near_them(source: &str) {
        const QUESTIONS: usize = 20;
        let len = source.encode_utf16().count();
        let mut doc = SourceDocument::new(source);
        let before = READ.get();
        for k in 0..QUESTIONS {
            let at = (len - 1_000 - k * 37) as u32;
            let range = |length| TextRange { start: at, length };
            doc.code_ranges(range(40), Checker::Spelling);
            doc.text_styles(range(3));
            doc.insert_symbol("\\alpha", range(0));
            doc.math_at(at);
            if k % 5 == 0 {
                doc.edit(at + 500, 0, "x");
            }
        }
        let read = READ.get() - before;
        assert!(
            read < len + QUESTIONS * 4 * 2 * SPACING,
            "{read} units read of {len}"
        );
    }

    #[test]
    fn questions_about_a_long_text_read_only_near_them() {
        let source = "A paragraph with $x^2$ and \\textbf{bold \\emph{words}}.\n\n".repeat(5_000);
        questions_near_the_end_read_near_them(&source);
    }

    #[test]
    fn braces_nobody_closes_cost_no_more_as_they_pile_up() {
        let source: String = (0..5_000).map(|n| format!("{{ line {n} word\n")).collect();
        questions_near_the_end_read_near_them(&source);
    }
}
