use super::edit::Change;
use super::{INDENT, SourceDocument, TextRange, clamp, indentation, span, splice};
use crate::utf16;

impl SourceDocument {
    pub(crate) fn paste_table(
        &self,
        selection: TextRange,
        cells: &str,
        booktabs: bool,
    ) -> Option<Change> {
        let (text, selection) = (&self.text, clamp(selection, self.text.len()));
        let (start, end) = selection.bounds();
        let line = text.bounds(text.line_index(selection.start));
        let contents = &text.units[line.start..line.end];
        let indent = String::from_utf16_lossy(&contents[..indentation(contents)]);
        let table = tabular(cells, &indent, booktabs)?;
        let before = &text.units[line.start..start];
        let after = &text.units[end..line.next.max(end)];
        let blank = |units: &[u16]| {
            units
                .iter()
                .all(|u| matches!(u, 0x09..=0x0d | 0x20 | 0x85 | 0x2028 | 0x2029))
        };
        let newline = |units: &[u16]| {
            if blank(units) {
                String::new()
            } else {
                format!("\n{indent}")
            }
        };
        // On lines of its own, the text either side of it keeping theirs.
        let pasted = format!("{}{table}{}", newline(before), newline(after));
        let caret = start + utf16::len(&pasted);
        Some(Change {
            edits: vec![splice(start, end - start, pasted)],
            selections: vec![span(caret, 0)],
        })
    }
}

/// Cells as Numbers, Excel and Google Sheets copy them, tab-separated, or as a CSV file holds them, as a tabular whose
/// lines after the first start with `indent`. Text of fewer than two columns isn't a table.
fn tabular(text: &str, indent: &str, booktabs: bool) -> Option<String> {
    let rows = ['\t', ',']
        .into_iter()
        .map(|separator| rows(text, separator))
        .find(|rows| widest(rows) >= 2)?;
    let width = widest(&rows);
    let body = if rows.len() > 1 { &rows[1..] } else { &rows };
    let columns: String = (0..width)
        .map(|column| {
            let cells = body.iter().filter_map(|row| row.get(column));
            let mut filled = cells.filter(|cell| !cell.is_empty()).peekable();
            if filled.peek().is_some() && filled.all(|cell| numeric(cell)) {
                'r'
            } else {
                'l'
            }
        })
        .collect();
    let (top, middle, bottom) = if booktabs {
        ("\\toprule", "\\midrule", "\\bottomrule")
    } else {
        ("\\hline", "\\hline", "\\hline")
    };
    let mut lines = vec![
        format!("\\begin{{tabular}}{{{columns}}}"),
        format!("{INDENT}{top}"),
    ];
    for (index, row) in rows.iter().enumerate() {
        lines.push(format!("{INDENT}{}", line(row, width)));
        if index == 0 && rows.len() > 1 {
            lines.push(format!("{INDENT}{middle}"));
        }
    }
    lines.push(format!("{INDENT}{bottom}"));
    lines.push("\\end{tabular}".to_owned());
    Some(lines.join(&format!("\n{indent}")))
}

fn widest(rows: &[Vec<String>]) -> usize {
    rows.iter().map(Vec::len).max().unwrap_or(0)
}

/// Fields may be quoted as spreadsheets and CSV files quote them, `""` standing for a quote, to hold separators and
/// line breaks. A cell's line breaks and runs of spaces become one space, and blank rows around the table go.
fn rows(text: &str, separator: char) -> Vec<Vec<String>> {
    let (mut rows, mut row, mut cell) = (vec![], vec![], String::new());
    let (mut quoted, mut fresh) = (false, true);
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            if c != '"' {
                cell.push(c);
            } else if chars.next_if_eq(&'"').is_some() {
                cell.push('"');
            } else {
                quoted = false;
            }
            continue;
        }
        fresh = match c {
            '"' if fresh => {
                quoted = true;
                false
            }
            '\r' | '\n' => {
                if c == '\r' {
                    chars.next_if_eq(&'\n');
                }
                row.push(std::mem::take(&mut cell));
                rows.push(std::mem::take(&mut row));
                true
            }
            c if c == separator => {
                row.push(std::mem::take(&mut cell));
                true
            }
            c => {
                cell.push(c);
                false
            }
        };
    }
    if !fresh || !row.is_empty() {
        row.push(cell);
        rows.push(row);
    }
    let mut rows: Vec<Vec<String>> = rows
        .iter()
        .map(|row| row.iter().map(|cell| words(cell)).collect())
        .collect();
    let blank = |row: &Vec<String>| row.iter().all(String::is_empty);
    while rows.last().is_some_and(blank) {
        rows.pop();
    }
    let leading = rows.iter().take_while(|row| blank(row)).count();
    rows.drain(..leading);
    rows
}

fn words(cell: &str) -> String {
    cell.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A number as a spreadsheet shows one: signed, with a currency or percent sign, grouped digits or an exponent.
fn numeric(cell: &str) -> bool {
    let unsigned = cell.trim_start_matches(['+', '-', '\u{2212}', '$', '€', '£', '¥']);
    let number = unsigned.strip_suffix('%').unwrap_or(unsigned);
    let (digits, exponent) = number.split_once(['e', 'E']).unwrap_or((number, "0"));
    let exponent = exponent.strip_prefix(['+', '-']).unwrap_or(exponent);
    digits.starts_with(|c: char| c.is_ascii_digit() || c == '.')
        && digits.contains(|c: char| c.is_ascii_digit())
        && digits.chars().all(|c| matches!(c, '0'..='9' | ',' | '.'))
        && !exponent.is_empty()
        && exponent.chars().all(|c| c.is_ascii_digit())
}

/// Cells joined by `&`, an empty one leaving no doubled space.
fn line(row: &[String], width: usize) -> String {
    let mut words = vec![];
    for column in 0..width {
        if column > 0 {
            words.push("&".to_owned());
        }
        let cell = row
            .get(column)
            .map_or_else(String::new, |cell| escaped(cell));
        words.push(cell);
    }
    words.push("\\\\".to_owned());
    words.retain(|word| !word.is_empty());
    words.join(" ")
}

fn escaped(cell: &str) -> String {
    let mut text = String::with_capacity(cell.len());
    for c in cell.chars() {
        match c {
            '&' | '%' | '$' | '#' | '_' | '{' | '}' => {
                text.push('\\');
                text.push(c);
            }
            '~' => text.push_str("\\textasciitilde{}"),
            '^' => text.push_str("\\textasciicircum{}"),
            '\\' => text.push_str("\\textbackslash{}"),
            c => text.push(c),
        }
    }
    text
}
