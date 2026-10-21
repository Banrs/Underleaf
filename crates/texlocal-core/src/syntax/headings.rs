//! The class a main file names, and how it sets its headings (TeX Live's base, amscls, koma-script, memoir, IEEEtran,
//! llncs): levels, numbering, size, weight and shape. An unknown class has every level, set as the standard classes do.

use serde::Serialize;

use super::SourceDocument;
use super::scan::{Scanner, Visit, arguments};
use super::scans::SPACING;
use Shape::{Italic, SmallCaps, Upright};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentClass {
    pub name: String,
    pub point_size: u32,
}

impl SourceDocument {
    pub fn document_class(&self) -> Option<DocumentClass> {
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
        // The class comes before the document, which isn't read for it.
        while first.0.is_none() && scanner.i < units.len() {
            scanner.run(units, scanner.i + SPACING, &[], &mut first);
        }
        class_at(units, first.0?)
    }
}

/// The class a \documentclass names, read from the end of its name.
pub(crate) fn class_at(units: &[u16], name_end: usize) -> Option<DocumentClass> {
    let (mut options, mut name) = (Vec::new(), Vec::new());
    let (_, closed) = arguments(units, name_end, |piece, braced| {
        (if braced { &mut name } else { &mut options }).extend_from_slice(&units[piece]);
    });
    let size = |option: &str| match option.trim().trim_start_matches("fontsize=") {
        "11pt" => Some(11),
        "12pt" => Some(12),
        _ => None,
    };
    closed.then(|| DocumentClass {
        name: String::from_utf16_lossy(&name).trim().to_owned(),
        point_size: String::from_utf16_lossy(&options)
            .split(',')
            .find_map(size)
            .unwrap_or(10),
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Shape {
    Upright,
    Italic,
    SmallCaps,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Font {
    pub scale: f64,
    pub bold: bool,
    pub shape: Shape,
}

pub(crate) const LEVELS: [(&str, &str); 6] = [
    ("part", "Part"),
    ("chapter", "Chapter"),
    ("section", "Section"),
    ("subsection", "Subsection"),
    ("subsubsection", "Subsubsection"),
    ("paragraph", "Paragraph"),
];

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Level {
    pub title: &'static str,
    pub command: &'static str,
    pub font: Font,
    pub marker: Option<String>,
}

#[derive(Clone, Copy)]
enum Size {
    Step(usize),
    Points(f64),
}

type Look = Option<(Size, bool, Shape)>;

/// A class's look for each of `LEVELS`, none where it has no such level.
type Looks = [Look; 6];

/// Steps of the class's sizes: \normalsize, \large, \Large, \huge and \Huge.
const NORMAL: usize = 0;
const LARGE_: usize = 1;
const LARGE: usize = 2;
const HUGE_: usize = 4;
const HUGE: usize = 5;

const NO: Look = None;

const fn b(step: usize) -> Look {
    Some((Size::Step(step), true, Upright))
}

const fn p(shape: Shape) -> Look {
    Some((Size::Step(NORMAL), false, shape))
}

/// \@xxpt and \@xivpt, whatever the size option.
const fn pt(points: f64) -> Look {
    Some((Size::Points(points), true, Upright))
}

const BOOK: Looks = [b(HUGE), b(HUGE), b(LARGE), b(LARGE_), b(NORMAL), b(NORMAL)];
const ARTICLE: Looks = [b(HUGE_), NO, b(LARGE), b(LARGE_), b(NORMAL), b(NORMAL)];
const AMS_ARTICLE: Looks = [
    b(NORMAL),
    NO,
    p(SmallCaps),
    b(NORMAL),
    p(Italic),
    p(Upright),
];
const AMS_BOOK: Looks = [
    pt(20.74),
    pt(14.4),
    b(NORMAL),
    b(NORMAL),
    p(Italic),
    p(Upright),
];
const KOMA_ARTICLE: Looks = [b(HUGE), NO, b(LARGE), b(LARGE_), b(NORMAL), b(NORMAL)];
/// headings=big, KOMA-Script's default.
const KOMA_BOOK: Looks = [b(HUGE), b(HUGE_), b(LARGE), b(LARGE_), b(NORMAL), b(NORMAL)];
const IEEE: Looks = [NO, NO, p(SmallCaps), p(Italic), p(Italic), p(Italic)];
const LLNCS: Looks = [b(HUGE), NO, b(LARGE_), b(NORMAL), b(NORMAL), p(Italic)];
/// beamer.cls defines neither \chapter nor \paragraph.
const BEAMER: Looks = [b(HUGE), NO, b(LARGE), b(LARGE_), b(NORMAL), NO];

/// A class's looks, how deep it numbers its levels, and whether it has chapters.
fn known(name: &str) -> Option<(&'static Looks, i64, bool)> {
    Some(match name {
        "article" | "proc" => (&ARTICLE, 3, false),
        "report" | "book" | "memoir" => (&BOOK, 2, true),
        "amsart" | "amsproc" => (&AMS_ARTICLE, 3, false),
        "amsbook" => (&AMS_BOOK, 3, true),
        "scrartcl" => (&KOMA_ARTICLE, 3, false),
        "scrreprt" | "scrbook" => (&KOMA_BOOK, 2, true),
        "IEEEtran" => (&IEEE, 4, false),
        "llncs" => (&LLNCS, 2, false),
        // Frames print no section headings: only the part page has a number.
        "beamer" => (&BEAMER, 0, false),
        "letter" | "minimal" => (&[NO; 6], 0, false),
        _ => return None,
    })
}

fn points(size: u32) -> [f64; 6] {
    match size {
        11 => [10.95, 12.0, 14.4, 17.28, 20.74, 24.88],
        12 => [12.0, 14.4, 17.28, 20.74, 24.88, 24.88],
        _ => [10.0, 12.0, 14.4, 17.28, 20.74, 24.88],
    }
}

pub fn heading_styles(class: Option<&DocumentClass>, has_chapters: bool) -> Vec<Level> {
    let sizes = points(class.map_or(10, |c| c.point_size));
    // IEEEtran numbers its levels I, A, 1, a.
    let roman = class.is_some_and(|c| c.name == "IEEEtran");
    let (looks, numbered, chapters) = class.and_then(|c| known(&c.name)).unwrap_or((
        &BOOK,
        if has_chapters { 2 } else { 3 },
        has_chapters,
    ));
    let marker = |index: usize| {
        let depth = index as i64 - 1;
        if depth < 0 {
            return Some("I".to_owned());
        }
        if depth > numbered {
            return None;
        }
        if roman {
            return Some(["I", "A", "1", "a"][depth as usize - 1].to_owned());
        }
        if depth == 0 {
            return chapters.then(|| "1".to_owned());
        }
        Some(vec!["1"; (depth + chapters as i64) as usize].join("."))
    };
    let normal = Level {
        title: "Normal Text",
        command: "",
        font: Font {
            scale: 1.0,
            bold: false,
            shape: Upright,
        },
        marker: None,
    };
    let levels = LEVELS.iter().zip(looks).enumerate();
    let levels = levels.filter_map(|(index, (&(command, title), look))| {
        let (size, bold, shape) = (*look)?;
        let points = match size {
            Size::Step(step) => sizes[step],
            Size::Points(points) => points,
        };
        Some(Level {
            title,
            command,
            font: Font {
                scale: points / sizes[NORMAL],
                bold,
                shape,
            },
            marker: marker(index),
        })
    });
    std::iter::once(normal).chain(levels).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn styles(name: Option<&str>, size: u32, chapters: bool) -> Vec<Level> {
        let class = name.map(|name| DocumentClass {
            name: name.to_owned(),
            point_size: size,
        });
        heading_styles(class.as_ref(), chapters)
    }

    fn titles(levels: &[Level]) -> String {
        let titles: Vec<&str> = levels.iter().map(|l| l.title).collect();
        titles.join(", ")
    }

    fn markers(levels: &[Level]) -> String {
        let markers = levels.iter().map(|l| l.marker.as_deref().unwrap_or("-"));
        markers.collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn the_class_has_its_levels_and_numbers_them() {
        let article = styles(Some("article"), 10, false);
        let titled = "Normal Text, Part, Section, Subsection, Subsubsection, Paragraph";
        assert_eq!(titles(&article), titled);
        assert_eq!(markers(&article), "- I 1 1.1 1.1.1 -");
        let report = "- I 1 1.1 1.1.1 - -";
        assert_eq!(markers(&styles(Some("report"), 10, false)), report);
        let ieee = styles(Some("IEEEtran"), 10, false);
        assert_eq!(markers(&ieee), "- I A 1 a");
        let titled = "Normal Text, Section, Subsection, Subsubsection, Paragraph";
        assert_eq!(titles(&ieee), titled);
        assert_eq!(titles(&styles(Some("letter"), 10, false)), "Normal Text");
        let beamer = styles(Some("beamer"), 10, false);
        let titled = "Normal Text, Part, Section, Subsection, Subsubsection";
        assert_eq!(titles(&beamer), titled);
        assert_eq!(markers(&beamer), "- I - - -");
        assert_eq!(markers(&styles(Some("thesis"), 10, true)), report);
        let none = "- I - 1 1.1 1.1.1 -";
        assert_eq!(markers(&styles(None, 10, false)), none);
    }

    #[test]
    fn the_class_sets_the_levels_sizes() {
        let font = |levels: &[Level], command: &str| {
            let font = levels.iter().find(|l| l.command == command).unwrap().font;
            (font.scale, font.bold, font.shape)
        };
        let book = styles(Some("book"), 10, false);
        assert_eq!(font(&book, "part"), (2.488, true, Shape::Upright));
        assert!((font(&styles(Some("article"), 10, false), "part").0 - 2.074).abs() < 0.001);
        assert!((font(&styles(Some("article"), 12, false), "section").0 - 1.44).abs() < 0.001);
        assert_eq!(font(&book, ""), (1.0, false, Shape::Upright));
        let amsart = styles(Some("amsart"), 10, false);
        assert_eq!(font(&amsart, "section"), (1.0, false, Shape::SmallCaps));
    }

    #[test]
    fn the_class_is_the_one_named_outside_comments() {
        let class = |text: &str| {
            let class = SourceDocument::new(text).document_class();
            class.map_or(String::new(), |c| format!("{} {}pt", c.name, c.point_size))
        };
        assert_eq!(
            class("% \\documentclass{book}\n\\documentclass[a4paper, 12pt]{ article }"),
            "article 12pt"
        );
        assert_eq!(
            class("\\documentclass[fontsize=11pt]{scrartcl}"),
            "scrartcl 11pt"
        );
        assert_eq!(class("50\\% \\documentclass{memoir}"), "memoir 10pt");
        assert_eq!(class("no class"), "");
        // The preamble's first: a class named in the body doesn't count.
        let body = "\\documentclass{report}\n\\begin{document}\n\\documentclass{book}";
        assert_eq!(class(body), "report 10pt");
    }
}
