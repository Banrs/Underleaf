use schemars::JsonSchema;
use serde::Serialize;

use super::SourceDocument;
use super::scan::{Scanner, Visit, braced};
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
