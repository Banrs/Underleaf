//! A document's outline and word count, read from its main file through the files it
//! inputs, and what each file defines and refers to, and where; each file is read once per
//! change.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::ops::Range;
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};

use regex::Regex;
use serde::Serialize;

use crate::checks::{Slip, Structure};
use crate::projects::file_kind;
use crate::stamp::Stamp;
use crate::syntax::catalog::CATALOG;
use crate::syntax::scan::{Group, Scanner, Visit};
use crate::syntax::{SymbolKind, Text, headings, prose, scan};
use crate::{lock, paths};

// What a title drops whole: \texorpdfstring's TeX argument (its PDF string is
// the group after), labels, notes, and on a label's line an environment's \begin and \end.
static TITLE_DROP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:texorpdfstring|label|index|footnote|begin|end)\s*\{").unwrap()
});
static TITLE_STYLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:emph|text(?:bf|it|sl|sc|tt|sf|rm|up|md|normal)|underline|em|bf|it|sl|sc|tt|sf|rm|normalfont|(?:bf|md)series|(?:it|sl|sc|up)shape|(?:rm|sf|tt)family)(?-u:\b)\s*").unwrap()
});
static TITLE_BRACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\([{}&%$#_])|[{}]").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
// Matched on the decoded text, not the raw bytes: in Unicode mode a byte that
// isn't UTF-8 (a Latin-1 umlaut) drops its entry, and `(?-u)` narrows `\s` to
// ASCII, which swallows a non-breaking space into the key.
static BIB_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@([0-9A-Za-z_]+)\s*[{(]\s*([^,\s]+)\s*,").unwrap());
// Only a field's name, in any case as BibTeX reads it: the first of an entry's fields or one
// after a comma.
static CROSSREF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)(?:^|,)\s*crossref\s*=\s*[{"]?\s*([^\s,{}"]+)"#).unwrap());

/// A sectioning command's heading: depth (0 for \part to 5 for \paragraph), title as plain text, 1-based line and file. An empty title is `untitled`, shown by its level.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Heading {
    pub depth: usize,
    pub command: &'static str,
    pub level: &'static str,
    pub title: String,
    pub untitled: bool,
    pub line: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// Its own prose words: up to the next heading or input of its file, and in an outline up
    /// to the next heading the document reads.
    #[serde(skip)]
    pub words: usize,
}

impl Heading {
    fn new(depth: usize, title: Option<String>, line: usize) -> Self {
        let (command, level) = headings::LEVELS[depth];
        Self {
            depth,
            command,
            level,
            untitled: title.is_none(),
            title: title.unwrap_or_else(|| format!("Untitled {level}")),
            line,
            file: None,
            words: 0,
        }
    }
}

/// What one file says, each list in the file's order: the project's symbols are their union
/// over files, its outline and word count a walk over them from the main file.
#[derive(Default)]
pub struct Facts {
    /// Without their file, which is the name the walk reaches it by.
    pub headings: Vec<Heading>,
    pub inputs: Vec<Input>,
    pub words: usize,
    pub labels: Vec<Named>,
    /// A .bib file's keys, or a .tex file's \bibitems.
    pub citations: Vec<Named>,
    pub commands: Vec<Defined>,
    pub environments: Vec<Named>,
    /// Labels and citations referred to, one for each key a list names, environments begun or
    /// ended, graphics included, and every command, from its backslash.
    pub uses: Vec<Named>,
    pub class: Option<headings::DocumentClass>,
    /// What `\usepackage` and `\RequirePackage` load.
    pub packages: Vec<String>,
    /// Where a new `\usepackage` goes: at the end of the line where the last one's argument ends,
    /// else `\documentclass`'s, which a package can't come before.
    pub new_package: Option<Place>,
    /// What `\bibliography` and `\addbibresource` name, as written.
    pub bibliographies: Vec<String>,
    /// What TeX would find unbalanced in it.
    pub slips: Vec<Slip>,
    /// Where TeX stops reading it, if before its end.
    pub end: Option<Place>,
}

/// Where a name is written: its line, from 1, and its column, from 0, and length in UTF-16 units.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Place {
    pub line: u32,
    pub column: u32,
    pub length: u32,
}

impl Place {
    pub(crate) fn of(text: &Text, range: Range<usize>) -> Self {
        let line = text.line_index(range.start as u32);
        Self {
            line: line as u32 + 1,
            column: range.start as u32 - text.lines[line],
            length: range.len() as u32,
        }
    }
}

/// A name a file defines or refers to.
#[derive(Clone)]
pub struct Named {
    pub kind: SymbolKind,
    pub name: String,
    pub place: Place,
    /// What completion says of a citation beside its key: its .bib entry's authors, year and
    /// title; or of a label, what it labels.
    pub detail: Option<String>,
}

/// A command the project defines, with the arguments it takes in braces.
#[derive(Clone)]
pub struct Defined {
    pub name: String,
    pub arguments: usize,
    pub place: Place,
    /// The definition as the maths preview gives it to RaTeX; none without its body, or for a
    /// `\def` with parameters.
    pub tex: Option<String>,
}

/// A file read in place after the first `before` headings of the file that names it.
pub struct Input {
    before: usize,
    pub(crate) name: String,
    folder: Folder,
    pub(crate) place: Place,
    /// The prose words after it, up to the next heading or input.
    words: usize,
}

/// Where an input's name is looked for, as the import package has it.
enum Folder {
    /// That of the file naming it if that was imported, then the main file's.
    Inherited,
    /// \import's, from the main file's.
    Import(String),
    /// \subimport's, from the naming file's.
    Sub(String),
}

impl Input {
    /// The file it names, spelt as `found` finds it, read from `file`, which an \import gave the
    /// folder `within`; and the folder that file's own inputs are looked for in.
    pub(crate) fn resolve(
        &self,
        file: &str,
        within: &str,
        found: impl Fn(&str) -> Option<String>,
    ) -> Option<(String, String)> {
        let parent = file.rsplit_once('/').map_or("", |(parent, _)| parent);
        let folder = match &self.folder {
            Folder::Inherited => None,
            Folder::Import(folder) => Some(folder.clone()),
            Folder::Sub(folder) => Some(joined(parent, folder)),
        };
        let folders = match (&folder, within) {
            (Some(folder), _) => vec![folder.as_str()],
            (None, "") => vec![""],
            (None, within) => vec![within, ""],
        };
        let name = &self.name;
        let tex = format!("{}.tex", name.strip_suffix(".tex").unwrap_or(name));
        // TeX tries name.tex before the name as written.
        let input = folders
            .iter()
            .flat_map(|folder| [joined(folder, &tex), joined(folder, name)])
            .find_map(|rel| found(&rel))?;
        Some((input, folder.unwrap_or_else(|| within.to_owned())))
    }
}

impl Facts {
    pub(crate) fn read(source: &str, kind: &str) -> Self {
        let text = Text::new(source);
        let mut facts = Self::default();
        if kind == "bib" {
            let (mut byte, mut unit) = (0, 0);
            // Each is after the last, so counted on from it.
            let mut cited = |at: Range<usize>| {
                unit += source[byte..at.start].encode_utf16().count();
                byte = at.start;
                let units = unit..unit + source[at].encode_utf16().count();
                named(&text, SymbolKind::Citation, units)
            };
            for (entry, body) in entries(source) {
                let kind = entry[1].to_ascii_lowercase();
                if matches!(kind.as_str(), "comment" | "string" | "preamble") {
                    continue;
                }
                let start = entry.get_match().end();
                facts.citations.push(Named {
                    detail: detail(&fields(body)),
                    ..cited(entry.get(2).expect("an entry has a key").range())
                });
                // The entry it takes fields from, which a rename of that one must reach.
                if let Some(parent) = CROSSREF.captures(body).and_then(|parent| parent.get(1)) {
                    let at = start + parent.start()..start + parent.end();
                    facts.uses.push(cited(at));
                }
            }
            return facts;
        }
        // Found as the words are counted, so none is in a comment, maths or literal code.
        let mut heading_line = None;
        // Where each heading and input is, in the file's order, and whether it is a heading.
        let mut cuts = Vec::new();
        let prose = prose::prose(&text, |text, name, name_end| {
            let line = text.line_index(name_end as u32) + 1;
            let units = &text.units;
            if let Some(depth) = headings::LEVELS.iter().position(|l| l.0 == name) {
                if heading_line != Some(line)
                    && let (Some((title, _)), _) = braced(units, name_end)
                {
                    let heading = Heading::new(depth, plain_title(&title), line);
                    facts.headings.push(heading);
                    cuts.push((name_end, true));
                }
                heading_line = Some(line);
            } else if let Some((name, folder, at)) = input(units, name, name_end) {
                facts.inputs.push(Input {
                    before: facts.headings.len(),
                    name,
                    folder,
                    place: Place::of(text, at),
                    words: 0,
                });
                cuts.push((name_end, false));
            }
        });
        let len = text.units.len();
        facts.words = prose.words(0..len);
        let (mut headings, mut inputs) = (facts.headings.iter_mut(), facts.inputs.iter_mut());
        for (i, &(from, heading)) in cuts.iter().enumerate() {
            let to = cuts.get(i + 1).map_or(len, |cut| cut.0);
            let counted = if heading {
                &mut headings.next().expect("a heading for each cut").words
            } else {
                &mut inputs.next().expect("an input for each cut").words
            };
            *counted = prose.words(from..to);
        }
        let mut names = Names(&text, &mut facts, None, Structure::default());
        let mut scanner = Scanner::default();
        scanner.run(&text.units, text.units.len(), &[], &mut names);
        let Names(.., structure) = names;
        (facts.slips, facts.end) = structure.finish(&text, &scanner.groups());
        facts
    }
}

/// What a text names for others to refer to, and the names it refers to, outside comments and
/// literal code; and the last caption's or heading's title, with where its argument closes, for
/// a label just after it to say what it labels; and what TeX would find unbalanced.
struct Names<'a>(&'a Text, &'a mut Facts, Option<(usize, String)>, Structure);

impl Visit for Names<'_> {
    fn command(&mut self, name: &str, start: usize, name_end: usize) {
        let (text, facts) = (self.0, &mut *self.1);
        self.3.command(text, name, start, name_end);
        facts
            .uses
            .push(named(text, SymbolKind::Command, start..name_end));
        let names = |list| {
            let names = listed(&text.units, name_end, list).into_iter();
            names.map(|at| String::from_utf16_lossy(&text.units[at]))
        };
        match name {
            "bibitem" => {
                let keys = listed(&text.units, name_end, false).into_iter();
                let keys = keys.map(|at| named(text, SymbolKind::Citation, at));
                facts.citations.extend(keys);
            }
            "documentclass" if facts.class.is_none() => {
                facts.class = headings::class_at(&text.units, name_end);
                facts.new_package = Some(after_line(text, name_end));
            }
            "usepackage" | "RequirePackage" => {
                facts.packages.extend(names(true));
                if name == "usepackage" {
                    facts.new_package = Some(after_line(text, name_end));
                }
            }
            "bibliography" | "addbibresource" => {
                facts.bibliographies.extend(names(name == "bibliography"));
            }
            "newcommand" | "renewcommand" | "providecommand" | "DeclareMathOperator" | "def" => {
                let command = defined(text, name, name_end);
                let command = command
                    .filter(|d| d.name.starts_with('\\') && (name != "def" || d.tex.is_some()));
                facts.commands.extend(command);
            }
            "newenvironment" => {
                let environment =
                    defined(text, name, name_end).filter(|d| !d.name.starts_with('\\'));
                let environment = environment.map(|Defined { name, place, .. }| Named {
                    kind: SymbolKind::Environment,
                    name,
                    place,
                    detail: None,
                });
                facts.environments.extend(environment);
            }
            name if name == "caption" || headings::LEVELS.iter().any(|l| l.0 == name) => {
                let (title, _) = braced(&text.units, name_end);
                self.2 = title.and_then(|(title, at)| Some((at.end, plain_title(&title)?)));
            }
            _ => self.used(name, start, name_end),
        }
    }

    fn math_command(&mut self, name: &str, start: usize, name_end: usize) {
        self.3.command(self.0, name, start, name_end);
        let command = named(self.0, SymbolKind::Command, start..name_end);
        self.1.uses.push(command);
        self.used(name, start, name_end);
    }

    fn brace(&mut self, at: usize, open: bool) {
        self.3.brace(self.0, at, open);
    }

    fn unclosed(&mut self, group: &Group) {
        self.3.unclosed(self.0, group);
    }
}

