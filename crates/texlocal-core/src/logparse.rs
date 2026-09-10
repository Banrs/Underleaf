//! latexmk/TeX log parsing, ported line-for-line from server/compile.js.
//! We compile with -file-line-error, so errors look like:
//!   ./main.tex:12: Undefined control sequence.
//! Warnings look like:
//!   LaTeX Warning: Reference `fig:x' on page 1 undefined on input line 10.

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct LogItem {
    #[serde(rename = "type")]
    pub kind: &'static str, // "error" | "warning"
    pub file: Option<String>,
    pub line: Option<u32>,
    pub message: String,
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).unwrap())
}

pub fn parse_log(log: &str, main_file: &str) -> Vec<LogItem> {
    static FILE_LINE: OnceLock<Regex> = OnceLock::new();
    static ERROR_STOP: OnceLock<Regex> = OnceLock::new();
    static BANG: OnceLock<Regex> = OnceLock::new();
    static L_NO: OnceLock<Regex> = OnceLock::new();
    static WARNING: OnceLock<Regex> = OnceLock::new();
    static WARN_STOP: OnceLock<Regex> = OnceLock::new();
    static ON_LINE: OnceLock<Regex> = OnceLock::new();

    let file_line = re(
        &FILE_LINE,
        r"(?i)^(.+?\.(?:tex|sty|cls|bib|def|clo)):(\d+):\s*(.*)$",
    );
    let error_stop = re(&ERROR_STOP, r"^(l\.\d+|\s*$|!)");
    let bang = re(&BANG, r"^! (.*)$");
    let l_no = re(&L_NO, r"^l\.(\d+)");
    let warning = re(
        &WARNING,
        r"^(LaTeX|Package (\S+)|Class (\S+)) Warning:\s*(.*)$",
    );
    let warn_stop = re(&WARN_STOP, r"Warning|Error|^!");
    let on_line = re(&ON_LINE, r"on input line (\d+)");

    let lines: Vec<&str> = log.split('\n').collect();
    let mut items: Vec<LogItem> = Vec::new();

    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];

        if let Some(m) = file_line.captures(line) {
            // Error detail often continues on following lines up to the "l.<n>" echo.
            let mut message = m[3].to_string();
            for next in &lines[(i + 1)..(i + 4).min(lines.len())] {
                if error_stop.is_match(next) {
                    break;
                }
                message.push(' ');
                message.push_str(next.trim());
            }
            let file = m[1].strip_prefix("./").unwrap_or(&m[1]).to_string();
            items.push(LogItem {
                kind: "error",
                file: Some(file),
                line: m[2].parse().ok(),
                message: message.trim().to_string(),
            });
            i += 1;
            continue;
        }

        if let Some(m) = bang.captures(line) {
            let line_no = lines[(i + 1)..(i + 12).min(lines.len())]
                .iter()
                .find_map(|next| l_no.captures(next))
                .and_then(|lm| lm[1].parse().ok());
            items.push(LogItem {
                kind: "error",
                file: Some(main_file.to_string()),
                line: line_no,
                message: m[1].trim().to_string(),
            });
            i += 1;
            continue;
        }

        if let Some(m) = warning.captures(line) {
            let mut message = m[4].to_string();
            for next in &lines[(i + 1)..(i + 3).min(lines.len())] {
                if next.trim().is_empty() || warn_stop.is_match(next) {
                    break;
                }
                message.push(' ');
                message.push_str(next.trim());
            }
            let line_no = on_line.captures(&message).and_then(|lm| lm[1].parse().ok());
            items.push(LogItem {
                kind: "warning",
                file: None,
                line: line_no,
                message: message.trim().to_string(),
            });
        }
        i += 1;
    }

    // De-duplicate repeated messages (reruns produce copies).
    let mut seen = HashSet::new();
    items
        .into_iter()
        .filter(|it| {
            let key = format!(
                "{}|{}|{}|{}",
                it.kind,
                it.file.as_deref().unwrap_or("\u{0}"),
                it.line
                    .map_or_else(|| "\u{0}".to_string(), |n| n.to_string()),
                it.message
            );
            seen.insert(key)
        })
        .collect()
}
