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

use crate::projects::file_kind;
use crate::stamp::Stamp;
use crate::syntax::catalog::CATALOG;
use crate::syntax::scan::{Scanner, Visit};
use crate::syntax::{SymbolKind, Text, headings, prose, scan};
use crate::{lock, paths};

// What a title drops whole: \texorpdfstring's TeX argument (its PDF string is
// the group after), labels and notes.
static TITLE_DROP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\(?:texorpdfstring|label|index|footnote)\s*\{").unwrap());
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
    /// ended, and graphics included.
    pub uses: Vec<Used>,
    pub class: Option<headings::DocumentClass>,
}

/// Where a name is written: its line, from 1, and its column, from 0, and length in UTF-16 units.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Place {
    pub line: u32,
    pub column: u32,
    pub length: u32,
}

impl Place {
    fn of(text: &Text, range: Range<usize>) -> Self {
        let line = text.line_index(range.start as u32);
        Self {
            line: line as u32 + 1,
            column: range.start as u32 - text.lines[line],
            length: range.len() as u32,
        }
    }
}

#[derive(Clone)]
pub struct Named {
    pub name: String,
    pub place: Place,
    /// What completion says of it beside its name: a .bib entry's authors, year and title.
    pub detail: Option<String>,
}

/// A command the project defines, with the arguments it takes in braces.
#[derive(Clone)]
pub struct Defined {
    pub name: String,
    pub arguments: usize,
    pub place: Place,
}

pub struct Used {
    pub kind: SymbolKind,
    pub name: String,
    pub place: Place,
}

/// A file read in place after the first `before` headings of the file that names it.
pub struct Input {
    before: usize,
    pub(crate) name: String,
    folder: Folder,
    pub(crate) place: Place,
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
        let folders: Vec<&str> = match &folder {
            Some(folder) => vec![folder],
            None => [within]
                .into_iter()
                .chain((!within.is_empty()).then_some(""))
                .collect(),
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
        if kind == "bib" {
            let mut entries = BIB_KEY.captures_iter(source).peekable();
            let (mut citations, mut byte, mut unit) = (Vec::new(), 0, 0);
            while let Some(entry) = entries.next() {
                let kind = entry[1].to_ascii_lowercase();
                if matches!(kind.as_str(), "comment" | "string" | "preamble") {
                    continue;
                }
                let key = entry.get(2).expect("an entry has a key");
                unit += source[byte..key.start()].encode_utf16().count();
                byte = key.start();
                let end = unit + key.as_str().encode_utf16().count();
                // Read to the next entry at most, so one left unbalanced takes nothing of those
                // after it.
                let next = entries
                    .peek()
                    .map_or(source.len(), |next| next.get_match().start());
                citations.push(Named {
                    name: key.as_str().to_owned(),
                    place: Place::of(&text, unit..end),
                    detail: detail(&fields(&source[entry.get_match().end()..next])),
                });
            }
            return Self {
                citations,
                ..Self::default()
            };
        }
        let mut facts = Self::default();
        // Found as the words are counted, so none is in a comment, maths or literal code.
        let mut heading_line = None;
        let words = prose::words(&text, |text, name, name_end| {
            let line = text.line_index(name_end as u32) + 1;
            let units = &text.units;
            if let Some(depth) = headings::LEVELS.iter().position(|l| l.0 == name) {
                if heading_line != Some(line)
                    && let (Some((title, _)), _) = braced(units, name_end)
                {
                    let heading = Heading::new(depth, plain_title(&title), line);
                    facts.headings.push(heading);
                }
                heading_line = Some(line);
            } else if let Some((name, folder, at)) = input(units, name, name_end) {
                let before = facts.headings.len();
                facts.inputs.push(Input {
                    before,
                    name,
                    folder,
                    place: Place::of(text, at),
                });
            }
        });
        let mut names = Names(&text, &mut facts);
        Scanner::default().run(&text.units, text.units.len(), &[], &mut names);
        Self { words, ..facts }
    }
}

/// What a text names for others to refer to, and the names it refers to, outside comments and
/// literal code.
struct Names<'a>(&'a Text, &'a mut Facts);

