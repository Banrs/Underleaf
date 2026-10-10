//! Ranges a spelling checker should skip: TeX names, maths and literal code.
//! Name arguments include cases that the highlighter leaves uncoloured when
//! options come first, as in `\usepackage[utf8]{inputenc}`.

use crate::maths::{Point, Scans, Visit};
use crate::{blank, catalog::CATALOG, merge_range, Text, TextRange};

/// Absolute UTF-16 ranges to skip in `start..end`: math and literal code from
/// the shared math scan, plus name arguments from commands in the paragraph.
/// Name arguments are read from the paragraph's start as they cannot contain
/// a blank line; the scan resumes from a kept point before it.
pub fn not_prose(text: &Text, scans: &mut Scans, start: u32, end: u32) -> Vec<TextRange> {
    let mut line = text.line_index(start);
    while line > 0 && !blank(text.line(line - 1)) {
        line -= 1;
    }
    let paragraph = text.lines[line] as usize;
    let end_index = end as usize;
    let Point { mut scanner, run } = scans.resume(&text.units, paragraph, end_index);
    let mut found = Found {
        text,
        end: end_index,
        parsed_until: paragraph,
        ranges: run.map(|(from, to)| range(from, to)).into_iter().collect(),
        names: Vec::new(),
    };
    scanner.run(&text.units[..end_index], end_index, &[], &mut found);
    let Found {
        mut ranges, names, ..
    } = found;
    ranges.extend(names);
    ranges.retain(|r| {
        let range_end = r.start.saturating_add(r.length);
        if start == end {
            r.start <= start && start < range_end
        } else {
            r.start < end && range_end > start
        }
    });
    ranges.sort_unstable_by_key(|r| (r.start, r.start.saturating_add(r.length)));
    ranges.dedup_by(|range, previous| {
        if range.start > previous.start + previous.length {
            return false;
        }
        previous.length = previous
            .length
            .max(range.start + range.length - previous.start);
        true
    });
    ranges
}

fn range(from: usize, to: usize) -> TextRange {
    TextRange {
        start: from as u32,
        length: (to - from) as u32,
    }
}

/// What the scan finds: maths and code, and the name arguments of the
/// commands from `parsed_until` on.
struct Found<'a> {
    text: &'a Text,
    end: usize,
    parsed_until: usize,
    ranges: Vec<TextRange>,
    names: Vec<TextRange>,
}

impl Visit for Found<'_> {
    fn range(&mut self, from: usize, to: usize) {
        merge_range(&mut self.ranges, range(from, to));
    }

    fn command(&mut self, name: &str, command_start: usize, name_end: usize) {
        let catalog = &*CATALOG;
        if command_start >= self.parsed_until
            && [
                &catalog.name_commands,
                &catalog.cite_commands,
                &catalog.ref_commands,
            ]
            .iter()
            .any(|list| list.iter().any(|n| n == name))
        {
            self.parsed_until = argument_ranges(self.text, name_end, self.end, &mut self.names);
        }
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
                '\\' => {
                    i = (i + 2).min(end);
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
    use crate::SourceDocument;

    /// The name arguments `not_prose` finds in the whole source.
    fn names(source: &str) -> Vec<String> {
        let units: Vec<u16> = source.encode_utf16().collect();
        SourceDocument::new(source)
            .not_prose(0, units.len() as u32)
            .iter()
            .map(|r| {
                String::from_utf16_lossy(&units[r.start as usize..(r.start + r.length) as usize])
            })
            .collect()
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
    }

    #[test]
    fn from_the_paragraph_start() {
        let source = "\\usepackage{amsmath,\n  amssymb}\n\nText";
        let doc = SourceDocument::new(source);
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
        let ranges = SourceDocument::new(text).not_prose(0, text.len() as u32);
        let covered = |at: usize| {
            ranges
                .iter()
                .any(|r| r.start as usize <= at && at < (r.start + r.length) as usize)
        };
        assert!(!covered(text.find("Speling").unwrap()));
        assert!(covered(text.find("amssymb").unwrap()));
    }

    #[test]
    fn math_and_code_are_not_prose_but_math_text_commands_are() {
        let text = "Before $x + \\text{Speling stays} + y$ after\n\\begin{align}\na&=b\\label{eq:one}\\\n\\end{align}\n\\verb|Speling|";
        let ranges = SourceDocument::new(text).not_prose(0, text.encode_utf16().count() as u32);
        let covered = |needle: &str| {
            let at = text.find(needle).unwrap();
            let start = text[..at].encode_utf16().count() as u32;
            let length = needle.encode_utf16().count() as u32;
            ranges
                .iter()
                .any(|r| r.start <= start && r.start.saturating_add(r.length) >= start + length)
        };
        assert!(covered("$x + "));
        assert!(!covered("Speling stays"));
        assert!(covered("y$"));
        assert!(covered("a&=b"));
        assert!(covered("\\verb|Speling|"));
    }

    #[test]
    fn ranges_started_before_the_checked_slice_remain_absolute() {
        let text = "first\n\\begin{equation}\n𐐀 + x";
        let doc = SourceDocument::new(text);
        let word = text.find("𐐀").unwrap();
        let start = text[..word].encode_utf16().count() as u32;
        let found = doc.not_prose(start, 1);
        let math_start = text.find("\\begin").unwrap();
        let math_start = text[..math_start].encode_utf16().count() as u32;
        assert!(found.iter().any(|r| r.start == math_start));
        assert!(found.iter().any(|r| {
            r.start <= start && r.start + r.length == start + 1 && r.start + r.length > start
        }));
    }

    #[test]
    fn comments_and_unclosed_literal_code_keep_their_boundaries() {
        let text = "$x % Speling stays prose\n y$ \\begin{verbatim}\nSpeling code\n\\end{verbatim}\n\\begin{lstlisting}\nopen code";
        let ranges = SourceDocument::new(text).not_prose(0, text.encode_utf16().count() as u32);
        let covered_at = |needle: &str| {
            let at = text.find(needle).unwrap();
            let offset = text[..at].encode_utf16().count() as u32;
            ranges
                .iter()
                .any(|r| r.start <= offset && offset < r.start + r.length)
        };
        assert!(covered_at("x"));
        assert!(!covered_at("Speling stays"));
        assert!(covered_at("y$"));
        assert!(covered_at("Speling code"));
        assert!(covered_at("open code"));

        let code = text.find("Speling code").unwrap();
        let code_start = text[..code].encode_utf16().count() as u32;
        let inside_code = SourceDocument::new(text).not_prose(code_start, 1);
        let verbatim_start = text.find("\\begin{verbatim}").unwrap();
        let verbatim_start = text[..verbatim_start].encode_utf16().count() as u32;
        assert!(inside_code
            .iter()
            .any(|r| r.start == verbatim_start && r.start + r.length == code_start + 1));
    }

    #[test]
    fn commands_inside_literal_code_do_not_suppress_following_prose() {
        let text = "\\begin{verbatim}\n\\input{raw\n\\end{verbatim}\nSpeling prose";
        let units = text.encode_utf16().count() as u32;
        let doc = SourceDocument::new(text);
        let ranges = doc.not_prose(0, units);
        let prose = text.find("Speling").unwrap();
        let prose = text[..prose].encode_utf16().count() as u32;
        assert!(!ranges
            .iter()
            .any(|r| r.start <= prose && r.start + r.length > prose));

        let checked = doc.not_prose(prose, 1);
        assert!(checked.is_empty());
    }
}
