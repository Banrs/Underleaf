//! A document's outline and word count, read from its main file through the
//! files it inputs.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::paths;
use crate::syntax::catalog::{CATALOG, alternation};
use crate::syntax::headings;

static COMMENT_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*%").unwrap());
static COMMENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(^|[^\\])%.*$").unwrap());
// Headings, inputs and their literal boundaries in reading order. Consume other
// control sequences too, so an escaped slash cannot start a command.
static TOKEN: LazyLock<Regex> = LazyLock::new(|| {
    let headings = alternation(CATALOG.heading_levels.iter().map(|level| &level.command));
    let literals = alternation(&CATALOG.verbatim_environments);
    Regex::new(&format!(
        r"%|\\(?:(?P<heading>{headings})\*?\s*(?:\[[^\]]*\])?\s*\{{|(?:input|include|subfile)\s*\{{(?P<braced>[^{{}}%]+)\}}|input\s+(?P<bare>[^{{}}\\%\s]+)|begin\s*\{{(?P<literal>{literals})\}}|verb\*?(?P<delimiter>[^A-Za-z])|[A-Za-z]+|.)"
    ))
    .unwrap()
});
static COMMAND: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\[a-zA-Z]+\*?(?:\[[^\]]*\])?").unwrap());
// What a title drops whole: \texorpdfstring's TeX argument (its PDF string is
// the group after), labels and notes.
static TITLE_DROP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\(?:texorpdfstring|label|index|footnote)\s*\{").unwrap());
// Styles a title shows as plain text: \emph and the like, and font switches.
static TITLE_STYLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:emph|text(?:bf|it|sl|sc|tt|sf|rm|up|md|normal)|underline|em|bf|it|sl|sc|tt|sf|rm|normalfont|(?:bf|md)series|(?:it|sl|sc|up)shape|(?:rm|sf|tt)family)(?-u:\b)\s*").unwrap()
});
// Grouping braces go; an escaped special shows as itself.
static TITLE_BRACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\([{}&%$#_])|[{}]").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
// What separates words: spaces and TeX's special characters.
static WORD_BREAK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\s{}$&_^~\\%]").unwrap());

/// A sectioning command: its depth (0 for \part to 5 for \paragraph),
/// command and level, its title as plain text, its 1-based line and, in a
/// project's analysis, its file. A heading whose title is empty is
/// `untitled`, and titled by its level: "Untitled Section".
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Heading {
    pub depth: usize,
    /// Without its backslash: "section".
    pub command: &'static str,
    /// The level's name: "Section".
    pub level: &'static str,
    pub title: String,
    pub untitled: bool,
    pub line: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

impl Heading {
    fn new(depth: usize, title: Option<String>, line: usize, file: Option<String>) -> Self {
        let level = &CATALOG.heading_levels[depth];
        Heading {
            depth,
            command: &level.command,
            level: &level.title,
            untitled: title.is_none(),
            title: title.unwrap_or_else(|| format!("Untitled {}", level.title)),
            line,
            file,
        }
    }
}

/// A heading with what nests under it. `fold_key` names its fold in the
/// project's saved UI state: file, depth, title and which of that name it is.
#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutlineNode {
    /// Its place in the outline, read in order.
    pub index: usize,
    #[serde(flatten)]
    pub heading: Heading,
    pub fold_key: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<OutlineNode>,
}

/// A session's `analyze` answer: the outline as a tree, the words, and the
/// levels the main file's class has, as it sets and numbers them.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectAnalysis {
    pub tree: Vec<OutlineNode>,
    pub words: usize,
    pub heading_styles: Vec<headings::Level>,
}

impl ProjectAnalysis {
    /// `class`, the main file's; a class it doesn't know numbers its headings
    /// as a book's once the document has chapters.
    pub(crate) fn new(analysis: &Analysis, class: Option<&headings::DocumentClass>) -> Self {
        let chapters = analysis.outline.iter().any(|h| h.command == "chapter");
        ProjectAnalysis {
            tree: outline_tree(&analysis.outline),
            words: analysis.words,
            heading_styles: headings::heading_styles(class, chapters),
        }
    }
}

/// The outline nested by depth. A heading deeper than the one before it goes
/// under it, so a subsection before any section sits flush, not under a
/// missing parent.
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
            // An untitled heading's key is as it was before it had a title,
            // so its saved fold stays.
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
                children,
            });
        }
        nodes
    }
    nest(outline, &mut 0, None, &mut HashMap::new())
}