impl Visit for Names<'_> {
    fn command(&mut self, name: &str, start: usize, name_end: usize) {
        let (text, facts) = (self.0, &mut *self.1);
        match name {
            "bibitem" => {
                let keys = listed(&text.units, name_end, false).into_iter();
                facts.citations.extend(keys.map(|at| named(text, at)));
            }
            "documentclass" if facts.class.is_none() => {
                facts.class = headings::class_at(&text.units, name_end);
            }
            "newcommand" | "DeclareMathOperator" | "newenvironment" => {
                let command = name != "newenvironment";
                if let Some(defined) = defined(text, name_end)
                    && defined.name.starts_with('\\') == command
                {
                    if command {
                        facts.commands.push(defined);
                    } else {
                        let Defined { name, place, .. } = defined;
                        facts.environments.push(Named {
                            name,
                            place,
                            detail: None,
                        });
                    }
                }
            }
            _ => self.math_command(name, start, name_end),
        }
    }

    fn math_command(&mut self, name: &str, _: usize, name_end: usize) {
        let (text, catalog) = (self.0, &*CATALOG);
        let kind = match name {
            "begin" | "end" => SymbolKind::Environment,
            "includegraphics" => SymbolKind::File,
            name if catalog.ref_commands.contains(name) => SymbolKind::Label,
            name if catalog.cite_commands.contains(name) => SymbolKind::Citation,
            "label" => {
                let labels = listed(&text.units, name_end, false).into_iter();
                let labels = labels.map(|at| named(text, at));
                // One still being typed (`fig:`) isn't a label yet.
                let labels = labels.filter(|label| !label.name.ends_with(':'));
                self.1.labels.extend(labels);
                return;
            }
            _ => return,
        };
        let list = matches!(kind, SymbolKind::Label | SymbolKind::Citation);
        for at in listed(&text.units, name_end, list) {
            let Named { name, place, .. } = named(text, at);
            self.1.uses.push(Used { kind, name, place });
        }
    }
}

fn named(text: &Text, at: Range<usize>) -> Named {
    Named {
        name: String::from_utf16_lossy(&text.units[at.clone()]),
        place: Place::of(text, at),
        detail: None,
    }
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

/// What completion says of a .bib entry, "Knuth · 1984 · The TeXbook", as far as its fields
/// tell: its authors' last names, its year (or biblatex's date's) and its title.
fn detail(fields: &[(String, String)]) -> Option<String> {
    let field = |name: &str| {
        fields
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    };
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
    let year = field("year").or_else(|| field("date").and_then(|date| date.get(..4)));
    let parts = [
        authors,
        year.and_then(plain_title),
        field("title").and_then(plain_title),
    ];
    let parts: Vec<String> = parts.into_iter().flatten().collect();
    (!parts.is_empty()).then(|| parts.join(" · "))
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
            nodes.push(OutlineNode {
                index,
                heading: heading.clone(),
                fold_key: format!("{key}#{count}"),
                children: nest(outline, next, Some(heading.depth), seen),
            });
        }
        nodes
    }
    nest(outline, &mut 0, None, &mut HashMap::new())
}

/// The heading a line of a file is under: the file's last at or above the line, matched by name as the analysis matches files (case folded, as on Mac and Windows).
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
    let placed = |headings: &[Heading]| -> Vec<Heading> {
        let file = Some(file.clone());
        let place = |h: &Heading| Heading {
            file: file.clone(),
            ..h.clone()
        };
        headings.iter().map(place).collect()
    };
    let mut at = 0;
    for input in &facts.inputs {
        into.outline
            .extend(placed(&facts.headings[at..input.before]));
        at = input.before;
        let found = |rel: &str| {
            let path = paths::safe_path(root, rel);
            path.is_ok_and(|path| path.is_file())
                .then(|| rel.to_owned())
        };
        if let Some((input, within)) = input.resolve(&file, within, found) {
            walk(root, files, &input, &within, seen, into);
        }
    }
    into.outline.extend(placed(&facts.headings[at..]));
    into.words += facts.words;
}

