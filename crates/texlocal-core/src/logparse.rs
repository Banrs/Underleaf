//! latexmk/TeX log parsing. Warnings name no file, so the open file is tracked from the log's "(./x.tex" and ")" marks.

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::{Captures, Regex};
use serde::Serialize;

/// How serious an item is: "error" or "warning" on the wire.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Hash)]
pub struct LogItem {
    #[serde(rename = "type")]
    pub kind: Severity,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub message: String,
    /// `message` for a line's end: on one line, without LaTeX's own prefix.
    pub short: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
}

impl LogItem {
    fn new(kind: Severity, file: Option<String>, line: Option<u32>, message: String) -> Self {
        let flat = message.split_whitespace().collect::<Vec<_>>().join(" ");
        let short = flat
            .strip_prefix("LaTeX Error: ")
            .unwrap_or(&flat)
            .to_owned();
        Self {
            kind,
            file,
            line,
            message,
            command: undefined_command(&short),
            short,
        }
    }

    pub(crate) fn error(message: impl Into<String>) -> Self {
        Self::new(Severity::Error, None, None, message.into())
    }
}

/// The command a message names as undefined, as `parse_log` writes it, and for
/// no other message: one from a file TeX loaded has that file's name before it.
fn undefined_command(message: &str) -> Option<String> {
    let name = message.strip_prefix("Undefined control sequence: \\")?;
    let letters = name.chars().all(|c| c.is_ascii_alphabetic() || c == '@');
    ((!name.is_empty() && letters) || name.chars().count() == 1).then(|| format!("\\{name}"))
}

// `path:line: ` from -file-line-error for any file TeX reads, or TeX's own `! `; `error_start` also requires a path, which a time like "12:30: " is not.
static ERROR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:(?P<file>(?:[A-Za-z]:)?[^\s:!][^:]*):(?P<line>\d+):(?:\s+|$)|! )(?P<message>.*)$",
    )
    .unwrap()
});
static L_NO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^l\.(\d+)").unwrap());
static LAST_CS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\\(?:[A-Za-z@]+|.))\s*$").unwrap());
static WARNING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:LaTeX(?: Font| NFSS)?|Package \S+|Class \S+) Warning:\s*(?P<message>.*)$")
        .unwrap()
});
static ON_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"on input line (\d+)").unwrap());
static BAD_BOX_LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:at lines|detected at line) (\d+)").unwrap());
static BIBTEX_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.*)---line (\d+) of file (.+)$").unwrap());
static BIBTEX_WARNING_PLACE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^--line (\d+) of file (.+)$").unwrap());
static BIBER_MESSAGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[\d+\] .*> (ERROR|WARN) - (.*)$").unwrap());
static SHELL_ESCAPE_ASKED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)shell[- ]escape|\\write18").unwrap());
static RUNSYSTEM_REFUSED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"runsystem\(.*\)\.\.\.disabled").unwrap());

fn error_start(line: &str) -> Option<Captures<'_>> {
    ERROR
        .captures(line)
        .filter(|m| m.name("file").is_none_or(|f| is_path(f.as_str())))
}

/// Whether the text before "12:" is a path and not words: TeX prints project files as "./name", so even a name with a space has a slash.
fn is_path(text: &str) -> bool {
    text.contains(['/', '\\']) || (text.contains('.') && !text.contains(char::is_whitespace))
}

fn warning_start(line: &str) -> Option<Captures<'_>> {
    line.contains(" Warning:")
        .then(|| WARNING.captures(line))
        .flatten()
}

/// A forward-slash project path; None for an absolute TeX distribution path,
/// `/…` or, from a TeX on Windows, `C:/…`, `C:\…` or `\\server\…`.
fn project_path(path: &str) -> Option<String> {
    let absolute = match path.as_bytes() {
        [b'/' | b'\\', ..] => true,
        [drive, b':', b'/' | b'\\', ..] => drive.is_ascii_alphabetic(),
        _ => false,
    };
    (!absolute).then(|| path.strip_prefix("./").unwrap_or(path).to_string())
}

