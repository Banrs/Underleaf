use serde::Serialize;

use super::SourceDocument;
use super::scan::{Scanner, Visit, arguments};
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
        class_at(units, first.0?)
    }
}

pub(crate) fn class_at(units: &[u16], name_end: usize) -> Option<String> {
    let mut name = Vec::new();
    let (_, closed) = arguments(units, name_end, |piece, braced| {
        if braced {
            name.extend_from_slice(&units[piece]);
        }
    });
    closed.then(|| String::from_utf16_lossy(&name).trim().to_owned())
}

pub(crate) const LEVELS: [(&str, &str); 6] = [
    ("part", "Part"),
    ("chapter", "Chapter"),
    ("section", "Section"),
    ("subsection", "Subsection"),
    ("subsubsection", "Subsubsection"),
    ("paragraph", "Paragraph"),
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Level {
    pub title: &'static str,
    pub command: &'static str,
}

pub fn heading_styles(class: Option<&str>) -> Vec<Level> {
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
        .map(|&(command, title)| Level { title, command });
    std::iter::once(Level {
        title: "Normal Text",
        command: "",
    })
    .chain(levels)
    .collect()
}