impl Names<'_> {
    /// A label's definition, or a name that refers to something, in prose or maths.
    fn used(&mut self, name: &str, start: usize, name_end: usize) {
        let (text, catalog) = (self.0, &*CATALOG);
        let kind = match name {
            "begin" | "end" => SymbolKind::Environment,
            "includegraphics" => SymbolKind::File,
            name if catalog.ref_commands.contains(name) => SymbolKind::Label,
            name if catalog.cite_commands.contains(name) => SymbolKind::Citation,
            "label" => {
                // The title it is in or just after, else its line.
                let after = |close: usize| {
                    let between = text.units.get(close + 1..start).unwrap_or_default();
                    String::from_utf16_lossy(between).trim().is_empty()
                };
                let line = || String::from_utf16_lossy(text.line(text.line_index(start as u32)));
                let detail = match &self.2 {
                    Some((close, title)) if after(*close) => Some(title.clone()),
                    _ => plain_title(&line()).filter(|line| !line.contains('\\')),
                };
                let labels = listed(&text.units, name_end, false).into_iter();
                let labels = labels.map(|at| Named {
                    detail: detail.clone(),
                    ..named(text, SymbolKind::Label, at)
                });
                // One still being typed (`fig:`) isn't a label yet.
                let labels = labels.filter(|label| !label.name.ends_with(':'));
                self.1.labels.extend(labels);
                return;
            }
            _ => return,
        };
        let list = matches!(kind, SymbolKind::Label | SymbolKind::Citation);
        let names = listed(&text.units, name_end, list).into_iter();
        self.1.uses.extend(names.map(|at| named(text, kind, at)));
    }
}

