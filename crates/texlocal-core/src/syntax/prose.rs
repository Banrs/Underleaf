//! Ranges a spelling checker should skip: TeX names, maths and literal code.
//! Name arguments include cases that the highlighter leaves uncoloured when
//! options come first, as in `\usepackage[utf8]{inputenc}`.

use super::maths::{Scans, Visit};
use super::{Text, TextRange, blank, catalog::CATALOG};

/// Absolute UTF-16 ranges to skip in `start..end` (all of the text reached):
/// math and literal code from the shared math scan, plus name arguments. The
/// scan resumes from a kept point before `start`, which carries how far
/// names have been read.
pub fn not_prose(text: &Text, scans: &mut Scans, start: u32, end: u32) -> Vec<TextRange> {
    let mut point = scans.resume(text, start as usize, end as usize);
    let ranges = Vec::from_iter(point.run.map(|(from, to)| range(from, to)));
    let (end, reading, names) = (end as usize, point.names, Vec::new());
    let mut found = Found {
        text,
        end,
        ranges,
        names,
        reading,
    };
    found.reading.resume(text, end, &mut found.names);
    let units = &text.units()[..end];
    point.scanner.run(units, end, &[], &mut found);
    let (mut ranges, end) = (found.ranges, end as u32);
    ranges.extend(found.names);
    // Those that overlap the range, or hold its start when it's empty.
    let ends = |r: &TextRange| r.start.saturating_add(r.length);
    ranges.retain(|r| ends(r) > start && (r.start < end || r.start == start));
    ranges.sort_unstable_by_key(|r| (r.start, ends(r)));
    let mut merged = Vec::new();
    ranges.into_iter().for_each(|r| merge_range(&mut merged, r));
    merged
}

/// Append a range to an ordered list, joining overlap and adjacency.
fn merge_range(ranges: &mut Vec<TextRange>, range: TextRange) {
    match ranges.last_mut() {
        Some(last) if range.start <= last.start + last.length => {
            last.length = last.length.max(range.start + range.length - last.start);
        }
        _ => ranges.push(range),
    }
}

fn range(from: usize, to: usize) -> TextRange {
    super::range(from as u32, (to - from) as u32)
}

/// Where name arguments have been read to, and where the last command that
/// takes them starts its: a reading resumed after it reads that again, as it
/// may run on past where it resumes. A command inside another's names is
/// none, and none is read across a blank line, so a paragraph's start needs
/// nothing from before it.
#[derive(Clone, Copy, Default)]
pub(crate) struct Names {
    from: Option<usize>,
    parsed_until: usize,
}

impl Names {
    pub fn command(
        &mut self,
        text: &Text,
        (name, start, name_end): (&str, usize, usize),
        end: usize,
        ranges: &mut Vec<TextRange>,
    ) {
        let c = &*CATALOG;
        let lists = [&c.name_commands, &c.cite_commands, &c.ref_commands];
        if start >= self.parsed_until && lists.iter().any(|l| l.iter().any(|n| n == name)) {
            self.from = Some(name_end);
            self.parsed_until = argument_ranges(text, name_end, end, ranges);
        }
    }

    pub fn resume(&mut self, text: &Text, end: usize, ranges: &mut Vec<TextRange>) {
        if let Some(from) = self.from {
            self.parsed_until = argument_ranges(text, from, end, ranges);
        }
    }
}

/// What the scan finds: maths and code, and name arguments.
struct Found<'a> {
    text: &'a Text,
    end: usize,
    ranges: Vec<TextRange>,
    names: Vec<TextRange>,
    reading: Names,
}

impl Visit for Found<'_> {
    fn range(&mut self, from: usize, to: usize) {
        merge_range(&mut self.ranges, range(from, to));
    }

    fn command(&mut self, name: &str, start: usize, name_end: usize) {
        let command = (name, start, name_end);
        (self.reading).command(self.text, command, self.end, &mut self.names);
    }
}

/// Options and the first braced argument, stopping at a blank line or EOF.
fn argument_ranges(text: &Text, mut i: usize, end: usize, ranges: &mut Vec<TextRange>) -> usize {
    let at = |i| char::from_u32(text.units()[i] as u32).unwrap_or_default();
    let paragraph_end =
        |i| at(i) == '\n' && i + 1 < end && blank(text.line(text.line_index(i as u32 + 1)));
    let mut push = |from: usize, to: usize| ranges.push(range(from, to));
    let (mut close, mut from, mut depth) = (None, 0, 0);
    i += (i < end && at(i) == '*') as usize;
    while i < end && !paragraph_end(i) {
        let c = at(i);
        if c == '%' {
            if close.is_some() {
                push(from, i);
            }
            while i < end && at(i) != '\n' {
                i += 1;
            }
            from = i;
            continue;
        }
        if let Some(delimiter) = close {
            match c {
                // An escape, but not of a line feed: that may end the paragraph.
                '\\' if i + 1 < end && at(i + 1) != '\n' => i += 1,
                '{' => depth += 1,
                '}' if depth > 0 => depth -= 1,
                c if c == delimiter && depth == 0 => {
                    push(from, i);
                    close = None;
                    if delimiter == '}' {
                        i += 1;
                        break;
                    }
                }
                _ => {}
            }
        } else {
            close = match c {
                '[' => Some(']'),
                '{' => Some('}'),
                ' ' | '\t' | '\r' | '\n' => None,
                _ => break,
            };
            from = i + 1;
        }
        i += 1;
    }
    if close.is_some() {
        push(from, i);
    }
    i
}