/// Whether the word after a "(" is a file TeX opens, not text in parentheses:
/// it has a slash, or is a Windows path in full, `C:\…` or `\\server\…`. A
/// backslash alone would take a command: "(\end occurred inside a group".
fn opens_file(token: &str) -> bool {
    token.contains('/')
        || match token.as_bytes() {
            [drive, b':', b'\\', ..] => drive.is_ascii_alphabetic(),
            [b'\\', b'\\', ..] => token[2..].contains('\\'),
            _ => false,
        }
}

fn track<'a>(open: &mut Vec<Option<&'a str>>, line: &'a str) {
    let mut rest = line;
    while let Some(i) = rest.find(['(', ')']) {
        let paren = rest.as_bytes()[i];
        rest = &rest[i + 1..];
        if paren == b')' {
            open.pop();
            continue;
        }
        let (token, after) = match rest.strip_prefix('"') {
            Some(quoted) => quoted.split_once('"').unwrap_or((quoted, "")),
            None => rest.split_at(
                rest.find(|c: char| c.is_whitespace() || c == '(' || c == ')')
                    .unwrap_or(rest.len()),
            ),
        };
        open.push(opens_file(token).then_some(token));
        rest = after;
    }
}

/// An absolute TeX distribution path is attributed to the open project file, with no line number.
fn locate(
    named: Option<&str>,
    line: Option<u32>,
    open: &[Option<&str>],
    main_file: &str,
    message: &mut String,
) -> (Option<String>, Option<u32>) {
    let Some(line) = line else {
        return (None, None);
    };
    let mut files = open.iter().rev().flatten().copied();
    let Some(path) = named.or_else(|| files.clone().next()) else {
        return (Some(main_file.to_string()), Some(line));
    };
    if let Some(rel) = project_path(path) {
        return (Some(rel), Some(line));
    }
    let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
    *message = format!("{name}: {message}");
    (files.find_map(project_path), None)
}

/// The name a diagnostic's continuation lines carry in parentheses, e.g. "(hyperref)".
fn continuation_tag(text: &str) -> Option<&str> {
    let mut words = text.split_whitespace();
    match (words.next()?, words.next()?) {
        ("Package" | "Class", name) => Some(name),
        ("LaTeX", "Font") => Some("Font"),
        ("LaTeX", word) if word.ends_with(':') => Some("LaTeX"),
        _ => None,
    }
}

fn starts_new(line: &str) -> bool {
    line.trim().is_empty()
        || line.starts_with(['!', '<'])
        || L_NO.is_match(line)
        || error_start(line).is_some()
        || warning_start(line).is_some()
}

/// What `next` adds to a message after `prev`: a line led by the diagnostic's own "(name)", an indented one, or the rest of a line an engine wrapped at column 79.
fn continuation<'a>(
    prev: &str,
    next: &'a str,
    tag: Option<&str>,
) -> Option<(&'a str, &'static str)> {
    let tagged = tag.and_then(|tag| next.strip_prefix('(')?.strip_prefix(tag)?.strip_prefix(')'));
    if let Some(rest) = tagged {
        Some((rest.trim(), " "))
    } else if prev.chars().count() == 79 && !next.starts_with('(') {
        Some((next, ""))
    } else {
        next.starts_with([' ', '\t']).then(|| (next.trim(), " "))
    }
}

fn blank_from(lines: &[&str], from: usize) -> usize {
    (from..lines.len())
        .find(|&j| lines[j].trim().is_empty())
        .unwrap_or(lines.len())
}

fn echo_of(lines: &[&str], i: usize) -> Option<usize> {
    lines[i + 1..(i + 12).min(lines.len())]
        .iter()
        .take_while(|next| !next.starts_with('!') && error_start(next).is_none())
        .position(|next| L_NO.is_match(next))
        .map(|k| i + 1 + k)
}

