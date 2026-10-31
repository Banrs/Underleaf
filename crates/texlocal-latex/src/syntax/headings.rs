use std::sync::LazyLock;

use regex::Regex;
use schemars::JsonSchema;
use serde::Serialize;

use super::SourceDocument;
use super::scan::{self, Scanner, Visit, braced};
use super::scans::SPACING;

impl SourceDocument {
    pub fn document_class(&self) -> Option<String> {
        struct First(Option<usize>);
        impl Visit for First {
            fn command(&mut self, name: &str, _: usize, name_end: usize) {
                if name == "documentclass" {
                    self.0 = self.0.or(Some(name_end));
                }
            }
        }
        let units = &self.text.units;
        let (mut scanner, mut first) = (Scanner::default(), First(None));
        while first.0.is_none() && scanner.i < units.len() {
            scanner.run(units, scanner.i + SPACING, &[], &mut first);
        }
        let (class, _) = braced(units, first.0?).0?;
        Some(class.trim().to_owned())
    }
}

pub(crate) const LEVELS: [(&str, &str); 6] = [
    ("part", "Part"),
    ("chapter", "Chapter"),
    ("section", "Section"),
    ("subsection", "Subsection"),
    ("subsubsection", "Subsubsection"),
    ("paragraph", "Paragraph"),
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, JsonSchema)]
pub(crate) struct HeadingStyle {
    pub(crate) title: &'static str,
    pub(crate) command: &'static str,
}

pub(crate) fn heading_styles(class: Option<&str>) -> Vec<HeadingStyle> {
    let allowed = |command: &&str| match class {
        Some("letter" | "minimal") => false,
        Some("IEEEtran") => !matches!(*command, "part" | "chapter"),
        Some("beamer") => !matches!(*command, "chapter" | "paragraph"),
        Some("article" | "proc" | "amsart" | "amsproc" | "scrartcl" | "llncs") => {
            *command != "chapter"
        }
        _ => true,
    };
    let levels = LEVELS
        .iter()
        .filter(|(command, _)| allowed(command))
        .map(|&(command, title)| HeadingStyle { title, command });
    std::iter::once(HeadingStyle {
        title: "Normal Text",
        command: "",
    })
    .chain(levels)
    .collect()
}

static TITLE_DROP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:texorpdfstring|label|index|footnote|begin|end)\s*\{").unwrap()
});
static TITLE_STYLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:emph|text(?:bf|it|sl|sc|tt|sf|rm|up|md|normal)|underline|em|bf|it|sl|sc|tt|sf|rm|normalfont|(?:bf|md)series|(?:it|sl|sc|up)shape|(?:rm|sf|tt)family)(?-u:\b)\s*").unwrap()
});
static TITLE_BRACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\([{}&%$#_])|[{}]").unwrap());
pub(crate) static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());

pub(crate) fn plain_title(title: &str) -> Option<String> {
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
