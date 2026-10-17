//! The kernel's text styles a selection is in, as a word processor's Bold,
//! Italic and Underline show theirs, and the edits that take each away.

use serde::Serialize;

use super::maths::{Group, Scans, Visit};
use super::{NAME, Text, TextEdit, TextRange, ascii, edit};

/// The styles the whole selection has, each as the edits that unwrap the
/// innermost command giving it: its name and opening brace, then its closing
/// brace. Declarations ({\bfseries …}) aren't read, and nor is a command
/// whose argument doesn't close.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct TextStyles {
    pub bold: Option<Vec<TextEdit>>,
    pub italic: Option<Vec<TextEdit>>,
    pub underline: Option<Vec<TextEdit>>,
}

/// The font shape so far, outermost command first: \emph turns it upright
/// in italic or slanted text, as LaTeX's \em does, and italic otherwise.
#[derive(Clone, Copy, PartialEq)]
enum Shape {
    Upright,
    Slanted,
    Italic(usize),
}

/// The groups open at the selection's ends, and how the scan saw them close.
#[derive(Default)]
struct Found {
    start: usize,
    end: usize,
    open: Vec<Vec<Group>>,
    /// Where each group that may hold the selection closes, by where it opens.
    closes: Vec<(usize, usize)>,
    /// A command the selection is exactly, from its backslash to its brace.
    whole: Option<Group>,
}

impl Visit for Found {
    fn at(&mut self, groups: Vec<Group>) {
        self.open.push(groups);
    }

    fn closed(&mut self, group: &Group, close: usize) {
        let Some((command, _)) = group.command else {
            return;
        };
        // A group that holds the selection, or the command that is the selection.
        let whole = command == self.start && close + 1 == self.end;
        if whole || close >= self.end && group.open < self.start {
            self.closes.push((group.open, close));
        }
        if whole {
            self.whole = Some(group.clone());
        }
    }
}

/// The scan resumes from a kept point before the selection, and stops once
/// the groups open at its end have closed.
pub(crate) fn text_styles(text: &Text, scans: &mut Scans, selection: TextRange) -> TextStyles {
    use Shape::*;
    let (src, start) = (text.units(), selection.start as usize);
    let end = start + selection.length as usize;
    let mut found = Found { start, end, ..Found::default() };
    let mut scanner = scans.resume(text, start, src.len()).scanner;
    scanner.run(src, src.len(), &[start, end], &mut found);
    let (first, last) = (&found.open[0], &found.open[1]);
    let common = first.iter().zip(last).take_while(|(a, b)| a.open == b.open);
    let mut groups: Vec<&Group> = common.map(|(a, _)| a).collect();
    groups.extend(found.whole.as_ref());
    // Only text styles: maths has its own (\mathbf).
    let text_from = groups.iter().rposition(|g| g.math).map_or(0, |k| k + 1);
    let (mut bold, mut shape, mut underline) = (None, Upright, None);
    for (k, group) in groups.iter().enumerate().skip(text_from) {
        let Some((backslash, name_end)) = group.command else {
            continue;
        };
        match ascii(&src[backslash + 1..name_end], &mut [0; NAME]) {
            "textbf" => bold = Some(k),
            "textmd" => bold = None,
            "textnormal" => (bold, shape) = (None, Upright),
            "textit" => shape = Italic(k),
            "textsl" => shape = Slanted,
            "textup" => shape = Upright,
            "emph" => shape = if shape == Upright { Italic(k) } else { Upright },
            "underline" => underline = Some(k),
            _ => {}
        }
    }
    let italic = if let Italic(k) = shape { Some(k) } else { None };
    let unwrap = |k: Option<usize>| {
        let group = groups[k?];
        let (backslash, _) = group.command?;
        let close = found.closes.iter().find(|c| c.0 == group.open)?.1;
        let head = edit(backslash as u32, (group.open + 1 - backslash) as u32, "");
        Some(vec![head, edit(close as u32, 1, "")])
    };
    TextStyles { bold: unwrap(bold), italic: unwrap(italic), underline: unwrap(underline) }
}

