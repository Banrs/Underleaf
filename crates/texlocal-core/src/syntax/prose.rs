//! Ranges a spelling checker should skip: TeX names, maths and literal code.
//! Name arguments include cases that the highlighter leaves uncoloured when
//! options come first, as in `\usepackage[utf8]{inputenc}`.

use super::maths::{Point, Scans, Visit};
use super::{Text, TextRange, blank, catalog::CATALOG};

/// Absolute UTF-16 ranges to skip in `start..end`: math and literal code from
/// the shared math scan, plus name arguments. The scan resumes from a kept
/// point before `start`, which carries how far names have been read.
pub fn not_prose(text: &Text, scans: &mut Scans, start: u32, end: u32) -> Vec<TextRange> {
    let end_index = end as usize;
    let Point {
        mut scanner,
        run,
        names,
    } = scans.resume(text, start as usize, end_index);
    let mut found = Found {
        text,
        end: end_index,
        ranges: run.map(|(from, to)| range(from, to)).into_iter().collect(),
        names: Vec::new(),
        reading: names,
    };
    found.reading.resume(text, end_index, &mut found.names);
    scanner.run(&text.units[..end_index], end_index, &[], &mut found);
    let mut ranges = found.ranges;
    ranges.extend(found.names);
    ranges.retain(|r| {
        let range_end = r.start.saturating_add(r.length);
        if start == end {
            r.start <= start && start < range_end
        } else {
            r.start < end && range_end > start
        }
    });
    ranges.sort_unstable_by_key(|r| (r.start, r.start.saturating_add(r.length)));
    ranges.into_iter().fold(Vec::new(), |mut merged, range| {
        merge_range(&mut merged, range);
        merged
    })
}

/// Append a range to an ordered list, joining overlap and adjacency.
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

