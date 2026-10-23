//! What a session finds wrong in a project without TeX: references, citations and inputs
//! nothing defines, names defined twice, and environments, braces and maths left open, in the
//! files the main file reaches.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

use crate::analyze::{Facts, Input, Named, Place};
use crate::logparse::{LogItem, Severity};
use crate::syntax::scan::{self, Group};
use crate::syntax::{SymbolKind, Symbols, Text};

/// Something one file leaves unbalanced, where it is.
pub struct Slip {
    place: Place,
    message: String,
    kind: Kind,
}

/// Environments are errors, and TeX pairs them across `\input` by name: a file may end one that
/// a file read before it began.
#[derive(PartialEq, Eq)]
enum Kind {
    Mismatched,
    Unbegun(String),
    Unended(String),
    Unbalanced,
}

/// Environments, braces and maths as TeX pairs them, read with the scanner, so comments,
/// literal code and escaped braces and dollars are left out.
#[derive(Default)]
pub(crate) struct Structure {
    environments: Vec<(String, usize)>,
    braces: Vec<usize>,
    slips: Vec<Slip>,
    /// The first `\end{document}` outside braces, whose `\enddocument` ends TeX's run.
    end: Option<usize>,
}

impl Structure {
    /// In braces, a `\begin` or `\end` is most often a definition's, split across its arguments
    /// and paired only where it is used.
    pub fn command(&mut self, text: &Text, name: &str, start: usize, name_end: usize) {
        if !matches!(name, "begin" | "end") || !self.braces.is_empty() || !self.read(start) {
            return;
        }
        let Some((environment, _)) = scan::environment_name(&text.units, name_end) else {
            return;
        };
        let environment = String::from_utf16_lossy(environment).trim().to_owned();
        if name == "begin" {
            self.environments.push((environment, start));
            return;
        }
        if environment == "document" {
            self.end = Some(start);
        }
        let begun = self
            .environments
            .iter()
            .rposition(|(e, _)| *e == environment);
        let Some(begun) = begun else {
            let message = format!("\\end{{{environment}}} has no \\begin{{{environment}}}.");
            return self.slip(text, start, message, Kind::Unbegun(environment));
        };
        // TeX names the innermost environment still open.
        if let Some((open, at)) = self.environments.get(begun + 1..).and_then(<[_]>::last) {
            let message = format!(
                "\\begin{{{open}}} on line {} is ended by \\end{{{environment}}}.",
                line(text, *at)
            );
            self.slip(text, start, message, Kind::Mismatched);
        }
        self.environments.truncate(begun);
    }

    pub fn brace(&mut self, text: &Text, at: usize, open: bool) {
        if !self.read(at) {
            return;
        }
        if open {
            self.braces.push(at);
        } else if self.braces.pop().is_none() {
            let message = "This } has nothing to close.".into();
            self.slip(text, at, message, Kind::Unbalanced);
        }
    }

    pub fn unclosed(&mut self, text: &Text, group: &Group) {
        if !self.read(group.open) {
            return;
        }
        let open = &text.units[group.open..group.open + group.end.len()];
        let message = format!(
            "This {} is still open where the paragraph ends.",
            String::from_utf16_lossy(open)
        );
        self.slip(text, group.open, message, Kind::Unbalanced);
    }

    /// With what the scanner still has open at the text's end; and where TeX stops reading.
    pub fn finish(mut self, text: &Text, open: &[Group]) -> (Vec<Slip>, Option<Place>) {
        for group in open.iter().filter(|group| group.delimited()) {
            self.unclosed(text, group);
        }
        for at in std::mem::take(&mut self.braces) {
            let message = "This { is never closed.".into();
            self.slip(text, at, message, Kind::Unbalanced);
            // The `\end`s after it went unpaired.
            self.environments.clear();
        }
        for (environment, at) in std::mem::take(&mut self.environments) {
            let message = format!("\\begin{{{environment}}} is never ended.");
            self.slip(text, at, message, Kind::Unended(environment));
        }
        // For the walk to pair environments with other files' as TeX reads them.
        self.slips.sort_by_key(|slip| slip.place);
        (self.slips, self.end.map(|end| Place::of(text, end..end)))
    }

    fn read(&self, at: usize) -> bool {
        self.end.is_none_or(|end| at < end)
    }

