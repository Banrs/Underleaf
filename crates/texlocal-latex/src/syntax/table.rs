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
        let after = &text.units[end..text.around(end).next];
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
    let mut tables = ['\t', ','].into_iter().filter_map(|separator| {
        let (rows, valid_quotes) = rows(text, separator);
        let width = rows.iter().map(Vec::len).max().unwrap_or(0);
        (width >= 2).then_some((rows, width, valid_quotes))
    });
    let first = tables.next()?;
    // A tab can look like a separator if the surrounding quotes belong to a CSV field.
    let (rows, width, _) = if first.2 {
        first
    } else {
        tables
            .find(|(_, _, valid_quotes)| *valid_quotes)
            .unwrap_or(first)
    };
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

/// Fields may be quoted as spreadsheets and CSV files quote them, `""` standing for a quote, to hold separators and
/// line breaks. A cell's line breaks and runs of spaces become one space, and blank rows around the table go.
fn rows(text: &str, separator: char) -> (Vec<Vec<String>>, bool) {
    let (mut rows, mut row, mut cell) = (vec![], vec![], String::new());
    let (mut quoted, mut fresh, mut valid_quotes) = (false, true, true);
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            if c != '"' {
                cell.push(c);
            } else if chars.next_if_eq(&'"').is_some() {
                cell.push('"');
            } else {
                quoted = false;
                valid_quotes &= chars
                    .peek()
                    .is_none_or(|&c| c == separator || matches!(c, '\r' | '\n'));
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
                row.push(take_cell(&mut cell));
                rows.push(std::mem::take(&mut row));
                true
            }
            c if c == separator => {
                row.push(take_cell(&mut cell));
                true
            }
            c => {
                valid_quotes &= c != '"';
                cell.push(c);
                false
            }
        };
    }
    if !fresh || !row.is_empty() {
        row.push(take_cell(&mut cell));
        rows.push(row);
    }
    let blank = |row: &Vec<String>| row.iter().all(String::is_empty);
    while rows.last().is_some_and(blank) {
        rows.pop();
    }
    let leading = rows.iter().take_while(|row| blank(row)).count();
    rows.drain(..leading);
    (rows, valid_quotes && !quoted)
}

fn take_cell(cell: &mut String) -> String {
    let words = cell.split_whitespace().collect::<Vec<_>>().join(" ");
    cell.clear();
    words
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
    let mut line = String::new();
    for column in 0..width {
        if column > 0 {
            line.push_str("& ");
        }
        if let Some(cell) = row.get(column).filter(|cell| !cell.is_empty()) {
            push_escaped(&mut line, cell);
            line.push(' ');
        }
    }
    line.push_str("\\\\");
    line
}

fn push_escaped(text: &mut String, cell: &str) {
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
}