/// The heading a line of a file is under, as its place in `outline`: the
/// file's last at or above the line. None above the file's first, since where
/// the file is read in isn't known.
pub fn current_heading(outline: &[Heading], file: &str, line: usize) -> Option<usize> {
    outline
        .iter()
        .rposition(|h| h.file.as_deref() == Some(file) && h.line <= line)
}

#[derive(Debug, Default, PartialEq, Serialize)]
pub struct Analysis {
    pub outline: Vec<Heading>,
    pub words: usize,
}

/// The document LaTeX reads from the main file, into the files its \input,
/// \include and \subfile name (each once, so a loop ends): the headings in
/// reading order, each with its file, and the words of them all. `open` is the
/// editor's file: when the main file doesn't reach it, the document is that
/// file alone.
pub fn analyze_project(root: &Path, main: &str, open: &str) -> Analysis {
    let Ok(open) = paths::rel_key(open) else {
        return Analysis::default();
    };
    let key = paths::fold_case(&open);
    let mut analysis = Analysis::default();
    let mut seen = HashSet::new();
    read(root, main, &mut seen, &mut analysis);
    if !seen.contains(&key) {
        analysis = Analysis::default();
        read(root, &open, &mut HashSet::new(), &mut analysis);
    }
    analysis
}

fn read(root: &Path, file: &str, seen: &mut HashSet<String>, into: &mut Analysis) {
    let Ok(file) = paths::rel_key(file) else {
        return;
    };
    if !seen.insert(paths::fold_case(&file)) {
        return;
    }
    let Some(text) = paths::safe_path(root, &file)
        .ok()
        .and_then(|path| fs::read(path).ok())
    else {
        return;
    };
    let text = crate::lossy_string(text);
    let mut literal: Option<String> = None;
    for (index, line) in text.lines().enumerate() {
        if !COMMENT_LINE.is_match(line) {
            into.words += words(line);
        }
        let mut code = line;
        let mut heading_on_line = false;
        loop {
            if let Some(end) = literal.as_ref() {
                let Some((_, rest)) = code.split_once(end.as_str()) else {
                    break;
                };
                code = rest;
                literal = None;
            }
            let Some(m) = TOKEN.captures(code) else {
                break;
            };
            let token = m.get(0).unwrap();
            if token.as_str() == "%" {
                break;
            }
            code = &code[token.end()..];
            if let Some(heading) = m.name("heading") {
                if !heading_on_line {
                    heading_on_line = true;
                    if let Some(title) = brace_group(code) {
                        let depth = CATALOG
                            .heading_levels
                            .iter()
                            .position(|level| level.command == heading.as_str())
                            .expect("a heading level of the catalog");
                        let title = plain_title(title);
                        into.outline.push(Heading::new(
                            depth,
                            title,
                            index + 1,
                            Some(file.clone()),
                        ));
                    }
                }
            } else if let Some(name) = m.name("braced").or_else(|| m.name("bare")) {
                let name = name.as_str().trim();
                let tex = format!("{}.tex", name.strip_suffix(".tex").unwrap_or(name));
                // TeX tries name.tex before the name as written.
                if let Some(input) = [tex, name.to_owned()]
                    .into_iter()
                    .find(|rel| paths::safe_path(root, rel).is_ok_and(|path| path.is_file()))
                {
                    read(root, &input, seen, into);
                }
            } else if let Some(environment) = m.name("literal") {
                literal = Some(format!("\\end{{{}}}", environment.as_str()));
            } else if let Some(delimiter) = m.name("delimiter") {
                let Some((_, rest)) = code.split_once(delimiter.as_str()) else {
                    break;
                };
                code = rest;
            }
        }
    }
}

/// The brace group opened just before `rest`, up to its matching `}`, so a
/// title keeps its nested groups; None when it doesn't close on the line.
fn brace_group(rest: &str) -> Option<&str> {
    let (mut depth, mut escaped) = (0, false);
    for (i, b) in rest.bytes().enumerate() {
        match b {
            _ if escaped => escaped = false,
            b'\\' => escaped = true,
            b'{' => depth += 1,
            b'}' if depth == 0 => return Some(&rest[..i]),
            b'}' => depth -= 1,
            _ => {}
        }
    }
    None
}