    fn slip(&mut self, text: &Text, at: usize, message: String, kind: Kind) {
        let place = Place::of(text, at..at);
        self.slips.push(Slip {
            place,
            message,
            kind,
        });
    }
}

fn line(text: &Text, at: usize) -> u32 {
    text.line_index(at as u32) as u32 + 1
}

/// A name written out, not made by a macro or a definition's parameter.
fn literal(name: &str) -> bool {
    !name.is_empty() && !name.contains(['\\', '#'])
}

/// What of a file's `names` TeX reads.
fn read<'a>(facts: &'a Facts, names: &'a [Named]) -> impl Iterator<Item = &'a Named> {
    names
        .iter()
        .filter(|n| facts.end.is_none_or(|end| n.place < end))
}

/// The files the main file reaches, as TeX reads them.
struct Walk<'a> {
    symbols: &'a Symbols,
    /// Each once, in the order TeX first reads it.
    files: Vec<(&'a str, &'a Facts)>,
    /// In the order TeX reads them, through the inputs.
    labels: Vec<(&'a str, &'a Named)>,
    /// So too, less each environment one file leaves open that a later one ends.
    slips: Vec<(&'a str, &'a Slip)>,
    missing: Vec<(&'a str, &'a Input)>,
}

impl<'a> Walk<'a> {
    fn read(&mut self, file: &str, within: &str) {
        let symbols = self.symbols;
        let Some((file, facts)) = symbols.by_file.get_key_value(file) else {
            return;
        };
        let file = file.as_str();
        if self.files.iter().any(|(read, ..)| *read == file) {
            return;
        }
        self.files.push((file, facts));
        let mut labels = read(facts, &facts.labels).peekable();
        let mut slips = facts.slips.iter().peekable();
        let inputs = facts.inputs.iter();
        for input in inputs.filter(|i| facts.end.is_none_or(|end| i.place < end)) {
            while let Some(label) = labels.next_if(|label| label.place < input.place) {
                self.labels.push((file, label));
            }
            while let Some(slip) = slips.next_if(|slip| slip.place < input.place) {
                self.slip(file, slip);
            }
            match input.resolve(file, within, |rel| symbols.spelt(rel)) {
                Some((input, within)) => self.read(&input, &within),
                None => self.missing.push((file, input)),
            }
        }
        self.labels.extend(labels.map(|label| (file, label)));
        slips.for_each(|slip| self.slip(file, slip));
    }

    fn slip(&mut self, file: &'a str, slip: &'a Slip) {
        let begun = self
            .slips
            .iter()
            .rposition(|(_, open)| match (&open.kind, &slip.kind) {
                (Kind::Unended(a), Kind::Unbegun(b)) => a == b,
                _ => false,
            });
        match begun {
            Some(begun) => drop(self.slips.remove(begun)),
            None => self.slips.push((file, slip)),
        }
    }
}

/// Each name `defined` gives a second time, at that place, saying where the first is.
fn twice<'a>(defined: impl IntoIterator<Item = (&'a str, &'a Named)>, noun: &str) -> Vec<LogItem> {
    let mut first = HashMap::new();
    let mut twice = Vec::new();
    for (file, named) in defined.into_iter().filter(|(_, n)| literal(&n.name)) {
        match first.entry(named.name.as_str()) {
            Entry::Vacant(entry) => {
                entry.insert((file, named.place.line));
            }
            Entry::Occupied(entry) => {
                let (at, line) = entry.get();
                let message = format!(
                    "The {noun} “{}” is defined already, on line {line} of {at}.",
                    named.name
                );
                twice.push(warning(file, named.place.line, message));
            }
        }
    }
    twice
}

/// What `found` finds of the file a bibliography's name is: BibTeX appends .bib to a name;
/// biblatex takes it as written.
pub(crate) fn bib_file<T>(name: &str, found: impl Fn(&str) -> Option<T>) -> Option<T> {
    found(&format!("{name}.bib")).or_else(|| found(name))
}

fn warning(file: &str, line: u32, message: String) -> LogItem {
    LogItem::new(Severity::Warning, Some(file.into()), Some(line), message)
}

