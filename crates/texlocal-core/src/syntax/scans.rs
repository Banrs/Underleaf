//! Scanners kept through the text every few thousand units, so a question
//! about one place reads from the nearest before it rather than from the
//! start. An edit forgets those that read what it changed.

use super::prose::Names;
use super::scan::{Scanner, Visit};
use super::{Text, TextRange};

pub(crate) struct Scans(Vec<Point>);

/// A kept scanner, the maths or code run that ranges after it may join, and
/// how far name arguments have been read.
#[derive(Clone, Default)]
pub(crate) struct Point {
    pub scanner: Scanner,
    pub run: Option<(usize, usize)>,
    pub names: Names,
}

/// The last maths or code run so far, adjacent ranges joined.
impl Visit for Option<(usize, usize)> {
    fn range(&mut self, from: usize, to: usize) {
        *self = match *self {
            Some((start, end)) if from <= end => Some((start, end.max(to))),
            _ => Some((from, to)),
        };
    }
}

/// What a point is kept with, read through the whole text.
struct Keeping<'a> {
    text: &'a Text,
    run: &'a mut Option<(usize, usize)>,
    names: &'a mut Names,
    scratch: Vec<TextRange>,
}

impl Visit for Keeping<'_> {
    fn range(&mut self, from: usize, to: usize) {
        self.run.range(from, to);
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
        // The first point has read nothing, so it's always kept.
        let kept = self.0.partition_point(|p| p.scanner.reach <= at);
        self.0.truncate(kept);
    }

    /// The last point at or before `before` that has read nothing at or past
    /// `end`, from which reading the text up to `end` goes as it would from
    /// the start. Points are kept as far as `before` first, each a few
    /// pointers whatever the groups open.
    pub fn resume(&mut self, text: &Text, before: usize, end: usize) -> Point {
        let mut point = self.0[self.0.len() - 1].clone();
        // Its names were read through the text as it was when it was kept,
        // past what an edit since may have changed.
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
    use crate::syntax::{SourceDocument, TextRange};

    /// Whether 200 spelling, style and preview questions near the end of
    /// `source`, between edits, read it once to keep their points and then
    /// near each question only: each of a question's four answers reads at
    /// most from the kept point before it, less than twice their spacing
    /// (the preview to its maths' close after it too), where from the start
    /// would be the text.
    fn questions_near_the_end_read_near_them(source: &str) {
        const QUESTIONS: usize = 200;
        let len = source.encode_utf16().count();
        let mut doc = SourceDocument::new(source);
        let before = READ.get();
        for k in 0..QUESTIONS {
            let at = (len - 1_000 - k * 37) as u32;
            let range = |length| TextRange { start: at, length };
            doc.not_prose(at, 40);
            doc.text_styles(range(3));
            doc.insert_symbol("\\alpha", range(0));
            doc.math_at(at);
            if k % 20 == 0 {
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
        // 2.8 million units, braces closed and paragraphs short: each question
        // had read it all from the start, 52 s in a test build for these.
        let source = "A paragraph with $x^2$ and \\textbf{bold \\emph{words}}.\n\n".repeat(50_000);
        questions_near_the_end_read_near_them(&source);
    }

    #[test]
    fn braces_nobody_closes_cost_no_more_as_they_pile_up() {
        // 20,000 lines, a brace left open on each and no blank line: kept points
        // had been dropped above 64 open groups, and each question read the
        // whole text from the start, twice.
        let source: String = (0..20_000).map(|n| format!("{{ line {n} word\n")).collect();
        questions_near_the_end_read_near_them(&source);
    }
}
