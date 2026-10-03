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
static ERROR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:(?i:(?P<file>.+?\.(?:tex|ltx|sty|cls|bib|bbl|aux|toc|lof|lot|out|ind|nav|snm|def|clo|cfg|fd|tikz|pgf))):(?P<line>\d+):\s*|! )(?P<message>.*)$").unwrap()
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

/// A forward-slash project path; None for an absolute TeX distribution path.
fn project_path(path: &str) -> Option<String> {
    (!path.starts_with('/')).then(|| path.strip_prefix("./").unwrap_or(path).to_string())
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
    let name = path.rsplit('/').next().unwrap_or(path);
    *message = format!("{name}: {message}");
    (files.find_map(project_path), None)
}

/// Join after TeX's 79-column wrap without a space; otherwise separate lines
/// and drop an indented package "(name)" prefix.
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

/// The first blank line from `from`, or the end.
fn blank_from(lines: &[&str], from: usize) -> usize {
    (from..lines.len())
        .find(|&j| lines[j].trim().is_empty())
        .unwrap_or(lines.len())
}

pub fn parse_log(log: &str, main_file: &str) -> Vec<LogItem> {
    let lines: Vec<&str> = log.lines().collect();
    let mut items: Vec<LogItem> = Vec::new();
    let mut open = Vec::new();
    // Lines before this one echo source or a box's contents, whose
    // parentheses needn't pair up, so they aren't tracked.
    let mut quiet_until = 0;

    for (i, &line) in lines.iter().enumerate() {
        // Skip the warning regex for most lines of a long log.
        let diagnostic = ERROR.captures(line).or_else(|| {
            line.contains(" Warning:")
                .then(|| WARNING.captures(line))
                .flatten()
        });
        if let Some(m) = diagnostic {
            let named = m.name("file").map(|m| m.as_str());
            let error = named.is_some() || line.starts_with("! ");
            let mut message = m["message"].to_string();
            // Find the source echo without borrowing the next error's.
            let echo = if error {
                lines[i + 1..(i + 12).min(lines.len())]
                    .iter()
                    .take_while(|next| !next.starts_with('!') && !ERROR.is_match(next))
                    .position(|next| L_NO.is_match(next))
                    .map(|k| i + 1 + k)
            } else {
                None
            };
            if error {
                quiet_until = echo.map_or_else(|| blank_from(&lines, i + 1), |j| j + 2);
            }
            let continuation = if named.is_some() {
                3
            } else if error {
                0
            } else {
                2
            };
            let mut prev = line;
            for next in &lines[i + 1..(i + 1 + continuation).min(lines.len())] {
                if next.trim().is_empty()
                    || next.starts_with('!')
                    || if error {
                        next.starts_with('<') || L_NO.is_match(next)
                    } else {
                        next.contains("Warning") || next.contains("Error")
                    }
                {
                    break;
                }
                append(&mut message, prev, next);
                prev = next;
            }
            // A fatal summary repeats the stopping error; keep it only alone.
            let summary = error && message.trim_start().starts_with("==>");
            if summary && items.iter().any(|item| item.kind == "error") {
                continue;
            }
            // TeX's context or source echo names the undefined command.
            if let Some(m) = echo
                .filter(|_| {
                    message
                        .trim_start()
                        .starts_with("Undefined control sequence.")
                })
                .and_then(|j| {
                    lines[i + 1..=j]
                        .iter()
                        .find_map(|line| LAST_CS.captures(line))
                })
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
            items.push(LogItem {
                kind: if error { "error" } else { "warning" },
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

    // Reruns duplicate messages; keep the first in order.
    let keep: Vec<bool> = {
        let mut seen = HashSet::with_capacity(items.len());
        items.iter().map(|item| seen.insert(item)).collect()
    };
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
                Some(LogItem {
                    kind: "error",
                    line: file.as_ref().and(m[2].parse().ok()),
                    file,
                    message: message.trim().to_string(),
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
    fn a_bibtex_error_takes_its_message_from_the_line_above_its_place() {
        let items = parse_blg("I couldn't open database file .bib\n---line 5 of file main.aux\n");
        assert_eq!(items[0].message, "I couldn't open database file .bib");
        assert_eq!(items[0].line, Some(5));
    }

    #[test]
    fn tex_distribution_paths_are_not_the_projects() {
        assert_eq!(project_path("./main.tex"), Some("main.tex".into()));
        assert_eq!(
            project_path("chapters/a.tex"),
            Some("chapters/a.tex".into())
        );
        assert_eq!(project_path("/usr/local/texlive/a.sty"), None);
    }
}