fn range(from: usize, to: usize) -> TextRange {
    TextRange {
        start: from as u32,
        length: (to - from) as u32,
    }
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
        if command_start >= self.parsed_until && lists.iter().any(|l| l.iter().any(|n| n == name)) {
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

    fn command(&mut self, name: &str, command_start: usize, name_end: usize) {
        let command = (name, command_start, name_end);
        self.reading
            .command(self.text, command, self.end, &mut self.names);
    }
}

/// Options and the first braced argument, stopping at a blank line or EOF.
fn argument_ranges(text: &Text, mut i: usize, end: usize, ranges: &mut Vec<TextRange>) -> usize {
    let at = |i| char::from_u32(text.units[i] as u32).unwrap_or_default();
    let paragraph_end =
        |i| at(i) == '\n' && i + 1 < end && blank(text.line(text.line_index(i as u32 + 1)));
    let mut push = |from: usize, to: usize| ranges.push(range(from, to));
    let mut close = None;
    let (mut from, mut depth) = (0, 0);
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
                '\\' if i + 1 < end && at(i + 1) != '\n' => {
                    i += 2;
                    continue;
                }
                '{' => depth += 1,
                '}' if depth > 0 => depth -= 1,
                c if c == delimiter && depth == 0 => {
                    push(from, i);
                    i += 1;
                    close = None;
                    if delimiter == '}' {
                        break;
                    }
                    continue;
                }
                _ => {}
            }
        } else {
            close = match c {
                '[' => Some(']'),
                '{' => Some('}'),
                ' ' | '\t' | '\r' | '\n' => {
                    i += 1;
                    continue;
                }
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
    use crate::syntax::{SourceDocument, TextRange, utf16};

    /// What isn't prose in the whole of `text`.
    fn whole(text: &str) -> Vec<TextRange> {
        SourceDocument::new(text).not_prose(0, utf16(text) as u32)
    }

    /// The name arguments `not_prose` finds in the whole source.
    fn names(source: &str) -> Vec<String> {
        let units: Vec<u16> = source.encode_utf16().collect();
        whole(source)
            .iter()
            .map(|r| {
                String::from_utf16_lossy(&units[r.start as usize..(r.start + r.length) as usize])
            })
            .collect()
    }

    /// Where `needle` is, the first in `text`, in UTF-16 units.
    fn find(text: &str, needle: &str) -> std::ops::Range<u32> {
        let start = utf16(&text[..text.find(needle).unwrap()]) as u32;
        start..start + utf16(needle) as u32
    }

    /// Whether a range holds all of `needle`.
    fn covered(ranges: &[TextRange], text: &str, needle: &str) -> bool {
        let found = find(text, needle);
        ranges
            .iter()
            .any(|r| r.start <= found.start && found.end <= r.start + r.length)
    }

    /// Whether no range holds any of `needle`.
    fn prose(ranges: &[TextRange], text: &str, needle: &str) -> bool {
        let found = find(text, needle);
        ranges
            .iter()
            .all(|r| r.start + r.length <= found.start || found.end <= r.start)
    }

    #[test]
    fn names_but_not_prose() {
        assert_eq!(names("\\usepackage[utf8]{inputenc}"), ["utf8", "inputenc"]);
        assert_eq!(
            names("see \\cite[p.~3]{knuth, lamport} and \\cref*{fig:a}."),
            ["p.~3", "knuth, lamport", "fig:a"]
        );
        assert_eq!(
            names("\\includegraphics[width=0.8\\linewidth]{plots/a b}"),
            ["width=0.8\\linewidth", "plots/a b"]
        );
        // Only the first braced argument: a frame's title is prose.
        assert_eq!(
            names("\\begin{frame}{Title} \\emph{x} \\\\ \\%cite{y}"),
            ["frame"]
        );
        assert_eq!(
            names("\\usepackage{amsmath,\n  {amssymb}}"),
            ["amsmath,\n  {amssymb}"]
        );
        // Not in a comment, nor past a blank line.
        assert_eq!(names("% \\cite{x}\n\\input{a\n\nprose}"), ["a"]);
        // Not even after a backslash at the end of a line.
        assert_eq!(names("\\cite{a\\\n\nprose}"), ["a\\"]);
    }

    #[test]
    fn from_the_paragraph_start() {
        let source = "\\usepackage{amsmath,\n  amssymb}\n\nText";
        let mut doc = SourceDocument::new(source);
        let found = doc.not_prose(25, 1); // in "amssymb"
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].start, 12);
        assert_eq!(found[0].start + found[0].length, 26);
        assert!(doc.not_prose(36, 2).is_empty()); // in "Text"
    }

    #[test]
    fn arguments_can_start_on_the_next_line() {
        assert_eq!(
            names("\\usepackage\n[utf8]\n{inputenc}"),
            ["utf8", "inputenc"]
        );
        assert_eq!(names("😀 \\cite\n{𐐀key}"), ["𐐀key"]);
    }

    #[test]
    fn comments_inside_arguments_stay_prose_and_do_not_close_the_argument() {
        let text = "\\usepackage{amsmath,% Speling }\n amssymb}";
        let ranges = whole(text);
        assert!(prose(&ranges, text, "Speling"));
        assert!(covered(&ranges, text, "amssymb"));
    }

    #[test]
    fn math_and_code_are_not_prose_but_math_text_commands_are() {
        let text = "Before $x + \\text{Speling stays} + y$ after\n\\begin{align}\na&=b\\label{eq:one}\\\n\\end{align}\n\\verb|Speling|";
        let ranges = whole(text);
        assert!(covered(&ranges, text, "$x + "));
        assert!(prose(&ranges, text, "Speling stays"));
        assert!(covered(&ranges, text, "y$"));
        assert!(covered(&ranges, text, "a&=b"));
        assert!(covered(&ranges, text, "\\verb|Speling|"));
    }

    #[test]
    fn ranges_started_before_the_checked_slice_remain_absolute() {
        let text = "first\n\\begin{equation}\n𐐀 + x";
        let start = find(text, "𐐀").start;
        let found = SourceDocument::new(text).not_prose(start, 1);
        assert!(found.iter().any(|r| r.start == find(text, "\\begin").start));
        let to_it = |r: &TextRange| r.start <= start && r.start + r.length == start + 1;
        assert!(found.iter().any(to_it));
    }

    #[test]
    fn comments_and_unclosed_literal_code_keep_their_boundaries() {
        let text = "$x % Speling stays prose\n y$ \\begin{verbatim}\nSpeling code\n\\end{verbatim}\n\\begin{lstlisting}\nopen code";
        let ranges = whole(text);
        assert!(covered(&ranges, text, "x"));
        assert!(prose(&ranges, text, "Speling stays"));
        assert!(covered(&ranges, text, "y$"));
        assert!(covered(&ranges, text, "Speling code"));
        assert!(covered(&ranges, text, "open code"));

        let code_start = find(text, "Speling code").start;
        let inside_code = SourceDocument::new(text).not_prose(code_start, 1);
        let verbatim_start = find(text, "\\begin{verbatim}").start;
        assert!(
            inside_code
                .iter()
                .any(|r| r.start == verbatim_start && r.start + r.length == code_start + 1)
        );

        // An unclosed \verb is code to its line's end, and no more.
        let text = "\\verb|Speling\nprose \\cite{key}";
        let ranges = whole(text);
        assert!(covered(&ranges, text, "Speling"));
        assert!(prose(&ranges, text, "prose"));
        assert!(covered(&ranges, text, "key"));
    }

    #[test]
    fn commands_inside_literal_code_do_not_suppress_following_prose() {
        let text = "\\begin{verbatim}\n\\input{raw\n\\end{verbatim}\nSpeling prose";
        let mut doc = SourceDocument::new(text);
        let ranges = doc.not_prose(0, utf16(text) as u32);
        assert!(prose(&ranges, text, "Speling"));
        assert!(doc.not_prose(find(text, "Speling").start, 1).is_empty());
    }
}
