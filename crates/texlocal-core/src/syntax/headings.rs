//! The class a main file names, and how the class sets its headings, as its
//! class file does (TeX Live's base, amscls, koma-script, memoir, IEEEtran
//! and llncs): the levels it has, how it numbers them, and each one's size
//! against the text's, its weight and its shape. A class it doesn't know has
//! every level, set as the standard classes set them, and numbers them as a
//! book's once the document has chapters.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use super::catalog::{CATALOG, HeadingLevel};

/// The class a main file's `\documentclass` names, and the type size its
/// options set.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentClass {
    pub name: String,
    /// 10, 11 or 12 (points): LaTeX's size options.
    pub point_size: u32,
}

/// A comment, from a % that isn't escaped to the line's end, however the line ends.
static COMMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new("(?m)(^|[^\\\\])%[^\n\r\u{85}\u{2028}\u{2029}]*").unwrap());
static CLASS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\documentclass\s*(?:\[([^\]]*)\])?\s*\{\s*([^}\s]+)\s*\}").unwrap()
});

/// The class named outside comments, if any. LaTeX takes it in the
/// preamble, so the text up to the first `\begin{document}` after a class
/// is named is read first, and the whole only when that has none.
pub fn document_class(text: &str) -> Option<DocumentClass> {
    let named = |text: &str| {
        let uncommented = COMMENT.replace_all(text, "$1");
        let c = CLASS.captures(&uncommented)?;
        let options: Vec<&str> = c
            .get(1)
            .map_or(vec![], |o| o.as_str().split(',').map(str::trim).collect());
        // KOMA-Script's fontsize=11pt as well as the standard 11pt.
        let point_size = [11, 12]
            .into_iter()
            .find(|size| {
                let (standard, koma) = (format!("{size}pt"), format!("fontsize={size}pt"));
                options.iter().any(|&o| o == standard || o == koma)
            })
            .unwrap_or(10);
        Some(DocumentClass {
            name: c[2].to_owned(),
            point_size,
        })
    };
    let preamble = text.find("\\documentclass").and_then(|at| {
        let after = at + "\\documentclass".len();
        let begin = text[after..].find("\\begin{document}")?;
        Some(&text[..after + begin + "\\begin{document}".len()])
    });
    preamble.and_then(named).or_else(|| named(text))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Shape {
    Upright,
    Italic,
    SmallCaps,
}

/// A level's look: its size as a multiple of the text's, bold or not, and its shape.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Font {
    pub scale: f64,
    pub bold: bool,
    pub shape: Shape,
}

/// A level the class has, as its headings are set; Normal Text first,
/// whose `command` is empty.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Level {
    pub title: String,
    pub command: String,
    pub font: Font,
    /// Its number as its heading prints it, with the class's counters.
    pub marker: Option<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum Family {
    Article,
    Book,
    AmsArticle,
    AmsBook,
    KomaArticle,
    KomaBook,
    Ieee,
    Llncs,
    Beamer,
    Unsectioned,
}

fn family(class: &str) -> Option<Family> {
    use Family::*;
    Some(match class {
        "article" | "proc" => Article,
        "report" | "book" | "memoir" => Book,
        "amsart" | "amsproc" => AmsArticle,
        "amsbook" => AmsBook,
        "scrartcl" => KomaArticle,
        "scrreprt" | "scrbook" => KomaBook,
        "IEEEtran" => Ieee,
        "llncs" => Llncs,
        "beamer" => Beamer,
        "letter" | "minimal" => Unsectioned,
        _ => return None,
    })
}

/// size10.clo, size11.clo and size12.clo, in points: \normalsize, \large,
/// \Large, \LARGE, \huge and \Huge.
fn points(size: u32) -> [f64; 6] {
    match size {
        11 => [10.95, 12.0, 14.4, 17.28, 20.74, 24.88],
        12 => [12.0, 14.4, 17.28, 20.74, 24.88, 24.88],
        _ => [10.0, 12.0, 14.4, 17.28, 20.74, 24.88],
    }
}

const NORMAL: usize = 0;
const LARGE_: usize = 1;
const LARGE: usize = 2;
const HUGE_: usize = 4;
const HUGE: usize = 5;