#[cfg(test)]
mod tests {
    use crate::syntax::{SourceDocument, TextRange, range, utf16};

    /// What isn't prose in the whole of `text`.
    fn whole(text: &str) -> Vec<TextRange> {
        SourceDocument::new(text).not_prose(0, utf16(text) as u32)
    }

    /// Where `needle` is, the first in `text`, in UTF-16 units.
    fn find(text: &str, needle: &str) -> u32 {
        utf16(&text[..text.find(needle).unwrap()]) as u32
    }

    /// Whether a range holds all of each needle (split at ";"), after "+",
    /// or none of it, after "-".
    fn skips(text: &str, needles: &str) {
        let ranges = whole(text);
        for needle in needles.split(';') {
            let (code, needle) = (needle.starts_with('+'), &needle[1..]);
            let start = find(text, needle);
            let end = start + utf16(needle) as u32;
            let all = |r: &TextRange| r.start <= start && end <= r.start + r.length;
            let none = |r: &TextRange| r.start + r.length <= start || end <= r.start;
            let found = [ranges.iter().any(all), ranges.iter().all(none)];
            assert_eq!(found, [code, !code], "{needle} in {text}");
        }
    }

    #[test]
    fn names_but_not_prose() {
        for case in [
            r"\usepackage[utf8]{inputenc} => utf8|inputenc",
            r"see \cite[p.~3]{knuth, lamport} and \cref*{fig:a}. => p.~3|knuth, lamport|fig:a",
            r"\includegraphics[width=0.8\linewidth]{plots/a b} => width=0.8\linewidth|plots/a b",
            // Only the first braced argument: a frame's title is prose.
            r"\begin{frame}{Title} \emph{x} \\ \%cite{y} => frame",
            "\\usepackage{amsmath,\n  {amssymb}} => amsmath,\n  {amssymb}",
            // Not in a comment, nor past a blank line, nor after a backslash ending a line.
            "% \\cite{x}\n\\input{a\n\nprose} => a",
            "\\cite{a\\\n\nprose} => a\\",
            // On the lines after their command.
            "\\usepackage\n[utf8]\n{inputenc} => utf8|inputenc",
            "😀 \\cite\n{𐐀key} => 𐐀key",
        ] {
            let (source, names) = case.split_once(" => ").unwrap();
            let units: Vec<u16> = source.encode_utf16().collect();
            let text = |r: &TextRange| {
                String::from_utf16_lossy(&units[r.start as usize..][..r.length as usize])
            };
            let found: Vec<String> = whole(source).iter().map(text).collect();
            assert_eq!(found.join("|"), names);
        }
        // A comment in one stays prose, and doesn't close it.
        let text = "\\usepackage{amsmath,% Speling }\n amssymb}";
        skips(text, "-Speling;+amssymb");
    }

    #[test]
    fn maths_and_code_are_not_prose_but_maths_text_is() {
        let text = "Before $x + \\text{Speling stays} + y$ after\n\\begin{align}\na&=b\\label{eq:one}\\\n\\end{align}\n\\verb|Speling|";
        skips(text, "+$x + ;-Speling stays;+y$;+a&=b;+\\verb|Speling|");
        let text = "$x % Speling stays prose\n y$ \\begin{verbatim}\nSpeling code\n\\end{verbatim}\n\\begin{lstlisting}\nopen code";
        skips(text, "+x;-Speling stays;+y$;+Speling code;+open code");
        // An unclosed \verb is code to its line's end, and no more.
        skips("\\verb|Speling\nprose \\cite{key}", "+Speling;-prose");
        // A command in literal code is the code's.
        let text = "\\begin{verbatim}\n\\input{raw\n\\end{verbatim}\nSpeling prose";
        skips(text, "-Speling");
    }

    #[test]
    fn a_range_is_whole_from_its_start() {
        let mut doc = SourceDocument::new("\\usepackage{amsmath,\n  amssymb}\n\nText");
        assert_eq!(doc.not_prose(25, 1), [range(12, 14)]); // in "amssymb"
        assert!(doc.not_prose(36, 2).is_empty()); // in "Text"
        // Maths and code started before the question, a unit asked about at
        // "+"; nothing of literal code's commands outlives it, at "-".
        for case in [
            "first\n\\begin{equation}\n𐐀 + x => +𐐀",
            "x \\begin{verbatim}\nSpeling code\n\\end{verbatim} => +Speling",
            "\\begin{verbatim}\n\\input{raw\n\\end{verbatim}\nSpeling prose => -Speling",
        ] {
            let (text, at) = case.split_once(" => ").unwrap();
            let (start, begin) = (find(text, &at[1..]), find(text, "\\begin"));
            let expected = at.starts_with('+').then(|| range(begin, start + 1 - begin));
            let found = SourceDocument::new(text).not_prose(start, 1);
            assert_eq!(found, Vec::from_iter(expected), "{text}");
        }
    }
}
