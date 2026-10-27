use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::ops::Range;
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};

use regex::Regex;
use serde::Serialize;

use crate::checks::{Slip, Structure, Walk};
use crate::projects::file_kind;
use crate::stamp::Stamp;
use crate::syntax::catalog::CATALOG;
use crate::syntax::scan::{Group, Scanner, Visit};
use crate::syntax::{SymbolKind, Symbols, Text, headings, prose, scan};
use crate::{lock, paths};

static TITLE_DROP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:texorpdfstring|label|index|footnote|begin|end)\s*\{").unwrap()
});
static TITLE_STYLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:emph|text(?:bf|it|sl|sc|tt|sf|rm|up|md|normal)|underline|em|bf|it|sl|sc|tt|sf|rm|normalfont|(?:bf|md)series|(?:it|sl|sc|up)shape|(?:rm|sf|tt)family)(?-u:\b)\s*").unwrap()
});
static TITLE_BRACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\([{}&%$#_])|[{}]").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
static BIB_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@([0-9A-Za-z_]+)\s*[{(]\s*([^,\s]+)\s*,").unwrap());
static CROSSREF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)(?:^|,)\s*crossref\s*=\s*[{"]?\s*([^\s,{}"]+)"#).unwrap());

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Heading {
    #[serde(skip)]
    pub depth: usize,
    pub command: &'static str,
    pub level: &'static str,
    pub title: String,
    pub untitled: bool,
    pub line: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
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

#[derive(Default)]
pub struct Facts {
    pub headings: Vec<Heading>,
    pub inputs: Vec<Input>,
    pub words: usize,
    pub labels: Vec<Named>,
    pub citations: Vec<Named>,
    pub commands: Vec<Defined>,
    pub environments: Vec<Named>,
    pub uses: Vec<Named>,
    pub class: Option<String>,
    pub packages: Vec<String>,
    pub new_package: Option<Place>,
    pub bibliographies: Vec<String>,
    pub slips: Vec<Slip>,
    pub end: Option<Place>,
}

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

#[derive(Clone)]
pub struct Named {
    pub kind: SymbolKind,
    pub name: String,
    pub place: Place,
    pub detail: Option<String>,
}

#[derive(Clone)]
pub struct Defined {
    pub name: String,
    pub arguments: usize,
    pub place: Place,
    pub tex: Option<String>,
}

pub struct Input {
    pub(crate) before: usize,
    pub(crate) name: String,
    folder: Folder,
    pub(crate) place: Place,
    pub(crate) words: usize,
}

enum Folder {
    Inherited,
    Import(String),
    Sub(String),
}

impl Input {
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
                if let Some(parent) = CROSSREF.captures(body).and_then(|parent| parent.get(1)) {
                    let at = start + parent.start()..start + parent.end();
                    facts.uses.push(cited(at));
                }
            }
            return facts;
        }
        let mut heading_line = None;
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
    fn used(&mut self, name: &str, start: usize, name_end: usize) {
        let (text, catalog) = (self.0, &*CATALOG);
        let kind = match name {
            "begin" | "end" => SymbolKind::Environment,
            "includegraphics" => SymbolKind::File,
            name if catalog.ref_commands.contains(name) => SymbolKind::Label,
            name if catalog.cite_commands.contains(name) => SymbolKind::Citation,
            "label" => {
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

fn year(fields: &[(String, String)]) -> Option<String> {
    let date = || field(fields, "date").and_then(|date| date.get(..4));
    field(fields, "year").or_else(date).and_then(plain_title)
}

fn detail(fields: &[(String, String)]) -> Option<String> {
    let field = |name| field(fields, name);
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

pub(crate) fn bib_entry(source: &str, key: &str) -> Option<String> {
    let (_, body) = entries(source).find(|(entry, _)| &entry[2] == key)?;
    let fields = fields(body);
    let field = |name| field(&fields, name);
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

#[derive(Default)]
pub struct Files(Mutex<HashMap<String, (Stamp, Arc<Facts>)>>);

impl Files {
    pub fn facts(&self, abs: &Path, rel: &str) -> io::Result<Arc<Facts>> {
        let stamp = Stamp::of(&fs::metadata(abs)?);
        let key = paths::fold_case(rel);
        if let Some((read, facts)) = lock(&self.0).get(&key)
            && *read == stamp
            && stamp.modified % 1_000_000_000 != 0
        {
            return Ok(Arc::clone(facts));
        }
        let text = crate::lf(crate::lossy_string(fs::read(abs)?));
        let facts = Arc::new(Facts::read(&text, file_kind(rel)));
        lock(&self.0).insert(key, (stamp, Arc::clone(&facts)));
        Ok(facts)
    }

    pub fn keep<'a>(&self, rels: impl Iterator<Item = &'a String>) {
        let kept: HashSet<String> = rels.map(|rel| paths::fold_case(rel)).collect();
        lock(&self.0).retain(|key, _| kept.contains(key));
    }
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutlineNode {
    pub index: usize,
    #[serde(flatten)]
    pub heading: Heading,
    pub fold_key: String,
    pub words: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<Self>,
}

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

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Analysis {
    #[serde(skip)]
    pub outline: Vec<Heading>,
    #[serde(skip)]
    pub files: Vec<String>,
    pub tree: Vec<OutlineNode>,
    pub words: usize,
    pub heading_styles: Vec<headings::Level>,
}

pub fn analyze_project(symbols: &Symbols, main: Option<&str>, shown: Option<&str>) -> Analysis {
    let mut walk = Walk::from(symbols, main.unwrap_or_default());
    if let Some(shown) = shown
        && !walk.files.iter().any(|(file, _)| *file == shown)
    {
        walk = Walk::from(symbols, shown);
    }
    let class = main.and_then(|main| symbols.by_file.get(main)?.class.as_deref());
    Analysis {
        tree: outline_tree(&walk.outline),
        words: walk.words,
        heading_styles: headings::heading_styles(class),
        files: walk
            .files
            .iter()
            .map(|(file, _)| (*file).to_owned())
            .collect(),
        outline: walk.outline,
    }
}

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

pub(crate) const INPUT_DEPTH: usize = 15;

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