/// The levels a class has, Normal Text first, as it sets and numbers them;
/// `class` none for a document without one.
pub fn heading_styles(class: Option<&DocumentClass>, has_chapters: bool) -> Vec<Level> {
    use Family::*;
    let family = class.and_then(|c| family(&c.name));
    let sizes = points(class.map_or(10, |c| c.point_size));
    let bold = |size: usize| Font {
        scale: sizes[size] / sizes[0],
        bold: true,
        shape: Shape::Upright,
    };
    let plain = |shape| Font {
        scale: 1.0,
        bold: false,
        shape,
    };
    // The standard classes' (article.cls, book.cls): every level bold, and so memoir's.
    let mut fonts: HashMap<&str, Font> = HashMap::from([
        ("part", bold(HUGE)),
        ("chapter", bold(HUGE)),
        ("section", bold(LARGE)),
        ("subsection", bold(LARGE_)),
        ("subsubsection", bold(NORMAL)),
        ("paragraph", bold(NORMAL)),
    ]);
    let sections = &CATALOG.heading_levels;
    let mut commands: Vec<&str> = sections.iter().map(|l| l.command.as_str()).collect();
    let (numbered, chapters, roman) = match family {
        Some(Article | KomaArticle | AmsArticle) => (3, false, false),
        Some(Book | KomaBook) => (2, true, false),
        Some(AmsBook) => (3, true, false),
        Some(Ieee) => (4, false, true),
        Some(Llncs) => (2, false, false),
        // Frames print no section headings: only the part page has a number.
        Some(Beamer) => (0, false, false),
        Some(Unsectioned) => (0, false, false),
        None => (if has_chapters { 2 } else { 3 }, has_chapters, false),
    };
    let without = |commands: &mut Vec<&str>, gone: &[&str]| commands.retain(|c| !gone.contains(c));
    match family {
        Some(Article) => {
            fonts.insert("part", bold(HUGE_));
            without(&mut commands, &["chapter"]);
        }
        Some(AmsArticle) => {
            fonts = HashMap::from([
                ("part", bold(NORMAL)),
                ("section", plain(Shape::SmallCaps)),
                ("subsection", bold(NORMAL)),
                ("subsubsection", plain(Shape::Italic)),
                ("paragraph", plain(Shape::Upright)),
            ]);
            without(&mut commands, &["chapter"]);
        }
        Some(AmsBook) => {
            // \@xxpt and \@xivpt, whatever the size option.
            let fixed = |points: f64| Font {
                scale: points / sizes[0],
                bold: true,
                shape: Shape::Upright,
            };
            fonts = HashMap::from([
                ("part", fixed(20.74)),
                ("chapter", fixed(14.4)),
                ("section", bold(NORMAL)),
                ("subsection", bold(NORMAL)),
                ("subsubsection", plain(Shape::Italic)),
                ("paragraph", plain(Shape::Upright)),
            ]);
        }
        Some(KomaArticle) => without(&mut commands, &["chapter"]),
        // headings=big, KOMA-Script's default.
        Some(KomaBook) => {
            fonts.insert("chapter", bold(HUGE_));
        }
        Some(Ieee) => {
            fonts = HashMap::from([
                ("section", plain(Shape::SmallCaps)),
                ("subsection", plain(Shape::Italic)),
                ("subsubsection", plain(Shape::Italic)),
                ("paragraph", plain(Shape::Italic)),
            ]);
            without(&mut commands, &["part", "chapter"]);
        }
        Some(Llncs) => {
            fonts.insert("section", bold(LARGE_));
            fonts.insert("subsection", bold(NORMAL));
            fonts.insert("paragraph", plain(Shape::Italic));
            without(&mut commands, &["chapter"]);
        }
        // beamer.cls defines neither \chapter nor \paragraph.
        Some(Beamer) => without(&mut commands, &["chapter", "paragraph"]),
        Some(Unsectioned) => commands.clear(),
        Some(Book) | None => {}
    }
    let marker = |index: usize| {
        // LaTeX's depths: part -1, chapter 0, section 1.
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
        title: "Normal Text".to_owned(),
        command: String::new(),
        font: plain(Shape::Upright),
        marker: None,
    };
    let levels = sections
        .iter()
        .enumerate()
        .filter(|(_, l)| commands.contains(&l.command.as_str()))
        .map(|(index, HeadingLevel { title, command })| Level {
            title: title.clone(),
            command: command.clone(),
            font: fonts
                .get(command.as_str())
                .copied()
                .unwrap_or(plain(Shape::Upright)),
            marker: marker(index),
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

    fn titles(levels: &[Level]) -> Vec<&str> {
        levels.iter().map(|l| l.title.as_str()).collect()
    }

    fn markers(levels: &[Level]) -> Vec<Option<&str>> {
        levels.iter().map(|l| l.marker.as_deref()).collect()
    }

    #[test]
    fn the_class_has_its_levels_and_numbers_them() {
        let article = styles(Some("article"), 10, false);
        assert_eq!(
            titles(&article),
            [
                "Normal Text",
                "Part",
                "Section",
                "Subsection",
                "Subsubsection",
                "Paragraph"
            ]
        );
        let numbers = [None, Some("I"), Some("1"), Some("1.1"), Some("1.1.1"), None];
        assert_eq!(markers(&article), numbers);
        let report = [
            None,
            Some("I"),
            Some("1"),
            Some("1.1"),
            Some("1.1.1"),
            None,
            None,
        ];
        assert_eq!(markers(&styles(Some("report"), 10, false)), report);
        let ieee = styles(Some("IEEEtran"), 10, false);
        assert_eq!(
            markers(&ieee),
            [None, Some("I"), Some("A"), Some("1"), Some("a")]
        );
        assert_eq!(
            titles(&ieee),
            [
                "Normal Text",
                "Section",
                "Subsection",
                "Subsubsection",
                "Paragraph"
            ]
        );
        assert_eq!(titles(&styles(Some("letter"), 10, false)), ["Normal Text"]);
        let beamer = styles(Some("beamer"), 10, false);
        assert_eq!(
            titles(&beamer),
            [
                "Normal Text",
                "Part",
                "Section",
                "Subsection",
                "Subsubsection"
            ]
        );
        assert_eq!(markers(&beamer), [None, Some("I"), None, None, None]);
        // A class it doesn't know has every level, numbered as a book's once there are chapters.
        assert_eq!(markers(&styles(Some("thesis"), 10, true)), report);
        let none = [
            None,
            Some("I"),
            None,
            Some("1"),
            Some("1.1"),
            Some("1.1.1"),
            None,
        ];
        assert_eq!(markers(&styles(None, 10, false)), none);
    }

    #[test]
    fn the_class_sets_the_levels_sizes() {
        let font = |levels: &[Level], command: &str| {
            levels.iter().find(|l| l.command == command).unwrap().font
        };
        let book = styles(Some("book"), 10, false);
        assert_eq!(
            font(&book, "part"),
            Font {
                scale: 2.488,
                bold: true,
                shape: Shape::Upright
            }
        );
        assert!((font(&styles(Some("article"), 10, false), "part").scale - 2.074).abs() < 0.001);
        assert!((font(&styles(Some("article"), 12, false), "section").scale - 1.44).abs() < 0.001);
        assert_eq!(
            font(&book, ""),
            Font {
                scale: 1.0,
                bold: false,
                shape: Shape::Upright
            }
        );
        assert_eq!(
            font(&styles(Some("amsart"), 10, false), "section"),
            Font {
                scale: 1.0,
                bold: false,
                shape: Shape::SmallCaps
            }
        );
    }

    #[test]
    fn the_class_is_the_one_named_outside_comments() {
        let class = |text: &str| document_class(text).map(|c| (c.name, c.point_size));
        assert_eq!(
            class("% \\documentclass{book}\n\\documentclass[a4paper, 12pt]{ article }"),
            Some(("article".into(), 12))
        );
        assert_eq!(
            class("\\documentclass[fontsize=11pt]{scrartcl}"),
            Some(("scrartcl".into(), 11))
        );
        assert_eq!(
            class("50\\% \\documentclass{memoir}"),
            Some(("memoir".into(), 10))
        );
        assert_eq!(class("no class"), None);
        // The preamble's first: a class named in the body doesn't count.
        let body = "\\documentclass{report}\n\\begin{document}\n\\documentclass{book}";
        assert_eq!(class(body), Some(("report".into(), 10)));
        // A comment ends at any line break.
        assert_eq!(
            class("% x\r\\documentclass{book}"),
            Some(("book".into(), 10))
        );
    }
}