/// A title as the outline shows it: styles, labels and grouping braces gone,
/// spaces collapsed; none when nothing is left.
fn plain_title(title: &str) -> Option<String> {
    let mut rest = title;
    let mut title = String::new();
    while let Some(m) = TITLE_DROP.find(rest) {
        title.push_str(&rest[..m.start()]);
        rest = &rest[m.end()..];
        if let Some(group) = brace_group(rest) {
            rest = &rest[group.len() + 1..];
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

/// Rough word count of a line's code: drop commands and TeX's special
/// characters, and count the runs left that contain a letter.
fn words(line: &str) -> usize {
    let code = COMMENT
        .captures(line)
        .map_or(line, |m| &line[..m.get(1).unwrap().end()]);
    WORD_BREAK
        .split(&COMMAND.replace_all(code, " "))
        .filter(|w| w.chars().any(char::is_alphabetic))
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A heading's depth, title ("" for none) and line.
    type Outline<'a> = &'a [(usize, &'a str, usize)];

    /// Headings and words, of one file's text.
    #[test]
    fn a_file_reads_as_its_outline_and_words() {
        let cases: &[(&str, Outline, usize)] = &[
            ("", &[], 0),
            ("Hello world\n", &[], 2),
            (
                "one\r\n\\section{Two}\r\n\\section{Three}\nfour",
                &[(2, "Two", 2), (2, "Three", 3)],
                4,
            ),
            (
                "\\part{P}\n\\chapter{C}\n\\section{S}\n\\subsection{Sub}\n\\subsubsection{SubSub}\n\\paragraph{Para}\n\\subparagraph{Not in the outline}",
                &[
                    (0, "P", 1),
                    (1, "C", 2),
                    (2, "S", 3),
                    (3, "Sub", 4),
                    (4, "SubSub", 5),
                    (5, "Para", 6),
                ],
                10,
            ),
            (
                "\\section*{Starred}\n\\section[Short]{Long title}\n\\subsection * [x] {Spaced}\n\\section\u{a0}{After a no-break space}",
                &[
                    (2, "Starred", 1),
                    (2, "Long title", 2),
                    (2, "After a no-break space", 4),
                ],
                9,
            ),
            ("\\section{}\n\\chapter*{}", &[(2, "", 1), (1, "", 2)], 0),
            ("Text \\section{A} and \\subsection{B}", &[(2, "A", 1)], 4),
            (
                "% \\section{Hidden}\n  \t% \\section{Indented}\n\\section{Shown} % \\section{After}",
                &[(2, "Shown", 3)],
                1,
            ),
            (
                "\\section{\\texorpdfstring{$\\mathbf{E}$-fields}{E-fields} and \\textbf{More}}\n\\subsection{A {\\bfseries Bold} \\textit{and} Heading\\label{sec:a}}\n\\section{Notes\\footnote{See \\cite{x}.}}\n\\section{R\\&D at 50\\% \\{set\\}}",
                &[
                    (2, "E-fields and More", 1),
                    (3, "A Bold and Heading", 2),
                    (2, "Notes", 3),
                    (2, "R&D at 50% {set}", 4),
                ],
                17,
            ),
            (
                "Hello \\textbf{bold} world \\cite[p.~3]{key} text \\\\ done",
                &[],
                6,
            ),
            ("one two % three four\n50\\% off % really", &[], 3),
            ("x^2 + y_1 = $a$ and~b & c{d}e", &[], 8),
            ("123 456 7.5 foo123", &[], 1),
            ("Café naïve Ελληνικά Русский 中文 123", &[], 5),
            (
                "\\begin{verbatim}\n\\section{Hidden}\n\\end{verbatim}\\section{Visible}\n\\verb|\\section{Hidden}| \\section{After}\n\\\\section{Escaped}",
                &[(2, "Visible", 3), (2, "After", 4)],
                7,
            ),
        ];
        let dir = tempfile::tempdir().unwrap();
        for &(text, outline, words) in cases {
            fs::write(dir.path().join("main.tex"), text).unwrap();
            let expected = Analysis {
                outline: outline
                    .iter()
                    .map(|&(depth, title, line)| {
                        let title = (!title.is_empty()).then(|| title.into());
                        Heading::new(depth, title, line, Some("main.tex".into()))
                    })
                    .collect(),
                words,
            };
            let found = analyze_project(dir.path(), "main.tex", "main.tex");
            assert_eq!(found, expected, "{text}");
        }
    }

    #[test]
    fn the_outline_nests_by_depth_with_a_fold_key_for_each_heading() {
        let heading = |depth, title: &str, file: &str, line| {
            let title = (!title.is_empty()).then(|| title.into());
            Heading::new(depth, title, line, Some(file.into()))
        };
        // A subsection before any section sits flush; same-named headings are numbered.
        let outline = [
            heading(3, "Early", "a.tex", 1),
            heading(2, "Intro", "a.tex", 5),
            heading(3, "Intro", "a.tex", 8),
            heading(3, "Intro", "a.tex", 9),
            heading(2, "Intro", "a.tex", 12),
            heading(1, "Back", "b.tex", 2),
            heading(1, "", "b.tex", 4),
        ];
        let tree = outline_tree(&outline);
        let shape = |nodes: &[OutlineNode]| -> Vec<(usize, String, usize)> {
            nodes
                .iter()
                .map(|n| (n.index, n.fold_key.clone(), n.children.len()))
                .collect()
        };
        assert_eq!(
            shape(&tree),
            [
                (0, "a.tex\t3:Early#1".into(), 0),
                (1, "a.tex\t2:Intro#1".into(), 2),
                (4, "a.tex\t2:Intro#2".into(), 0),
                (5, "b.tex\t1:Back#1".into(), 0),
                (6, "b.tex\t1:(untitled)#1".into(), 0),
            ]
        );
        assert_eq!(
            shape(&tree[1].children),
            [
                (2, "a.tex\t3:Intro#1".into(), 0),
                (3, "a.tex\t3:Intro#2".into(), 0),
            ]
        );
        // On the wire: the heading's own fields, camelCase keys, no empty children; one
        // without a title is titled by its level.
        let json = serde_json::to_value(&tree[0]).unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "index": 0, "depth": 3, "command": "subsection", "level": "Subsection", "title": "Early",
                "untitled": false, "line": 1, "file": "a.tex", "foldKey": "a.tex\t3:Early#1" })
        );
        let untitled = serde_json::to_value(&tree[4]).unwrap();
        assert_eq!(
            (&untitled["title"], &untitled["untitled"]),
            (
                &serde_json::json!("Untitled Chapter"),
                &serde_json::json!(true)
            )
        );
        // The heading a line is under: its file's last at or above it.
        assert_eq!(current_heading(&outline, "a.tex", 9), Some(3));
        assert_eq!(current_heading(&outline, "a.tex", 100), Some(4));
        assert_eq!(current_heading(&outline, "b.tex", 1), None);
        assert_eq!(current_heading(&outline, "c.tex", 5), None);
    }

    /// The main file's inputs read in place, each file once, commented ones not;
    /// a file the main file doesn't reach is its own document.
    #[test]
    fn a_project_reads_its_inputs_in_place() {
        let dir = tempfile::tempdir().unwrap();
        let write = |rel: &str, text: &str| {
            let path = dir.path().join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        };
        write(
            "main.tex",
            "\\section{Intro}\nHello world\n\\input{chapters/a}\n% \\input{loose}\n\\include{b}\\input{main}\n\\section{End}",
        );
        write("chapters/a.tex", "\\section{A}\none two\n\\input{b.tex}");
        write("b.tex", "\\subsection{B}");
        write("loose.tex", "\\section{Loose}\nthree");
        let headings = |a: &Analysis| -> Vec<(String, String, usize)> {
            a.outline
                .iter()
                .map(|h| (h.title.clone(), h.file.clone().unwrap(), h.line))
                .collect()
        };
        let project = analyze_project(dir.path(), "main.tex", "chapters/a.tex");
        let at = |t: &str, f: &str, l| (t.to_owned(), f.to_owned(), l);
        assert_eq!(
            headings(&project),
            [
                at("Intro", "main.tex", 1),
                at("A", "chapters/a.tex", 1),
                at("B", "b.tex", 1),
                at("End", "main.tex", 6)
            ]
        );
        assert_eq!(project.words, 12);
        let loose = analyze_project(dir.path(), "main.tex", "loose.tex");
        assert_eq!(headings(&loose), [at("Loose", "loose.tex", 1)]);
        assert_eq!(loose.words, 2);
    }
}
