//! A document's outline and word count, read from its main file through the
//! files it inputs.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::paths;
use crate::syntax::catalog::CATALOG;
use crate::syntax::{headings, prose, scan};

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

/// A sectioning command: its depth (0 for \part to 5 for \paragraph),
/// command and level, its title as plain text, its 1-based line and, in a
/// project's analysis, its file. A heading whose title is empty is
/// `untitled`, and titled by its level: "Untitled Section".
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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
        Self {
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
    pub children: Vec<Self>,
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
/// the file is read in isn't known. Its name is matched as the analysis
/// matches files, so `\input{chapters/one}` is `Chapters/One.tex` where
/// names fold case, as on the Mac's and Windows' disks.
pub fn current_heading(outline: &[Heading], file: &str, line: usize) -> Option<usize> {
    let file = paths::fold_case(file);
    outline.iter().rposition(|h| {
        h.line <= line
            && h.file
                .as_deref()
                .is_some_and(|f| paths::fold_case(f) == file)
    })
}

/// A session's `analyze` answer: the outline as a tree, the words, and the
/// levels the main file's class has, as it sets and numbers them. The
/// outline itself is kept for `outline_current`.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Analysis {
    #[serde(skip)]
    pub outline: Vec<Heading>,
    pub tree: Vec<OutlineNode>,
    pub words: usize,
    pub heading_styles: Vec<headings::Level>,
}

/// The document LaTeX reads from the main file, into the files its \input,
/// \include and \subfile name (each once, so a loop ends): the headings in
/// reading order, each with its file, and the words of them all. `open` is the
/// editor's file: when the main file doesn't reach it, the document is that
/// file alone. `class` is the main file's; a class it doesn't know numbers
/// its headings as a book's once the document has chapters.
pub fn analyze_project(
    root: &Path,
    main: &str,
    open: &str,
    class: Option<&headings::DocumentClass>,
) -> Analysis {
    let mut analysis = Analysis::default();
    if let Ok(open) = paths::rel_key(open) {
        let mut seen = HashSet::new();
        read(root, main, &mut seen, &mut analysis);
        if !seen.contains(&paths::fold_case(&open)) {
            analysis = Analysis::default();
            read(root, &open, &mut HashSet::new(), &mut analysis);
        }
    }
    let chapters = analysis.outline.iter().any(|h| h.command == "chapter");
    analysis.tree = outline_tree(&analysis.outline);
    analysis.heading_styles = headings::heading_styles(class, chapters);
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
    // The file's headings in reading order, one a line, and the files it
    // reads in, read where it does: found as its words are counted, by the
    // scanner, so none is in a comment, maths or literal code.
    let mut heading_line = None;
    let words = prose::words(&text, |text, name, name_end| {
        let line = text.line_index(name_end as u32) + 1;
        let units = &text.units;
        let mut levels = CATALOG.heading_levels.iter();
        if let Some(depth) = levels.position(|l| l.command == name) {
            if heading_line != Some(line)
                && let (Some(title), _) = braced(units, name_end)
            {
                let heading = Heading::new(depth, plain_title(&title), line, Some(file.clone()));
                into.outline.push(heading);
            }
            heading_line = Some(line);
        } else if matches!(name, "input" | "include" | "subfile")
            && let Some(name) = input_name(units, name_end, name == "input")
        {
            let tex = format!("{}.tex", name.strip_suffix(".tex").unwrap_or(&name));
            // TeX tries name.tex before the name as written.
            if let Some(input) = [tex, name]
                .into_iter()
                .find(|rel| paths::safe_path(root, rel).is_ok_and(|path| path.is_file()))
            {
                read(root, &input, seen, into);
            }
        }
    });
    into.words += words;
}

/// A command's braced argument, without its comments, if it closes; and
/// where the reading stopped.
fn braced(units: &[u16], name_end: usize) -> (Option<String>, usize) {
    let mut text = Vec::new();
    let (stop, closed) = scan::arguments(units, name_end, |piece, braced| {
        if braced {
            text.extend_from_slice(&units[piece]);
        }
    });
    (closed.then(|| String::from_utf16_lossy(&text)), stop)
}

/// The file an \input, \include or \subfile names: its braced argument, or
/// for \input (`bare`) also a name as TeX reads one without braces, to a
/// space.
fn input_name(units: &[u16], name_end: usize, bare: bool) -> Option<String> {
    let name = match braced(units, name_end) {
        (Some(name), _) => name,
        (None, stop) if bare => char::decode_utf16(units[stop..].iter().copied())
            .map_while(|c| c.ok().filter(|c| !"{}\\% \t\r\n".contains(*c)))
            .collect(),
        _ => return None,
    };
    Some(name.trim().to_owned())
}

