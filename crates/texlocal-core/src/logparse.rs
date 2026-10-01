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

use crate::paths::is_absolute_like;

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Hash)]
pub struct LogItem {
    #[serde(rename = "type")]
    pub kind: &'static str, // "error" | "warning"
    pub file: Option<String>,
    pub line: Option<u32>,
    pub message: String,
}

impl LogItem {
    pub(crate) fn error(message: impl Into<String>) -> Self {
        Self {
            kind: "error",
            file: None,
            line: None,
            message: message.into(),
        }
    }
}

// Sources, and the files LaTeX writes and reads back (.aux, .toc, .bbl …),
// where a fragile command or a bibliography entry raises its error.
static FILE_LINE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(.+?\.(?:tex|ltx|sty|cls|bib|bbl|aux|toc|lof|lot|out|ind|nav|snm|def|clo|cfg|fd|tikz|pgf)):(\d+):\s*(.*)$").unwrap()
});
static L_NO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^l\.(\d+)").unwrap());
static LAST_CS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\\(?:[A-Za-z@]+|.))\s*$").unwrap());
static WARNING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(LaTeX(?: Font| NFSS)?|Package (\S+)|Class (\S+)) Warning:\s*(.*)$").unwrap()
});
static ON_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"on input line (\d+)").unwrap());
static BIBTEX_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.*)---line (\d+) of file (.+)$").unwrap());
static BIBER_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[\d+\] .*> ERROR - (.*)$").unwrap());

fn has_error(items: &[LogItem]) -> bool {
    items.iter().any(|item| item.kind == "error")
}

/// A forward-slash project path; None for an absolute TeX distribution path.
fn project_path(path: &str) -> Option<String> {
    (!is_absolute_like(path)).then(|| {
        path.strip_prefix("./")
            .or_else(|| path.strip_prefix(".\\"))
            .unwrap_or(path)
            .replace('\\', "/")
    })
}

/// Follow the files TeX opens and closes on a line. Each "(" pushes the path
/// it opens, or None for a parenthesis in text, and each ")" pops.
fn track(open: &mut Vec<Option<String>>, line: &str) {
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
        open.push(token.contains(['/', '\\']).then(|| token.to_string()));
        rest = after;
    }
}

