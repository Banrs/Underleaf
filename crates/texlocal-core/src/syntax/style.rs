use std::ops::Range;

use serde::Serialize;

use super::scan::{Group, Visit};
use super::{NAME, SourceDocument, TextEdit, TextRange, ascii, clamp, splice};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct TextStyles {
    pub bold: Option<Vec<TextEdit>>,
    pub italic: Option<Vec<TextEdit>>,
    pub underline: Option<Vec<TextEdit>>,
}

#[derive(Clone, Copy, PartialEq)]
enum Shape {
    Upright,
    Slanted,
    Italic(usize),
}

struct Found {
    start: usize,
    end: usize,
    open: Vec<Vec<Group>>,
    closes: Vec<(usize, usize)>,
    whole: Option<Group>,
}

impl Visit for Found {
    fn at(&mut self, groups: Vec<Group>) {
        self.open.push(groups);
    }

    fn closed(&mut self, group: &Group, close: Range<usize>) {
        let (Some((command, _)), close) = (group.command, close.start) else {
            return;
        };
        if close >= self.end && group.open < self.start {
            self.closes.push((group.open, close));
        } else if command == self.start && close + 1 == self.end {
            self.closes.push((group.open, close));
            self.whole = Some(group.clone());
        }
    }
}

impl SourceDocument {
    pub fn text_styles(&mut self, selection: TextRange) -> TextStyles {
        let (start, end) = clamp(selection, self.text.len()).bounds();
        let src = &self.text.units;
        let mut found = Found {
            start,
            end,
            open: Vec::new(),
            closes: Vec::new(),
            whole: None,
        };
        let mut scanner = self.scans.resume(&self.text, start, src.len()).scanner;
        scanner.run(src, src.len(), &[start, end], &mut found);
        let [at_start, at_end] = [&found.open[0], &found.open[1]];
        let mut groups: Vec<&Group> = at_start
            .iter()
            .zip(at_end)
            .take_while(|(a, b)| a.open == b.open)
            .map(|(a, _)| a)
            .collect();
        groups.extend(found.whole.as_ref());
        let text_from = groups.iter().rposition(|g| g.math).map_or(0, |k| k + 1);
        let (mut bold, mut shape, mut underline) = (None, Shape::Upright, None);
        for (k, group) in groups.iter().enumerate().skip(text_from) {
            let Some((backslash, name_end)) = group.command else {
                continue;
            };
            match ascii(&src[backslash + 1..name_end], &mut [0; NAME]) {
                "textbf" => bold = Some(k),
                "textmd" => bold = None,
                "textnormal" => (bold, shape) = (None, Shape::Upright),
                "textit" => shape = Shape::Italic(k),
                "textsl" => shape = Shape::Slanted,
                "textup" => shape = Shape::Upright,
                "emph" => {
                    shape = match shape {
                        Shape::Upright => Shape::Italic(k),
                        _ => Shape::Upright,
                    }
                }
                "underline" => underline = Some(k),
                _ => {}
            }
        }
        let italic = match shape {
            Shape::Italic(k) => Some(k),
            _ => None,
        };
        let unwrap = |k: Option<usize>| {
            let group = groups[k?];
            let (backslash, _) = group.command?;
            let close = found.closes.iter().find(|c| c.0 == group.open)?.1;
            Some(vec![
                splice(backslash, group.open + 1 - backslash, ""),
                splice(close, 1, ""),
            ])
        };
        TextStyles {
            bold: unwrap(bold),
            italic: unwrap(italic),
            underline: unwrap(underline),
        }
    }
}
