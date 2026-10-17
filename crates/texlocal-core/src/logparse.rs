//! latexmk/TeX log parsing.
//! We compile with -file-line-error, so errors look like:
//!   ./main.tex:12: Undefined control sequence.
//! Warnings look like:
//!   LaTeX Warning: Reference `fig:x' on page 1 undefined on input line 10.
//! and name no file: the file is the one TeX has open, which the log marks
//! with "(./chapters/intro.tex" as it opens it and ")" as it closes it.

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
    /// The command an "Undefined control sequence" names, with its backslash.
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
        let command = undefined_command(&short);
        Self {
            kind,
            file,
            line,
            message,
            short,
            command,
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
    // TeX's two forms of name: letters (and @), or one character of any other kind.
    let letters = name.chars().all(|c| c.is_ascii_alphabetic() || c == '@');
    ((!name.is_empty() && letters) || name.chars().count() == 1).then(|| format!("\\{name}"))
}

// What -file-line-error prints for an error in any file TeX reads (a source,
// a .bbl or .aux it wrote, a .cbx or .dat a package loads): `path:line: `. Or
// TeX's own `! `. A path is told from a message by its colon, digits and
// colon, so no list of file types is needed; `error_start` also asks that it
// is a path, which a time, "built at 12:30: …", is not.
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
static BIBTEX_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.*)---line (\d+) of file (.+)$").unwrap());
static BIBER_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[\d+\] .*> ERROR - (.*)$").unwrap());

/// An error's first line, `! message` or `path:line: message`.
fn error_start(line: &str) -> Option<Captures<'_>> {
    ERROR
        .captures(line)
        .filter(|m| m.name("file").is_none_or(|f| is_path(f.as_str())))
}

/// Whether the text before "12:" is a path and not words: it has a separator,
/// or a dot and no space. (TeX prints a file of the project's folder as
/// "./name", so one with a space in its name has a slash too.)
fn is_path(text: &str) -> bool {
    text.contains(['/', '\\']) || (text.contains('.') && !text.contains(char::is_whitespace))
}

/// A warning's first line.
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

