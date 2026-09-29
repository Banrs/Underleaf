// A document's outline, word count and line count, read the way the browser
// client's `analyzeDoc` (web/src/state.js) reads them, so every host shows the
// same numbers. The regular expressions are that file's, spelled for JavaScript's
// rules (its `\s`, its `.`); tests/fixtures/analyze.json holds both to them.

use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

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
        r"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?[{JS_SPACE}]*(?:\[[^\]]*\])?[{JS_SPACE}]*\{{([^}}]*)\}}"
    ))
    .unwrap()
});
static COMMENT_LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"^[{JS_SPACE}]*%")).unwrap());
// JavaScript's `.` stops at line terminators, so a `%` with U+2028 or U+2029
// after it starts no comment.
static COMMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(^|[^\\])%[^\n\r\x{2028}\x{2029}]*$").unwrap());
static COMMAND: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\[a-zA-Z]+\*?(?:\[[^\]]*\])?").unwrap());
// What separates words: JavaScript's `\s` and TeX's special characters.
static WORD_BREAK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!(r"[{JS_SPACE}{{}}$&_^~\\%]")).unwrap());

/// A sectioning command: its depth (0 for \part to 5 for \paragraph), its
/// title ("(untitled)" when empty) and its 1-based line.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Heading {
    pub depth: usize,
    pub title: String,
    pub line: usize,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Analysis {
    pub outline: Vec<Heading>,
    pub words: usize,
    pub lines: usize,
}

/// The outline, words and lines in one pass. Lines break where CodeMirror
/// breaks them, at CR LF, CR or LF, so the line count is the editor's.
pub fn analyze(text: &str) -> Analysis {
    let mut outline = Vec::new();
    let mut words = 0;
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
            let title = &m[2];
            outline.push(Heading {
                depth: LEVELS.iter().position(|l| *l == &m[1]).unwrap_or(2),
                title: if title.is_empty() {
                    "(untitled)"
                } else {
                    title
                }
                .to_string(),
                line: lines,
            });
        }
        words += line_words(line);
    }
    Analysis {
        outline,
        words,
        lines,
    }
}

/// Rough word count of a prose line: drop the comment, commands and TeX's
/// special characters, and count the runs left that contain a letter.
fn line_words(line: &str) -> usize {
    let line = match COMMENT.captures(line) {
        Some(m) => &line[..m.get(1).unwrap().end()],
        None => line,
    };
    WORD_BREAK
        .split(&COMMAND.replace_all(line, " "))
        .filter(|w| {
            w.chars()
                .any(|c| c.is_ascii_alphabetic() || ('À'..='ž').contains(&c))
        })
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
