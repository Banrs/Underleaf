use std::collections::hash_map::Entry;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use schemars::JsonSchema;
use serde::Serialize;

use crate::facts::{Facts, Heading, Input, Kind, Named, Slip};
use crate::logparse::{LogItem, Severity};
use crate::message::Message;
use crate::messages;
use crate::syntax::{Installed, SymbolKind, Symbols, headings};

#[derive(Default)]
pub struct Scan {
    pub facts: BTreeMap<String, Arc<Facts>>,
    pub symbols: Arc<Symbols>,
}

impl Scan {
    pub fn new(
        facts: BTreeMap<String, Arc<Facts>>,
        files: Vec<String>,
        installed: Arc<Installed>,
    ) -> Self {
        let by_file = facts
            .iter()
            .map(|(file, facts)| (file.clone(), Arc::clone(&facts.defined)));
        let symbols = Symbols {
            files,
            by_file: by_file.collect(),
            installed,
        };
        Self {
            facts,
            symbols: Arc::new(symbols),
        }
    }
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
struct OutlineNode {
    index: usize,
    heading: Heading,
    fold_key: String,
    words: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    children: Option<Vec<Self>>,
}

fn outline_tree(outline: &[Heading]) -> Vec<OutlineNode> {
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
            let file = &heading.file;
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
                children: (!children.is_empty()).then_some(children),
            });
        }
        nodes
    }
    nest(outline, &mut 0, None, &mut HashMap::new())
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Analysis {
    #[serde(skip)]
    pub outline: Vec<Heading>,
    #[serde(skip)]
    pub files: Vec<String>,
    tree: Vec<OutlineNode>,
    words: usize,
    heading_styles: Vec<headings::HeadingStyle>,
}

pub fn analyze(scan: &Scan, main: Option<&str>, shown: Option<&str>) -> Analysis {
    let mut walk = Walk::from(scan, main.unwrap_or_default());
    if let Some(shown) = shown
        && !walk.files.iter().any(|(file, _)| *file == shown)
    {
        walk = Walk::from(scan, shown);
    }
    let class = main.and_then(|main| scan.facts.get(main)?.class.as_deref());
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

const INPUT_DEPTH: usize = 15;

fn literal(name: &str) -> bool {
    !name.is_empty() && !name.contains(['\\', '#'])
}

fn read<'a>(facts: &'a Facts, names: &'a [Named]) -> impl Iterator<Item = &'a Named> {
    names
        .iter()
        .filter(|n| facts.end.is_none_or(|end| n.place < end))
}

struct Walk<'a> {
    scan: &'a Scan,
    files: Vec<(&'a str, &'a Facts)>,
    labels: Vec<(&'a str, &'a Named)>,
    slips: Vec<(&'a str, &'a Slip)>,
    missing: Vec<(&'a str, &'a Input)>,
    outline: Vec<Heading>,
    words: usize,
}

impl<'a> Walk<'a> {
    fn from(scan: &'a Scan, file: &str) -> Self {
        let mut walk = Self {
            scan,
            files: Vec::new(),
            labels: Vec::new(),
            slips: Vec::new(),
            missing: Vec::new(),
            outline: Vec::new(),
            words: 0,
        };
        walk.read(file, "", 0);
        walk
    }

    fn read(&mut self, file: &str, within: &str, depth: usize) {
        let scan = self.scan;
        if depth == INPUT_DEPTH {
            return;
        }
        let Some((file, facts)) = scan.facts.get_key_value(file) else {
            return;
        };
        let file = file.as_str();
        if self.files.iter().any(|(read, ..)| *read == file) {
            return;
        }
        self.files.push((file, facts));
        let mut labels = read(facts, &facts.defined.labels).peekable();
        let mut slips = facts.slips.iter().peekable();
        let headings = &facts.headings;
        let read_headings = headings
            .iter()
            .take_while(|h| facts.end.is_none_or(|end| h.line as u32 <= end.line))
            .count();
        let placed = |heading: &Heading| Heading {
            file: file.to_owned(),
            ..heading.clone()
        };
        let headed: usize = headings.iter().map(|h| h.words).sum();
        let after_inputs: usize = facts.inputs.iter().map(|input| input.words).sum();
        self.credit(facts.words - headed - after_inputs);
        let mut at = 0;
        let inputs = facts.inputs.iter();
        for input in inputs.filter(|i| facts.end.is_none_or(|end| i.place < end)) {
            while let Some(label) = labels.next_if(|label| label.place < input.place) {
                self.labels.push((file, label));
            }
            while let Some(slip) = slips.next_if(|slip| slip.place < input.place) {
                self.slip(file, slip);
            }
            let before = input.before.min(read_headings);
            self.outline.extend(headings[at..before].iter().map(placed));
            at = before;
            match input.resolve(file, within, |rel| scan.symbols.spelt(rel)) {
                Some((input, within)) => self.read(&input, &within, depth + 1),
                None => self.missing.push((file, input)),
            }
            self.credit(input.words);
        }
        self.outline
            .extend(headings[at..read_headings].iter().map(placed));
        self.words += facts.words;
        self.labels.extend(labels.map(|label| (file, label)));
        slips.for_each(|slip| self.slip(file, slip));
    }

