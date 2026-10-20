//! The class a main file names, and how it sets its headings (TeX Live's base, amscls, koma-script, memoir, IEEEtran,
//! llncs): levels, numbering, size, weight and shape. An unknown class has every level, set as the standard classes do.

use serde::Serialize;

use super::scan::{Scanner, Visit, arguments};
use super::scans::SPACING;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentClass {
    pub name: String,
    pub point_size: u32,
}

pub fn document_class(text: &str) -> Option<DocumentClass> {
    struct First(Option<usize>);
    impl Visit for First {
        fn command(&mut self, name: &str, _: usize, name_end: usize) {
            if name == "documentclass" {
                self.0 = self.0.or(Some(name_end));
            }
        }
    }
    let units: Vec<u16> = text.encode_utf16().collect();
    let (mut scanner, mut first) = (Scanner::default(), First(None));
    // The class comes before the document, which isn't read for it.
    while first.0.is_none() && scanner.i < units.len() {
        scanner.run(&units, scanner.i + SPACING, &[], &mut first);
    }
    let (mut options, mut name) = (Vec::new(), Vec::new());
    let (_, closed) = arguments(&units, first.0?, |piece, braced| {
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

type Look = (&'static str, Size, bool, Shape);

const NORMAL: usize = 0;
const LARGE_: usize = 1;
const LARGE: usize = 2;
const HUGE_: usize = 4;
const HUGE: usize = 5;

const fn bold(command: &'static str, step: usize) -> Look {
    (command, Size::Step(step), true, Shape::Upright)
}

const fn plain(command: &'static str, shape: Shape) -> Look {
    (command, Size::Step(NORMAL), false, shape)
}

const BOOK: &[Look] = &[
    bold("part", HUGE),
    bold("chapter", HUGE),
    bold("section", LARGE),
    bold("subsection", LARGE_),
    bold("subsubsection", NORMAL),
    bold("paragraph", NORMAL),
];
const ARTICLE: &[Look] = &[
    bold("part", HUGE_),
    bold("section", LARGE),
    bold("subsection", LARGE_),
    bold("subsubsection", NORMAL),
    bold("paragraph", NORMAL),
];
const AMS_ARTICLE: &[Look] = &[
    bold("part", NORMAL),
    plain("section", Shape::SmallCaps),
    bold("subsection", NORMAL),
    plain("subsubsection", Shape::Italic),
    plain("paragraph", Shape::Upright),
];
const AMS_BOOK: &[Look] = &[
    // \@xxpt and \@xivpt, whatever the size option.
    ("part", Size::Points(20.74), true, Shape::Upright),
    ("chapter", Size::Points(14.4), true, Shape::Upright),
    bold("section", NORMAL),
    bold("subsection", NORMAL),
    plain("subsubsection", Shape::Italic),
    plain("paragraph", Shape::Upright),
];
const KOMA_ARTICLE: &[Look] = &[
    bold("part", HUGE),
    bold("section", LARGE),
    bold("subsection", LARGE_),
    bold("subsubsection", NORMAL),
    bold("paragraph", NORMAL),
];
/// headings=big, KOMA-Script's default.
const KOMA_BOOK: &[Look] = &[
    bold("part", HUGE),
    bold("chapter", HUGE_),
    bold("section", LARGE),
    bold("subsection", LARGE_),
    bold("subsubsection", NORMAL),
    bold("paragraph", NORMAL),
];
const IEEE: &[Look] = &[
    plain("section", Shape::SmallCaps),
    plain("subsection", Shape::Italic),
    plain("subsubsection", Shape::Italic),
    plain("paragraph", Shape::Italic),
];
const LLNCS: &[Look] = &[
    bold("part", HUGE),
    bold("section", LARGE_),
    bold("subsection", NORMAL),
    bold("subsubsection", NORMAL),
    plain("paragraph", Shape::Italic),
];
/// beamer.cls defines neither \chapter nor \paragraph.
const BEAMER: &[Look] = &[
    bold("part", HUGE),
    bold("section", LARGE),
    bold("subsection", LARGE_),
    bold("subsubsection", NORMAL),
];

struct Class {
    looks: &'static [Look],
    numbered: i64,
    chapters: bool,
    roman: bool,
}

impl Class {
    const fn new(looks: &'static [Look], numbered: i64, chapters: bool) -> Self {
        Self {
            looks,
            numbered,
            chapters,
            roman: false,
        }
    }
}

fn known(name: &str) -> Option<Class> {
    Some(match name {
        "article" | "proc" => Class::new(ARTICLE, 3, false),
        "report" | "book" | "memoir" => Class::new(BOOK, 2, true),
        "amsart" | "amsproc" => Class::new(AMS_ARTICLE, 3, false),
        "amsbook" => Class::new(AMS_BOOK, 3, true),
        "scrartcl" => Class::new(KOMA_ARTICLE, 3, false),
        "scrreprt" | "scrbook" => Class::new(KOMA_BOOK, 2, true),
        "IEEEtran" => Class {
            roman: true,
            ..Class::new(IEEE, 4, false)
        },
        "llncs" => Class::new(LLNCS, 2, false),
        // Frames print no section headings: only the part page has a number.
        "beamer" => Class::new(BEAMER, 0, false),
        "letter" | "minimal" => Class::new(&[], 0, false),
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
    let Class {
        looks,
        numbered,
        chapters,
        roman,
    } = class.and_then(|c| known(&c.name)).unwrap_or(Class::new(
        BOOK,
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
            shape: Shape::Upright,
        },
        marker: None,
    };
    let levels = LEVELS.iter().enumerate();
    let levels = levels.filter_map(|(index, &(command, title))| {
        let &(_, size, bold, shape) = looks.iter().find(|look| look.0 == command)?;
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
            document_class(text).map_or(String::new(), |c| format!("{} {}pt", c.name, c.point_size))
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
