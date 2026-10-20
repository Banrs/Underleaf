//! What isn't prose: maths, literal code, command names and the names commands take (and, for Writing Tools,
//! comments). What's left is the text's words, which the status bar counts.

use super::scan::{Scanner, Visit, arguments};
use super::{Checker, SourceDocument, Text, TextRange, catalog::CATALOG, clamp, span};

impl SourceDocument {
    pub fn code_ranges(&mut self, selection: TextRange, checker: Checker) -> Vec<TextRange> {
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

/// Where name arguments have been read to, and where the last command that takes them starts its: a reading resumed
/// after it reads that again. A command inside another's names is none, and none is read across a blank line.
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
        if command_start >= self.parsed_until && lists.iter().any(|l| l.contains(name)) {
            self.from = Some(name_end);
            self.resume(text, end, ranges);
        }
    }

    pub fn resume(&mut self, text: &Text, end: usize, ranges: &mut Vec<TextRange>) {
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

/// A file's words: runs of prose that hold a letter, prose being what Writing Tools is given. Each command outside
/// maths and code goes to `command` too, so the outline finds its headings and inputs in the same reading.
pub(crate) fn words(text: &Text, command: impl FnMut(&Text, &str, usize)) -> usize {
    let len = text.units.len();
    let writing = Checker::WritingTools;
    let mut reading = Reading::new(text, len, Names::default(), writing, command);
    Scanner::default().run(&text.units, len, &[], &mut reading);
    let mut skipped = reading.ranges;
    skipped.extend(reading.others);
    let (mut words, mut at) = (0, 0);
    for r in merged(skipped).iter().chain([&span(len, 0)]) {
        words += count(&text.units[at..r.start as usize]);
        at = (r.start + r.length) as usize;
    }
    words
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

#[cfg(test)]
mod tests {
    use crate::syntax::{Checker, SourceDocument, TextRange, range, utf16};

    fn code(doc: &mut SourceDocument, start: u32, length: u32) -> Vec<TextRange> {
        doc.code_ranges(range(start, length), Checker::Spelling)
    }

    fn whole(text: &str) -> Vec<TextRange> {
        code(&mut SourceDocument::new(text), 0, utf16(text) as u32)
    }

    fn names(source: &str) -> Vec<String> {
        let units: Vec<u16> = source.encode_utf16().collect();
        let text = |r: &TextRange| {
            String::from_utf16_lossy(&units[r.start as usize..(r.start + r.length) as usize])
        };
        let ranges = whole(source);
        let names = ranges.iter().map(text);
        names.filter(|name| !name.starts_with('\\')).collect()
    }

    fn find(text: &str, needle: &str) -> std::ops::Range<u32> {
        let start = utf16(&text[..text.find(needle).unwrap()]) as u32;
        start..start + utf16(needle) as u32
    }

    fn covered(ranges: &[TextRange], text: &str, needle: &str) -> bool {
        let found = find(text, needle);
        ranges
            .iter()
            .any(|r| r.start <= found.start && found.end <= r.start + r.length)
    }

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
            names("\\bibitem[Knuth]{knuth84} The book"),
            ["Knuth", "knuth84"]
        );
        assert_eq!(
            names("see \\cite[e.g.][p.~3]{knuth, lamport} and \\cref*{fig:a}."),
            ["e.g.", "p.~3", "knuth, lamport", "fig:a"]
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
        // Not even after a backslash at the end of a line, a command with it.
        assert_eq!(names("\\cite{a\\\n\nprose}"), ["a\\\n"]);
    }

    #[test]
    fn from_the_paragraph_start() {
        let source = "\\usepackage{amsmath,\n  amssymb}\n\nText";
        let mut doc = SourceDocument::new(source);
        let found = code(&mut doc, 25, 1); // in "amssymb"
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].start, 12);
        assert_eq!(found[0].start + found[0].length, 26);
        assert!(code(&mut doc, 36, 2).is_empty()); // in "Text"
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
        let found = code(&mut SourceDocument::new(text), start, 1);
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
        let inside_code = code(&mut SourceDocument::new(text), code_start, 1);
        let verbatim_start = find(text, "\\begin{verbatim}").start;
        assert!(
            inside_code
                .iter()
                .any(|r| r.start == verbatim_start && r.start + r.length == code_start + 1)
        );

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
        let ranges = code(&mut doc, 0, utf16(text) as u32);
        assert!(prose(&ranges, text, "Speling"));
        assert!(code(&mut doc, find(text, "Speling").start, 1).is_empty());
    }
}
