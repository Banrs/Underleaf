//! The kernel's text styles a selection is in, as a word processor's Bold,
//! Italic and Underline show theirs, and the edits that take each away.

use serde::Serialize;

use crate::maths::{Group, Scans, Visit};
use crate::{ascii, edit, Text, TextEdit, TextRange, NAME};

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
        if close >= self.end && group.open < self.start {
            self.closes.push((group.open, close));
        } else if command == self.start && close + 1 == self.end {
            self.closes.push((group.open, close));
            self.whole = Some(group.clone());
        }
    }
}

/// The scan resumes from a kept point before the selection, and stops once
/// the groups open at its end have closed.
pub(crate) fn text_styles(text: &Text, scans: &mut Scans, selection: TextRange) -> TextStyles {
    let src = &text.units;
    let start = selection.start as usize;
    let end = start + selection.length as usize;
    let mut found = Found {
        start,
        end,
        open: Vec::new(),
        closes: Vec::new(),
        whole: None,
    };
    let mut scanner = scans.resume(text, start, src.len()).scanner;
    scanner.run(src, src.len(), &[start, end], &mut found);
    let Found {
        open,
        closes,
        whole,
        ..
    } = found;
    let [at_start, at_end] = [&open[0], &open[1]];
    let mut groups: Vec<&Group> = at_start
        .iter()
        .zip(at_end)
        .take_while(|(a, b)| a.open == b.open)
        .map(|(a, _)| a)
        .collect();
    groups.extend(whole.as_ref());
    // Only text styles: maths has its own (\mathbf).
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
        let close = closes.iter().find(|c| c.0 == group.open)?.1;
        Some(vec![
            edit(backslash as u32, (group.open + 1 - backslash) as u32, ""),
            edit(close as u32, 1, ""),
        ])
    };
    TextStyles {
        bold: unwrap(bold),
        italic: unwrap(italic),
        underline: unwrap(underline),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The styles at the selection marked by "«" and "»" (or the caret, "‸"),
    /// as each command's name, or "?" for one the edits don't unwrap.
    fn styles(marked: &str) -> [Option<String>; 3] {
        let (start, end) = match marked.find('‸') {
            Some(at) => (at, at),
            None => (
                marked.find('«').unwrap(),
                marked.find('»').unwrap() - '«'.len_utf8(),
            ),
        };
        let source: String = marked.chars().filter(|c| !"‸«»".contains(*c)).collect();
        let text = Text::new(&source);
        let units: Vec<u16> = source.encode_utf16().collect();
        let start16 = source[..start].encode_utf16().count() as u32;
        let end16 = source[..end].encode_utf16().count() as u32;
        let found = text_styles(
            &text,
            &mut Scans::default(),
            TextRange {
                start: start16,
                length: end16 - start16,
            },
        );
        [found.bold, found.italic, found.underline].map(|edits| {
            edits.map(|edits| {
                let (head, tail) = (&edits[0], &edits[1]);
                let opening = String::from_utf16_lossy(
                    &units[head.start as usize..(head.start + head.length) as usize],
                );
                let closing = units[tail.start as usize] == b'}' as u16;
                if opening.ends_with('{') && closing {
                    opening[1..]
                        .chars()
                        .take_while(char::is_ascii_alphabetic)
                        .collect()
                } else {
                    "?".to_string()
                }
            })
        })
    }

    fn just(
        bold: Option<&str>,
        italic: Option<&str>,
        underline: Option<&str>,
    ) -> [Option<String>; 3] {
        [bold, italic, underline].map(|s| s.map(str::to_string))
    }

    #[test]
    fn the_caret_takes_the_commands_it_is_in() {
        assert_eq!(
            styles(r"a \textbf{b‸c} d"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(
            styles(r"a \textbf{‸bc} d"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(
            styles(r"a \textbf{bc‸} d"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(styles(r"a ‸\textbf{bc} d"), just(None, None, None));
        assert_eq!(styles(r"a \textbf{bc}‸ d"), just(None, None, None));
        assert_eq!(
            styles(r"\textit{a \underline{b \textbf{c‸}}}"),
            just(Some("textbf"), Some("textit"), Some("underline"))
        );
        assert_eq!(styles(r"\textbf {a‸}"), just(Some("textbf"), None, None));
        assert_eq!(
            styles("\\textbf % bold\n{a‸}"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(styles("\\textbf\n\n{a‸}"), just(None, None, None));
        assert_eq!(styles(r"\textbf x{a‸}"), just(None, None, None));
    }

    #[test]
    fn the_innermost_command_is_the_one_to_unwrap() {
        let nested = r"\textbf{a \textbf{b‸} c}";
        let found = text_styles(
            &Text::new(&nested.replace('‸', "")),
            &mut Scans::default(),
            TextRange {
                start: 19,
                length: 0,
            },
        );
        assert_eq!(found.bold.unwrap()[0].start, 10);
        assert_eq!(styles(nested), just(Some("textbf"), None, None));
    }

    #[test]
    fn emph_is_italic_in_upright_text_and_upright_in_italic() {
        assert_eq!(styles(r"\emph{a‸}"), just(None, Some("emph"), None));
        assert_eq!(styles(r"\textit{\emph{a‸}}"), just(None, None, None));
        assert_eq!(styles(r"\emph{\emph{a‸}}"), just(None, None, None));
        assert_eq!(
            styles(r"\emph{\emph{\emph{a‸}}}"),
            just(None, Some("emph"), None)
        );
        assert_eq!(styles(r"\textsl{\emph{a‸}}"), just(None, None, None));
        assert_eq!(styles(r"\textit{\textup{a‸}}"), just(None, None, None));
        assert_eq!(
            styles(r"\textbf{\textit{\textnormal{a‸}}}"),
            just(None, None, None)
        );
        assert_eq!(styles(r"\textbf{\textmd{a‸}}"), just(None, None, None));
    }

    #[test]
    fn a_selection_takes_what_all_of_it_is_in() {
        assert_eq!(styles(r"\textbf{«ab»} c"), just(Some("textbf"), None, None));
        assert_eq!(styles(r"\textbf{a«b} c»"), just(None, None, None));
        assert_eq!(styles(r"\textbf{a«b} \textbf{c»}"), just(None, None, None));
        assert_eq!(
            styles(r"\textit{\textbf{«a} b»}"),
            just(None, Some("textit"), None)
        );
        // The whole command, as a double-click and a drag select it.
        assert_eq!(
            styles(r"x «\textbf{ab}» c"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(
            styles(r"\textit{«\textbf{ab}»}"),
            just(Some("textbf"), Some("textit"), None)
        );
    }

    #[test]
    fn braces_are_the_text_s_own() {
        assert_eq!(
            styles(r"\textbf{a \} b‸}"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(
            styles(r"\textbf{a \{ b‸}"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(
            styles("\\textbf{a % }\nb‸}"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(
            styles(r"\textbf{a \verb|}| b‸}"),
            just(Some("textbf"), None, None)
        );
        assert_eq!(
            styles("\\textbf{a\n\\begin{verbatim}\n}\n\\end{verbatim}\nb‸}"),
            just(Some("textbf"), None, None)
        );
        // Unclosed, there's nothing to unwrap.
        assert_eq!(styles(r"\textbf{a‸"), just(None, None, None));
    }

    #[test]
    fn maths_has_its_own_styles() {
        assert_eq!(styles(r"\textbf{$x‸$}"), just(None, None, None));
        assert_eq!(styles(r"\textbf{$\text{x‸}$}"), just(None, None, None));
        assert_eq!(styles(r"$\textbf{x‸}$"), just(Some("textbf"), None, None));
        assert_eq!(
            styles(r"$\text{\textit{x‸}}$"),
            just(None, Some("textit"), None)
        );
        assert_eq!(styles(r"$\mathbf{x‸}$"), just(None, None, None));
        assert_eq!(
            styles(r"\textbf{a \[ x \] b‸}"),
            just(Some("textbf"), None, None)
        );
    }
}