/// What the files `main` reaches get wrong, as a build's issues, by file and then line.
pub(crate) fn check(symbols: &Symbols, main: &str) -> Vec<LogItem> {
    let mut walk = Walk {
        symbols,
        files: Vec::new(),
        labels: Vec::new(),
        slips: Vec::new(),
        missing: Vec::new(),
    };
    walk.read(main, "");
    let reached = || walk.files.iter().copied();
    let undefined = |kind, noun: &str, defined: &HashSet<&str>| -> Vec<LogItem> {
        let uses =
            reached().flat_map(|(file, facts)| read(facts, &facts.uses).map(move |u| (file, u)));
        let uses = uses.filter(|(_, used)| used.kind == kind && literal(&used.name));
        let undefined = uses.filter(|(_, used)| !defined.contains(&*used.name));
        let item = |(file, used): (&str, &Named)| {
            let message = format!("No {noun} “{}” is defined.", used.name);
            warning(file, used.place.line, message)
        };
        undefined.map(item).collect()
    };
    let packages: HashSet<&str> = reached()
        .flat_map(|(_, facts)| &facts.packages)
        .map(String::as_str)
        .collect();
    let mut items = twice(walk.labels.iter().copied(), "label");

    // xr reads labels from another document's .aux.
    if !packages.contains("xr") && !packages.contains("xr-hyperref") {
        let mut labels: HashSet<&str> = walk.labels.iter().map(|(_, l)| l.name.as_str()).collect();
        if packages.contains("lastpage") {
            labels.extend(["LastPage", "VeryLastPage"]);
        }
        items.extend(undefined(SymbolKind::Label, "label", &labels));
    }

    let named = reached().flat_map(|(_, facts)| &facts.bibliographies);
    let bibliographies: Vec<Option<String>> = named
        .map(|name| bib_file(name, |rel| symbols.spelt(rel)))
        .collect();
    let mut seen = HashSet::new();
    let bibs = bibliographies
        .iter()
        .flatten()
        .filter(|bib| seen.insert(*bib));
    let entries = bibs.filter_map(|bib| symbols.by_file.get_key_value(bib));
    let entries: Vec<(&str, &Named)> = entries
        .flat_map(|(bib, facts)| facts.citations.iter().map(move |c| (bib.as_str(), c)))
        .collect();
    items.extend(twice(entries.iter().copied(), "citation"));
    // One outside the project, perhaps in TeX's own folders, may define any key.
    if bibliographies.iter().all(Option::is_some) {
        let bibitems = reached().flat_map(|(_, facts)| read(facts, &facts.citations));
        let mut keys: HashSet<&str> = bibitems.map(|c| c.name.as_str()).collect();
        keys.extend(entries.iter().map(|(_, c)| c.name.as_str()));
        // `\nocite{*}` cites every entry.
        keys.insert("*");
        items.extend(undefined(SymbolKind::Citation, "citation", &keys));
    }

    // Without TeX's list of its own files (MiKTeX keeps none), an input may be one of them.
    let in_tex = |name: &str| {
        let name = name.rsplit('/').next().unwrap_or(name);
        let name = name.strip_suffix(".tex").unwrap_or(name);
        let inputs = &symbols.installed.inputs;
        inputs.is_empty() || inputs.binary_search_by(|i| i.as_str().cmp(name)).is_ok()
    };
    let unread = walk.missing.iter();
    let unread: Vec<_> = unread
        .filter(|(_, input)| !literal(&input.name) || !in_tex(&input.name))
        .collect();
    let missing = unread.iter().filter(|(_, input)| literal(&input.name));
    items.extend(missing.map(|(file, input)| {
        let message = format!("No file “{}” is in the project.", input.name);
        warning(file, input.place.line, message)
    }));

    // A file the walk couldn't read may begin or end what is left.
    let slips = walk.slips.iter().filter(|(_, slip)| {
        unread.is_empty() || !matches!(slip.kind, Kind::Unbegun(_) | Kind::Unended(_))
    });
    items.extend(slips.map(|&(file, slip)| {
        let kind = if slip.kind == Kind::Unbalanced {
            Severity::Warning
        } else {
            Severity::Error
        };
        let message = slip.message.clone();
        LogItem::new(kind, Some(file.into()), Some(slip.place.line), message)
    }));
    items.sort_by(|a, b| (&a.file, a.line).cmp(&(&b.file, b.line)));
    items
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::projects::file_kind;
    use crate::syntax::Installed;

    type Item = (String, u32, String, bool);
    type Files<'a> = &'a [(&'a str, &'a str)];

    /// What `check` finds in a project of `files` whose main file is main.tex, with TeX's own
    /// `inputs`: each item's file, line, message and whether it is an error.
    fn checked(files: Files, inputs: &[&str]) -> Vec<Item> {
        let read = |&(rel, text): &(&str, &str)| {
            let kind = file_kind(rel);
            matches!(kind, "tex" | "bib")
                .then(|| (rel.to_owned(), Arc::new(Facts::read(text, kind))))
        };
        let inputs = inputs.iter().map(|&input| input.into()).collect();
        let symbols = Symbols {
            by_file: files.iter().filter_map(read).collect(),
            files: files.iter().map(|(rel, _)| (*rel).to_owned()).collect(),
            installed: Arc::new(Installed {
                inputs,
                ..Installed::default()
            }),
            ..Symbols::default()
        };
        let item = |i: LogItem| {
            let error = i.kind == Severity::Error;
            (i.file.unwrap(), i.line.unwrap(), i.message, error)
        };
        check(&symbols, "main.tex").into_iter().map(item).collect()
    }

    fn warned(file: &str, line: u32, message: &str) -> Item {
        (file.into(), line, message.into(), false)
    }

    /// Only in the files the main file reaches.
    #[test]
    fn a_reference_no_label_defines_is_reported_unless_xr_brings_labels_from_elsewhere() {
        let main = "\\usepackage{lastpage}\n\\label{a}\\ref{a}\n\\cref{a, b}\\eqref{loose}\n\
            \\pageref{LastPage}\\newcommand{\\r}[1]{\\ref{#1}}\n% \\ref{c}\n\\input{ch}";
        let files = [
            ("main.tex", main),
            ("ch.tex", "\\autoref{d}"),
            ("loose.tex", "\\label{loose}\\ref{e}"),
        ];
        assert_eq!(
            checked(&files, &[]),
            [
                warned("ch.tex", 1, "No label “d” is defined."),
                warned("main.tex", 3, "No label “b” is defined."),
                warned("main.tex", 3, "No label “loose” is defined."),
            ]
        );
        let xr = format!("\\usepackage{{xr}}\\externaldocument{{other}}\n{main}");
        assert_eq!(checked(&[("main.tex", &xr)], &[]), []);
    }

    /// Only while every bibliography named is in the project: TeX's own folders may hold another.
    #[test]
    fn a_citation_nothing_defines_is_reported_while_every_bibliography_is_the_projects() {
        let bib = ("refs.bib", "@book{knuth, title={T}}");
        let cite = "\\cite[p.~1]{knuth, lamport}\\nocite{*}\n";
        let lamport = || vec![warned("main.tex", 1, "No citation “lamport” is defined.")];
        let cases = [
            ("\\bibliography{refs}", lamport()),
            ("\\addbibresource{refs.bib}", lamport()),
            (
                "\\begin{thebibliography}{9}\\bibitem{knuth}\\end{thebibliography}",
                lamport(),
            ),
            ("\\bibliography{refs,IEEEabrv}", vec![]),
        ];
        for (end, expected) in cases {
            let main = format!("{cite}{end}");
            assert_eq!(checked(&[("main.tex", &main), bib], &[]), expected, "{end}");
        }
    }

    /// In the order TeX reads them, through an input between two labels.
    #[test]
    fn a_label_or_bib_key_defined_twice_is_reported_where_it_comes_again() {
        let files = [
            (
                "main.tex",
                "\\label{a}\n\\input{ch}\n\\label{b}\n\\bibliography{refs}",
            ),
            ("ch.tex", "\\label{b}\n\\label{a}"),
            ("refs.bib", "@book{knuth,}\n@misc{knuth,}"),
        ];
        let twice = |noun, name, first| {
            format!("The {noun} “{name}” is defined already, on line 1 of {first}.")
        };
        assert_eq!(
            checked(&files, &[]),
            [
                warned("ch.tex", 2, &twice("label", "a", "main.tex")),
                warned("main.tex", 3, &twice("label", "b", "ch.tex")),
                warned("refs.bib", 2, &twice("citation", "knuth", "refs.bib")),
            ]
        );
    }

    /// Only with the installed TeX's list of its files, which MiKTeX doesn't keep.
    #[test]
    fn an_input_in_neither_the_project_nor_tex_is_reported() {
        let main = "\\input{ch/one}\\include{gone}\n\\input{glyphtounicode}\\subfile{data.csv}\\input{\\dir/x}";
        let files = [("main.tex", main), ("ch/one.tex", ""), ("data.csv", "")];
        let gone = warned("main.tex", 1, "No file “gone” is in the project.");
        assert_eq!(checked(&files, &["glyphtounicode"]), [gone]);
        assert_eq!(checked(&files, &[]), []);
    }

    /// \enddocument ends TeX's run, so notes below it are no document's.
    #[test]
    fn nothing_after_the_documents_end_is_checked() {
        let main = "\\begin{document}\\label{a}\n\\end{document}\n\
            Notes: \\begin{todo} { $x \\ref{b} \\label{a} \\input{gone}";
        assert_eq!(checked(&[("main.tex", main)], &["tex"]), []);
    }

    /// Where TeX would complain; not in comments, literal code, escapes, a URL's address or
    /// braces, nor an environment that a file read before or after this one begins or ends, or
    /// that an input the walk can't read might, or that a brace left open hides the end of.
    #[test]
    fn environments_braces_and_maths_left_open_or_closed_twice_are_reported() {
        let error = |line, message: &str| ("main.tex".to_owned(), line, message.to_owned(), true);
        let open = |line, open| {
            warned(
                "main.tex",
                line,
                &format!("This {open} is still open where the paragraph ends."),
            )
        };
        let none = "% \\begin{x} {\n\\verb|{$| \\lstinline[language=C]|}$| \\lstinline{a{b}$} \\mintinline{c}{$}\n\\begin{verbatim}\n\\end{x} }\n\\end{verbatim}\n\
            \\begin{lstlisting}\n{\n\\end{lstlisting}\n\\begin{minted}{py}\n}\n\\end{minted}\n\
            \\{ \\} \\$ 50\\% \\url{a%20b} \\href{c%d}{e}\n\\newcommand{\\bc}{\\begin{center}}\n\\renewcommand*\\ee{\\end{flushleft}}\n\
            \\newenvironment{bx}[1][x]{\\end{quote}}{\\begin{quote}}\n\\def\\x#1{\\end{itemize}}\n\
            \\begin{document}$a$ \\(b\\) $$c$$ \\begin{equation}{d}\\end{equation}\n\\end{document}";
        let cases: [(Files, Vec<Item>); 10] = [
            (
                &[(
                    "main.tex",
                    "\\begin{document}\n\\begin{itemize}\n\\end{document}",
                )],
                vec![error(
                    3,
                    "\\begin{itemize} on line 2 is ended by \\end{document}.",
                )],
            ),
            (
                &[("main.tex", "\n\\end{figure}")],
                vec![error(2, "\\end{figure} has no \\begin{figure}.")],
            ),
            (
                &[("main.tex", "\\begin{proof}\ntext")],
                vec![error(1, "\\begin{proof} is never ended.")],
            ),
            (
                &[("main.tex", "a $x\n\nb \\[ y")],
                vec![open(1, "$"), open(3, "\\[")],
            ),
            (
                &[("main.tex", "\\begin{x}\\textbf{a\n\nb\\end{x}")],
                vec![warned("main.tex", 1, "This { is never closed.")],
            ),
            (
                &[("main.tex", "a\nb}")],
                vec![warned("main.tex", 2, "This } has nothing to close.")],
            ),
            (&[("main.tex", none)], vec![]),
            (
                &[
                    ("main.tex", "\\begin{document}\n\\input{body}"),
                    ("body.tex", "Text.\n\\end{document}"),
                ],
                vec![],
            ),
            (
                &[
                    ("main.tex", "\\input{header}\nText.\n\\end{document}"),
                    ("header.tex", "\\documentclass{article}\n\\begin{document}"),
                ],
                vec![],
            ),
            (
                &[("main.tex", "\\begin{document}\n\\input{\\body}")],
                vec![],
            ),
        ];
        for (files, expected) in cases {
            assert_eq!(checked(files, &[]), expected, "{files:?}");
        }
    }
}