/// What \newcommand, \DeclareMathOperator or \newenvironment defines, named braced or not, with
/// the arguments it takes in braces: as many as its first option counts, but for an optional one.
fn defined(text: &Text, name_end: usize) -> Option<Defined> {
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
    let mut options = Vec::new();
    scan::arguments(units, stop, |piece, braced| {
        if !braced {
            options.push(String::from_utf16_lossy(&units[piece]));
        }
    });
    let count = options.first().and_then(|count| count.trim().parse().ok());
    let arguments = count
        .unwrap_or(0_usize)
        .saturating_sub(usize::from(options.len() > 1));
    Some(Defined {
        name,
        arguments,
        place: Place::of(text, at),
    })
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
            let words = prose::words(&Text::new(line), |_, _, _| {});
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
            ("\\section{}\n\\chapter*{}", &[(2, "", 1), (1, "", 2)], 0),
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
        let dir = tempfile::tempdir().unwrap();
        for &(text, outline, words) in cases {
            fs::write(dir.path().join("main.tex"), text).unwrap();
            let expected: Vec<_> = outline
                .iter()
                .map(|&(depth, title, line)| heading(depth, title, "main.tex", line))
                .collect();
            let found =
                analyze_project(dir.path(), &Files::default(), "main.tex", "main.tex", None);
            assert_eq!((found.outline, found.words), (expected, words), "{text}");
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
        let named = |list: &[Named]| -> Vec<(String, Place)> {
            list.iter().map(|n| (n.name.clone(), n.place)).collect()
        };
        let tex = "😀 \\label{fig:a}\n\\cite[p.~3]{knuth, lamport} \\ref{fig:a}\n\
            \\newcommand{\\R}{x} \\newenvironment{thm}{}{}\n\
            \\begin{thm}\\includegraphics{figs/plot}\\end{thm}\n\\bibitem{b} \\input{chapters/a}";
        let facts = Facts::read(tex, "tex");
        assert_eq!(named(&facts.labels), [("fig:a".into(), at(1, 10, 5))]);
        assert_eq!(named(&facts.citations), [("b".into(), at(5, 9, 1))]);
        assert_eq!(named(&facts.environments), [("thm".into(), at(3, 35, 3))]);
        let commands = facts.commands.iter().map(|c| (&*c.name, c.place));
        assert_eq!(commands.collect::<Vec<_>>(), [("\\R", at(3, 12, 2))]);
        let input = &facts.inputs[0];
        assert_eq!((&*input.name, input.place), ("chapters/a", at(5, 19, 10)));
        let uses = facts.uses.iter().map(|u| (u.kind, &*u.name, u.place));
        assert_eq!(
            uses.collect::<Vec<_>>(),
            [
                (SymbolKind::Citation, "knuth", at(2, 12, 5)),
                (SymbolKind::Citation, "lamport", at(2, 19, 7)),
                (SymbolKind::Label, "fig:a", at(2, 33, 5)),
                (SymbolKind::Environment, "thm", at(4, 7, 3)),
                (SymbolKind::File, "figs/plot", at(4, 28, 9)),
                (SymbolKind::Environment, "thm", at(4, 43, 3)),
            ]
        );
        let bib = Facts::read("% 😀\n@book{knuth84,\n  title={T}}\n@misc{ é2,}", "bib");
        assert_eq!(
            named(&bib.citations),
            [("knuth84".into(), at(2, 6, 7)), ("é2".into(), at(4, 7, 2))]
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
        let read = Facts::read(bib, "bib").citations.into_iter();
        let details: Vec<_> = read.map(|c| (c.name, c.detail)).collect();
        let detail = |key: &str, detail: Option<&str>| (key.into(), detail.map(String::from));
        assert_eq!(
            details,
            [
                detail("knuth", Some("Knuth · 1984 · The TeXbook, Vol. A")),
                detail("two", Some("One and Two · 2020 · On Two")),
                detail("many", Some("A et al.")),
                detail("corp", Some("Procter and Gamble and de La Fontaine")),
                detail("open", Some("Never closed, year = 1999")),
                detail("after", Some("Last · 2001")),
                detail("bare", None),
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
                "untitled": false, "line": 1, "file": "a.tex", "foldKey": "a.tex\t3:Early#1" })
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
        let whole = analyze_project(
            dir.path(),
            &Files::default(),
            "main.tex",
            "chapters/a.tex",
            None,
        );
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
        let loose = analyze_project(dir.path(), &Files::default(), "main.tex", "loose.tex", None);
        assert_eq!(headings(&loose), [("Loose", Some("loose.tex"), 1)]);
        assert_eq!(loose.words, 2);
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