#[cfg(test)]
mod tests {
    use crate::syntax::{SourceDocument, TextEdit, range, utf16};

    #[test]
    fn a_selection_has_the_styles_all_of_it_is_in() {
        // The selection marked by "«" and "»" (or the caret, "‸"), and its
        // styles, each as its command's name, "?" for one the edits don't
        // unwrap, or nothing for a style it hasn't: bold, italic and
        // underline, by spaces.
        for case in [
            // The caret takes the commands it is in.
            r"a \textbf{b‸c} d => textbf  ",
            r"a \textbf{‸bc} d => textbf  ",
            r"a \textbf{bc‸} d => textbf  ",
            r"a ‸\textbf{bc} d =>   ",
            r"a \textbf{bc}‸ d =>   ",
            r"\textit{a \underline{b \textbf{c‸}}} => textbf textit underline",
            r"\textbf {a‸} => textbf  ",
            "\\textbf % bold\n{a‸} => textbf  ",
            "\\textbf\n\n{a‸} =>   ",
            r"\textbf x{a‸} =>   ",
            // \emph is italic in upright text and upright in italic.
            r"\emph{a‸} =>  emph ",
            r"\textit{\emph{a‸}} =>   ",
            r"\emph{\emph{\emph{a‸}}} =>  emph ",
            r"\textsl{\emph{a‸}} =>   ",
            r"\textit{\textup{a‸}} =>   ",
            r"\textbf{\textit{\textnormal{a‸}}} =>   ",
            r"\textbf{\textmd{a‸}} =>   ",
            // A selection takes what all of it is in, or the command it is.
            r"\textbf{«ab»} c => textbf  ",
            r"\textbf{a«b} c» =>   ",
            r"\textbf{a«b} \textbf{c»} =>   ",
            r"\textit{\textbf{«a} b»} =>  textit ",
            r"x «\textbf{ab}» c => textbf  ",
            r"\textit{«\textbf{ab}»} => textbf textit ",
            // Braces are the text's own.
            r"\textbf{a \} b‸} => textbf  ",
            "\\textbf{a % }\nb‸} => textbf  ",
            r"\textbf{a \verb|}| b‸} => textbf  ",
            "\\textbf{a\n\\begin{verbatim}\n}\n\\end{verbatim}\nb‸} => textbf  ",
            r"\textbf{a‸ =>   ",
            // Maths has its own styles.
            r"\textbf{$x‸$} =>   ",
            r"\textbf{$\text{x‸}$} =>   ",
            r"$\textbf{x‸}$ => textbf  ",
            r"$\text{\textit{x‸}}$ =>  textit ",
            r"\textbf{a \[ x \] b‸} => textbf  ",
        ] {
            let (marked, expected) = case.split_once(" => ").unwrap();
            let at = |mark| utf16(&marked[..marked.find(mark).or(marked.find('‸')).unwrap()]);
            let source: String = marked.chars().filter(|c| !"‸«»".contains(*c)).collect();
            let (start, end) = (at('«'), at('»') - marked.contains('»') as usize);
            let selection = range(start as u32, (end - start) as u32);
            let found = SourceDocument::new(&source).text_styles(selection);
            let name = |edits: Option<Vec<TextEdit>>| {
                let Some([head, tail]) = edits.as_deref() else {
                    return String::new();
                };
                // The sources are ASCII: their units are their bytes.
                let opening = &source[head.start as usize..][..head.length as usize];
                let closed = source.as_bytes()[tail.start as usize] == b'}';
                let letters = |c: &str| -> String {
                    let name = c[1..].chars();
                    name.take_while(char::is_ascii_alphabetic).collect()
                };
                let command = opening.strip_suffix('{').filter(|_| closed);
                command.map_or("?".into(), letters)
            };
            let found = [found.bold, found.italic, found.underline].map(name);
            assert_eq!(found.join(" "), expected, "{marked}");
        }
        // The innermost command is the one to unwrap.
        let mut nested = SourceDocument::new(r"\textbf{a \textbf{b} c}");
        let bold = nested.text_styles(range(19, 0)).bold;
        assert_eq!(bold.unwrap()[0].start, 10);
    }
}