/// A title as the outline shows it: styles, labels and grouping braces gone,
/// spaces collapsed; none when nothing is left.
fn plain_title(title: &str) -> Option<String> {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A heading's depth, title ("" for none) and line.
    type Outline<'a> = &'a [(usize, &'a str, usize)];

    fn heading(depth: usize, title: &str, file: &str, line: usize) -> Heading {
        let title = (!title.is_empty()).then(|| title.into());
        Heading::new(depth, title, line, Some(file.into()))
    }

    /// Words part at every Unicode space and at TeX's special characters,
    /// and nowhere else; a letter of any script makes a word.
    #[test]
    fn words_part_at_unicode_spaces_and_tex_specials() {
        let cases = [
            ("", 0),
            ("plain ascii words", 3),
            ("a\u{a0}b\u{2003}c\u{3000}d\u{1680}e\tf", 6),
            ("one\u{85}two\u{2028}three\u{2029}four", 4),
            // Neither is a space, so each joins its neighbours.
            ("x\u{feff}y z\u{200b}w", 2),
            ("Ελληνικά слова 漢字です עברית", 4),
            ("a{b}c&d_e^f~g", 7),
            // Maths is no prose.
            ("a{b}c$d$e", 4),
            // What \cite takes is no prose either.
            ("\\textbf{bold} \\cite[p. 3]{key} 42 -- ...", 1),
            ("kept % dropped words", 1),
            ("50\\% off % gone", 1),
            ("%all comment", 0),
        ];
        for (line, expected) in cases {
            assert_eq!(prose::words(line, |_, _, _| {}), expected, "{line:?}");
        }
    }

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
            // TeX's spaces and comments come before an argument, a no-break
            // space doesn't.
            (
                "\\section*{Starred}\n\\section[Short]{Long title}\n\\subsection * [x] {Spaced}\n\\section\u{a0}{After a no-break space}\n\\section % a note\n{After a comment}",
                &[
                    (2, "Starred", 1),
                    (2, "Long title", 2),
                    (3, "Spaced", 3),
                    (2, "After a comment", 5),
                ],
                13,
            ),
            // Titles that wrap, and one on the line after its command; not
            // across a blank line, nor its comment.
            (
                "\\section{A title the editor\n  wraps at eighty}\n\\section\n{Next line}\n\\section{Not\n\nclosed}\n\\section{Commented % out\n here}",
                &[
                    (2, "A title the editor wraps at eighty", 1),
                    (2, "Next line", 3),
                    (2, "Commented here", 8),
                ],
                13,
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
                14,
            ),
            // Words are prose: not a citation's key, a comment, maths, a
            // command's name, or the names a preamble or an environment has.
            (
                "Hello \\textbf{bold} world \\cite[p.~3]{key} text \\\\ done",
                &[],
                5,
            ),
            ("one two % three four\n50\\% off % really", &[], 3),
            ("a line break \\\\% then a comment", &[], 3),
            ("x^2 + y_1 = $a$ and~b & c{d}e", &[], 7),
            (
                "\\documentclass[a4paper]{article}\n\\usepackage{amsmath}\n\\begin{document}\nTwo words\n\\begin{itemize}\\item one\\end{itemize}\n\\[ x + y \\]\n\\begin{lstlisting}\nx = 5 % 3\n\\end{lstlisting}\n\\end{document}",
                &[],
                3,
            ),
            ("123 456 7.5 foo123", &[], 1),
            ("Café naïve Ελληνικά Русский 中文 123", &[], 5),
            (
                "\\begin{verbatim}\n\\section{Hidden}\n\\end{verbatim}\\section{Visible}\n\\verb|\\section{Hidden}| \\section{After}\n\\\\section{Escaped}",
                &[(2, "Visible", 3), (2, "After", 4)],
                4,
            ),
        ];
        let dir = tempfile::tempdir().unwrap();
        for &(text, outline, words) in cases {
            fs::write(dir.path().join("main.tex"), text).unwrap();
            let expected: Vec<_> = outline
                .iter()
                .map(|&(depth, title, line)| heading(depth, title, "main.tex", line))
                .collect();
            let found = analyze_project(dir.path(), "main.tex", "main.tex", None);
            assert_eq!((found.outline, found.words), (expected, words), "{text}");
        }
    }

    #[test]
    fn the_outline_nests_by_depth_with_a_fold_key_for_each_heading() {
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
        assert_eq!(untitled["title"], "Untitled Chapter");
        assert_eq!(untitled["untitled"], true);
        // The heading a line is under: its file's last at or above it.
        assert_eq!(current_heading(&outline, "a.tex", 9), Some(3));
        assert_eq!(current_heading(&outline, "a.tex", 100), Some(4));
        assert_eq!(current_heading(&outline, "b.tex", 1), None);
        assert_eq!(current_heading(&outline, "c.tex", 5), None);
        // The file named in another case is the same one where names fold it.
        let folded = cfg!(any(target_os = "macos", windows)).then_some(3);
        assert_eq!(current_heading(&outline, "A.TEX", 9), folded);
    }

    /// A project folder of `files`, each a path and its text.
    fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for (rel, text) in files {
            let path = dir.path().join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        }
        dir
    }

    /// The main file's inputs read in place, each file once, commented ones not;
    /// a file the main file doesn't reach is its own document.
    #[test]
    fn a_project_reads_its_inputs_in_place() {
        let dir = project(&[
            (
                "main.tex",
                "\\section{Intro}\nHello world\n\\input{chapters/a}\n% \\input{loose}\n\\include{b}\\input{main}\n\\section{End}",
            ),
            ("chapters/a.tex", "\\section{A}\none two\n\\input{b.tex}"),
            ("b.tex", "\\subsection{B}"),
            ("loose.tex", "\\section{Loose}\nthree"),
        ]);
        fn headings(a: &Analysis) -> Vec<(&str, Option<&str>, usize)> {
            let outline = a.outline.iter();
            outline
                .map(|h| (h.title.as_str(), h.file.as_deref(), h.line))
                .collect()
        }
        let whole = analyze_project(dir.path(), "main.tex", "chapters/a.tex", None);
        assert_eq!(
            headings(&whole),
            [
                ("Intro", Some("main.tex"), 1),
                ("A", Some("chapters/a.tex"), 1),
                ("B", Some("b.tex"), 1),
                ("End", Some("main.tex"), 6)
            ]
        );
        // Its files' names aren't words.
        assert_eq!(whole.words, 8);
        let loose = analyze_project(dir.path(), "main.tex", "loose.tex", None);
        assert_eq!(headings(&loose), [("Loose", Some("loose.tex"), 1)]);
        assert_eq!(loose.words, 2);
    }

    /// Inputs are followed as TeX finds them: by an unbraced name, and by a
    /// name with its .tex, not given a second; not in a literal or comment
    /// environment. The open file named another way is still the one read.
    #[test]
    fn inputs_are_followed_as_tex_finds_them() {
        let one = [
            ("main.tex", "\\section{Main}\n\\input{chapters/one}"),
            ("chapters/one.tex", "\\section{One}"),
        ];
        let unbraced = [
            (
                "main.tex",
                "\\section{Main}\n\\input chapter\n\\section{End}",
            ),
            ("chapter.tex", "\\section{Chapter}\nbody"),
        ];
        let named_tex = [
            ("main.tex", "\\input{part.tex}"),
            ("part.tex", "\\section{Part}"),
            ("part.tex.tex", "\\section{Wrong}"),
        ];
        let literal = [
            (
                "main.tex",
                "\\section{Main}\n\\begin{verbatim}\n\\input{example}\n\\end{verbatim}\n\\begin{comment}\n\\input{example}\n\\end{comment}\n\\verb|\\input{example}|\n\\input{real}",
            ),
            ("example.tex", "\\section{Example}"),
            ("real.tex", "\\section{Real}"),
        ];
        let cases: [(&[_], &str, &[&str]); 6] = [
            (&one, "chapters/one.tex", &["Main", "One"]),
            (&one, "./chapters/one.tex", &["Main", "One"]),
            (&one, "chapters/../chapters/one.tex", &["Main", "One"]),
            (&unbraced, "main.tex", &["Main", "Chapter", "End"]),
            (&named_tex, "main.tex", &["Part"]),
            (&literal, "main.tex", &["Main", "Real"]),
        ];
        for (files, open, titles) in cases {
            let dir = project(files);
            let found = analyze_project(dir.path(), "main.tex", open, None).outline;
            let found: Vec<_> = found.iter().map(|h| h.title.as_str()).collect();
            assert_eq!(found, titles, "{files:?} with {open} open");
        }
    }
}