/// Follow the files TeX opens and closes on a line. Each "(" pushes the path
/// it opens, or None for a parenthesis in text, and each ")" pops.
fn track<'a>(open: &mut Vec<Option<&'a str>>, line: &'a str) {
    let mut rest = line;
    while let Some(i) = rest.find(['(', ')']) {
        let paren = rest.as_bytes()[i];
        rest = &rest[i + 1..];
        if paren == b')' {
            open.pop();
            continue;
        }
        // A path with a space in it is quoted.
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

/// Prefer the named file, then the innermost open file, then the main file.
/// An absolute TeX distribution path uses any open project caller without a
/// line number, and prefixes the message with the distribution file's name.
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

/// The name a diagnostic's continuation lines carry in parentheses, from its
/// first line: "Package hyperref Warning:" goes on as "(hyperref) …", "LaTeX
/// Font Warning:" as "(Font) …", "LaTeX Warning:" as "(LaTeX) …".
fn continuation_tag(text: &str) -> Option<&str> {
    let mut words = text.split_whitespace();
    match (words.next()?, words.next()?) {
        ("Package" | "Class", name) => Some(name),
        ("LaTeX", "Font") => Some("Font"),
        ("LaTeX", word) if word.ends_with(':') => Some("LaTeX"),
        _ => None,
    }
}

/// A line that starts something of its own, which ends the message before it.
fn starts_new(line: &str) -> bool {
    line.trim().is_empty()
        || line.starts_with(['!', '<'])
        || L_NO.is_match(line)
        || error_start(line).is_some()
        || warning_start(line).is_some()
}

/// What `next` adds to a message whose last line was `prev`, and how it joins:
/// a line led by the diagnostic's own "(name)" (a package's message breaks
/// like that), or one indented under it (LaTeX's own). Or the rest of `prev`,
/// when an engine wrapped it at column 79 (it does not with max_print_line
/// set, but a distribution that ignores that does).
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

/// The first blank line from `from`, or the end.
fn blank_from(lines: &[&str], from: usize) -> usize {
    (from..lines.len())
        .find(|&j| lines[j].trim().is_empty())
        .unwrap_or(lines.len())
}

/// The line of the "l.<n>" echo of the error at `lines[i]`, if it has one
/// before the next error.
fn echo_of(lines: &[&str], i: usize) -> Option<usize> {
    lines[i + 1..(i + 12).min(lines.len())]
        .iter()
        .take_while(|next| !next.starts_with('!') && error_start(next).is_none())
        .position(|next| L_NO.is_match(next))
        .map(|k| i + 1 + k)
}

pub fn parse_log(log: &str, main_file: &str) -> Vec<LogItem> {
    let lines: Vec<&str> = log.lines().collect();
    let mut items: Vec<LogItem> = Vec::new();
    let mut open = Vec::new();
    // Lines before this one echo source or a box's contents, whose
    // parentheses needn't pair up, so they aren't tracked.
    let mut quiet_until = 0;

    for (i, &line) in lines.iter().enumerate() {
        // Skip both regexes for most lines of a long log: an error starts
        // "! " or names its file and line with colons.
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
                    // A package's first line may end in a space of its own.
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
            // TeX's context or source echo names the undefined command.
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
            // The box's contents follow, up to a blank line.
            quiet_until = blank_from(&lines, i + 1);
        }
        if i >= quiet_until {
            track(&mut open, line);
        }
    }

    // Reruns duplicate messages; keep the first in order.
    let mut seen = HashSet::with_capacity(items.len());
    let keep: Vec<bool> = items.iter().map(|item| seen.insert(item)).collect();
    let mut keep = keep.into_iter();
    items.retain(|_| keep.next().unwrap());
    items
}

/// Errors from bibtex's or biber's own log (.blg). A bibtex error names the
/// .bib line, after its message or on the line below it; biber's name none a
/// user can open.
pub fn parse_blg(blg: &str) -> Vec<LogItem> {
    let mut previous = "";
    blg.lines()
        .filter_map(|line| {
            let above = std::mem::replace(&mut previous, line);
            if let Some(m) = BIBTEX_ERROR.captures(line) {
                let file = project_path(m[3].trim());
                let message = if m[1].trim().is_empty() { above } else { &m[1] };
                Some(LogItem::new(
                    Severity::Error,
                    file.clone(),
                    file.and(m[2].parse().ok()),
                    message.trim().to_string(),
                ))
            } else {
                BIBER_ERROR
                    .captures(line)
                    .map(|m| LogItem::error(m[1].trim()))
            }
        })
        .collect()
}

