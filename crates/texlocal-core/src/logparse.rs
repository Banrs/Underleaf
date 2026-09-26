//! latexmk/TeX log parsing.
//! We compile with -file-line-error, so errors look like:
//!   ./main.tex:12: Undefined control sequence.
//! Warnings look like:
//!   LaTeX Warning: Reference `fig:x' on page 1 undefined on input line 10.

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

static FILE_LINE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(.+?\.(?:tex|sty|cls|bib|def|clo)):(\d+):\s*(.*)$").unwrap()
});
static L_NO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^l\.(\d+)").unwrap());
static WARNING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(LaTeX|Package (\S+)|Class (\S+)) Warning:\s*(.*)$").unwrap());
static ON_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"on input line (\d+)").unwrap());

fn has_error(items: &[LogItem]) -> bool {
    items.iter().any(|item| item.kind == "error")
}

pub fn parse_log(log: &str, main_file: &str) -> Vec<LogItem> {
    // lines(), not split('\n'): a Windows TeX log or latexmk's own output ends
    // lines with \r\n, and a kept \r would land mid-message when a
    // continuation line is appended.
    let lines: Vec<&str> = log.lines().collect();
    let mut items: Vec<LogItem> = Vec::new();

    for (i, &line) in lines.iter().enumerate() {
        if let Some(m) = FILE_LINE.captures(line) {
            // Error detail often continues on following lines up to the "l.<n>" echo.
            let mut message = m[3].to_string();
            for next in &lines[(i + 1)..(i + 4).min(lines.len())] {
                if next.trim().is_empty() || next.starts_with('!') || L_NO.is_match(next) {
                    break;
                }
                message.push(' ');
                message.push_str(next.trim());
            }
            // TeX's closing "==> Fatal error occurred" takes the place of
            // the error that stopped it: that error names the place, and
            // the summary names none of its own. After that error it is
            // left out, so one mistake counts as one error.
            let summary = message.trim_start().starts_with("==>");
            if summary && has_error(&items) {
                continue;
            }
            let file = m[1].strip_prefix("./").unwrap_or(&m[1]).to_string();
            items.push(LogItem {
                kind: "error",
                file: (!summary).then_some(file),
                line: if summary { None } else { m[2].parse().ok() },
                message: message.trim().to_string(),
            });
        } else if let Some(message) = line.strip_prefix("! ") {
            if message.trim_start().starts_with("==>") && has_error(&items) {
                continue;
            }
            // Its own "l.<n>" echo only: not one that belongs to the next
            // error, as a closing "==> Fatal error occurred" would borrow.
            let line_no: Option<u32> = lines[(i + 1)..(i + 12).min(lines.len())]
                .iter()
                .take_while(|next| !next.starts_with('!') && !FILE_LINE.is_match(next))
                .find_map(|next| L_NO.captures(next))
                .and_then(|lm| lm[1].parse().ok());
            items.push(LogItem {
                kind: "error",
                // The main file only where the log names a line in it.
                file: line_no.map(|_| main_file.to_string()),
                line: line_no,
                message: message.trim().to_string(),
            });
        // The substring test first: most lines of a long log are neither
        // kind, and it costs far less than a regex call per line.
        } else if let Some(m) = line
            .contains(" Warning:")
            .then(|| WARNING.captures(line))
            .flatten()
        {
            let mut message = m[4].to_string();
            for next in &lines[(i + 1)..(i + 3).min(lines.len())] {
                if next.trim().is_empty()
                    || next.starts_with('!')
                    || next.contains("Warning")
                    || next.contains("Error")
                {
                    break;
                }
                message.push(' ');
                message.push_str(next.trim());
            }
            let line_no = ON_LINE.captures(&message).and_then(|lm| lm[1].parse().ok());
            items.push(LogItem {
                kind: "warning",
                file: None,
                line: line_no,
                message: message.trim().to_string(),
            });
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

#[cfg(test)]
mod tests {
    use super::parse_log;

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
        assert_eq!(
            items[0].message,
            "Undefined control sequence. <recently read> \\foo"
        );
        assert_eq!(items[1].message, "Emergency stop.");
        assert_eq!(items[1].line, Some(9));
        assert_eq!(items[2].line, Some(44));
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
}
