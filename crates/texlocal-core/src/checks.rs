//! What a session finds wrong in a project without TeX: references, citations and inputs
//! nothing defines, names defined twice, and environments, braces and maths left open, in the
//! files the main file reaches.

use std::collections::hash_map::Entry;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use crate::analyze::{Facts, Input, Named, Place};
use crate::logparse::{LogItem, Severity};
use crate::paths;
use crate::syntax::scan::{self, Group};
use crate::syntax::{Installed, SymbolKind, Text};

/// Commands whose arguments define others: `\begin` and `\end` in them are often split across
/// the arguments, and pair only where the definition is used.
const DEFINITIONS: &[&str] = &[
    "newcommand",
    "renewcommand",
    "providecommand",
    "DeclareRobustCommand",
    "newenvironment",
    "renewenvironment",
    "NewDocumentCommand",
    "RenewDocumentCommand",
    "ProvideDocumentCommand",
    "DeclareDocumentCommand",
    "NewDocumentEnvironment",
    "RenewDocumentEnvironment",
    "def",
    "gdef",
    "edef",
    "xdef",
];

/// Something one file leaves unbalanced, on its 1-based line.
pub struct Slip {
    line: u32,
    message: String,
    kind: Kind,
}

/// Environments are errors, and TeX pairs them across `\input`: a file may end one that the
/// file inputting it began, or begin one that a file it inputs ends.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Mismatched,
    Unbegun,
    Unended,
    Unbalanced,
}

/// Environments, braces and maths as TeX pairs them, read with the scanner, so comments,
/// literal code and escaped braces and dollars are left out.
#[derive(Default)]
pub(crate) struct Structure {
    environments: Vec<(String, usize)>,
    braces: Vec<usize>,
    /// Where the last definition's arguments end.
    defining: usize,
    slips: Vec<Slip>,
}