fn named(text: &Text, kind: SymbolKind, at: Range<usize>) -> Named {
    Named {
        kind,
        name: String::from_utf16_lossy(&text.units[at.clone()]),
        place: Place::of(text, at),
        detail: None,
    }
}

/// Each .bib entry and what follows its key, read to the next entry at most, so one left
/// unbalanced takes nothing of those after it.
fn entries(source: &str) -> impl Iterator<Item = (regex::Captures<'_>, &str)> {
    let mut found = BIB_KEY.captures_iter(source).peekable();
    std::iter::from_fn(move || {
        let entry = found.next()?;
        let next = found
            .peek()
            .map_or(source.len(), |next| next.get_match().start());
        let body = &source[entry.get_match().end()..next];
        Some((entry, body))
    })
}

/// A .bib entry's fields from just after its key, each named in lower case, with its value as
/// written but for the braces or quotes around it and any `#` joining its parts. Braces nest
/// and hold quotes; the entry ends at the brace or parenthesis that closes it, or, unbalanced,
/// with `body`.
fn fields(body: &str) -> Vec<(String, String)> {
    let (mut fields, mut name, mut value) = (Vec::new(), String::new(), None::<String>);
    let (mut depth, mut quoted) = (0_usize, false);
    for c in body.chars() {
        let top = depth == 0 && !quoted;
        match (c, value.as_mut()) {
            ('}' | ')', _) if top => break,
            (',', _) if top => {
                fields.extend(value.take().map(|value| (name.clone(), value)));
                name.clear();
            }
            ('=', None) => value = Some(String::new()),
            (c, None) if !c.is_whitespace() => name.push(c.to_ascii_lowercase()),
            (_, None) => {}
            ('"', Some(_)) if depth == 0 => quoted = !quoted,
            ('{', Some(text)) => {
                if !top {
                    text.push(c);
                }
                depth += 1;
            }
            ('}', Some(text)) => {
                depth = depth.saturating_sub(1);
                if depth > 0 || quoted {
                    text.push(c);
                }
            }
            (c, Some(_)) if top && (c == '#' || c.is_whitespace()) => {}
            (c, Some(text)) => text.push(c),
        }
    }
    fields.extend(value.map(|value| (name, value)));
    fields
}

fn field<'a>(fields: &'a [(String, String)], name: &str) -> Option<&'a str> {
    let mut named = fields.iter().filter(|(n, _)| n == name);
    named.next().map(|(_, value)| value.as_str())
}

/// Its year, or biblatex's date's.
fn year(fields: &[(String, String)]) -> Option<String> {
    let date = || field(fields, "date").and_then(|date| date.get(..4));
    field(fields, "year").or_else(date).and_then(plain_title)
}

/// What completion says of a .bib entry, "Knuth · 1984 · The TeXbook", as far as its fields
/// tell: its authors' last names, its year and its title.
fn detail(fields: &[(String, String)]) -> Option<String> {
    let field = |name| field(fields, name);
    // A last name comes first before a comma, else last.
    let last = |name: &str| {
        let name = name.trim();
        let last = match parted(name, ",").as_slice() {
            [last, _, ..] => *last,
            _ => *parted(name, " ").last().expect("a part at least"),
        };
        plain_title(last)
    };
    let authors = field("author").and_then(|authors| {
        let authors = SPACES.replace_all(authors, " ");
        let names: Vec<String> = parted(&authors, " and ")
            .into_iter()
            .filter_map(last)
            .collect();
        match names.as_slice() {
            [] => None,
            [one] => Some(one.clone()),
            [one, two] => Some(format!("{one} and {two}")),
            [one, ..] => Some(format!("{one} et al.")),
        }
    });
    let parts = [authors, year(fields), field("title").and_then(plain_title)];
    let parts: Vec<String> = parts.into_iter().flatten().collect();
    (!parts.is_empty()).then(|| parts.join(" · "))
}

/// What Quick Help says of the entry `key` in a .bib file's `source`, a line for each of what
/// its fields tell: its authors' whole names, its title, its year and where it was published.
pub(crate) fn bib_entry(source: &str, key: &str) -> Option<String> {
    let (_, body) = entries(source).find(|(entry, _)| &entry[2] == key)?;
    let fields = fields(body);
    let field = |name| field(&fields, name);
    // "Knuth, Donald" is Donald Knuth.
    let author = |name: &str| match parted(name.trim(), ",").as_slice() {
        [last, first, ..] => plain_title(&format!("{first} {last}")),
        _ => plain_title(name),
    };
    let authors = field("author").map(|authors| {
        let authors = SPACES.replace_all(authors, " ");
        let names = parted(&authors, " and ").into_iter().filter_map(author);
        names.collect::<Vec<_>>().join(", ")
    });
    let published = ["journal", "publisher", "booktitle"]
        .into_iter()
        .find_map(field);
    let lines = [
        authors.filter(|authors| !authors.is_empty()),
        field("title").and_then(plain_title),
        year(&fields),
        published.and_then(plain_title),
    ];
    Some(lines.into_iter().flatten().collect::<Vec<_>>().join("\n"))
}

