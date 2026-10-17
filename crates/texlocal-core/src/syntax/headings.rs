//! The class a main file names, and how the class sets its headings, as its
//! class file does (TeX Live's base, amscls, koma-script, memoir, IEEEtran
//! and llncs): the levels it has, how it numbers them, and each one's size
//! against the text's, its weight and its shape. A class it doesn't know has
//! every level, set as the standard classes set them, and numbers them as a
//! book's once the document has chapters.

use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use super::catalog::CATALOG;

/// The class a main file's `\documentclass` names, and the type size its
/// options set.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentClass {
    pub name: String,
    /// 10, 11 or 12 (points): LaTeX's size options.
    pub point_size: u32,
}

static CLASS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\documentclass\s*(?:\[([^\]]*)\])?\s*\{\s*([^}\s]+)\s*\}").unwrap()
});

/// A line of TeX without its comment, which starts at the first % that no
/// backslash escapes (`\%` is a percent sign, `\\%` a line break and a comment).
pub(crate) fn uncommented(line: &str) -> &str {
    let mut escaped = false;
    for (i, c) in line.char_indices() {
        match c {
            '%' if !escaped => return &line[..i],
            '\\' => escaped = !escaped,
            _ => escaped = false,
        }
    }
    line
}

/// The class named outside comments, if any. LaTeX takes it in the
/// preamble, so the text up to the first `\begin{document}` after a class
/// is named is read first, and the whole only when that has none.
pub fn document_class(text: &str) -> Option<DocumentClass> {
    let named = |text: &str| {
        // A comment ends at any line break; to CLASS, every break is a space.
        let lines = text.split(['\n', '\r', '\u{85}', '\u{2028}', '\u{2029}']);
        let code = lines.map(uncommented).collect::<Vec<_>>().join("\n");
        let c = CLASS.captures(&code)?;
        // KOMA-Script's fontsize=11pt as well as the standard 11pt.
        let options = c.get(1).map_or("", |o| o.as_str()).replace("fontsize=", "");
        let sizes: Vec<&str> = options.split(',').map(str::trim).collect();
        let set = |size: &u32| sizes.contains(&format!("{size}pt").as_str());
        let point_size = [11, 12].into_iter().find(set).unwrap_or(10);
        let name = c[2].to_owned();
        Some(DocumentClass { name, point_size })
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

/// How a class sets a level: bold at one of `points`' sizes, bold at a size
/// of its own (amsbook's \@xxpt and \@xivpt, whatever the size option), or
/// at the text's size in a shape.
#[derive(Clone, Copy)]
enum Look {
    Bold(usize),
    Points(f64),
    Plain(Shape),
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

const NORMAL: Option<Look> = Some(Look::Bold(0));
const LARGE_: Option<Look> = Some(Look::Bold(1));
const LARGE: Option<Look> = Some(Look::Bold(2));
const HUGE_: Option<Look> = Some(Look::Bold(4));
const HUGE: Option<Look> = Some(Look::Bold(5));
const UPRIGHT: Option<Look> = Some(Look::Plain(Shape::Upright));
const ITALIC: Option<Look> = Some(Look::Plain(Shape::Italic));
const SMALL_CAPS: Option<Look> = Some(Look::Plain(Shape::SmallCaps));

/// The levels a class has, Normal Text first, as it sets and numbers them;
/// `class` none for a document without one.
pub fn heading_styles(class: Option<&DocumentClass>, has_chapters: bool) -> Vec<Level> {
    // The standard classes' (article.cls, book.cls), part to paragraph:
    // every level bold, and so memoir's. None for a level the class hasn't.
    let [part, chapter, s, ss, sss, paragraph] = [HUGE, HUGE, LARGE, LARGE_, NORMAL, NORMAL];
    let (name, mut unknown) = (class.map_or("", |c| &c.name), false);
    let looks = match name {
        "article" | "proc" => [HUGE_, None, s, ss, sss, paragraph],
        "report" | "book" | "memoir" => [part, chapter, s, ss, sss, paragraph],
        "amsart" | "amsproc" => [NORMAL, None, SMALL_CAPS, NORMAL, ITALIC, UPRIGHT],
        "amsbook" => {
            let [part, chapter] = [20.74, 14.4].map(|p| Some(Look::Points(p)));
            [part, chapter, NORMAL, NORMAL, ITALIC, UPRIGHT]
        }
        "scrartcl" => [part, None, s, ss, sss, paragraph],
        // headings=big, KOMA-Script's default.
        "scrreprt" | "scrbook" => [part, HUGE_, s, ss, sss, paragraph],
        "IEEEtran" => [None, None, SMALL_CAPS, ITALIC, ITALIC, ITALIC],
        "llncs" => [part, None, LARGE_, NORMAL, sss, ITALIC],
        // Frames print no section headings: only the part page has a number;
        // beamer.cls defines neither \chapter nor \paragraph.
        "beamer" => [part, None, s, ss, sss, None],
        "letter" | "minimal" => [None; 6],
        _ => {
            unknown = true;
            [part, chapter, s, ss, sss, paragraph]
        }
    };
    // Whether it has chapters, how deep its headings are numbered, and
    // whether its numbers are IEEEtran's Roman and letters.
    let chapters = looks[1].is_some() && (has_chapters || !unknown);
    let numbered = match name {
        "IEEEtran" => 4,
        "amsbook" => 3,
        "llncs" => 2,
        "beamer" => 0,
        _ => 3 - chapters as i64,
    };
    let sizes = points(class.map_or(10, |c| c.point_size));
    let font = |look| {
        let (scale, bold, shape) = match look {
            Look::Bold(size) => (sizes[size] / sizes[0], true, Shape::Upright),
            Look::Points(points) => (points / sizes[0], true, Shape::Upright),
            Look::Plain(shape) => (1.0, false, shape),
        };
        Font { scale, bold, shape }
    };
    // LaTeX's depths: part -1, chapter 0, section 1; Normal Text has none.
    let marker = |depth: i64| match depth {
        -2 => None,
        -1 => Some("I".to_owned()),
        _ if depth > numbered => None,
        _ if name == "IEEEtran" => Some(["I", "A", "1", "a"][depth as usize - 1].to_owned()),
        0 => chapters.then(|| "1".to_owned()),
        _ => Some(vec!["1"; (depth + chapters as i64) as usize].join(".")),
    };
    let headings = CATALOG.heading_levels.iter();
    let levels = headings.map(|l| (l.title.as_str(), &*l.command));
    let all = std::iter::once(("Normal Text", "")).chain(levels);
    let all = all.zip(std::iter::once(UPRIGHT).chain(looks)).enumerate();
    let level = |(index, ((title, command), look)): (usize, ((&str, &str), Option<Look>))| {
        Some(Level {
            title: title.to_owned(),
            command: command.to_owned(),
            font: font(look?),
            marker: marker(index as i64 - 2),
        })
    };
    all.filter_map(level).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn styles(name: &str, point_size: u32, chapters: bool) -> Vec<Level> {
        let name = name.to_owned();
        let class = DocumentClass { name, point_size };
        heading_styles(Some(&class).filter(|c| !c.name.is_empty()), chapters)
    }

    #[test]
    fn the_class_has_its_levels_and_numbers_them() {
        // A class, whether the document has chapters, and its levels'
        // commands and markers, "-" for none.
        for case in [
            "article: text -, part I, section 1, subsection 1.1, subsubsection 1.1.1, paragraph -",
            "report: text -, part I, chapter 1, section 1.1, subsection 1.1.1, subsubsection -, paragraph -",
            "IEEEtran: text -, section I, subsection A, subsubsection 1, paragraph a",
            "letter: text -",
            "beamer: text -, part I, section -, subsection -, subsubsection -",
            "amsbook: text -, part I, chapter 1, section 1.1, subsection 1.1.1, subsubsection 1.1.1.1, paragraph -",
            // A class it doesn't know has every level, numbered as a book's once
            // there are chapters.
            "thesis chapters: text -, part I, chapter 1, section 1.1, subsection 1.1.1, subsubsection -, paragraph -",
            ": text -, part I, chapter -, section 1, subsection 1.1, subsubsection 1.1.1, paragraph -",
        ] {
            let (class, expected) = case.split_once(": ").unwrap();
            let name = class.trim_end_matches(" chapters");
            let level = |l: &Level| {
                let c = &l.command;
                let command = if c.is_empty() { "text" } else { c };
                format!("{command} {}", l.marker.as_deref().unwrap_or("-"))
            };
            let levels: Vec<_> = styles(name, 10, name != class).iter().map(level).collect();
            assert_eq!(levels.join(", "), expected);
        }
    }

    #[test]
    fn the_class_sets_the_levels_sizes() {
        // A class, its size option and a level's command, and how it sets the level.
        for case in [
            "book 10 part: 2.488 true Upright",
            "book 10: 1.000 false Upright",
            "article 10 part: 2.074 true Upright",
            "article 12 section: 1.440 true Upright",
            "amsart 10 section: 1.000 false SmallCaps",
            "amsbook 12 chapter: 1.200 true Upright",
        ] {
            let (class, expected) = case.split_once(": ").unwrap();
            let mut class = class.split(' ');
            let name = class.next().unwrap();
            let size = class.next().unwrap().parse().unwrap();
            let command = class.next().unwrap_or("");
            let levels = styles(name, size, false);
            let f = levels.iter().find(|l| l.command == command).unwrap().font;
            assert_eq!(format!("{:.3} {} {:?}", f.scale, f.bold, f.shape), expected);
        }
    }

    #[test]
    fn the_class_is_the_one_named_outside_comments() {
        for case in [
            "% \\documentclass{book}\n\\documentclass[a4paper, 12pt]{ article } => article 12",
            "\\documentclass[fontsize=11pt]{scrartcl} => scrartcl 11",
            "50\\% \\documentclass{memoir} => memoir 10",
            "no class => none",
            // The preamble's first: a class named in the body doesn't count.
            "\\documentclass{report}\n\\begin{document}\n\\documentclass{book} => report 10",
            // A comment ends at any line break.
            "% x\r\\documentclass{book} => book 10",
        ] {
            let (text, class) = case.split_once(" => ").unwrap();
            let found = document_class(text).map(|c| format!("{} {}", c.name, c.point_size));
            assert_eq!(found.as_deref().unwrap_or("none"), class, "{text}");
        }
    }
}
