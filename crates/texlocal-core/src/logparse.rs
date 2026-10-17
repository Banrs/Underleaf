//! latexmk/TeX log parsing.
//! We compile with -file-line-error, so errors look like:
//!   ./main.tex:12: Undefined control sequence.
//! Warnings look like:
//!   LaTeX Warning: Reference `fig:x' on page 1 undefined on input line 10.
//! and name no file: the file is the one TeX has open, which the log marks
//! with "(./chapters/intro.tex" as it opens it and ")" as it closes it.

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Hash)]
pub struct LogItem {
    #[serde(rename = "type")]
    pub kind: &'static str, // "error" | "warning"
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
    fn new(kind: &'static str, file: Option<String>, line: Option<u32>, message: String) -> Self {
        let mut short = message.split_whitespace().collect::<Vec<_>>().join(" ");
        if short.starts_with("LaTeX Error: ") {
            short.drain(.."LaTeX Error: ".len());
        }
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
        Self::new("error", None, None, message.into())
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

// An error's place: sources, and the files LaTeX writes and reads back (.aux,
// .toc, .bbl …), where a fragile command or a bibliography entry raises it.
// The prefixes of lines are matched, not captured, as capturing costs most of
// a long log's parse.
static PLACE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?i:.+?\.(?:tex|ltx|sty|cls|bib|bbl|aux|toc|lof|lot|out|ind|nav|snm|def|clo|cfg|fd|tikz|pgf)):\d+:\s*").unwrap()
});
static L_NO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^l\.\d+").unwrap());
static LAST_CS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\\(?:[A-Za-z@]+|.))\s*$").unwrap());
static WARNING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:LaTeX(?: Font| NFSS)?|Package \S+|Class \S+) Warning:\s*").unwrap()
});
static ON_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"on input line \d+").unwrap());
static BIBTEX_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.*)---line (\d+) of file (.+)$").unwrap());
static BIBER_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[\d+\] .*> ERROR - (.*)$").unwrap());

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