/// `text` parted at each `at` outside braces, which hold a name's own spaces, commas and
/// `and`s, as BibTeX parts names; `and` in any case.
fn parted<'a>(text: &'a str, at: &str) -> Vec<&'a str> {
    let (mut parts, mut depth, mut from) = (Vec::new(), 0_usize, 0);
    for (i, c) in text.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => depth = depth.saturating_sub(1),
            _ if depth == 0
                && i >= from
                && text
                    .get(i..i + at.len())
                    .is_some_and(|s| s.eq_ignore_ascii_case(at)) =>
            {
                parts.push(&text[from..i]);
                from = i + at.len();
            }
            _ => {}
        }
    }
    parts.push(&text[from..]);
    parts
}

/// Each file's facts by its name as the volume compares names, with the stamp read at. An
/// analysis and a symbol scan may read at once, so it isn't held while a file is read.
#[derive(Default)]
pub struct Files(Mutex<HashMap<String, (Stamp, Arc<Facts>)>>);

impl Files {
    /// Read again once the file's stamp changes, or always on a volume that keeps whole
    /// seconds, where a write of the same length in the same second keeps the stamp.
    pub fn facts(&self, abs: &Path, rel: &str) -> io::Result<Arc<Facts>> {
        let stamp = Stamp::of(&fs::metadata(abs)?);
        let key = paths::fold_case(rel);
        if let Some((read, facts)) = lock(&self.0).get(&key)
            && *read == stamp
            && stamp.modified % 1_000_000_000 != 0
        {
            return Ok(Arc::clone(facts));
        }
        // A line ends where an editor's does, at a carriage return alone too.
        let text = crate::lf(crate::lossy_string(fs::read(abs)?));
        let facts = Arc::new(Facts::read(&text, file_kind(rel)));
        lock(&self.0).insert(key, (stamp, Arc::clone(&facts)));
        Ok(facts)
    }

    pub fn at(&self, root: &Path, rel: &str) -> Option<Arc<Facts>> {
        self.facts(&paths::safe_path(root, rel).ok()?, rel).ok()
    }

    /// Those of other files go, as a scan of the project finds them gone.
    pub fn keep<'a>(&self, rels: impl Iterator<Item = &'a String>) {
        let kept: HashSet<String> = rels.map(|rel| paths::fold_case(rel)).collect();
        lock(&self.0).retain(|key, _| kept.contains(key));
    }
}

/// A heading with what nests under it. `fold_key` names its fold in the
/// project's saved UI state: file, depth, title and which of that name it is.
#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutlineNode {
    pub index: usize,
    #[serde(flatten)]
    pub heading: Heading,
    pub fold_key: String,
    /// Its words and its children's: up to the next heading at its level or above.
    pub words: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<Self>,
}

/// The outline nested by depth; a subsection before any section sits flush.
pub fn outline_tree(outline: &[Heading]) -> Vec<OutlineNode> {
    fn nest(
        outline: &[Heading],
        next: &mut usize,
        above: Option<usize>,
        seen: &mut HashMap<String, usize>,
    ) -> Vec<OutlineNode> {
        let mut nodes = Vec::new();
        while let Some(heading) = outline.get(*next)
            && above.is_none_or(|depth| heading.depth > depth)
        {
            let index = *next;
            *next += 1;
            let file = heading.file.as_deref().unwrap_or_default();
            // An untitled heading's key is as it was before it had a title,
            // so its saved fold stays.
            let title = if heading.untitled {
                "(untitled)"
            } else {
                &heading.title
            };
            let key = format!("{file}\t{}:{title}", heading.depth);
            let count = seen.entry(key.clone()).or_default();
            *count += 1;
            let fold_key = format!("{key}#{count}");
            let children = nest(outline, next, Some(heading.depth), seen);
            nodes.push(OutlineNode {
                index,
                heading: heading.clone(),
                fold_key,
                words: heading.words + children.iter().map(|c| c.words).sum::<usize>(),
                children,
            });
        }
        nodes
    }
    nest(outline, &mut 0, None, &mut HashMap::new())
}

/// The heading a line of a file is under: the file's last at or above the line, matched by name as the analysis matches files (case folded, as on the Mac).
pub fn current_heading(outline: &[Heading], file: &str, line: usize) -> Option<usize> {
    let file = paths::fold_case(file);
    outline.iter().rposition(|h| {
        h.line <= line
            && h.file
                .as_deref()
                .is_some_and(|f| paths::fold_case(f) == file)
    })
}

/// A session's `analyze` answer; the outline itself is kept for `outline_current`.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Analysis {
    #[serde(skip)]
    pub outline: Vec<Heading>,
    /// The files read, each once, in the order read.
    #[serde(skip)]
    pub files: Vec<String>,
    pub tree: Vec<OutlineNode>,
    pub words: usize,
    pub heading_styles: Vec<headings::Level>,
}

/// The document LaTeX reads from the main file through the files it inputs (each once, so a loop ends). `open` is the editor's file, alone when the main file doesn't reach it.
pub fn analyze_project(
    root: &Path,
    files: &Files,
    main: &str,
    open: &str,
    class: Option<&headings::DocumentClass>,
) -> Analysis {
    let mut analysis = Analysis::default();
    if let Ok(open) = paths::rel_key(open) {
        let mut seen = HashSet::new();
        walk(root, files, main, "", &mut seen, &mut analysis);
        if !seen.contains(&paths::fold_case(&open)) {
            analysis = Analysis::default();
            walk(root, files, &open, "", &mut HashSet::new(), &mut analysis);
        }
    }
    let chapters = analysis.outline.iter().any(|h| h.command == "chapter");
    analysis.tree = outline_tree(&analysis.outline);
    analysis.heading_styles = headings::heading_styles(class, chapters);
    analysis
}

/// The project file `rel` names, spelt as the disk spells it. TeX names a file as the author
/// wrote it, which a volume that ignores case finds under another spelling; a document kept
/// by that spelling would be out of step with the tree, and its save would rename the file.
pub(crate) fn disk_spelling(root: &Path, rel: &str) -> Option<String> {
    let mut path = root.to_path_buf();
    let mut spelt = Vec::new();
    for name in rel.split('/') {
        let folded = paths::fold_case(name);
        let found = fs::read_dir(&path)
            .ok()?
            .flatten()
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|entry| paths::fold_case(entry) == folded)
            .max_by_key(|entry| entry == name)?;
        path.push(&found);
        spelt.push(found);
    }
    path.is_file().then(|| spelt.join("/"))
}

