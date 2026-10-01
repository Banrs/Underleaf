// A project's outline, word count and line count, each file read the way the
// browser client's `analyzeDoc` (web/src/state.js) reads the open one, so every
// host shows the same numbers. The regular expressions are that file's, spelled
// for JavaScript's rules (its `\s`, its `.`); tests/fixtures/analyze.json holds
// both to them.

use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::paths;

/// JavaScript's `\s`, which differs from Unicode's White_Space (U+FEFF in,
/// U+0085 out).
const JS_SPACE: &str =
    r"\t\n\x0B\x0C\r \xA0\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}";
const LEVELS: [&str; 6] = [
    "part",
    "chapter",
    "section",
    "subsection",
    "subsubsection",
    "paragraph",
];

static SECTION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?[{JS_SPACE}]*(?:\[[^\]]*\])?[{JS_SPACE}]*\{{"
    ))
    .unwrap()
});
static COMMENT_LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"^[{JS_SPACE}]*%")).unwrap());
// JavaScript's `.` stops at line terminators, so a `%` with U+2028 or U+2029
// after it starts no comment.
static COMMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(^|[^\\])%[^\n\r\x{2028}\x{2029}]*$").unwrap());
// A file read in place, as TeX's \input, LaTeX's \include and \subfile read it.
static INPUT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"\\(?:(?:input|include|subfile)[{JS_SPACE}]*\{{([^{{}}]+)\}}|input[{JS_SPACE}]+([^{{}}\\%{JS_SPACE}]+))"
    ))
    .unwrap()
});
static COMMAND: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\[a-zA-Z]+\*?(?:\[[^\]]*\])?").unwrap());
// What a title drops whole: \texorpdfstring's TeX argument (its PDF string is
// the group after), labels and notes.
static TITLE_DROP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"\\(?:texorpdfstring|label|index|footnote)[{JS_SPACE}]*\{{(?:[^{{}}]|\{{[^{{}}]*\}})*\}}"
    ))
    .unwrap()
});
// Styles a title shows as plain text: \emph and the like, and font switches.
static TITLE_STYLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"\\(?:emph|text(?:bf|it|sl|sc|tt|sf|rm|up|md|normal)|underline|em|bf|it|sl|sc|tt|sf|rm|normalfont|(?:bf|md)series|(?:it|sl|sc|up)shape|(?:rm|sf|tt)family)(?-u:\b)[{JS_SPACE}]*"
    ))
    .unwrap()
});
// Grouping braces go; an escaped special shows as itself.
static TITLE_BRACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\([{}&%$#_])|[{}]").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!("[{JS_SPACE}]+")).unwrap());
// What separates words: JavaScript's `\s` and TeX's special characters.
static WORD_BREAK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"[{JS_SPACE}{{}}$&_^~\\%]")).unwrap());

/// A sectioning command: its depth (0 for \part to 5 for \paragraph), its
/// title as plain text ("(untitled)" when empty), its 1-based line and, in a
/// project's analysis, its file.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Heading {
    pub depth: usize,
    pub title: String,
    pub line: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

#[derive(Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Analysis {
    pub outline: Vec<Heading>,
    pub words: usize,
    pub lines: usize,
}

/// The document LaTeX reads from the main file, into the files its \input,
/// \include and \subfile name (each once, so a loop ends): the headings in
/// reading order, each with its file, and the words of them all. `open` is the
/// editor's file, whose lines it counts; when the main file doesn't reach it,
/// the document is that file alone.
pub fn analyze_project(root: &Path, main: &str, open: &str) -> Analysis {
    let Ok(open) = paths::rel_key(open) else {
        return Analysis::default();
    };
    let key = paths::fold_case(&open);
    let mut analysis = Analysis::default();
    let mut seen = HashSet::new();
    read(root, main, &key, &mut seen, &mut analysis);
    if !seen.contains(&key) {
        analysis = Analysis::default();
        read(root, &open, &key, &mut HashSet::new(), &mut analysis);
    }
    analysis
}

