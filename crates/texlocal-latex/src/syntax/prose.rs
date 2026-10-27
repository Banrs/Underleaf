use std::ops::Range;

use super::scan::{Scanner, Visit, arguments};
use super::{Checker, SourceDocument, Text, TextRange, catalog::CATALOG, clamp, span};

impl SourceDocument {
    pub(crate) fn words(&self, selection: TextRange) -> usize {
        let (start, end) = clamp(selection, self.text.len()).bounds();
        prose(&self.text, |_, _, _| {}).words(start..end)
    }

    pub(crate) fn code_ranges(&mut self, selection: TextRange, checker: Checker) -> Vec<TextRange> {
        let (start, end) = clamp(selection, self.text.len()).bounds();
        let (text, mut point) = (&self.text, self.scans.resume(&self.text, start, end));
        let mut reading = Reading::new(text, end, point.names, checker, |_: &Text, _: &str, _| {});
        let run = point.run.map(|(from, to)| span(from, to - from));
        reading.ranges.extend(run);
        reading.names.resume(text, end, &mut reading.others);
        point
            .scanner
            .run(&text.units[..end], end, &[], &mut reading);
        let mut ranges = reading.ranges;
        ranges.extend(reading.others);
        let (start, end) = (start as u32, end as u32);
        ranges.retain(|r| {
            let range_end = r.start.saturating_add(r.length);
            if start == end {
                r.start <= start && start < range_end
            } else {
                r.start < end && range_end > start
            }
        });
        merged(ranges)
    }
}

fn merged(mut ranges: Vec<TextRange>) -> Vec<TextRange> {
    ranges.sort_unstable_by_key(|r| (r.start, r.start.saturating_add(r.length)));
    ranges.into_iter().fold(Vec::new(), |mut merged, range| {
        merge_range(&mut merged, range);
        merged
    })
}

fn merge_range(ranges: &mut Vec<TextRange>, range: TextRange) {
    if let Some(last) = ranges
        .last_mut()
        .filter(|last| range.start <= last.start + last.length)
    {
        last.length = last.length.max(range.start + range.length - last.start);
    } else {
        ranges.push(range);
    }
}

#[derive(Clone, Copy, Default)]
pub(crate) struct Names {
    from: Option<usize>,
    parsed_until: usize,
}

impl Names {
    pub(crate) fn command(
        &mut self,
        text: &Text,
        (name, command_start, name_end): (&str, usize, usize),
        end: usize,
        ranges: &mut Vec<TextRange>,
    ) {
        let catalog = &*CATALOG;
        let lists = [
            &catalog.name_commands,
            &catalog.cite_commands,
            &catalog.ref_commands,
        ];
        if command_start >= self.parsed_until && lists.iter().any(|l| l.contains(name)) {
            self.from = Some(name_end);
            self.resume(text, end, ranges);
        }
    }

    pub(crate) fn resume(&mut self, text: &Text, end: usize, ranges: &mut Vec<TextRange>) {
        if let Some(from) = self.from {
            self.parsed_until = arguments(&text.units[..end], from, |r, _| {
                ranges.push(span(r.start, r.len()));
            })
            .0;
        }
    }
}

struct Reading<'a, F> {
    text: &'a Text,
    end: usize,
    ranges: Vec<TextRange>,
    others: Vec<TextRange>,
    names: Names,
    comments: bool,
    command: F,
}

impl<'a, F: FnMut(&Text, &str, usize)> Reading<'a, F> {
    fn new(text: &'a Text, end: usize, names: Names, checker: Checker, command: F) -> Self {
        Self {
            text,
            end,
            ranges: Vec::new(),
            others: Vec::new(),
            names,
            comments: checker == Checker::WritingTools,
            command,
        }
    }
}

impl<F: FnMut(&Text, &str, usize)> Visit for Reading<'_, F> {
    fn range(&mut self, from: usize, to: usize) {
        merge_range(&mut self.ranges, span(from, to - from));
    }

    fn comment(&mut self, from: usize, to: usize) {
        if self.comments {
            self.others.push(span(from, to - from));
        }
    }

    fn command(&mut self, name: &str, command_start: usize, name_end: usize) {
        self.others
            .push(span(command_start, name_end - command_start));
        let command = (name, command_start, name_end);
        self.names
            .command(self.text, command, self.end, &mut self.others);
        (self.command)(self.text, name, name_end);
    }
}

pub(crate) struct Prose<'a> {
    units: &'a [u16],
    skipped: Vec<TextRange>,
}

pub(crate) fn prose<'a>(text: &'a Text, command: impl FnMut(&Text, &str, usize)) -> Prose<'a> {
    let len = text.units.len();
    let writing = Checker::WritingTools;
    let mut reading = Reading::new(text, len, Names::default(), writing, command);
    Scanner::default().run(&text.units, len, &[], &mut reading);
    let mut skipped = reading.ranges;
    skipped.extend(reading.others);
    Prose {
        units: &text.units,
        skipped: merged(skipped),
    }
}

impl Prose<'_> {
    pub(crate) fn words(&self, range: Range<usize>) -> usize {
        let end = |r: &TextRange| (r.start + r.length) as usize;
        let first = self.skipped.partition_point(|r| end(r) <= range.start);
        let mut at = first.checked_sub(1).map_or(0, |i| end(&self.skipped[i]));
        let mut words = 0;
        for r in self.skipped[first..]
            .iter()
            .chain([&span(self.units.len(), 0)])
        {
            let (from, to) = (at.max(range.start), (r.start as usize).min(range.end));
            if from < to {
                words += count(&self.units[from..to]);
            }
            if to == range.end {
                break;
            }
            at = end(r);
        }
        words
    }
}

fn count(prose: &[u16]) -> usize {
    let (mut words, mut lettered) = (0, false);
    for c in char::decode_utf16(prose.iter().copied()) {
        let c = c.unwrap_or(char::REPLACEMENT_CHARACTER);
        if c.is_whitespace() || "{}$&_^~\\%".contains(c) {
            words += lettered as usize;
            lettered = false;
        } else {
            lettered |= c.is_alphabetic();
        }
    }
    words + lettered as usize
}