/// `within` is the folder an \import gave the file, where its own inputs are looked for first.
fn walk(
    root: &Path,
    files: &Files,
    file: &str,
    within: &str,
    seen: &mut HashSet<String>,
    into: &mut Analysis,
) {
    let Some(file) = paths::rel_key(file)
        .ok()
        .and_then(|file| disk_spelling(root, &file))
    else {
        return;
    };
    if !seen.insert(paths::fold_case(&file)) {
        return;
    }
    let Some(facts) = files.at(root, &file) else {
        return;
    };
    into.files.push(file.clone());
    let placed = |heading: &Heading| Heading {
        file: Some(file.clone()),
        ..heading.clone()
    };
    let found = |rel: &str| {
        let path = paths::safe_path(root, rel);
        path.is_ok_and(|path| path.is_file())
            .then(|| rel.to_owned())
    };
    // Words before a file's first heading, or after an input, are the last heading's read.
    fn credit(outline: &mut [Heading], words: usize) {
        if let Some(last) = outline.last_mut() {
            last.words += words;
        }
    }
    let headed: usize = facts.headings.iter().map(|h| h.words).sum();
    let after_inputs: usize = facts.inputs.iter().map(|input| input.words).sum();
    credit(&mut into.outline, facts.words - headed - after_inputs);
    let mut at = 0;
    for input in &facts.inputs {
        let before = &facts.headings[at..input.before];
        into.outline.extend(before.iter().map(placed));
        at = input.before;
        if let Some((input, within)) = input.resolve(&file, within, found) {
            walk(root, files, &input, &within, seen, into);
        }
        credit(&mut into.outline, input.words);
    }
    into.outline.extend(facts.headings[at..].iter().map(placed));
    into.words += facts.words;
}

/// What \newcommand and its kin, \DeclareMathOperator, \def or \newenvironment defines, named
/// braced or not, with the arguments it takes in braces: as many as its first option counts, but
/// for an optional one.
fn defined(text: &Text, command: &str, name_end: usize) -> Option<Defined> {
    let units = &text.units;
    let (name, at, stop) = match braced(units, name_end) {
        (Some((name, at)), stop) => (name.trim().to_owned(), at, stop),
        (None, stop) if units.get(stop) == Some(&(b'\\' as u16)) => {
            let letters = units[stop + 1..]
                .iter()
                .take_while(|&&u| u < 128 && (u as u8).is_ascii_alphabetic());
            let end = stop + 1 + letters.count();
            (String::from_utf16_lossy(&units[stop..end]), stop..end, end)
        }
        _ => return None,
    };
    if name.trim_start_matches('\\').is_empty() {
        return None;
    }
    let (mut options, mut body) = (Vec::new(), Vec::new());
    let (_, closed) = scan::arguments(units, stop, |piece, braced| {
        if braced {
            body.extend_from_slice(&units[piece]);
        } else {
            options.push(String::from_utf16_lossy(&units[piece]));
        }
    });
    let count = options.first().and_then(|count| count.trim().parse().ok());
    let arguments = count
        .unwrap_or(0_usize)
        .saturating_sub(usize::from(options.len() > 1));
    // As \def, which RaTeX takes whether or not the name is defined; an optional first argument,
    // which RaTeX's \newcommand lacks, comes through the preview's \texlocal@optional.
    let body = String::from_utf16_lossy(&body);
    let parameters = |count| (1..=count).map(|n| format!("#{n}")).collect::<String>();
    let tex = match (command, options.get(1)) {
        _ if !closed => None,
        ("def", _) if !options.is_empty() => None,
        ("DeclareMathOperator", _) => {
            let star = if units.get(name_end) == Some(&(b'*' as u16)) {
                "*"
            } else {
                ""
            };
            Some(format!("\\def{name}{{\\operatorname{star}{{{body}}}}}"))
        }
        (_, Some(default)) => Some(format!(
            "\\def{name}{{\\texlocal@optional{name}@{{{default}}}}}\\def{name}@{}{{{body}}}",
            parameters(arguments + 1)
        )),
        _ => Some(format!("\\def{name}{}{{{body}}}", parameters(arguments))),
    };
    Some(Defined {
        name,
        arguments,
        place: Place::of(text, at),
        tex,
    })
}

/// The end of the line a command's arguments end on.
fn after_line(text: &Text, name_end: usize) -> Place {
    let (_, stop) = braced(&text.units, name_end);
    let end = text.around(stop - 1).end;
    Place::of(text, end..end)
}

fn joined(folder: &str, name: &str) -> String {
    match folder.trim_end_matches('/') {
        "" => name.to_owned(),
        folder => format!("{folder}/{name}"),
    }
}

/// A command's braced argument as TeX reads it, comments left out, and the range it spans; and
/// where the reading stopped.
fn braced(units: &[u16], name_end: usize) -> (Option<(String, Range<usize>)>, usize) {
    let (mut text, mut span) = (Vec::new(), None);
    let (stop, closed) = scan::arguments(units, name_end, |piece, braced| {
        if braced {
            text.extend_from_slice(&units[piece.clone()]);
            span.get_or_insert(piece.clone()).end = piece.end;
        }
    });
    let span = span.filter(|_| closed);
    let found = span.map(|span| (String::from_utf16_lossy(&text), span));
    (found, stop)
}

/// The names a command's closed braced argument holds, without the spaces around them: each
/// key of a `list` that commas part, or else the one name.
fn listed(units: &[u16], name_end: usize, list: bool) -> Vec<Range<usize>> {
    let blank = |u: &&u16| scan::tex_space(**u) || **u == u16::from(b'\n');
    let mut names = Vec::new();
    let (_, closed) = scan::arguments(units, name_end, |piece, braced| {
        if !braced {
            return;
        }
        let commas = piece
            .clone()
            .filter(|&i| list && units[i] == u16::from(b','));
        let mut from = piece.start;
        for end in commas.chain([piece.end]) {
            let start = from + units[from..end].iter().take_while(blank).count();
            let trail = units[start..end].iter().rev().take_while(blank).count();
            if start < end {
                names.push(start..end - trail);
            }
            from = end + 1;
        }
    });
    if closed { names } else { Vec::new() }
}