fn read(root: &Path, file: &str, open: &str, seen: &mut HashSet<String>, into: &mut Analysis) {
    let Ok(file) = paths::rel_key(file) else {
        return;
    };
    let key = paths::fold_case(&file);
    if !seen.insert(key.clone()) {
        return;
    }
    let Some(text) = paths::safe_path(root, &file)
        .ok()
        .and_then(|path| fs::read(path).ok())
    else {
        return;
    };
    let lines = add(
        into,
        &crate::lossy_string(text),
        Some(&file),
        &mut |into, name| {
            if let Some(input) = resolve(root, name) {
                read(root, &input, open, seen, into);
            }
        },
    );
    if key == open {
        into.lines = lines;
    }
}

/// The project file `\input{name}` reads: name.tex, which TeX tries first, or name.
fn resolve(root: &Path, name: &str) -> Option<String> {
    let name = name.trim();
    let tex = format!("{}.tex", name.strip_suffix(".tex").unwrap_or(name));
    [tex, name.to_owned()]
        .into_iter()
        .find(|rel| paths::safe_path(root, rel).is_ok_and(|path| path.is_file()))
}

/// Adds a file's headings and words to `into`, reading each file a line names
/// through `input` there, and returns its line count. Lines break where
/// CodeMirror breaks them, at CR LF, CR or LF, so the count is the editor's.
fn add(
    into: &mut Analysis,
    text: &str,
    file: Option<&str>,
    input: &mut dyn FnMut(&mut Analysis, &str),
) -> usize {
    let mut lines = 0;
    for line in text
        .split('\n')
        .flat_map(|l| l.strip_suffix('\r').unwrap_or(l).split('\r'))
    {
        lines += 1;
        if COMMENT_LINE.is_match(line) {
            continue;
        }
        if let Some(m) = SECTION.captures(line) {
            if let Some(title) = brace_group(&line[m.get(0).unwrap().end()..]) {
                into.outline.push(Heading {
                    depth: LEVELS.iter().position(|l| *l == &m[1]).unwrap_or(2),
                    title: plain_title(title),
                    line: lines,
                    file: file.map(Into::into),
                });
            }
        }
        let code = code(line);
        into.words += words(code);
        for m in INPUT.captures_iter(code) {
            input(into, m.get(1).or_else(|| m.get(2)).unwrap().as_str());
        }
    }
    lines
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
/// spaces collapsed, "(untitled)" when nothing is left.
fn plain_title(title: &str) -> String {
    let title = TITLE_DROP.replace_all(title, "");
    let title = TITLE_STYLE.replace_all(&title, "");
    let title = TITLE_BRACE.replace_all(&title, "$1");
    match SPACES.replace_all(&title, " ").trim_matches(' ') {
        "" => "(untitled)".into(),
        title => title.into(),
    }
}

/// A line up to its comment.
fn code(line: &str) -> &str {
    match COMMENT.captures(line) {
        Some(m) => &line[..m.get(1).unwrap().end()],
        None => line,
    }
}

/// Rough word count of a line's code: drop commands and TeX's special
/// characters, and count the runs left that contain a letter.
fn words(code: &str) -> usize {
    WORD_BREAK
        .split(&COMMAND.replace_all(code, " "))
        .filter(|w| w.chars().any(char::is_alphabetic))
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One file's analysis, as `analyzeDoc` reads the editor's.
    fn analyze(text: &str) -> Analysis {
        let mut analysis = Analysis::default();
        analysis.lines = add(&mut analysis, text, None, &mut |_, _| {});
        analysis
    }

    /// The cases web/src/state.js is held to as well (test/analyze.test.js).
    #[test]
    fn matches_the_shared_fixtures() {
        #[derive(Deserialize)]
        struct Case {
            name: String,
            text: String,
            expected: Analysis,
        }
        let cases: Vec<Case> =
            serde_json::from_str(include_str!("../tests/fixtures/analyze.json")).unwrap();
        for case in cases {
            assert_eq!(analyze(&case.text), case.expected, "{}", case.name);
        }
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
        assert_eq!((project.words, project.lines), (12, 3));
        let loose = analyze_project(dir.path(), "main.tex", "loose.tex");
        assert_eq!(headings(&loose), [at("Loose", "loose.tex", 1)]);
        assert_eq!((loose.words, loose.lines), (2, 2));
    }
}
