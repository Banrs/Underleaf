use std::cmp::Reverse;
use std::ops::{Range, RangeInclusive};

use super::scan::{Group, Scanner, Visit, blank_line, tex_space};
use super::{SourceDocument, Text};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncLines {
    Nowhere,
    Whole(RangeInclusive<u32>),
    Within {
        line: u32,
        range: RangeInclusive<u32>,
    },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Document,
    Picture,
    Other,
}

fn kind(name: &str) -> Kind {
    match name.trim_end_matches('*') {
        "document" => Kind::Document,
        "tikzcd" | "circuitikz" | "forest" => Kind::Picture,
        bare if bare.ends_with("picture") => Kind::Picture,
        _ => Kind::Other,
    }
}

#[derive(Default)]
struct Found {
    environments: Vec<(Kind, usize, usize)>,
    comments: Vec<usize>,
}

impl Visit for Found {
    fn closed(&mut self, group: &Group, close: Range<usize>) {
        if let Some(name) = group.environment() {
            self.environments
                .push((kind(name), group.open, close.start));
        }
    }

    fn literal(&mut self, open: usize, close: Range<usize>) {
        self.environments.push((Kind::Other, open, close.start));
    }

    fn comment(&mut self, from: usize, _: usize) {
        self.comments.push(from);
    }
}

pub fn sync_lines(text: &str, line: u32) -> SyncLines {
    scanned_whole(&Text::new(text), line)
}

/// Environments that only place what they hold, so a label in one names what's around it.
const LAYOUT: [&str; 4] = ["document", "center", "flushleft", "flushright"];
const LISTS: [&str; 3] = ["itemize", "enumerate", "description"];

/// The lines that typeset what a `\label` on `line` names: its innermost environment, an item in a list, or a heading
/// or paragraph on its own line, with the line before when the label starts its line.
pub fn labelled_lines(text: &str, line: u32) -> RangeInclusive<u32> {
    #[derive(Default)]
    struct Spans(Vec<(String, usize, usize)>);
    impl Visit for Spans {
        fn closed(&mut self, group: &Group, close: Range<usize>) {
            if let Some(name) = group.environment() {
                self.0.push((name.to_owned(), group.open, close.start));
            }
        }
    }
    let text = Text::new(text);
    let (mut spans, mut scanner) = (Spans::default(), Scanner::default());
    scanner.run(&text.units, text.units.len(), &[], &mut spans);
    let line_of = |at: usize| text.line_index(at as u32) as u32 + 1;
    let innermost = (spans.0.iter())
        .map(|(name, open, close)| {
            (
                name.trim_end_matches('*'),
                *open,
                line_of(*open)..=line_of(*close),
            )
        })
        .filter(|(name, _, lines)| lines.contains(&line) && !LAYOUT.contains(name))
        .min_by_key(|(_, open, lines)| (lines.end() - lines.start(), Reverse(*open)));
    match innermost {
        Some((name, ..)) if LISTS.contains(&name) => line..=line,
        Some((.., lines)) => lines,
        None => {
            let index = (line as usize)
                .saturating_sub(1)
                .min(text.lines.len().saturating_sub(1));
            let own = text.line(index);
            let start = own.iter().take_while(|&&u| tex_space(u)).count();
            let label: Vec<u16> = "\\label".encode_utf16().collect();
            let before = (0..index).rev().find(|&i| !blank_line(text.line(i)));
            match before {
                Some(before) if own[start..].starts_with(&label) => before as u32 + 1..=line,
                _ => line..=line,
            }
        }
    }
}

fn scanned_whole(text: &Text, line: u32) -> SyncLines {
    let mut found = Found::default();
    let mut scanner = Scanner::default();
    scanner.run(&text.units, text.units.len(), &[], &mut found);
    lines_at(text, found, &scanner, line)
}

fn is_document(group: &Group) -> bool {
    group
        .environment()
        .is_some_and(|name| kind(name) == Kind::Document)
}

impl SourceDocument {
    pub fn sync_lines(&mut self, line: u32) -> SyncLines {
        let text = &self.text;
        let Some(index) = (line as usize)
            .checked_sub(1)
            .filter(|&i| i < text.lines.len())
        else {
            return SyncLines::Nowhere;
        };
        let (units, start) = (&text.units, text.lines[index] as usize);
        let mut scanner = self.scans.resume(text, start, start).scanner;
        let mut found = Found::default();
        scanner.run(units, start, &[], &mut found);
        if !scanner.groups().any(is_document) {
            return scanned_whole(text, line);
        }
        let end = |index: usize| {
            text.lines
                .get(index + 1)
                .map_or(units.len(), |&at| at as usize)
        };
        scanner.run(units, end(index), &[], &mut found);
        let open = scanner
            .groups()
            .filter(|g| g.environment().is_some() && !is_document(g));
        let open: Vec<usize> = open.map(|group| group.open).collect();
        let blank = (index + 1..text.lines.len()).find(|&i| blank_line(text.line(i)));
        scanner.run(units, blank.map_or(units.len(), end), &[], &mut found);
        while scanner.i < units.len() && scanner.groups().any(|g| open.contains(&g.open)) {
            let line_end = end(text.line_index(scanner.i as u32));
            scanner.run(units, line_end, &[], &mut found);
        }
        lines_at(text, found, &scanner, line)
    }
}

fn lines_at(text: &Text, mut found: Found, scanner: &Scanner, line: u32) -> SyncLines {
    let units = &text.units;
    let unclosed = scanner
        .groups()
        .filter_map(|group| group.environment().map(|name| (group, name)));
    let unclosed = unclosed.map(|(group, name)| (kind(name), group.open, units.len()));
    found.environments.extend(unclosed);
    let Some(index) = (line as usize)
        .checked_sub(1)
        .filter(|&i| i < text.lines.len())
    else {
        return SyncLines::Nowhere;
    };
    let line_of = |at: usize| text.line_index(at as u32) as u32 + 1;
    let spans = found.environments.iter();
    let spans = spans.map(|&(kind, open, close)| (kind, line_of(open)..=line_of(close)));
    let document = spans.clone().find(|(kind, _)| *kind == Kind::Document);
    let body = document.map_or(1..=text.lines.len() as u32, |(_, lines)| {
        lines.start() + 1..=lines.end().saturating_sub(1)
    });
    let blank = |line: u32| blank_line(text.line(line as usize - 1));
    let start = text.lines[index] as usize;
    let indent = units[start..].iter().take_while(|&&u| tex_space(u)).count();
    let commented = found.comments.binary_search(&(start + indent)).is_ok();
    if !body.contains(&line) || blank(line) || commented {
        return SyncLines::Nowhere;
    }
    let around: Vec<_> = spans
        .filter(|(kind, lines)| *kind != Kind::Document && lines.contains(&line))
        .collect();
    let outermost =
        |(_, lines): &&(Kind, RangeInclusive<u32>)| (*lines.start(), Reverse(*lines.end()));
    let pictures = around.iter().filter(|(kind, _)| *kind == Kind::Picture);
    if let Some((_, picture)) = pictures.min_by_key(outermost) {
        return SyncLines::Whole(picture.clone());
    }
    let range = match around.iter().max_by_key(outermost) {
        Some((_, environment)) => environment.clone(),
        None => {
            let first = (*body.start()..line)
                .rev()
                .find(|&l| blank(l))
                .map_or(*body.start(), |l| l + 1);
            let last = (line + 1..=*body.end())
                .find(|&l| blank(l))
                .map_or(*body.end(), |l| l - 1);
            first..=last
        }
    };
    SyncLines::Within { line, range }
}
