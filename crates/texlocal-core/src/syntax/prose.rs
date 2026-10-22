//! What isn't prose: maths, literal code, command names and the names commands take (and, for Writing Tools,
//! comments). What's left is the text's words, which the status bar counts.

use std::ops::Range;

use super::scan::{Scanner, Visit, arguments};
use super::{Checker, SourceDocument, Text, TextRange, catalog::CATALOG, clamp, span};

impl SourceDocument {
    pub fn words(&self, selection: TextRange) -> usize {
        let (start, end) = clamp(selection, self.text.len()).bounds();
        prose(&self.text, |_, _, _| {}).words(start..end)
    }

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

/// A text read for its words: its prose is what Writing Tools is given, the runs between what
/// `skipped` holds.
pub(crate) struct Prose<'a> {
    units: &'a [u16],
    skipped: Vec<TextRange>,
}

/// Each command outside maths and code goes to `command` too, so the outline finds its headings
/// and inputs in the same reading.
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
    /// The runs of prose in `range` that hold a letter; one the range cuts counts on each side.
    pub fn words(&self, range: Range<usize>) -> usize {
        let end = |r: &TextRange| (r.start + r.length) as usize;
        // Merged, so ordered by their ends too: those before the range are passed over.
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

#[cfg(test)]
mod tests {
    use crate::syntax::{Checker, SourceDocument, range, utf16};

    /// The text with what `checker` passes over in «», of the whole text or of the character after `‸`.
    fn marked(source: &str, checker: Checker) -> String {
        let text = source.replace('‸', "");
        let units: Vec<u16> = text.encode_utf16().collect();
        let selection = match source.find('‸') {
            Some(at) => {
                let next = text[at..].chars().next().map_or(0, char::len_utf16);
                range(utf16(&text[..at]) as u32, next as u32)
            }
            None => range(0, units.len() as u32),
        };
        let ranges = SourceDocument::new(&text).code_ranges(selection, checker);
        let (mut marked, mut at) = (String::new(), 0);
        for r in ranges {
            let (start, end) = (r.start as usize, (r.start + r.length) as usize);
            marked += &String::from_utf16_lossy(&units[at..start]);
            marked.push('«');
            marked += &String::from_utf16_lossy(&units[start..end]);
            marked.push('»');
            at = end;
        }
        marked + &String::from_utf16_lossy(&units[at..])
    }

    fn spelling(source: &str) -> String {
        marked(source, Checker::Spelling)
    }

    /// What a command takes as names, not prose.
    fn names(source: &str) -> Vec<String> {
        let marked = spelling(source);
        let ranges = marked.split('«').skip(1).filter_map(|r| r.split_once('»'));
        ranges
            .map(|(name, _)| name.to_owned())
            .filter(|name| !name.starts_with('\\'))
            .collect()
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
        assert_eq!(
            names("\\usepackage\n[utf8]\n{inputenc}"),
            ["utf8", "inputenc"]
        );
        assert_eq!(names("😀 \\cite\n{𐐀key}"), ["𐐀key"]);
    }

    /// Both checkers pass over command names, an escape's too, and what isn't prose; only spelling checks a comment.
    #[test]
    fn checkers_leave_code_alone() {
        let text = "Prose \\emph{word} $x$ 50\\% % note";
        assert_eq!(spelling(text), "Prose «\\emph»{word} «$x$» 50«\\%» % note");
        let writing = marked(text, Checker::WritingTools);
        assert_eq!(writing, "Prose «\\emph»{word} «$x$» 50«\\%» «% note»");
    }

    /// A question reads from the paragraph's start, and what started before it keeps its own start.
    #[test]
    fn a_question_answers_from_where_its_ranges_start() {
        let cases = [
            (
                "\\usepackage{amsmath,\n  amss‸ymb}\n\nText",
                "\\usepackage{«amsmath,\n  amssy»mb}\n\nText",
            ),
            (
                "\\usepackage{amsmath,\n  amssymb}\n\nT‸ext",
                "\\usepackage{amsmath,\n  amssymb}\n\nText",
            ),
            (
                "first\n\\begin{equation}\n‸𐐀 + x",
                "first\n«\\begin{equation}\n𐐀» + x",
            ),
            (
                "$x$ \\begin{verbatim}\n‸Speling code\n\\end{verbatim}",
                "$x$ «\\begin{verbatim}\nS»peling code\n\\end{verbatim}",
            ),
            (
                "\\begin{verbatim}\n\\input{raw\n\\end{verbatim}\n‸Speling prose",
                "\\begin{verbatim}\n\\input{raw\n\\end{verbatim}\nSpeling prose",
            ),
        ];
        for (source, expected) in cases {
            assert_eq!(spelling(source), expected, "{source:?}");
        }
    }

    /// A comment stays prose and closes nothing, maths' text commands hold prose, and literal code runs to its end
    /// or the text's, holding no commands.
    #[test]
    fn maths_and_code_are_not_prose() {
        let cases = [
            (
                "\\usepackage{amsmath,% Speling }\n amssymb}",
                "«\\usepackage»{«amsmath,»% Speling }«\n amssymb»}",
            ),
            (
                "Before $x + \\text{Speling stays} + y$ after",
                "Before «$x + \\text{»Speling stays«} + y$» after",
            ),
            (
                "\\begin{align}\na&=b\\label{eq:one}\\\n\\end{align}",
                "«\\begin{align}\na&=b\\label{eq:one}\\\n\\end{align}»",
            ),
            (
                "$x % Speling stays prose\n y$",
                "«$x »% Speling stays prose\n« y$»",
            ),
            (
                "\\begin{verbatim}\nSpeling code\n\\end{verbatim}\n\\begin{lstlisting}\nopen code",
                "«\\begin{verbatim}\nSpeling code\n\\end{verbatim}»\n«\\begin{lstlisting}\nopen code»",
            ),
            (
                "\\verb|Speling|\n\\verb|Speling\nprose \\cite{key}",
                "«\\verb|Speling|»\n«\\verb|Speling»\nprose «\\cite»{«key»}",
            ),
            (
                "\\begin{verbatim}\n\\input{raw\n\\end{verbatim}\nSpeling prose",
                "«\\begin{verbatim}\n\\input{raw\n\\end{verbatim}»\nSpeling prose",
            ),
        ];
        for (source, expected) in cases {
            assert_eq!(spelling(source), expected, "{source:?}");
        }
    }

    /// Read in the whole text, so a range that starts in maths knows it.
    #[test]
    fn a_range_counts_its_prose_words_alone() {
        let text = "Before $x + y$ one \\textbf{two} \\cite{key} three. After";
        let (start, end) = (text.find("+ y").unwrap(), text.find(". After").unwrap());
        let args = format!(r#"{{"start": {start}, "length": {}}}"#, end - start);
        let words = SourceDocument::new(text).call("words", &args);
        assert_eq!(words.as_deref(), Some(r#"{"words":3}"#));
    }
}