/// Where a message at `line` points. `named` is the file it names, else it
/// is the innermost file open; a log that names no files is the main
/// file's. One of TeX's own files (a package), which the user can't open,
/// gives way to the project file that loaded it, with no line and the
/// package file's name before the message.
fn locate(
    named: Option<&str>,
    line: Option<u32>,
    open: &[Option<String>],
    main_file: &str,
    message: &mut String,
) -> (Option<String>, Option<u32>) {
    let Some(line) = line else {
        return (None, None);
    };
    let mut files = open.iter().rev().flatten().map(String::as_str);
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

/// Add the line after `prev` to a message. After a line TeX broke at its
/// default 79 columns (MiKTeX ignores max_print_line) it runs on mid-word;
/// otherwise it is a line of its own, which a package indents under its
/// "(name)".
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

/// The "l.<n>" line that echoes the source at the error on line `i`: its
/// own, not one that belongs to the next error, as a closing "==> Fatal
/// error occurred" would borrow.
fn echo_line(lines: &[&str], i: usize) -> Option<usize> {
    lines[(i + 1)..(i + 12).min(lines.len())]
        .iter()
        .take_while(|next| !next.starts_with('!') && !FILE_LINE.is_match(next))
        .position(|next| L_NO.is_match(next))
        .map(|k| i + 1 + k)
}

/// "Undefined control sequence." with the one TeX means: the last token of
/// the first context line from the error on line `i` to its echo that ends
/// in one ("<recently read> \foo", "\x ->\foo", the echo itself).
fn name_undefined(message: &mut String, lines: &[&str], i: usize, echo: Option<usize>) {
    let named = echo
        .filter(|_| message.starts_with("Undefined control sequence."))
        .and_then(|j| {
            lines[i + 1..=j]
                .iter()
                .find_map(|line| LAST_CS.captures(line))
        });
    if let Some(m) = named {
        *message = format!("Undefined control sequence: {}", &m[1]);
    }
}

/// The first blank line from `from`, or the end.
fn blank_from(lines: &[&str], from: usize) -> usize {
    (from..lines.len())
        .find(|&j| lines[j].trim().is_empty())
        .unwrap_or(lines.len())
}

pub fn parse_log(log: &str, main_file: &str) -> Vec<LogItem> {
    // lines(), not split('\n'): a Windows TeX log or latexmk's own output ends
    // lines with \r\n, and a kept \r would land mid-message when a
    // continuation line is appended.
    let lines: Vec<&str> = log.lines().collect();
    let mut items: Vec<LogItem> = Vec::new();
    let mut open: Vec<Option<String>> = Vec::new();
    // Lines before this one echo source or a box's contents, whose
    // parentheses needn't pair up, so they aren't tracked.
    let mut quiet_until = 0;

    for (i, &line) in lines.iter().enumerate() {
        if let Some(m) = FILE_LINE.captures(line) {
            // Error detail often continues on following lines, up to TeX's
            // context ("<inserted text>", "<read *>") or the "l.<n>" echo.
            let mut message = m[3].to_string();
            let mut prev = line;
            for next in &lines[(i + 1)..(i + 4).min(lines.len())] {
                if next.trim().is_empty() || next.starts_with(['!', '<']) || L_NO.is_match(next) {
                    break;
                }
                append(&mut message, prev, next);
                prev = next;
            }
            let echo = echo_line(&lines, i);
            quiet_until = echo.map_or_else(|| blank_from(&lines, i + 1), |j| j + 2);
            // TeX's closing "==> Fatal error occurred" takes the place of
            // the error that stopped it: that error names the place, and
            // the summary names none of its own. After that error it is
            // left out, so one mistake counts as one error.
            let summary = message.trim_start().starts_with("==>");
            if summary && has_error(&items) {
                continue;
            }
            name_undefined(&mut message, &lines, i, echo);
            let line_no = (!summary).then(|| m[2].parse().ok()).flatten();
            let (file, line_no) = locate(Some(&m[1]), line_no, &open, main_file, &mut message);
            items.push(LogItem {
                kind: "error",
                file,
                line: line_no,
                message: message.trim().to_string(),
            });
        } else if let Some(message) = line.strip_prefix("! ") {
            let echo = echo_line(&lines, i);
            quiet_until = echo.map_or_else(|| blank_from(&lines, i + 1), |j| j + 2);
            if message.trim_start().starts_with("==>") && has_error(&items) {
                continue;
            }
            let line_no = echo
                .and_then(|j| L_NO.captures(lines[j]))
                .and_then(|lm| lm[1].parse().ok());
            let mut message = message.trim().to_string();
            name_undefined(&mut message, &lines, i, echo);
            let (file, line_no) = locate(None, line_no, &open, main_file, &mut message);
            items.push(LogItem {
                kind: "error",
                file,
                line: line_no,
                message,
            });
        // The substring test first: most lines of a long log are neither
        // kind, and it costs far less than a regex call per line.
        } else if let Some(m) = line
            .contains(" Warning:")
            .then(|| WARNING.captures(line))
            .flatten()
        {
            let mut message = m[4].to_string();
            let mut prev = line;
            for next in &lines[(i + 1)..(i + 3).min(lines.len())] {
                if next.trim().is_empty()
                    || next.starts_with('!')
                    || next.contains("Warning")
                    || next.contains("Error")
                {
                    break;
                }
                append(&mut message, prev, next);
                prev = next;
            }
            let line_no = ON_LINE.captures(&message).and_then(|lm| lm[1].parse().ok());
            let (file, line_no) = locate(None, line_no, &open, main_file, &mut message);
            items.push(LogItem {
                kind: "warning",
                file,
                line: line_no,
                message: message.trim().to_string(),
            });
        } else if line.starts_with("Overfull \\") || line.starts_with("Underfull \\") {
            // The box's contents follow, up to a blank line.
            quiet_until = blank_from(&lines, i + 1);
        }
        if i >= quiet_until {
            track(&mut open, line);
        }
    }

    // De-duplicate repeated messages (reruns produce copies), keeping the
    // first of each in order.
    let keep: Vec<bool> = {
        let mut seen = HashSet::with_capacity(items.len());
        items.iter().map(|item| seen.insert(item)).collect()
    };
    let mut keep = keep.into_iter();
    items.retain(|_| keep.next().unwrap_or(false));
    items
}

/// Errors from bibtex's or biber's own log (.blg). A bibtex error names the
/// .bib line; biber's name none a user can open.
pub fn parse_blg(blg: &str) -> Vec<LogItem> {
    blg.lines()
        .filter_map(|line| {
            if let Some(m) = BIBTEX_ERROR.captures(line) {
                let file = project_path(m[3].trim());
                Some(LogItem {
                    kind: "error",
                    line: file.as_ref().and(m[2].parse().ok()),
                    file,
                    message: m[1].trim().to_string(),
                })
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
    use super::{latexmk_errors, parse_blg, parse_log, project_path};

    #[test]
    fn an_error_without_its_own_line_names_no_place() {
        // A "!" error doesn't take the next error's "l.<n>".
        let log = "! Emergency stop.\n\
                   ./main.tex:12: Undefined control sequence.\n\
                   l.12 \\foo\n";
        let items = parse_log(log, "main.tex");
        assert_eq!((items[0].file.as_deref(), items[0].line), (None, None));
        assert_eq!(items[1].line, Some(12));
        // TeX's closing summary names the stopping error's line, not its own.
        let log = "./main.tex:12: Undefined control sequence.\n\
                   l.12 \\foo\n\
                   \n\
                   ./main.tex:12:  ==> Fatal error occurred, no output PDF file produced!\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(items.len(), 1, "the summary folds into the error before it");
        assert_eq!(items[0].line, Some(12));
        // Alone, it is the failure's one record, with no place.
        let items = parse_log(
            "./main.tex:12:  ==> Fatal error occurred, no output PDF file produced!\n",
            "main.tex",
        );
        assert_eq!(items.len(), 1);
        assert_eq!((items[0].file.as_deref(), items[0].line), (None, None));
        let items = parse_log(
            "! Emergency stop.\n! ==> Fatal error occurred, no output PDF file produced!\n",
            "main.tex",
        );
        assert_eq!(items.len(), 1);
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
                ("warning", Some(1), "A on input line 1.".to_string()),
                ("error", Some(2), "Boom.".to_string()),
                ("warning", Some(2), "A on input line 2.".to_string()),
            ]
        );
    }

    #[test]
    fn a_warning_stops_at_the_next_message() {
        let log = "LaTeX Warning: First\n\
                   Package x Warning: Second\n\
                   ! Undefined control sequence.\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(items[0].message, "First");
        assert_eq!(items[1].message, "Second");
        assert_eq!(items[2].kind, "error");
    }

    #[test]
    fn errors_in_generated_files_are_reported() {
        let log = "(build/main.bbl\n\
                   build/main.bbl:5: Misplaced alignment tab character &.\n\
                   l.5 \\newblock Cats &\n\
                   \n\
                   build/main.bbl:5:  ==> Fatal error occurred, no output PDF file produced!\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].file.as_deref(), Some("build/main.bbl"));
        assert_eq!(items[0].line, Some(5));
        assert_eq!(items[0].message, "Misplaced alignment tab character &.");
    }

    #[test]
    fn lines_wrapped_at_79_columns_run_on() {
        let log =
            "LaTeX Warning: Reference `abcdefghijklmnopqrstuvwxyz' on page 1 undefined on in\n\
                   put line 3.\n\
                   \n\
                   ./main.tex:9: Missing number, treated as zero.\n\
                   l.9 x\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(items[0].line, Some(3));
        assert!(items[0].message.ends_with("undefined on input line 3."));
        // A line that wasn't wrapped still gets a space.
        let items = parse_log(
            "Package x Warning: First\n(x)                second on input line 2.\n",
            "main.tex",
        );
        assert_eq!(items[0].message, "First second on input line 2.");
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
        let places: Vec<_> = parse_log(log, "other.tex")
            .into_iter()
            .map(|it| (it.file, it.line))
            .collect();
        assert_eq!(
            places,
            [
                (Some("main.tex".to_string()), Some(4)),
                (Some("chapters/intro.tex".to_string()), Some(3)),
                (Some("main.tex".to_string()), Some(9)),
            ]
        );
    }

    #[test]
    fn a_place_in_a_tex_distribution_file_goes_to_the_file_that_loaded_it() {
        let log = "(./main.tex\n\
                   (/usr/local/texlive/2026/texmf-dist/tex/latex/graphics/graphicx.sty\n\
                   /usr/local/texlive/2026/texmf-dist/tex/latex/graphics/graphicx.sty:27: Undefine\n\
                   d control sequence.\n\
                   l.27 \\foo\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(
            (items[0].file.as_deref(), items[0].line),
            (Some("main.tex"), None)
        );
        assert_eq!(
            items[0].message,
            "graphicx.sty: Undefined control sequence: \\foo"
        );
    }

    #[test]
    fn font_warnings_count_and_package_prefixes_go() {
        let log = "LaTeX Font Warning: Font shape `OT1/nonexistentfam/m/n' undefined\n\
                   (Font)              using `OT1/cmr/m/n' instead on input line 3.\n\
                   \n\
                   Package biblatex Warning: Please (re)run Biber on the file:\n\
                   (biblatex)                main\n\
                   (biblatex)                and rerun LaTeX afterwards.\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(items[0].line, Some(3));
        assert_eq!(
            items[0].message,
            "Font shape `OT1/nonexistentfam/m/n' undefined using `OT1/cmr/m/n' instead on input line 3."
        );
        assert_eq!(
            items[1].message,
            "Please (re)run Biber on the file: main and rerun LaTeX afterwards."
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
        assert_eq!(items.len(), 2);
        assert_eq!(
            (
                items[0].file.as_deref(),
                items[0].line,
                items[0].message.as_str()
            ),
            (Some("refs.bib"), Some(1), "I was expecting a `,' or a `}'")
        );
        assert_eq!(items[1].message, "BibTeX subsystem: syntax error");

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
        assert_eq!(project_path("./main.tex"), Some("main.tex".into()));
        assert_eq!(
            project_path("chapters/a.tex"),
            Some("chapters/a.tex".into())
        );
        assert_eq!(
            project_path(r".\chapters\a.tex"),
            Some("chapters/a.tex".into())
        );
        for path in [
            "/usr/local/texlive/a.sty",
            "C:/texlive/a.sty",
            "c:\\a.sty",
            "\\\\server\\a.sty",
        ] {
            assert_eq!(project_path(path), None);
        }
    }

    #[test]
    fn windows_relative_log_and_bibliography_paths_use_forward_slashes() {
        let log = "(./main.tex\n(.\\chapters\\a.tex\nLaTeX Warning: Missing on input line 3.\n.\\chapters\\a.tex:4: Bad command.\nl.4 x\n";
        let items = parse_log(log, "main.tex");
        assert_eq!(items[0].file.as_deref(), Some("chapters/a.tex"));
        assert_eq!(items[1].file.as_deref(), Some("chapters/a.tex"));

        let items = parse_blg("Bad entry---line 5 of file .\\refs\\works.bib\n");
        assert_eq!(items[0].file.as_deref(), Some("refs/works.bib"));
    }
}