    fn credit(&mut self, words: usize) {
        if let Some(last) = self.outline.last_mut() {
            last.words += words;
        }
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

fn twice<'a>(
    defined: impl IntoIterator<Item = (&'a str, &'a Named)>,
    said: fn(&str, u32, &str) -> Message,
) -> Vec<LogItem> {
    let mut first = HashMap::new();
    let mut twice = Vec::new();
    for (file, named) in defined.into_iter().filter(|(_, n)| literal(&n.name)) {
        match first.entry(named.name.as_str()) {
            Entry::Vacant(entry) => {
                entry.insert((file, named.place.line));
            }
            Entry::Occupied(entry) => {
                let (at, line) = entry.get();
                let message = said(&named.name, *line, at);
                twice.push(warning(file, named.place.line, message));
            }
        }
    }
    twice
}

fn warning(file: &str, line: u32, message: Message) -> LogItem {
    LogItem::new(Severity::Warning, Some(file.into()), Some(line), message)
}

pub fn check(scan: &Scan, main: &str) -> Vec<LogItem> {
    let (walk, symbols) = (Walk::from(scan, main), &scan.symbols);
    let reached = || walk.files.iter().copied();
    let undefined = |kind, said: fn(&str) -> Message, defined: &HashSet<&str>| -> Vec<LogItem> {
        let uses =
            reached().flat_map(|(file, facts)| read(facts, &facts.uses).map(move |u| (file, u)));
        let uses = uses.filter(|(_, used)| used.kind == kind && literal(&used.name));
        let undefined = uses.filter(|(_, used)| !defined.contains(&*used.name));
        let item = |(file, used): (&str, &Named)| warning(file, used.place.line, said(&used.name));
        undefined.map(item).collect()
    };
    let packages: HashSet<&str> = reached()
        .flat_map(|(_, facts)| &facts.packages)
        .map(String::as_str)
        .collect();
    let mut items = twice(walk.labels.iter().copied(), |name, line, file| {
        messages::label_defined_twice(name, line, file)
    });

    if !packages.contains("xr") && !packages.contains("xr-hyperref") {
        let mut labels: HashSet<&str> = walk.labels.iter().map(|(_, l)| l.name.as_str()).collect();
        if packages.contains("lastpage") {
            labels.extend(["LastPage", "VeryLastPage"]);
        }
        items.extend(undefined(
            SymbolKind::Label,
            |name| messages::no_label(name),
            &labels,
        ));
    }

    let named = reached().flat_map(|(_, facts)| &facts.bibliographies);
    let bibliographies: Vec<Option<String>> = named
        .map(|name| {
            symbols
                .spelt(&format!("{name}.bib"))
                .or_else(|| symbols.spelt(name))
        })
        .collect();
    let mut seen = HashSet::new();
    let bibs = bibliographies
        .iter()
        .flatten()
        .filter(|bib| seen.insert(*bib));
    let entries = bibs.filter_map(|bib| scan.facts.get_key_value(bib));
    let entries: Vec<(&str, &Named)> = entries
        .flat_map(|(bib, facts)| {
            facts
                .defined
                .citations
                .iter()
                .map(move |c| (bib.as_str(), c))
        })
        .collect();
    items.extend(twice(entries.iter().copied(), |name, line, file| {
        messages::citation_defined_twice(name, line, file)
    }));
    if bibliographies.iter().all(Option::is_some) {
        let bibitems = reached().flat_map(|(_, facts)| read(facts, &facts.defined.citations));
        let mut keys: HashSet<&str> = bibitems.map(|c| c.name.as_str()).collect();
        keys.extend(entries.iter().map(|(_, c)| c.name.as_str()));
        keys.insert("*");
        items.extend(undefined(
            SymbolKind::Citation,
            |name| messages::no_citation(name),
            &keys,
        ));
    }

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
    items.extend(
        missing
            .map(|(file, input)| warning(file, input.place.line, messages::no_file(&input.name))),
    );

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