/// The steps latexmk's closing "Collected error summary" lists as failed,
/// one line each; more deeply indented lines add detail.
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
    use super::{
        LogItem, Severity, latexmk_errors, parse_blg, parse_log, project_path, undefined_command,
    };

    /// Each item's file and line.
    fn places(items: &[LogItem]) -> Vec<(Option<&str>, Option<u32>)> {
        items
            .iter()
            .map(|it| (it.file.as_deref(), it.line))
            .collect()
    }

    #[test]
    fn an_error_without_its_own_line_names_no_place() {
        let error = "./main.tex:12: Undefined control sequence.\nl.12 \\foo\n";
        let fatal = "==> Fatal error occurred, no output PDF file produced!";
        let cases: [(String, &[_]); 4] = [
            // A "!" error doesn't take the next error's "l.<n>".
            (
                format!("! Emergency stop.\n{error}"),
                &[(None, None), (Some("main.tex"), Some(12))],
            ),
            // TeX's closing summary names the stopping error's line, not its
            // own, and folds into the error before it.
            (
                format!("{error}\n./main.tex:12:  {fatal}\n"),
                &[(Some("main.tex"), Some(12))],
            ),
            // Alone, it is the failure's one record, with no place.
            (format!("./main.tex:12:  {fatal}\n"), &[(None, None)]),
            (format!("! Emergency stop.\n! {fatal}\n"), &[(None, None)]),
        ];
        for (log, expected) in cases {
            assert_eq!(places(&parse_log(&log, "main.tex")), expected, "{log}");
        }
    }

    #[test]
    fn crlf_logs_parse_like_lf_logs() {
        let lf = "./main.tex:3: Undefined control sequence.\n\
                  <recently read> \\foo\n\
                  l.3 \\foo\n\
                  \n\
                  ! Emergency stop.\n\
                  l.9 \\end\n\
                  Package hyperref Warning: Token not allowed\n\
                  (hyperref) removing `math shift' on input line 44.\n";
        let crlf = lf.replace('\n', "\r\n");
        let items = parse_log(&crlf, "main.tex");
        assert_eq!(items, parse_log(lf, "main.tex"));
        // The log's ./main.tex, without its ./
        assert_eq!(items[0].file.as_deref(), Some("main.tex"));
        assert_eq!(items[0].message, "Undefined control sequence: \\foo");
        assert_eq!(items[1].message, "Emergency stop.");
        assert_eq!(items[1].line, Some(9));
        assert_eq!(items[2].line, Some(44));
    }

    #[test]
    fn messages_name_the_undefined_control_sequence_without_tex_context() {
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
                   \\x ->\\foo\n\
                   \x20        \n\
                   l.24 \\x\n\
                   \n\
                   ./main.tex:5: Emergency stop.\n\
                   <read *> \n\
                   \x20        \n\
                   l.5 \\input{chapters/intro}\n";
        let messages: Vec<_> = parse_log(log, "main.tex")
            .into_iter()
            .map(|it| it.message)
            .collect();
        assert_eq!(
            messages,
            [
                "Undefined control sequence: \\undefinedmacro",
                "Missing $ inserted.",
                "Undefined control sequence: \\foo",
                "Emergency stop.",
            ]
        );
    }

    #[test]
    fn an_item_has_a_one_line_message_and_the_command_it_cannot_find() {
        let log = "./main.tex:3: LaTeX Error: Command \\a already defined.\n\
                   \x20              Or name \\end... illegal, see p.192 of the manual.\n\
                   \n\
                   See the LaTeX manual or LaTeX Companion for explanation.\n\
                   l.3 \\newcommand\\a{y}\n\
                   \n\
                   ./main.tex:4: Undefined control sequence.\n\
                   l.4 \\foo@x\n\
                   \n\
                   ./main.tex:5: Undefined control sequence.\n\
                   l.5 \\&\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(
            items[0].short,
            "Command \\a already defined. Or name \\end... illegal, see p.192 of the manual."
        );
        assert_eq!(items[0].command, None);
        let commands: Vec<_> = items[1..].iter().map(|it| it.command.as_deref()).collect();
        assert_eq!(commands, [Some("\\foo@x"), Some("\\&")]);
        // The name of a file TeX loaded comes first in its message: not this file's command.
        for message in [
            "x.sty: Undefined control sequence: \\a",
            "Undefined control sequence: \\ab-c",
        ] {
            assert_eq!(undefined_command(message), None, "{message}");
        }
    }

    #[test]
    fn duplicates_collapse_to_the_first_and_order_is_kept() {
        let log = "LaTeX Warning: A on input line 1.\n\
                   \n\
                   ./a.tex:2: Boom.\n\
                   \n\
                   LaTeX Warning: A on input line 1.\n\
                   \n\
                   LaTeX Warning: A on input line 2.\n\
                   \n\
                   ./a.tex:2: Boom.\n";
        let summary: Vec<_> = parse_log(log, "main.tex")
            .into_iter()
            .map(|it| (it.kind, it.line, it.message))
            .collect();
        assert_eq!(
            summary,
            [
                (Severity::Warning, Some(1), "A on input line 1.".to_string()),
                (Severity::Error, Some(2), "Boom.".to_string()),
                (Severity::Warning, Some(2), "A on input line 2.".to_string()),
            ]
        );
    }

    #[test]
    fn severity_is_error_or_warning_on_the_wire() {
        let item = LogItem::error("Boom.");
        assert_eq!(serde_json::to_value(&item).unwrap()["type"], "error");
        let warning = parse_log("LaTeX Warning: A on input line 1.\n", "main.tex");
        assert_eq!(
            serde_json::to_value(&warning[0]).unwrap()["type"],
            "warning"
        );
    }

    #[test]
    fn errors_in_generated_files_are_reported() {
        let log = "(build/main.bbl\n\
                   build/main.bbl:5: Misplaced alignment tab character &.\n\
                   l.5 \\newblock Cats &\n\
                   \n\
                   build/main.bbl:5:  ==> Fatal error occurred, no output PDF file produced!\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(places(&items), [(Some("build/main.bbl"), Some(5))]);
        assert_eq!(items[0].message, "Misplaced alignment tab character &.");
    }

    #[test]
    fn an_error_in_a_file_of_any_type_is_reported_and_a_time_is_not_an_error() {
        let log = "(./refs/my.cbx\n\
                   ./refs/my.cbx:12: Package biblatex Error: Bad style.\n\
                   l.12 \\x\n\
                   \n\
                   ./data.dat:2: Undefined control sequence.\n\
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
                   build at 10:30: no file here\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(
            places(&items),
            [
                (Some("refs/my.cbx"), Some(12)),
                (Some("data.dat"), Some(2)),
                (Some("My Chapter.tex"), Some(3)),
                // A distribution path: the project file that has it open, and no line.
                (Some("refs/my.cbx"), None),
            ]
        );
        assert_eq!(items[0].message, "Package biblatex Error: Bad style.");
        assert_eq!(items[3].message, "a.lbx: Boom.");
    }

    #[test]
    fn a_message_takes_the_file_tex_has_open() {
        // Parentheses in the echoed source and in an overfull box's contents
        // don't pair up, and mustn't close a file.
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
                   \x20)\n";
        assert_eq!(
            places(&parse_log(log, "other.tex")),
            [
                (Some("main.tex"), Some(4)),
                (Some("chapters/intro.tex"), Some(3)),
                (Some("main.tex"), Some(9)),
            ]
        );
    }

    #[test]
    fn a_windows_path_opens_a_file_and_a_command_in_parentheses_does_not() {
        let log = "(C:\\Users\\Alex\\AppData\\MiKTeX\\tex/latex/base\\article.cls\n\
                   (\\end occurred inside a group at level 1)\n\
                   (\\\\server\\share\\x.sty\n\
                   )\n\
                   )\n\
                   (./chapters/a.tex\n\
                   \n\
                   LaTeX Warning: Reference `x' on page 1 undefined on input line 3.\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(places(&items), [(Some("chapters/a.tex"), Some(3))]);
    }

    #[test]
    fn a_place_in_a_tex_distribution_file_goes_to_the_file_that_loaded_it() {
        let log = "(./main.tex\n\
                   (/usr/local/texlive/2026/texmf-dist/tex/latex/graphics/graphicx.sty\n\
                   /usr/local/texlive/2026/texmf-dist/tex/latex/graphics/graphicx.sty:27: Undefine\n\
                   d control sequence.\n\
                   l.27 \\foo\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(places(&items), [(Some("main.tex"), None)]);
        assert_eq!(
            items[0].message,
            "graphicx.sty: Undefined control sequence: \\foo"
        );
    }

    #[test]
    fn warnings_run_on_over_wrapped_and_continued_lines_and_stop_at_the_next_message() {
        // The log, the line of its first item, and each item's kind and message.
        type Case<'a> = (&'a str, Option<u32>, &'a [(Severity, &'a str)]);
        use Severity::{Error, Warning};
        let cases: [Case; 8] = [
            (
                "LaTeX Warning: First\n\
                 Package x Warning: Second\n\
                 ! Undefined control sequence.\n",
                None,
                &[
                    (Warning, "First"),
                    (Warning, "Second"),
                    (Error, "Undefined control sequence."),
                ],
            ),
            // A line wrapped at 79 columns runs on without a space.
            (
                "LaTeX Warning: Reference `abcdefghijklmnopqrstuvwxyz' on page 1 undefined on in\n\
                 put line 3.\n\
                 \n\
                 ./main.tex:9: Missing number, treated as zero.\n\
                 l.9 x\n",
                Some(3),
                &[
                    (
                        Warning,
                        "Reference `abcdefghijklmnopqrstuvwxyz' on page 1 undefined on input line 3.",
                    ),
                    (Error, "Missing number, treated as zero."),
                ],
            ),
            // A line that wasn't wrapped still gets a space.
            (
                "Package x Warning: First\n(x)                second on input line 2.\n",
                Some(2),
                &[(Warning, "First second on input line 2.")],
            ),
            (
                "LaTeX Font Warning: Font shape `OT1/nonexistentfam/m/n' undefined\n\
                 (Font)              using `OT1/cmr/m/n' instead on input line 3.\n",
                Some(3),
                &[(
                    Warning,
                    "Font shape `OT1/nonexistentfam/m/n' undefined using `OT1/cmr/m/n' instead on input line 3.",
                )],
            ),
            (
                "Package biblatex Warning: Please (re)run Biber on the file:\n\
                 (biblatex)                main\n\
                 (biblatex)                and rerun LaTeX afterwards.\n",
                None,
                &[(
                    Warning,
                    "Please (re)run Biber on the file: main and rerun LaTeX afterwards.",
                )],
            ),
            // However many lines the package breaks it into, down to its place.
            (
                "Package x Warning: One\n(x) two\n(x) three\n(x) four\n(x) five\n(x) six on input line 8.\n",
                Some(8),
                &[(Warning, "One two three four five six on input line 8.")],
            ),
            // LaTeX's own continuation is indented, and a line that is neither
            // that nor the warning's own is not part of it.
            (
                "LaTeX Warning: You have requested package `a',\n\
                 \x20              but the package provides `b'.\n\
                 Some other output on input line 5.\n\
                 (y) not this warning's.\n",
                None,
                &[(
                    Warning,
                    "You have requested package `a', but the package provides `b'.",
                )],
            ),
            // A line of exactly 79 columns is a line, not a wrap, when the
            // next is the package's own "(name)" line.
            (
                "Package microtype Warning: Unknown slot number of character 12 in font encoding\n\
                 (microtype)                removing it on input line 44.\n",
                Some(44),
                &[(
                    Warning,
                    "Unknown slot number of character 12 in font encoding removing it on input line 44.",
                )],
            ),
        ];
        for (log, line, expected) in cases {
            let items = parse_log(log, "main.tex");
            let got: Vec<_> = items
                .iter()
                .map(|it| (it.kind, it.message.as_str()))
                .collect();
            assert_eq!(got, expected, "{log}");
            assert_eq!(items[0].line, line, "{log}");
        }
        // The 79-column line above really is 79 columns.
        assert_eq!(
            "Package microtype Warning: Unknown slot number of character 12 in font encoding"
                .chars()
                .count(),
            79
        );
    }

    #[test]
    fn bibliography_and_latexmk_failures_are_errors() {
        let blg = "Database file #1: refs.bib\n\
                   I was expecting a `,' or a `}'---line 1 of file refs.bib\n\
                   \x20: @article{a \n\
                   Warning--empty title in a\n\
                   [812] Utils.pm:465> ERROR - BibTeX subsystem: syntax error\n";
        let items = parse_blg(blg);
        assert_eq!(places(&items), [(Some("refs.bib"), Some(1)), (None, None)]);
        assert_eq!(items[0].message, "I was expecting a `,' or a `}'");
        assert_eq!(items[1].message, "BibTeX subsystem: syntax error");
        // A BibTeX error takes its message from the line above its place.
        let items = parse_blg("I couldn't open database file .bib\n---line 5 of file main.aux\n");
        assert_eq!(items[0].message, "I couldn't open database file .bib");
        assert_eq!(items[0].line, Some(5));

        let output = "Latexmk: Errors, so I did not complete making targets\n\
                      Collected error summary (may duplicate other messages):\n\
                      \x20 biber main: Could not find main.bcf\n\
                      \x20     Refer to 'build/main.log' for details\n\
                      Latexmk: done\n";
        let items = latexmk_errors(output);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].message, "biber main: Could not find main.bcf");
    }

    #[test]
    fn tex_distribution_paths_are_not_the_projects() {
        for (path, project) in [
            ("./main.tex", Some("main.tex")),
            ("chapters/a.tex", Some("chapters/a.tex")),
            ("/usr/local/texlive/a.sty", None),
            (
                "C:/texlive/2026/texmf-dist/tex/latex/base/article.cls",
                None,
            ),
            (r"c:\Program Files\MiKTeX\tex/latex/base\article.cls", None),
            (r"\\server\texmf\a.sty", None),
            // A file named like a drive is still the project's.
            ("c:a.tex", Some("c:a.tex")),
        ] {
            assert_eq!(project_path(path).as_deref(), project, "{path}");
        }
    }

    // Logs as the engines wrote them, built here with the arguments and
    // environment of a build (tests/logs/*): pdfTeX with nested \input files,
    // XeTeX failing on a missing font, LuaTeX, bibtex, and latexmk's own
    // account of a failed biber. The MiKTeX excerpt is written by hand from
    // its documented form, as no Windows machine was at hand.
    const NESTED: &str = include_str!("../tests/logs/pdflatex-nested.txt");
    const FONTSPEC: &str = include_str!("../tests/logs/xelatex-fontspec-error.txt");
    const LUALATEX: &str = include_str!("../tests/logs/lualatex-warnings.txt");
    const BIBTEX: &str = include_str!("../tests/logs/bibtex-syntax-error.txt");
    const BIBER_FAILED: &str = include_str!("../tests/logs/latexmk-biber-failed.txt");
    const MIKTEX: &str = include_str!("../tests/logs/miktex-handwritten.txt");

    /// Each item's kind, place and message, the shape the assertions below read.
    fn summary(items: &[LogItem]) -> Vec<(Severity, Option<&str>, Option<u32>, &str)> {
        items
            .iter()
            .map(|it| (it.kind, it.file.as_deref(), it.line, it.message.as_str()))
            .collect()
    }

    #[test]
    fn a_pdftex_log_with_nested_files_gives_each_item_its_file_and_line() {
        use Severity::{Error, Warning};
        let hyperref = "Token not allowed in a PDF string (Unicode): removing";
        let items = parse_log(NESTED, "main.tex");
        assert_eq!(
            summary(&items),
            [
                (
                    Warning,
                    Some("main.tex"),
                    Some(5),
                    &*format!("{hyperref} `math shift' on input line 5.")
                ),
                (
                    Warning,
                    Some("main.tex"),
                    Some(5),
                    &*format!("{hyperref} `superscript' on input line 5.")
                ),
                (
                    Warning,
                    Some("chapters/intro.tex"),
                    Some(2),
                    "Reference `fig:nope' on page 1 undefined on input line 2."
                ),
                (
                    Warning,
                    Some("chapters/intro.tex"),
                    Some(2),
                    "Citation `missing' on page 1 undefined on input line 2."
                ),
                (
                    Error,
                    Some("chapters/deep.tex"),
                    Some(2),
                    "Undefined control sequence: \\undefinedmacroindeep"
                ),
                // Four lines in the log, to its place at the end.
                (
                    Warning,
                    Some("main.tex"),
                    Some(7),
                    "First line of the warning second line of the warning third line of the warning and a fourth, which ends it on input line 7."
                ),
                (
                    Error,
                    Some("data.dat"),
                    Some(2),
                    "Undefined control sequence: \\nosuchdatacommand"
                ),
                (Warning, None, None, "There were undefined references."),
            ]
        );
    }

    #[test]
    fn a_missing_font_in_xetex_gives_one_error_with_the_whole_message() {
        let items = parse_log(FONTSPEC, "main.tex");
        let errors: Vec<_> = items
            .iter()
            .filter(|it| it.kind == Severity::Error)
            .collect();
        // The three copies of fontspec's collapse to one, and XeTeX's own follows.
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
        assert!(
            error.short.starts_with(
                "Package fontspec Error: The font \"NoSuchFontAnywhere\" cannot be found;"
            ),
            "{}",
            error.short
        );
        assert!(
            error
                .short
                .ends_with("bug in the underlying font loading engine (XeTeX/luaotfload)."),
            "{}",
            error.short
        );
        // The "Info" lines and the source echo are not part of it.
        assert!(
            !error.message.contains("Could not resolve"),
            "{}",
            error.message
        );
        assert!(!error.message.contains("l.4"), "{}", error.message);
    }

    #[test]
    fn a_luatex_log_keeps_its_long_warning_and_the_error_after_it() {
        use Severity::{Error, Warning};
        let items = parse_log(LUALATEX, "main.tex");
        assert_eq!(
            summary(&items),
            [
                (
                    Warning,
                    None,
                    None,
                    "Unknown language 'latin'. Hyphenation patterns for 'english' will be used instead. With LuaTeX, lipsum requires babel to get proper hyphenation (you can use \\usepackage[base]{babel})."
                ),
                (
                    Warning,
                    Some("main.tex"),
                    Some(7),
                    "Reference `sec:nowhere' on page 1 undefined on input line 7."
                ),
                (
                    Error,
                    Some("main.tex"),
                    Some(8),
                    "Undefined control sequence: \\undefinedinlua"
                ),
                (Warning, None, None, "There were undefined references."),
            ]
        );
    }

    #[test]
    fn bibtex_and_latexmk_failures_are_read_from_their_own_output() {
        let items = parse_blg(BIBTEX);
        assert_eq!(
            summary(&items),
            [(
                Severity::Error,
                Some("refs.bib"),
                Some(7),
                "I was expecting a `,' or a `}'"
            )]
        );
        // The biber on the machine could not start; latexmk's summary says so.
        let items = latexmk_errors(BIBER_FAILED);
        assert_eq!(
            summary(&items),
            [(
                Severity::Error,
                None,
                None,
                "biber build/main: Could not open biber log file 'build/main.blg'"
            )]
        );
    }

    #[test]
    fn a_miktex_log_with_backslash_paths_and_wrapped_lines_parses_as_a_tex_live_one() {
        use Severity::{Error, Warning};
        let items = parse_log(MIKTEX, "main.tex");
        assert_eq!(
            summary(&items),
            [
                (
                    Warning,
                    Some("chapters/intro.tex"),
                    Some(3),
                    "Reference `fig:nope' on page 1 undefined on input line 3."
                ),
                // In a distribution file: the project file that loaded it, no line.
                (
                    Error,
                    Some("chapters/intro.tex"),
                    None,
                    "graphicx.sty: Undefined control sequence: \\foo"
                ),
                (
                    Error,
                    Some("main.tex"),
                    Some(9),
                    "Undefined control sequence: \\bar"
                ),
                // While a distribution package was loading, with its wrapped line joined.
                (
                    Warning,
                    Some("main.tex"),
                    None,
                    "ulem.sty: A warning from an engine that wraps its log at column 79 and breaks a word in two on input line 12."
                ),
            ]
        );
    }
}
