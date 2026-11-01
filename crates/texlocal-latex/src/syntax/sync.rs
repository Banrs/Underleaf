use std::cmp::Reverse;
use std::ops::{Range, RangeInclusive};

use super::Text;
use super::scan::{Group, Scanner, Visit, blank_line, tex_space};

/// The source lines a forward sync from one line may land on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncLines {
    /// The line typesets nothing: the preamble, the lines after the document, blank lines and comments.
    Nowhere,
    /// The line is in a picture, which is shown whole.
    Whole(RangeInclusive<u32>),
    /// The line itself, else the nearest line after it in its range, else the nearest before it.
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
    let text = Text::new(text);
    let units = &text.units;
    let mut found = Found::default();
    let mut scanner = Scanner::default();
    scanner.run(units, units.len(), &[], &mut found);
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