/// Follow the files TeX opens and closes on a line. Each "(" pushes the path
/// it opens, or None for a parenthesis in text, and each ")" pops.
fn track<'a>(open: &mut Vec<Option<&'a str>>, line: &'a str) {
    let mut rest = line;
    while let Some(i) = memchr::memchr2(b'(', b')', rest.as_bytes()) {
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
        open.push(token.contains('/').then_some(token));
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

/// Join after TeX's 79-column wrap (bytes in pdfTeX, characters in the
/// Unicode engines) without a space; otherwise separate lines and drop an
/// indented package "(name)" prefix.
fn append(message: &mut String, prev: &str, next: &str) {
    if prev.len() == 79 || prev.chars().count() == 79 {
        message.push_str(next);
        return;
    }
    let next = next.trim_start();
    let next = next
        .strip_prefix('(')
        .and_then(|rest| rest.split_once(')'))
        .map_or(next, |(_, rest)| rest);
    message.push(' ');
    message.push_str(next.trim());
}

pub(crate) fn parse_log(log: &str, main_file: &str) -> Vec<LogItem> {
    let lines: Vec<&str> = log.lines().collect();
    let blank_from = |from: usize| {
        (from..lines.len())
            .find(|&j| lines[j].trim().is_empty())
            .unwrap_or(lines.len())
    };
    let mut items = Vec::new();
    let mut open = Vec::new();
    let mut had_error = false;
    // Lines before this one echo source or a box's contents, whose
    // parentheses needn't pair up, so they aren't tracked.
    let mut quiet_until = 0;

    for (i, &line) in lines.iter().enumerate() {
        // Most lines of a long log are neither: an error names its file and
        // line with colons or starts "! ", and a warning says so.
        let place = line.contains(':').then(|| PLACE.find(line)).flatten();
        let (error, named, rest) = if let Some(m) = place {
            let place = m.as_str().trim_end().strip_suffix(':').unwrap();
            (true, place.rsplit_once(':'), &line[m.end()..])
        } else if let Some(rest) = line.strip_prefix("! ") {
            (true, None, rest)
        } else if line.contains(" Warning:")
            && let Some(m) = WARNING.find(line)
        {
            (false, None, &line[m.end()..])
        } else {
            if line.starts_with("Overfull \\") || line.starts_with("Underfull \\") {
                // The box's contents follow, up to a blank line.
                quiet_until = blank_from(i + 1);
            } else if i >= quiet_until {
                track(&mut open, line);
            }
            continue;
        };
        let mut message = rest.to_string();
        // The source echo, short of the next error's.
        let echo = error
            .then(|| {
                lines[i + 1..(i + 12).min(lines.len())]
                    .iter()
                    .take_while(|next| !next.starts_with('!') && !PLACE.is_match(next))
                    .position(|next| L_NO.is_match(next))
                    .map(|k| i + 1 + k)
            })
            .flatten();
        if error {
            quiet_until = echo.map_or_else(|| blank_from(i + 1), |j| j + 2);
        }
        let continuation = match (named, error) {
            (Some(_), _) => 3,
            (None, true) => 0,
            (None, false) => 2,
        };
        let mut prev = line;
        for &next in lines[i + 1..].iter().take(continuation) {
            let ends = if error {
                next.starts_with('<') || L_NO.is_match(next)
            } else {
                next.contains("Warning") || next.contains("Error")
            };
            if ends || next.trim().is_empty() || next.starts_with('!') {
                break;
            }
            append(&mut message, prev, next);
            prev = next;
        }
        // A fatal summary repeats the stopping error; keep it only alone.
        let summary = error && message.trim_start().starts_with("==>");
        if summary && had_error {
            continue;
        }
        // TeX's context or source echo names the undefined command.
        if message
            .trim_start()
            .starts_with("Undefined control sequence.")
            && let Some(j) = echo
            && let Some(cs) = lines[i + 1..=j].iter().find_map(|l| LAST_CS.captures(l))
        {
            message = format!("Undefined control sequence: {}", &cs[1]);
        }
        let line_no = if !error {
            ON_LINE
                .find(&message)
                .map(|m| &m.as_str()["on input line ".len()..])
        } else if summary && named.is_some() {
            None
        } else {
            named
                .map(|(_, n)| n)
                .or_else(|| Some(&L_NO.find(lines[echo?])?.as_str()[2..]))
        };
        let line_no = line_no.and_then(|n| n.parse().ok());
        let named = named.map(|(file, _)| file);
        let (file, line_no) = locate(named, line_no, &open, main_file, &mut message);
        let kind = if error { "error" } else { "warning" };
        items.push(LogItem::new(
            kind,
            file,
            line_no,
            message.trim().to_string(),
        ));
        had_error |= error;
        if !error && i >= quiet_until {
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
pub(crate) fn parse_blg(blg: &str) -> Vec<LogItem> {
    let mut previous = "";
    blg.lines()
        .filter_map(|line| {
            let above = std::mem::replace(&mut previous, line);
            let Some(m) = BIBTEX_ERROR.captures(line) else {
                return BIBER_ERROR
                    .captures(line)
                    .map(|m| LogItem::error(m[1].trim()));
            };
            let file = project_path(m[3].trim());
            let message = if m[1].trim().is_empty() { above } else { &m[1] };
            let line = file.as_ref().and(m[2].parse().ok());
            Some(LogItem::new(
                "error",
                file,
                line,
                message.trim().to_string(),
            ))
        })
        .collect()
}

/// The steps latexmk's closing "Collected error summary" lists as failed,
/// one line each; more deeply indented lines add detail.
pub(crate) fn latexmk_errors(output: &str) -> Vec<LogItem> {
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
    use super::{LogItem, latexmk_errors, parse_blg, parse_log, project_path};

    /// Each item as "kind file:line message", `-` for no file or line.
    fn read(items: &[LogItem]) -> Vec<String> {
        let place = |it: &LogItem| {
            let line = it.line.map_or("-".into(), |l| l.to_string());
            format!("{}:{line}", it.file.as_deref().unwrap_or("-"))
        };
        let read = |it: &LogItem| format!("{} {} {}", it.kind, place(it), it.message);
        items.iter().map(read).collect()
    }

    #[test]
    fn a_log_reads_as_its_errors_and_warnings_in_place() {
        let fatal = "==> Fatal error occurred, no output PDF file produced!";
        let cases: &[(&str, &[&str])] = &[
            // A "!" error has no place, and doesn't take the next error's "l.<n>".
            (
                "! Emergency stop.\n./main.tex:12: Undefined control sequence.\nl.12 \\foo\n",
                &[
                    "error -:- Emergency stop.",
                    "error main.tex:12 Undefined control sequence: \\foo",
                ],
            ),
            // TeX's closing summary repeats the stopping error, so goes; alone,
            // it is the failure's one record, with no place.
            (
                &format!("./main.tex:12: Missing $.\nl.12 x\n\n./main.tex:12:  {fatal}\n"),
                &["error main.tex:12 Missing $."],
            ),
            (
                &format!("./main.tex:12:  {fatal}\n"),
                &[&format!("error -:- {fatal}")],
            ),
            (
                &format!("! Emergency stop.\n! {fatal}\n"),
                &["error -:- Emergency stop."],
            ),
            // TeX's context or source echo names an undefined command.
            (
                "./main.tex:19: Undefined control sequence.\n\
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
                 l.5 \\input{chapters/intro}\n",
                &[
                    "error main.tex:19 Undefined control sequence: \\undefinedmacro",
                    "error main.tex:21 Missing $ inserted.",
                    "error main.tex:24 Undefined control sequence: \\foo",
                    "error main.tex:5 Emergency stop.",
                ],
            ),
            // Reruns repeat messages: the first of each stays, in order.
            (
                "LaTeX Warning: A on input line 1.\n\n./a.tex:2: Boom.\n\n\
                 LaTeX Warning: A on input line 1.\n\nLaTeX Warning: A on input line 2.\n\n\
                 ./a.tex:2: Boom.\n",
                &[
                    "warning root.tex:1 A on input line 1.",
                    "error a.tex:2 Boom.",
                    "warning root.tex:2 A on input line 2.",
                ],
            ),
            // Errors in the files LaTeX writes and reads back.
            (
                &format!(
                    "(build/main.bbl\nbuild/main.bbl:5: Misplaced alignment tab character &.\n\
                     l.5 \\newblock Cats &\n\nbuild/main.bbl:5:  {fatal}\n"
                ),
                &["error build/main.bbl:5 Misplaced alignment tab character &."],
            ),
            // A warning takes the file TeX has open; parentheses in echoed source
            // and in an overfull box's contents don't pair up, so close none.
            (
                "(./main.tex\n\
                 (/usr/local/texlive/2026/texmf-dist/tex/latex/base/article.cls\n\
                 Document Class: article 2025/01/22 v1.4n Standard LaTeX document class\n\
                 )\n\
                 ./main.tex:4: Undefined control sequence.\n\
                 l.4 Hello \\foo\n\
                 \x20              world (unbalanced paren.\n\
                 \n\
                 (./chapters/intro.tex\n\
                 LaTeX Warning: Reference `nope' on page 1 undefined on input line 3.\n\
                 \n\
                 )\n\
                 Overfull \\hbox (182.7699pt too wide) detected at line 7\n\
                 \\OT1/cmr/m/n/10 Some very long text (that overflows\n\
                 \n\
                 LaTeX Warning: Reference `x' on page 1 undefined on input line 9.\n\
                 \n\
                 )\n\
                 LaTeX Warning: Unused global option(s) on input line 2.\n",
                &[
                    "error main.tex:4 Undefined control sequence: \\foo",
                    "warning chapters/intro.tex:3 Reference `nope' on page 1 undefined on input line 3.",
                    "warning main.tex:9 Reference `x' on page 1 undefined on input line 9.",
                    "warning root.tex:2 Unused global option(s) on input line 2.",
                ],
            ),
            // A place in a TeX distribution file goes to the file that loaded it,
            // without a line, the distribution file named in the message.
            (
                "(./main.tex\n\
                 (/usr/local/texlive/2026/texmf-dist/tex/latex/graphics/graphicx.sty\n\
                 /usr/local/texlive/2026/texmf-dist/tex/latex/graphics/graphicx.sty:27: Undefine\n\
                 d control sequence.\n\
                 l.27 \\foo\n",
                &["error main.tex:- graphicx.sty: Undefined control sequence: \\foo"],
            ),
            // Warnings run on over package-prefixed lines, without a space after
            // TeX's 79-column wrap, and stop at the next message.
            (
                "LaTeX Warning: First\nPackage x Warning: Second\n! Undefined control sequence.\n",
                &[
                    "warning -:- First",
                    "warning -:- Second",
                    "error -:- Undefined control sequence.",
                ],
            ),
            (
                "LaTeX Warning: Reference `abcdefghijklmnopqrstuvwxyz' on page 1 undefined on in\n\
                 put line 3.\n",
                &[
                    "warning root.tex:3 Reference `abcdefghijklmnopqrstuvwxyz' on page 1 undefined on input line 3.",
                ],
            ),
            (
                "LaTeX Font Warning: Font shape `OT1/nonexistentfam/m/n' undefined\n\
                 (Font)              using `OT1/cmr/m/n' instead on input line 3.\n",
                &[
                    "warning root.tex:3 Font shape `OT1/nonexistentfam/m/n' undefined using `OT1/cmr/m/n' instead on input line 3.",
                ],
            ),
            (
                "Package biblatex Warning: Please (re)run Biber on the file:\n\
                 (biblatex)                main\n\
                 (biblatex)                and rerun LaTeX afterwards.\n",
                &["warning -:- Please (re)run Biber on the file: main and rerun LaTeX afterwards."],
            ),
        ];
        for (log, expected) in cases {
            assert_eq!(read(&parse_log(log, "root.tex")), *expected, "{log}");
            // CRLF logs read as LF ones.
            let crlf = log.replace('\n', "\r\n");
            assert_eq!(parse_log(&crlf, "root.tex"), parse_log(log, "root.tex"));
        }
    }

    #[test]
    fn an_item_has_a_one_line_message_and_the_command_it_cannot_find() {
        let log = "./main.tex:3: LaTeX Error: Environment foo\n\
                   undefined.\n\
                   l.3 \\begin{foo}\n\
                   \n\
                   ./main.tex:4: Undefined control sequence.\n\
                   l.4 \\foo@x\n\
                   \n\
                   ./main.tex:5: Undefined control sequence.\n\
                   l.5 \\&\n\
                   (/tex/x.sty\n\
                   /tex/x.sty:7: Undefined control sequence.\n\
                   l.7 \\a\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(items[0].message, "LaTeX Error: Environment foo undefined.");
        assert_eq!(items[0].short, "Environment foo undefined.");
        // Not a name TeX reads, nor this project's command.
        let commands: Vec<_> = items.iter().map(|it| it.command.as_deref()).collect();
        assert_eq!(commands, [None, Some("\\foo@x"), Some("\\&"), None]);
    }

    #[test]
    fn bibliography_and_latexmk_failures_are_errors() {
        let blg = "Database file #1: refs.bib\n\
                   I was expecting a `,' or a `}'---line 1 of file refs.bib\n\
                   \x20: @article{a \n\
                   Warning--empty title in a\n\
                   [812] Utils.pm:465> ERROR - BibTeX subsystem: syntax error\n\
                   I couldn't open database file .bib\n\
                   ---line 5 of file main.aux\n\
                   Oops---line 2 of file /usr/share/x.bst\n";
        assert_eq!(
            read(&parse_blg(blg)),
            [
                "error refs.bib:1 I was expecting a `,' or a `}'",
                "error -:- BibTeX subsystem: syntax error",
                "error main.aux:5 I couldn't open database file .bib",
                "error -:- Oops",
            ]
        );
        let output = "Latexmk: Errors, so I did not complete making targets\n\
                      Collected error summary (may duplicate other messages):\n\
                      \x20 biber main: Could not find main.bcf\n\
                      \x20     Refer to 'build/main.log' for details\n\
                      Latexmk: done\n";
        assert_eq!(
            read(&latexmk_errors(output)),
            ["error -:- biber main: Could not find main.bcf"]
        );
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
}