/// The file an \input, \include, \subfile, \import or \subimport names, and where; \input also
/// takes an unbraced name.
fn input(units: &[u16], command: &str, name_end: usize) -> Option<(String, Folder, Range<usize>)> {
    let (name, folder, at) = match (command, braced(units, name_end)) {
        ("input" | "include" | "subfile", (Some((name, at)), _)) => (name, Folder::Inherited, at),
        ("input", (None, stop)) => {
            let name: String = char::decode_utf16(units[stop..].iter().copied())
                .map_while(|c| c.ok().filter(|c| !"{}\\% \t\r\n".contains(*c)))
                .collect();
            let end = stop + name.encode_utf16().count();
            (name, Folder::Inherited, stop..end)
        }
        ("import" | "subimport", (Some((folder, _)), stop)) => {
            let folder = folder.trim().to_owned();
            let folder = match command {
                "import" => Folder::Import(folder),
                _ => Folder::Sub(folder),
            };
            let (name, at) = braced(units, stop).0?;
            (name, folder, at)
        }
        _ => return None,
    };
    Some((name.trim().to_owned(), folder, at))
}

fn plain_title(title: &str) -> Option<String> {
    let mut rest = title;
    let mut title = String::new();
    while let Some(m) = TITLE_DROP.find(rest) {
        title.push_str(&rest[..m.start()]);
        rest = &rest[m.end()..];
        if let Some(close) = scan::closing_brace(rest) {
            rest = &rest[close + 1..];
        } else {
            title.push_str(m.as_str());
        }
    }
    title.push_str(rest);
    let title = TITLE_STYLE.replace_all(&title, "");
    let title = TITLE_BRACE.replace_all(&title, "$1");
    match SPACES.replace_all(&title, " ").trim_matches(' ') {
        "" => None,
        title => Some(title.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type Outline<'a> = &'a [(usize, &'a str, usize)];

    fn heading(depth: usize, title: &str, file: &str, line: usize) -> Heading {
        let title = (!title.is_empty()).then(|| title.into());
        let file = Some(file.into());
        Heading {
            file,
            ..Heading::new(depth, title, line)
        }
    }

    /// Words part at Unicode spaces and TeX's special characters; only prose counts.
    #[test]
    fn words_part_at_unicode_spaces_and_tex_specials() {
        let cases = [
            ("", 0),
            ("plain ascii words", 3),
            ("123 456 7.5 foo123", 1),
            ("a\u{a0}b\u{2003}c\u{3000}d\u{1680}e\tf", 6),
            ("one\u{85}two\u{2028}three\u{2029}four", 4),
            ("x\u{feff}y z\u{200b}w", 2),
            ("Ελληνικά слова 漢字です עברית", 4),
            ("a{b}c&d_e^f~g", 7),
            ("a{b}c$d$e", 4),
            ("\\textbf{bold} \\cite[p. 3]{key} 42 -- ...", 1),
            ("kept % dropped words", 1),
            ("50\\% off % gone", 1),
            ("a line break \\\\% then a comment", 3),
            ("%all comment", 0),
            (
                "\\documentclass[a4paper]{article}\n\\usepackage{amsmath}\n\\begin{document}\nTwo words\n\\begin{itemize}\\item one\\end{itemize}\n\\[ x + y \\]\n\\begin{lstlisting}\nx = 5 % 3\n\\end{lstlisting}\n\\end{document}",
                3,
            ),
        ];
        for (line, expected) in cases {
            let text = Text::new(line);
            let words = prose::prose(&text, |_, _, _| {}).words(0..text.units.len());
            assert_eq!(words, expected, "{line:?}");
        }
    }

    #[test]
    fn a_file_reads_as_its_outline_and_words() {
        let cases: &[(&str, Outline, usize)] = &[
            (
                "one\r\n\\section{Two}\r\n\\section{Three}\nfour\r\\section{Five}",
                &[(2, "Two", 2), (2, "Three", 3), (2, "Five", 5)],
                5,
            ),
            (
                "\\part{P}\n\\chapter{C}\n\\section{S}\n\\subsection{Sub}\n\\subsubsection{SubSub}\n\\paragraph{Para}\n\\subparagraph{Not in the outline}",
                &[
                    (0, "P", 1),
                    (1, "C", 2),
                    (2, "S", 3),
                    (3, "Sub", 4),
                    (4, "SubSub", 5),
                    (5, "Para", 6),
                ],
                10,
            ),
            // TeX's spaces and comments come before an argument, a no-break
            // space doesn't.
            (
                "\\section*{Starred}\n\\section[Short]{Long title}\n\\subsection * [x] {Spaced}\n\\section\u{a0}{After a no-break space}\n\\section % a note\n{After a comment}",
                &[
                    (2, "Starred", 1),
                    (2, "Long title", 2),
                    (3, "Spaced", 3),
                    (2, "After a comment", 5),
                ],
                13,
            ),
            // Titles that wrap, and one on the line after its command; not
            // across a blank line, nor its comment.
            (
                "\\section{A title the editor\n  wraps at eighty}\n\\section\n{Next line}\n\\section{Not\n\nclosed}\n\\section{Commented % out\n here}",
                &[
                    (2, "A title the editor wraps at eighty", 1),
                    (2, "Next line", 3),
                    (2, "Commented here", 8),
                ],
                13,
            ),
            (
                "\\section{}\n\\chapter*{}",
                &[(2, "Untitled Section", 1), (1, "Untitled Chapter", 2)],
                0,
            ),
            ("Text \\section{A} and \\subsection{B}", &[(2, "A", 1)], 4),
            (
                "% \\section{Hidden}\n  \t% \\section{Indented}\n\\section{Shown} % \\section{After}",
                &[(2, "Shown", 3)],
                1,
            ),
            (
                "\\section{\\texorpdfstring{$\\mathbf{E}$-fields}{E-fields} and \\textbf{More}}\n\\subsection{A {\\bfseries Bold} \\textit{and} Heading\\label{sec:a}}\n\\section{Notes\\footnote{See \\cite{x}.}}\n\\section{R\\&D at 50\\% \\{set\\}}",
                &[
                    (2, "E-fields and More", 1),
                    (3, "A Bold and Heading", 2),
                    (2, "Notes", 3),
                    (2, "R&D at 50% {set}", 4),
                ],
                14,
            ),
            (
                "\\begin{verbatim}\n\\section{Hidden}\n\\end{verbatim}\\section{Visible}\n\\verb|\\section{Hidden}| \\section{After}\n\\\\section{Escaped}",
                &[(2, "Visible", 3), (2, "After", 4)],
                4,
            ),
        ];
        for &(text, outline, words) in cases {
            // A line ends where an editor's does, at a carriage return alone too.
            let facts = Facts::read(&crate::lf(text.into()), "tex");
            let headings = facts.headings.iter();
            let found: Vec<_> = headings.map(|h| (h.depth, &*h.title, h.line)).collect();
            assert_eq!((&found[..], facts.words), (outline, words), "{text}");
        }
    }

    /// In UTF-16 units, as the editors count: the emoji is two.
    #[test]
    fn a_file_places_what_it_defines_and_refers_to() {
        let at = |line, column, length| Place {
            line,
            column,
            length,
        };
        use SymbolKind::{Citation, Command, Environment, File, Label};
        fn named(list: &[Named]) -> Vec<(SymbolKind, &str, Place)> {
            let list = list.iter().filter(|n| n.kind != Command);
            list.map(|n| (n.kind, &*n.name, n.place)).collect()
        }
        let tex = "😀 \\label{fig:a}\n\\cite[p.~3]{knuth, lamport} \\ref{fig:a}\n\
            \\newcommand{\\R}{x} \\newenvironment{thm}{}{}\n\
            \\begin{thm}\\includegraphics{figs/plot}\\end{thm}\n\\bibitem{b} \\input{chapters/a}\n\
            \\nocite{b} \\nameref{fig:a}";
        let facts = Facts::read(tex, "tex");
        assert_eq!(named(&facts.labels), [(Label, "fig:a", at(1, 10, 5))]);
        assert_eq!(named(&facts.citations), [(Citation, "b", at(5, 9, 1))]);
        assert_eq!(
            named(&facts.environments),
            [(Environment, "thm", at(3, 35, 3))]
        );
        let commands = facts.commands.iter().map(|c| (&*c.name, c.place));
        assert_eq!(commands.collect::<Vec<_>>(), [("\\R", at(3, 12, 2))]);
        let input = &facts.inputs[0];
        assert_eq!((&*input.name, input.place), ("chapters/a", at(5, 19, 10)));
        let commands = facts.uses.iter().filter(|n| n.kind == Command);
        let commands: Vec<_> = commands.map(|n| (&*n.name, n.place)).collect();
        let names: Vec<_> = commands.iter().map(|(name, _)| *name).collect();
        assert_eq!(
            names,
            [
                "\\label",
                "\\cite",
                "\\ref",
                "\\newcommand",
                "\\R",
                "\\newenvironment",
                "\\begin",
                "\\includegraphics",
                "\\end",
                "\\bibitem",
                "\\input",
                "\\nocite",
                "\\nameref"
            ]
        );
        assert_eq!(commands[4].1, at(3, 12, 2), "from its backslash");
        assert_eq!(
            named(&facts.uses),
            [
                (Citation, "knuth", at(2, 12, 5)),
                (Citation, "lamport", at(2, 19, 7)),
                (Label, "fig:a", at(2, 33, 5)),
                (Environment, "thm", at(4, 7, 3)),
                (File, "figs/plot", at(4, 28, 9)),
                (Environment, "thm", at(4, 43, 3)),
                (Citation, "b", at(6, 8, 1)),
                (Label, "fig:a", at(6, 20, 5)),
            ]
        );
        let bib = Facts::read("% 😀\n@book{knuth84,\n  title={T}}\n@misc{ é2,}", "bib");
        assert_eq!(
            named(&bib.citations),
            [
                (Citation, "knuth84", at(2, 6, 7)),
                (Citation, "é2", at(4, 7, 2))
            ]
        );
    }

    /// The caption or heading it follows or is in, else its line where that is plain text.
    #[test]
    fn a_label_says_what_it_labels() {
        let tex = "\\section{Intro}\\label{sec:intro}\n\
            \\begin{figure}\\caption{A \\emph{plot}\n of x}\n  \\label{fig:plot}\\end{figure}\n\
            \\caption{Inner\\label{fig:inner}}\n\
            \\begin{equation}\n  E = mc^2 \\label{eq:e}\n\\end{equation}\n\
            \\begin{equation} F = ma \\label{eq:f}\\end{equation}\n\
            \\includegraphics{a.png}\\label{fig:a}";
        let labels = Facts::read(tex, "tex").labels;
        let details = labels.iter().map(|l| (&*l.name, l.detail.as_deref()));
        assert_eq!(
            details.collect::<Vec<_>>(),
            [
                ("sec:intro", Some("Intro")),
                ("fig:plot", Some("A plot of x")),
                ("fig:inner", Some("Inner")),
                ("eq:e", Some("E = mc^2")),
                ("eq:f", Some("F = ma")),
                ("fig:a", None),
            ]
        );
    }

    /// Through braces and quotes, a biblatex date, `#`, names in braces and an `AND`; an entry
    /// left open reads to the next one, not past it.
    #[test]
    fn a_bib_entry_tells_its_authors_year_and_title() {
        let bib = "@book{knuth,\n  author = {Knuth, Donald E.},\n  title = \"The {TeX}book, \" # {Vol. A},\n  year = 1984,\n}\n\
            @article{two, title = {On {\\em Two}}, author = {A. One and\n B. {Two}}, date = {2020-05-01}}\n\
            @misc(many, author = \"A and B and {World Health Organization}\")\n\
            @misc{corp, author = {{Procter and Gamble} AND Jean {de La Fontaine}}}\n\
            @misc{open, title = {Never {closed},\n  year = 1999\n\
            @misc{after, author = {Last, First}, year = {2001}}\n@misc{bare,}";
        let read = Facts::read(bib, "bib").citations;
        let details = read.iter().map(|c| (&*c.name, c.detail.as_deref()));
        assert_eq!(
            details.collect::<Vec<_>>(),
            [
                ("knuth", Some("Knuth · 1984 · The TeXbook, Vol. A")),
                ("two", Some("One and Two · 2020 · On Two")),
                ("many", Some("A et al.")),
                ("corp", Some("Procter and Gamble and de La Fontaine")),
                ("open", Some("Never closed, year = 1999")),
                ("after", Some("Last · 2001")),
                ("bare", None),
            ]
        );
    }

    #[test]
    fn the_outline_nests_by_depth_with_a_fold_key_for_each_heading() {
        let outline = [
            heading(3, "Early", "a.tex", 1),
            heading(2, "Intro", "a.tex", 5),
            heading(3, "Intro", "a.tex", 8),
            heading(3, "Intro", "a.tex", 9),
            heading(2, "Intro", "a.tex", 12),
            heading(1, "Back", "b.tex", 2),
            heading(1, "", "b.tex", 4),
        ];
        let tree = outline_tree(&outline);
        let shape = |nodes: &[OutlineNode]| -> Vec<(usize, String, usize)> {
            nodes
                .iter()
                .map(|n| (n.index, n.fold_key.clone(), n.children.len()))
                .collect()
        };
        assert_eq!(
            shape(&tree),
            [
                (0, "a.tex\t3:Early#1".into(), 0),
                (1, "a.tex\t2:Intro#1".into(), 2),
                (4, "a.tex\t2:Intro#2".into(), 0),
                (5, "b.tex\t1:Back#1".into(), 0),
                (6, "b.tex\t1:(untitled)#1".into(), 0),
            ]
        );
        assert_eq!(
            shape(&tree[1].children),
            [
                (2, "a.tex\t3:Intro#1".into(), 0),
                (3, "a.tex\t3:Intro#2".into(), 0),
            ]
        );
        let json = serde_json::to_value(&tree[0]).unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "index": 0, "depth": 3, "command": "subsection", "level": "Subsection", "title": "Early",
                "untitled": false, "line": 1, "file": "a.tex", "foldKey": "a.tex\t3:Early#1", "words": 0 })
        );
        let untitled = serde_json::to_value(&tree[4]).unwrap();
        assert_eq!(untitled["title"], "Untitled Chapter");
        assert_eq!(untitled["untitled"], true);
        assert_eq!(current_heading(&outline, "a.tex", 9), Some(3));
        assert_eq!(current_heading(&outline, "a.tex", 100), Some(4));
        assert_eq!(current_heading(&outline, "b.tex", 1), None);
        assert_eq!(current_heading(&outline, "c.tex", 5), None);
        // Both platforms' volumes fold case, so another spelling is the same file.
        assert_eq!(current_heading(&outline, "A.TEX", 9), Some(3));
    }

    fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for (rel, text) in files {
            let path = dir.path().join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        }
        dir
    }

    #[test]
    fn a_project_reads_its_inputs_in_place() {
        let dir = project(&[
            (
                "main.tex",
                "\\section{Intro}\nHello world\n\\input{chapters/a}\n% \\input{loose}\n\\include{b}\\input{main}\n\\section{End}",
            ),
            ("chapters/a.tex", "\\section{A}\none two\n\\input{b.tex}"),
            ("b.tex", "\\subsection{B}"),
            ("loose.tex", "\\section{Loose}\nthree"),
        ]);
        fn headings(a: &Analysis) -> Vec<(&str, Option<&str>, usize)> {
            let outline = a.outline.iter();
            outline
                .map(|h| (h.title.as_str(), h.file.as_deref(), h.line))
                .collect()
        }
        let analyzed =
            |open| analyze_project(dir.path(), &Files::default(), "main.tex", open, None);
        let whole = analyzed("chapters/a.tex");
        assert_eq!(
            headings(&whole),
            [
                ("Intro", Some("main.tex"), 1),
                ("A", Some("chapters/a.tex"), 1),
                ("B", Some("b.tex"), 1),
                ("End", Some("main.tex"), 6)
            ]
        );
        assert_eq!(whole.words, 8);
        let loose = analyzed("loose.tex");
        assert_eq!(headings(&loose), [("Loose", Some("loose.tex"), 1)]);
        assert_eq!(loose.words, 2);
    }

    /// Through the files it inputs; the words before the first heading are none's.
    #[test]
    fn a_heading_counts_its_words_and_its_childrens_up_to_the_next_of_its_level() {
        let dir = project(&[
            (
                "main.tex",
                "Before any\n\\section{Intro}\nHello world\n\\subsection{Detail}\nthree more words\n\\input{ch}\nafter it $x + y$\n\\section{End}\nlast",
            ),
            ("ch.tex", "chapter \\emph{text} here"),
        ]);
        let analysis = analyze_project(dir.path(), &Files::default(), "main.tex", "main.tex", None);
        let words = |nodes: &[OutlineNode]| nodes.iter().map(|n| n.words).collect::<Vec<_>>();
        assert_eq!(words(&analysis.tree), [12, 2]);
        assert_eq!(words(&analysis.tree[0].children), [9]);
        assert_eq!(analysis.words, 16);
    }

    #[test]
    fn inputs_are_followed_as_tex_finds_them() {
        let one = [
            ("main.tex", "\\section{Main}\n\\input{chapters/one}"),
            ("chapters/one.tex", "\\section{One}"),
        ];
        let unbraced = [
            (
                "main.tex",
                "\\section{Main}\n\\input chapter\n\\section{End}",
            ),
            ("chapter.tex", "\\section{Chapter}\nbody"),
        ];
        let named_tex = [
            ("main.tex", "\\input{part.tex}"),
            ("part.tex", "\\section{Part}"),
            ("part.tex.tex", "\\section{Wrong}"),
        ];
        let literal = [
            (
                "main.tex",
                "\\section{Main}\n\\begin{verbatim}\n\\input{example}\n\\end{verbatim}\n\\begin{comment}\n\\input{example}\n\\end{comment}\n\\verb|\\input{example}|\n\\input{real}",
            ),
            ("example.tex", "\\section{Example}"),
            ("real.tex", "\\section{Real}"),
        ];
        let imported = [
            (
                "main.tex",
                "\\section{Main}\n\\import{chapters/}{one}\n\\subimport{chapters}{two.tex}",
            ),
            (
                "chapters/one.tex",
                "\\section{One}\n\\input{inner}\n\\subimport{deep/}{three}",
            ),
            ("chapters/inner.tex", "\\section{Inner}"),
            ("chapters/two.tex", "\\section{Two}"),
            ("chapters/deep/three.tex", "\\section{Three}"),
        ];
        let cases: [(&[_], &str, &[&str]); 7] = [
            (&one, "chapters/one.tex", &["Main", "One"]),
            (&one, "./chapters/one.tex", &["Main", "One"]),
            (&one, "chapters/../chapters/one.tex", &["Main", "One"]),
            (&unbraced, "main.tex", &["Main", "Chapter", "End"]),
            (&named_tex, "main.tex", &["Part"]),
            (&literal, "main.tex", &["Main", "Real"]),
            (
                &imported,
                "main.tex",
                &["Main", "One", "Inner", "Three", "Two"],
            ),
        ];
        for (files, open, titles) in cases {
            let dir = project(files);
            let found =
                analyze_project(dir.path(), &Files::default(), "main.tex", open, None).outline;
            let found: Vec<_> = found.iter().map(|h| h.title.as_str()).collect();
            assert_eq!(found, titles, "{files:?} with {open} open");
        }
    }
}
