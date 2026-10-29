use super::Text;
use super::prose::Names;
use super::scan::{Scanner, Visit};

pub(crate) struct Scans(Vec<Point>);

#[derive(Clone, Default)]
pub(crate) struct Point {
    pub(crate) scanner: Scanner,
    pub(crate) run: Option<(usize, usize)>,
    pub(crate) names: Names,
}

struct Keeping<'a> {
    text: &'a Text,
    run: &'a mut Option<(usize, usize)>,
    names: &'a mut Names,
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
        self.names.command(self.text, command, end, |_| {});
    }
}

pub(crate) const SPACING: usize = 4096;

impl Default for Scans {
    fn default() -> Self {
        Self(vec![Point::default()])
    }
}

impl Scans {
    pub(crate) fn forget_from(&mut self, at: usize) {
        let kept = self.0.partition_point(|p| p.scanner.reach <= at);
        self.0.truncate(kept);
    }

    pub(crate) fn resume(&mut self, text: &Text, before: usize, end: usize) -> Point {
        let mut point = self.0[self.0.len() - 1].clone();
        point.names.resume(text, text.units.len(), |_| {});
        while point.scanner.i + SPACING <= before && point.scanner.i < text.units.len() {
            let until = point.scanner.i + SPACING;
            let mut keeping = Keeping {
                text,
                run: &mut point.run,
                names: &mut point.names,
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