/// The log's errors and warnings, and apart from them its overfull and underfull boxes.
pub fn parse_log(log: &str, main_file: &str) -> (Vec<LogItem>, Vec<LogItem>) {
    let lines: Vec<&str> = log.lines().collect();
    let mut items: Vec<LogItem> = Vec::new();
    let mut bad_boxes = Vec::new();
    let mut open = Vec::new();
    // Lines before this echo source whose parentheses needn't pair up.
    let mut quiet_until = 0;

    for (i, &line) in lines.iter().enumerate() {
        // Skip the regexes for most lines: an error starts "! " or has colons.
        let may_err = line.starts_with("! ") || line.contains(':');
        let diagnostic = may_err
            .then(|| error_start(line))
            .flatten()
            .or_else(|| warning_start(line));
        if let Some(m) = diagnostic {
            let named = m.name("file").map(|m| m.as_str());
            let error = named.is_some() || line.starts_with("! ");
            let mut message = m["message"].to_string();
            let echo = if error { echo_of(&lines, i) } else { None };
            if error {
                quiet_until = echo.map_or_else(|| blank_from(&lines, i + 1), |j| j + 2);
            }
            let tag = continuation_tag(if error { &m["message"] } else { line });
            let mut prev = line;
            for next in lines[i + 1..].iter().take_while(|next| !starts_new(next)) {
                let Some((text, joiner)) = continuation(prev, next, tag) else {
                    break;
                };
                if !text.is_empty() {
                    if !joiner.is_empty() {
                        message.truncate(message.trim_end().len());
                    }
                    message.push_str(joiner);
                    message.push_str(text);
                }
                prev = next;
            }
            // A fatal summary repeats the stopping error; keep it only alone.
            let summary = error && message.trim_start().starts_with("==>");
            if summary && items.iter().any(|item| item.kind == Severity::Error) {
                continue;
            }
            if message
                .trim_start()
                .starts_with("Undefined control sequence.")
                && let Some(j) = echo
                && let Some(m) = lines[i + 1..=j].iter().find_map(|l| LAST_CS.captures(l))
            {
                message = format!("Undefined control sequence: {}", &m[1]);
            }
            let line_no = if summary && named.is_some() {
                None
            } else if error {
                m.name("line")
                    .or_else(|| echo.and_then(|j| L_NO.captures(lines[j])?.get(1)))
                    .and_then(|line| line.as_str().parse().ok())
            } else {
                ON_LINE.captures(&message).and_then(|lm| lm[1].parse().ok())
            };
            let (file, line_no) = locate(named, line_no, &open, main_file, &mut message);
            items.push(LogItem::new(
                if error {
                    Severity::Error
                } else {
                    Severity::Warning
                },
                file,
                line_no,
                message.trim().to_string(),
            ));
        } else if line.starts_with("Overfull \\") || line.starts_with("Underfull \\") {
            quiet_until = blank_from(&lines, i + 1);
            let line_no = BAD_BOX_LINE.captures(line).and_then(|m| m[1].parse().ok());
            let mut message = line.trim().to_string();
            let (file, line_no) = locate(None, line_no, &open, main_file, &mut message);
            bad_boxes.push(LogItem::new(Severity::Warning, file, line_no, message));
        }
        if i >= quiet_until {
            track(&mut open, line);
        }
    }

    // Reruns duplicate messages; keep the first in order.
    let mut seen = HashSet::new();
    items.retain(|item| seen.insert(item.clone()));
    bad_boxes.retain(|item| seen.insert(item.clone()));
    (items, bad_boxes)
}

/// Errors and warnings from bibtex's or biber's .blg; bibtex names the .bib line after an
/// error's message or on the line below it, and below a warning's.
pub fn parse_blg(blg: &str) -> Vec<LogItem> {
    let mut items: Vec<LogItem> = Vec::new();
    let mut above = "";
    for line in blg.lines() {
        if let Some(m) = BIBTEX_ERROR.captures(line) {
            let file = project_path(m[3].trim());
            let message = if m[1].trim().is_empty() { above } else { &m[1] };
            items.push(LogItem::new(
                Severity::Error,
                file.clone(),
                file.and(m[2].parse().ok()),
                message.trim().to_string(),
            ));
        } else if let Some(message) = line.strip_prefix("Warning--") {
            items.push(LogItem::new(
                Severity::Warning,
                None,
                None,
                message.trim().to_string(),
            ));
        } else if let Some(m) = BIBTEX_WARNING_PLACE.captures(line)
            && above.starts_with("Warning--")
            && let Some(warning) = items.last_mut()
        {
            warning.file = project_path(m[2].trim());
            warning.line = warning.file.as_ref().and(m[1].parse().ok());
        } else if let Some(m) = BIBER_MESSAGE.captures(line) {
            let kind = if &m[1] == "WARN" {
                Severity::Warning
            } else {
                Severity::Error
            };
            items.push(LogItem::new(kind, None, None, m[2].trim().to_string()));
        }
        above = line;
    }
    items
}