impl Structure {
    pub fn command(&mut self, text: &Text, name: &str, start: usize, name_end: usize) {
        if DEFINITIONS.contains(&name) {
            self.defining = self.defining.max(definition_end(&text.units, name_end));
            return;
        }
        if !matches!(name, "begin" | "end") || start < self.defining {
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
        let begun = self
            .environments
            .iter()
            .rposition(|(e, _)| *e == environment);
        let Some(begun) = begun else {
            let message = format!("\\end{{{environment}}} has no \\begin{{{environment}}}.");
            return self.slip(text, start, message, Kind::Unbegun);
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
        if open {
            self.braces.push(at);
        } else if self.braces.pop().is_none() {
            let message = "This } has nothing to close.".into();
            self.slip(text, at, message, Kind::Unbalanced);
        }
    }

    pub fn unclosed(&mut self, text: &Text, group: &Group) {
        let open = match group.end.as_ref() {
            "$" => "$",
            "$$" => "$$",
            "\\)" => "\\(",
            _ => "\\[",
        };
        let message = format!("This {open} is still open where the paragraph ends.");
        self.slip(text, group.open, message, Kind::Unbalanced);
    }

    /// With what the scanner still has open at the text's end.
    pub fn finish(mut self, text: &Text, open: &[Group]) -> Vec<Slip> {
        for group in open.iter().filter(|group| group.delimited()) {
            self.unclosed(text, group);
        }
        for at in std::mem::take(&mut self.braces) {
            let message = "This { is never closed.".into();
            self.slip(text, at, message, Kind::Unbalanced);
        }
        for (environment, at) in std::mem::take(&mut self.environments) {
            let message = format!("\\begin{{{environment}}} is never ended.");
            self.slip(text, at, message, Kind::Unended);
        }
        self.slips
    }

    fn slip(&mut self, text: &Text, at: usize, message: String, kind: Kind) {
        let line = line(text, at);
        self.slips.push(Slip {
            line,
            message,
            kind,
        });
    }
}

fn line(text: &Text, at: usize) -> u32 {
    text.line_index(at as u32) as u32 + 1
}

/// Where a definition's name, parameters and arguments end: a name or parameter only before
/// its first braced argument, as `\def\name#1{…}` has them.
fn definition_end(units: &[u16], mut i: usize) -> usize {
    let blank = |u: &&u16| scan::tex_space(**u) || **u == u16::from(b'\n');
    let mut braced = false;
    loop {
        let next = i + units[i..].iter().take_while(blank).count();
        i = match units.get(next).and_then(|&u| u8::try_from(u).ok()) {
            Some(b'\\') if !braced => {
                let name = units[next + 1..].iter();
                let letters =
                    name.take_while(|&&u| u8::try_from(u).is_ok_and(|u| u.is_ascii_alphabetic()));
                (next + 1 + letters.count().max(1)).min(units.len())
            }
            Some(b'#') if !braced => (next + 2).min(units.len()),
            Some(b'*') => next + 1,
            Some(b'[' | b'{') => match scan::arguments(units, next, |_, _| {}) {
                (stop, true) => {
                    braced = true;
                    stop
                }
                _ => return i,
            },
            _ => return i,
        };
    }
}

/// A name written out, not made by a macro or a definition's parameter.
fn literal(name: &str) -> bool {
    !name.is_empty() && !name.contains(['\\', '#'])
}

/// The files the main file reaches, as TeX reads them.
struct Walk<'a> {
    by_file: &'a BTreeMap<String, Arc<Facts>>,
    found: &'a dyn Fn(&str) -> Option<String>,
    seen: HashSet<String>,
    /// Each once, in the order TeX first reads it, and whether another file inputs it.
    files: Vec<(&'a str, &'a Facts, bool)>,
    /// In the order TeX reads them, through the inputs.
    labels: Vec<(&'a str, &'a Named)>,
    missing: Vec<(&'a str, &'a Input)>,
}

impl<'a> Walk<'a> {
    fn read(&mut self, file: &str, within: &str, included: bool) {
        let Some((file, facts)) = self.by_file.get_key_value(file) else {
            return;
        };
        let file = file.as_str();
        if !self.seen.insert(paths::fold_case(file)) {
            return;
        }
        self.files.push((file, facts, included));
        let mut labels = facts.labels.iter().peekable();
        let at = |place: Place| (place.line, place.column);
        for input in &facts.inputs {
            while let Some(label) = labels.next_if(|label| at(label.place) < at(input.place)) {
                self.labels.push((file, label));
            }
            match input.resolve(file, within, self.found) {
                Some((input, within)) => self.read(&input, &within, true),
                None => self.missing.push((file, input)),
            }
        }
        self.labels.extend(labels.map(|label| (file, label)));
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

fn warning(file: &str, line: u32, message: String) -> LogItem {
    LogItem::new(Severity::Warning, Some(file.into()), Some(line), message)
}

/// What the files `main` reaches get wrong, as a build's issues, by file and then line. `files`
/// are the project's, `by_file` the facts of its .tex and .bib files.
pub(crate) fn check(
    by_file: &BTreeMap<String, Arc<Facts>>,
    files: &[String],
    main: &str,
    installed: &Installed,
) -> Vec<LogItem> {
    let spelt: HashMap<String, &String> = files.iter().map(|f| (paths::fold_case(f), f)).collect();
    let found = |rel: &str| {
        let rel = paths::fold_case(&paths::rel_key(rel).ok()?);
        spelt.get(&rel).map(|file| (*file).clone())
    };
    let mut walk = Walk {
        by_file,
        found: &found,
        seen: HashSet::new(),
        files: Vec::new(),
        labels: Vec::new(),
        missing: Vec::new(),
    };
    walk.read(main, "", false);
    let reached = || walk.files.iter().map(|&(file, facts, _)| (file, facts));
    let used = |kind| {
        let uses =
            reached().flat_map(move |(file, facts)| facts.uses.iter().map(move |u| (file, u)));
        uses.filter(move |(_, used)| used.kind == kind && literal(&used.name))
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
        let undefined = used(SymbolKind::Label).filter(|(_, used)| !labels.contains(&*used.name));
        items.extend(undefined.map(|(file, used)| {
            let message = format!("No label “{}” is defined.", used.name);
            warning(file, used.place.line, message)
        }));
    }

    // BibTeX appends .bib to a name; biblatex takes it as written.
    let named = reached().flat_map(|(_, facts)| &facts.bibliographies);
    let bibliographies: Vec<Option<String>> = named
        .map(|name| found(&format!("{name}.bib")).or_else(|| found(name)))
        .collect();
    let mut seen = HashSet::new();
    let bibs = bibliographies
        .iter()
        .flatten()
        .filter(|bib| seen.insert(*bib));
    let entries = bibs.filter_map(|bib| by_file.get_key_value(bib));
    let entries: Vec<(&str, &Named)> = entries
        .flat_map(|(bib, facts)| facts.citations.iter().map(move |c| (bib.as_str(), c)))
        .collect();
    items.extend(twice(entries.iter().copied(), "citation"));
    // One outside the project, perhaps in TeX's own folders, may define any key.
    if bibliographies.iter().all(Option::is_some) {
        let bibitems = reached().flat_map(|(_, facts)| &facts.citations);
        let mut keys: HashSet<&str> = bibitems.map(|c| c.name.as_str()).collect();
        keys.extend(entries.iter().map(|(_, c)| c.name.as_str()));
        let undefined = used(SymbolKind::Citation)
            .filter(|(_, used)| used.name != "*" && !keys.contains(&*used.name));
        items.extend(undefined.map(|(file, used)| {
            let message = format!("No citation “{}” is defined.", used.name);
            warning(file, used.place.line, message)
        }));
    }

    // Without TeX's list of its own files (MiKTeX keeps none), an input may be one of them.
    let in_tex = |name: &str| {
        let name = name.rsplit('/').next().unwrap_or(name);
        let name = name.strip_suffix(".tex").unwrap_or(name);
        let inputs = &installed.inputs;
        inputs.is_empty() || inputs.binary_search_by(|i| i.as_str().cmp(name)).is_ok()
    };
    let missing = walk.missing.iter();
    let missing = missing.filter(|(_, input)| literal(&input.name) && !in_tex(&input.name));
    items.extend(missing.map(|(file, input)| {
        let message = format!("No file “{}” is in the project.", input.name);
        warning(file, input.place.line, message)
    }));

    for &(file, facts, included) in &walk.files {
        let slips = facts.slips.iter().filter(|slip| match slip.kind {
            Kind::Unbegun => !included,
            Kind::Unended => facts.inputs.is_empty(),
            Kind::Mismatched | Kind::Unbalanced => true,
        });
        items.extend(slips.map(|slip| {
            let kind = if slip.kind == Kind::Unbalanced {
                Severity::Warning
            } else {
                Severity::Error
            };
            LogItem::new(
                kind,
                Some(file.into()),
                Some(slip.line),
                slip.message.clone(),
            )
        }));
    }
    items.sort_by(|a, b| (&a.file, a.line).cmp(&(&b.file, b.line)));
    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::file_kind;

    type Item = (String, u32, String, bool);
    type Files<'a> = &'a [(&'a str, &'a str)];

    /// What `check` finds in a project of `files` whose main file is main.tex: each item's file,
    /// line, message and whether it is an error.
    fn checked(files: Files, installed: &Installed) -> Vec<Item> {
        let read = |&(rel, text): &(&str, &str)| {
            let kind = file_kind(rel);
            matches!(kind, "tex" | "bib")
                .then(|| (rel.to_owned(), Arc::new(Facts::read(text, kind))))
        };
        let by_file = files.iter().filter_map(read).collect();
        let names: Vec<String> = files.iter().map(|(rel, _)| (*rel).to_owned()).collect();
        let items = check(&by_file, &names, "main.tex", installed);
        let item = |i: LogItem| {
            let error = i.kind == Severity::Error;
            (i.file.unwrap(), i.line.unwrap(), i.message, error)
        };
        items.into_iter().map(item).collect()
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
            checked(&files, &Installed::default()),
            [
                warned("ch.tex", 1, "No label “d” is defined."),
                warned("main.tex", 3, "No label “b” is defined."),
                warned("main.tex", 3, "No label “loose” is defined."),
            ]
        );
        let xr = format!("\\usepackage{{xr}}\\externaldocument{{other}}\n{main}");
        assert_eq!(checked(&[("main.tex", &xr)], &Installed::default()), []);
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
            assert_eq!(
                checked(&[("main.tex", &main), bib], &Installed::default()),
                expected,
                "{end}"
            );
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
            checked(&files, &Installed::default()),
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
        let installed = Installed {
            inputs: vec!["glyphtounicode".into()],
            ..Installed::default()
        };
        let gone = warned("main.tex", 1, "No file “gone” is in the project.");
        assert_eq!(checked(&files, &installed), [gone]);
        assert_eq!(checked(&files, &Installed::default()), []);
    }

    /// Where TeX would complain; not in comments, literal code, escapes or definitions, nor an
    /// environment that a file inputting this one, or one it inputs, ends.
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
        let none = "% \\begin{x} {\n\\verb|{$|\n\\begin{verbatim}\n\\end{x} }\n\\end{verbatim}\n\
            \\begin{lstlisting}\n{\n\\end{lstlisting}\n\\begin{minted}{py}\n}\n\\end{minted}\n\
            \\{ \\} \\$ 50\\%\n\\newcommand{\\bc}{\\begin{center}}\n\\renewcommand*\\ee{\\end{flushleft}}\n\
            \\newenvironment{bx}[1][x]{\\end{quote}}{\\begin{quote}}\n\\def\\x#1{\\end{itemize}}\n\
            \\begin{document}$a$ \\(b\\) $$c$$ \\begin{equation}{d}\\end{equation}\n\\end{document}";
        let cases: [(Files, Vec<Item>); 8] = [
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
                &[("main.tex", "\\textbf{a\n\nb")],
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
        ];
        for (files, expected) in cases {
            assert_eq!(checked(files, &Installed::default()), expected, "{files:?}");
        }
    }
}
