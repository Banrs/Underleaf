use std::collections::HashSet;
use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;
use schemars::JsonSchema;
use serde::Serialize;

use super::SourceDocument;
use super::catalog::CATALOG;
use super::scan::{End, Group, Visit, environment_name};

#[derive(Serialize, JsonSchema)]
pub(crate) struct MathPreview {
    pub(crate) start: u32,
    pub(crate) tex: String,
    pub(crate) display: bool,
}

static LABELS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\(?:label|tag)\{[^}]*\}").unwrap());
static NUMBERING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\(?:nonumber|notag)(?-u:\b)").unwrap());
static CONTROL_WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\[A-Za-z@]+").unwrap());

const AHEAD: usize = 20_000;

fn display(group: &Group) -> bool {
    matches!(group.end, End::Dollars | End::Bracket)
        || environment(group).is_some_and(|name| CATALOG.preview_environments.contains(name))
}

fn inline(group: &Group) -> bool {
    matches!(group.end, End::Dollar | End::Parenthesis)
}

fn environment(group: &Group) -> Option<&str> {
    let name = group.environment()?;
    Some(name.strip_suffix('*').unwrap_or(name))
}

struct Close {
    open: Option<usize>,
    at: usize,
    found: Option<(Group, Range<usize>)>,
}

impl Visit for Close {
    fn closed(&mut self, group: &Group, close: Range<usize>) {
        let wanted = match self.open {
            Some(open) => group.open == open,
            None => close.end == self.at && display(group),
        };
        if wanted && self.found.is_none() {
            self.found = Some((group.clone(), close));
        }
    }
}

impl SourceDocument {
    pub(crate) fn math_at(&mut self, caret: u32) -> Option<MathPreview> {
        let (units, caret) = (&self.text.units, caret.min(self.text.len()) as usize);
        let ahead = (caret + AHEAD).min(units.len());
        let mut scanner = self.scans.resume(&self.text, caret, ahead).scanner;
        let mut close = Close {
            open: None,
            at: caret,
            found: None,
        };
        scanner.run(units, caret, &[], &mut close);
        let open = scanner.groups().filter(|g| display(g)).last();
        let open = open.or_else(|| scanner.groups().find(|g| inline(g)));
        if let Some(open) = open.map(|g| g.open) {
            close = Close {
                open: Some(open),
                at: caret,
                found: None,
            };
            while close.found.is_none() && scanner.i < ahead {
                scanner.run(units, (scanner.i + 1024).min(ahead), &[], &mut close);
            }
        }
        let (group, close) = close.found?;
        let body = match group.delimiter() {
            Some(width) => group.open + width,
            None => environment_name(units, group.open + "\\begin".len())?.1,
        };
        let tex = preview_tex(
            environment(&group),
            &String::from_utf16_lossy(&units[body..close.start]),
        );
        (!tex.is_empty()).then(|| MathPreview {
            start: group.open as u32,
            tex: self.with_definitions(tex),
            display: display(&group),
        })
    }

    fn with_definitions(&self, tex: String) -> String {
        fn words(tex: &str) -> impl Iterator<Item = &str> {
            CONTROL_WORD.find_iter(tex).map(|word| word.as_str())
        }
        let mut wanted: Vec<&str> = words(&tex).collect();
        let (mut seen, mut definitions) = (HashSet::new(), String::new());
        while let Some(name) = wanted.pop() {
            if !seen.insert(name) {
                continue;
            }
            let command = self.symbols.commands.iter().find(|c| c.name == name);
            if let Some(definition) = command.and_then(|c| c.tex.as_deref()) {
                wanted.extend(words(definition));
                definitions.push_str(definition);
            }
        }
        definitions + &tex
    }
}

fn preview_tex(environment: Option<&str>, body: &str) -> String {
    let body = LABELS.replace_all(body, "");
    let body = NUMBERING.replace_all(&body, "");
    let clean = body.trim();
    let environment = match environment {
        None | Some("equation" | "multline") => return clean.to_string(),
        Some("cases") => "cases",
        Some("gather") => "gathered",
        Some(_) => "aligned",
    };
    format!("\\begin{{{environment}}}{clean}\\end{{{environment}}}")
}