pub(crate) const SHELL_ESCAPE: &str = "A package here runs programs as it builds, which needs Shell Escape. Turn on Shell Escape in the project's settings if you trust the project.";

/// A failed build's error that asks for shell escape (minted's "invoke LaTeX with the
/// -shell-escape flag") says where to allow it; without one, a program TeX refused
/// ("runsystem(…)...disabled") adds that error with no place.
pub(crate) fn point_to_shell_escape(errors: &mut Vec<LogItem>, log: &str) {
    if let Some(error) = errors
        .iter_mut()
        .find(|e| SHELL_ESCAPE_ASKED.is_match(&e.short))
    {
        *error = LogItem::new(
            Severity::Error,
            error.file.take(),
            error.line,
            SHELL_ESCAPE.into(),
        );
    } else if RUNSYSTEM_REFUSED.is_match(log) {
        errors.insert(0, LogItem::error(SHELL_ESCAPE));
    }
}

pub fn latexmk_errors(output: &str) -> Vec<LogItem> {
    output
        .lines()
        .skip_while(|line| !line.starts_with("Collected error summary"))
        .skip(1)
        .take_while(|line| line.starts_with("  "))
        .filter(|line| !line.starts_with("   "))
        .map(|line| LogItem::error(line.trim()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn described(items: &[LogItem]) -> Vec<String> {
        let place = |part: Option<String>| part.unwrap_or_else(|| "-".into());
        items
            .iter()
            .map(|it| {
                let kind = serde_json::to_value(it.kind).unwrap();
                let (file, line) = (
                    place(it.file.clone()),
                    place(it.line.map(|l| l.to_string())),
                );
                format!("{} {file}:{line} {}", kind.as_str().unwrap(), it.message)
            })
            .collect()
    }

    fn parsed(log: &str) -> Vec<String> {
        described(&parse_log(log, "main.tex").0)
    }

    #[test]
    fn an_error_takes_the_line_tex_echoes_after_it_or_names_no_place() {
        let error = "./main.tex:12: Undefined control sequence.\nl.12 \\foo\n";
        let fatal = "==> Fatal error occurred, no output PDF file produced!";
        let undefined = "error main.tex:12 Undefined control sequence: \\foo";
        let alone = format!("error -:- {fatal}");
        let cases: [(String, &[&str]); 5] = [
            (
                "! Emergency stop.\nl.9 \\end\n".into(),
                &["error main.tex:9 Emergency stop."],
            ),
            // A "!" error doesn't take the next error's "l.<n>".
            (
                format!("! Emergency stop.\n{error}"),
                &["error -:- Emergency stop.", undefined],
            ),
            // TeX's closing summary names the stopping error's line, not its
            // own, and folds into the error before it.
            (format!("{error}\n./main.tex:12:  {fatal}\n"), &[undefined]),
            // Alone, it is the failure's one record, with no place.
            (format!("./main.tex:12:  {fatal}\n"), &[&alone]),
            (
                format!("! Emergency stop.\n! {fatal}\n"),
                &["error -:- Emergency stop."],
            ),
        ];
        for (log, expected) in cases {
            assert_eq!(parsed(&log), expected, "{log}");
        }
    }

    #[test]
    fn messages_lose_texs_context_and_name_the_command_they_cannot_find() {
        let log = "./main.tex:19: Undefined control sequence.\n\
                   l.19 ...ndefined control sequence: \\undefinedmacro\n\
                   \x20                                                 .\n\
                   \n\
                   ./main.tex:21: Missing $ inserted.\n\
                   <inserted text> \n\
                   \x20               $\n\
                   l.21 x^\n\
                   \n\
                   ./main.tex:24: Undefined control sequence.\n\
                   \\x ->\\foo@x\n\
                   \x20        \n\
                   l.24 \\x\n\
                   \n\
                   ./main.tex:5: Undefined control sequence.\n\
                   l.5 \\&\n\
                   \n\
                   ./main.tex:3: LaTeX Error: Command \\a already defined.\n\
                   \x20              Or name \\end... illegal, see p.192 of the manual.\n\
                   \n\
                   See the LaTeX manual or LaTeX Companion for explanation.\n\
                   l.3 \\newcommand\\a{y}\n";
        let (items, _) = parse_log(log, "main.tex");
        let found: Vec<_> = items
            .iter()
            .map(|it| (it.short.as_str(), it.command.as_deref()))
            .collect();
        let undefined = |name| (format!("Undefined control sequence: {name}"), Some(name));
        let expected = [
            undefined("\\undefinedmacro"),
            ("Missing $ inserted.".into(), None),
            undefined("\\foo@x"),
            undefined("\\&"),
            (
                "Command \\a already defined. Or name \\end... illegal, see p.192 of the manual."
                    .into(),
                None,
            ),
        ];
        let expected: Vec<_> = expected.iter().map(|(s, c)| (s.as_str(), *c)).collect();
        assert_eq!(found, expected);
        // The name of a file TeX loaded comes first in its message: not this file's command.
        for message in [
            "x.sty: Undefined control sequence: \\a",
            "Undefined control sequence: \\ab-c",
        ] {
            assert_eq!(undefined_command(message), None, "{message}");
        }
    }

    #[test]
    fn an_error_in_a_file_of_any_type_is_reported_and_a_time_is_not_an_error() {
        let log = "(./refs/my.cbx\n\
                   ./refs/my.cbx:12: Package biblatex Error: Bad style.\n\
                   l.12 \\x\n\
                   \n\
                   ./data.dat:2: Missing number.\n\
                   l.2 \\nope\n\
                   \n\
                   ./My Chapter.tex:3: Missing $ inserted.\n\
                   l.3 x^2\n\
                   \n\
                   C:/proj/a.lbx:7: Boom.\n\
                   \n\
                   Output written on main.pdf (2 pages, built at 12:30: done).\n\
                   Document Class: article 2025/01/22 v1.4n Standard LaTeX document class\n\
                   File: size10.clo 2025/01/22 v1.4n Standard LaTeX file (size option)\n\
                   Package: x 3.1: 2025/01/22:\n\
                   build at 10:30: no file here\n\
                   )(build/main.bbl\n\
                   build/main.bbl:5: Misplaced alignment tab character &.\n\
                   l.5 \\newblock Cats &\n\
                   \n\
                   build/main.bbl:5:  ==> Fatal error occurred, no output PDF file produced!\n";
        assert_eq!(
            parsed(log),
            [
                "error refs/my.cbx:12 Package biblatex Error: Bad style.",
                "error data.dat:2 Missing number.",
                "error My Chapter.tex:3 Missing $ inserted.",
                "error refs/my.cbx:- a.lbx: Boom.",
                "error build/main.bbl:5 Misplaced alignment tab character &.",
            ]
        );
    }

    #[test]
    fn a_message_takes_the_file_tex_has_open() {
        // Parentheses in echoed source and box contents don't pair up, and a command in parentheses opens no file.
        let log = "(./main.tex\n\
                   (/usr/local/texlive/2026/texmf-dist/tex/latex/base/article.cls\n\
                   Document Class: article 2025/01/22 v1.4n Standard LaTeX document class\n\
                   )\n\
                   ./main.tex:4: Undefined control sequence.\n\
                   l.4 Hello \\foo\n\
                   \x20              world (unbalanced paren.\n\
                   The control sequence at the end of the top line\n\
                   \n\
                   (./chapters/intro.tex\n\
                   \n\
                   LaTeX Warning: Reference `nope' on page 1 undefined on input line 3.\n\
                   \n\
                   )\n\
                   \n\
                   Overfull \\hbox (182.7699pt too wide) detected at line 7\n\
                   \\OT1/cmr/m/n/10 Some very long text (that overflows\n\
                   \x20[]\n\
                   \n\
                   \n\
                   LaTeX Warning: Reference `x' on page 1 undefined on input line 9.\n\
                   \n\
                   (C:\\Users\\Alex\\AppData\\MiKTeX\\tex/latex/base\\article.cls\n\
                   (\\end occurred inside a group at level 1)\n\
                   Package ulem Warning: In a distribution file on input line 12.\n\
                   (\\\\server\\share\\x.sty\n\
                   )\n\
                   )\n\
                   (./chapters/a.tex\n\
                   \n\
                   LaTeX Warning: Reference `y' on page 1 undefined on input line 3.\n\
                   \n\
                   \x20)\n";
        let places: Vec<_> = parse_log(log, "other.tex")
            .0
            .into_iter()
            .map(|it| (it.file, it.line))
            .collect();
        let at = |file: &str, line| (Some(file.to_string()), Some(line));
        assert_eq!(
            places,
            [
                at("main.tex", 4),
                at("chapters/intro.tex", 3),
                at("main.tex", 9),
                (Some("main.tex".into()), None),
                at("chapters/a.tex", 3),
            ]
        );
    }

    #[test]
    fn warnings_run_on_over_wrapped_and_continued_lines_and_stop_at_the_next_message() {
        let cases: [(&str, &[&str]); 4] = [
            (
                "LaTeX Warning: First\n\
                 Package x Warning: Second\n\
                 ! Undefined control sequence.\n",
                &[
                    "warning -:- First",
                    "warning -:- Second",
                    "error -:- Undefined control sequence.",
                ],
            ),
            (
                "LaTeX Warning: Reference `abcdefghijklmnopqrstuvwxyz' on page 1 undefined on in\n\
                 put line 3.\n\
                 \n\
                 ./main.tex:9: Missing number, treated as zero.\n\
                 l.9 x\n",
                &[
                    "warning main.tex:3 Reference `abcdefghijklmnopqrstuvwxyz' on page 1 undefined on input line 3.",
                    "error main.tex:9 Missing number, treated as zero.",
                ],
            ),
            (
                "LaTeX Warning: You have requested package `a',\n\
                 \x20              but the package provides `b'.\n\
                 Some other output on input line 5.\n\
                 (y) not this warning's.\n",
                &["warning -:- You have requested package `a', but the package provides `b'."],
            ),
            // A line of exactly 79 columns is a line, not a wrap, when the
            // next is the package's own "(name)" line.
            (
                "Package microtype Warning: Unknown slot number of character 12 in font encoding\n\
                 (microtype)                removing it on input line 44.\n",
                &[
                    "warning main.tex:44 Unknown slot number of character 12 in font encoding removing it on input line 44.",
                ],
            ),
        ];
        for (log, expected) in cases {
            assert_eq!(parsed(log), expected, "{log}");
        }
        let line =
            "Package microtype Warning: Unknown slot number of character 12 in font encoding";
        assert_eq!(line.chars().count(), 79);
    }

    const NESTED: &str = include_str!("../tests/logs/pdflatex-nested.txt");
    const FONTSPEC: &str = include_str!("../tests/logs/xelatex-fontspec-error.txt");
    const LUALATEX: &str = include_str!("../tests/logs/lualatex-warnings.txt");

    #[test]
    fn a_pdftex_log_with_nested_files_gives_each_item_its_file_and_line() {
        let hyperref = "Token not allowed in a PDF string (Unicode): removing";
        assert_eq!(
            parsed(NESTED),
            [
                format!("warning main.tex:5 {hyperref} `math shift' on input line 5."),
                format!("warning main.tex:5 {hyperref} `superscript' on input line 5."),
                "warning chapters/intro.tex:2 Reference `fig:nope' on page 1 undefined on input line 2.".into(),
                "warning chapters/intro.tex:2 Citation `missing' on page 1 undefined on input line 2.".into(),
                "error chapters/deep.tex:2 Undefined control sequence: \\undefinedmacroindeep".into(),
                "warning main.tex:7 First line of the warning second line of the warning third line of the warning and a fourth, which ends it on input line 7.".into(),
                "error data.dat:2 Undefined control sequence: \\nosuchdatacommand".into(),
                "warning -:- There were undefined references.".into(),
            ]
        );
    }

    #[test]
    fn bad_boxes_are_kept_apart_from_the_issues_at_their_first_line() {
        let log = format!(
            "{NESTED}\n(./chapters/intro.tex\n\
             Underfull \\hbox (badness 10000) in paragraph at lines 12--14\n\
             []\\OT1/cmr/m/n/10 x\n\
             \n\
             Overfull \\vbox (3.0pt too high) has occurred while \\output is active\n\
             \n)"
        );
        let (items, bad_boxes) = parse_log(&log, "main.tex");
        assert_eq!(described(&items), parsed(NESTED));
        assert_eq!(
            described(&bad_boxes),
            [
                "warning main.tex:8 Overfull \\hbox (216.66702pt too wide) detected at line 8",
                "warning chapters/intro.tex:12 Underfull \\hbox (badness 10000) in paragraph at lines 12--14",
                "warning -:- Overfull \\vbox (3.0pt too high) has occurred while \\output is active",
            ]
        );
    }

    #[test]
    fn crlf_logs_parse_like_lf_logs() {
        for log in [NESTED, FONTSPEC, LUALATEX] {
            assert_eq!(parsed(&log.replace('\n', "\r\n")), parsed(log));
        }
    }

    #[test]
    fn a_missing_font_in_xetex_gives_one_error_with_the_whole_message() {
        let (items, _) = parse_log(FONTSPEC, "main.tex");
        let errors: Vec<_> = items
            .iter()
            .filter(|it| it.kind == Severity::Error)
            .collect();
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(
            errors[1]
                .message
                .ends_with("Metric (TFM) file or installed font not found.")
        );
        let error = errors[0];
        assert_eq!(
            (error.file.as_deref(), error.line),
            (Some("main.tex"), Some(4))
        );
        let (start, end) = (
            "Package fontspec Error: The font \"NoSuchFontAnywhere\" cannot be found;",
            "bug in the underlying font loading engine (XeTeX/luaotfload).",
        );
        assert!(error.short.starts_with(start) && error.short.ends_with(end));
        assert!(!error.message.contains("Could not resolve") && !error.message.contains("l.4"));
    }

    #[test]
    fn a_luatex_log_keeps_its_long_warning_and_the_error_after_it() {
        assert_eq!(
            parsed(LUALATEX),
            [
                "warning -:- Unknown language 'latin'. Hyphenation patterns for 'english' will be used instead. With LuaTeX, lipsum requires babel to get proper hyphenation (you can use \\usepackage[base]{babel}).",
                "warning main.tex:7 Reference `sec:nowhere' on page 1 undefined on input line 7.",
                "error main.tex:8 Undefined control sequence: \\undefinedinlua",
                "warning -:- There were undefined references.",
            ]
        );
    }

    #[test]
    fn bibliography_and_latexmk_failures_are_read_from_their_own_output() {
        let blg = "Database file #1: refs.bib\n\
                   I was expecting a `,' or a `}'---line 7 of file refs.bib\n\
                   \x20:   author = {Nobody},\n\
                   I'm skipping whatever remains of this entry\n\
                   Warning--empty author in broken\n\
                   Warning--I'm ignoring knuth's extra \"year\" field\n\
                   --line 12 of file refs.bib\n\
                   I couldn't open database file .bib\n---line 5 of file main.aux\n\
                   [812] Utils.pm:465> ERROR - BibTeX subsystem: syntax error\n\
                   [813] Biber.pm:131> WARN - Duplicate entry key 'x' in file 'refs.bib'\n";
        assert_eq!(
            described(&parse_blg(blg)),
            [
                "error refs.bib:7 I was expecting a `,' or a `}'",
                "warning -:- empty author in broken",
                "warning refs.bib:12 I'm ignoring knuth's extra \"year\" field",
                "error main.aux:5 I couldn't open database file .bib",
                "error -:- BibTeX subsystem: syntax error",
                "warning -:- Duplicate entry key 'x' in file 'refs.bib'",
            ]
        );
        let output = "Latexmk: All targets (build/main.pdf) are up-to-date\n\
                      Collected error summary (may duplicate other messages):\n\
                      \x20 biber build/main: Could not open biber log file 'build/main.blg'\n\
                      \x20   detail\n";
        assert_eq!(
            described(&latexmk_errors(output)),
            ["error -:- biber build/main: Could not open biber log file 'build/main.blg'"]
        );
    }
}
