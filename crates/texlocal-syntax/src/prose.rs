//! What a spelling checker passes over besides the highlighted commands and
//! maths: the names commands take, which the highlighting (stex's) leaves
//! uncoloured when options come first, as in `\usepackage[utf8]{inputenc}`.

use crate::{catalog::CATALOG, letter, space, Text, TextRange};

/// The options and first braced argument of each name command (the
/// catalog's, its citations' and references') in the paragraphs from
/// `start` to `end`. They're read from the paragraph's start, as an
/// argument can't hold a blank line.
pub fn not_prose(text: &Text, start: u32, end: u32) -> Vec<TextRange> {
    let blank = |line: usize| text.line(line).iter().all(|&u| space(u));
    let mut line = text.line_index(start);
    while line > 0 && !blank(line - 1) {
        line -= 1;
    }
    let (units, mut i) = (&text.units, text.lines[line] as usize);
    // A unit as a char, a surrogate as NUL; none past the end.
    let at = |i: usize| {
        units
            .get(i)
            .map(|&u| char::from_u32(u.into()).unwrap_or_default())
    };
    let comment_end = |mut i| {
        while !matches!(at(i), None | Some('\n')) {
            i += 1;
        }
        i
    };
    let mut ranges = Vec::new();
    while i < end as usize {
        let c = at(i);
        i += 1;
        if c == Some('%') {
            i = comment_end(i);
        }
        if c != Some('\\') {
            continue;
        }
        let name = i;
        while units.get(i).is_some_and(|&u| letter(u)) {
            i += 1;
        }
        let name = String::from_utf16_lossy(&units[name..i]);
        let catalog = &*CATALOG;
        let lists = [
            &catalog.name_commands,
            &catalog.cite_commands,
            &catalog.ref_commands,
        ];
        if !lists.iter().any(|list| list.contains(&name)) {
            i += name.is_empty() as usize; // an escape, as \%
            continue;
        }
        i += (at(i) == Some('*')) as usize;
        loop {
            while matches!(at(i), Some(' ' | '\t' | '\r' | '\n' | '%')) {
                if at(i) == Some('%') {
                    i = comment_end(i);
                }
                if at(i) == Some('\n') && blank(text.line_index(i as u32 + 1)) {
                    break;
                }
                i += 1;
            }
            let close = match at(i) {
                Some('[') => ']',
                Some('{') => '}',
                _ => break,
            };
            let (mut from, mut depth) = (i + 1, 0);
            // To its close, or the paragraph's end: an unclosed brace while typing.
            loop {
                i += 1;
                match at(i) {
                    None => break,
                    Some('%') => {
                        ranges.push(TextRange {
                            start: from as u32,
                            length: (i - from) as u32,
                        });
                        i = comment_end(i);
                        from = i;
                        if at(i).is_none() || blank(text.line_index(i as u32 + 1)) {
                            break;
                        }
                    }
                    Some('\\') => i += 1,
                    Some('{') => depth += 1,
                    Some('}') if depth > 0 => depth -= 1,
                    Some(c) if c == close && depth == 0 => break,
                    Some('\n') if blank(text.line_index(i as u32 + 1)) => break,
                    _ => {}
                }
            }
            let to = i.min(units.len());
            ranges.push(TextRange {
                start: from as u32,
                length: (to - from) as u32,
            });
            i += 1;
            if close == '}' {
                break;
            }
        }
    }
    ranges.retain(|r| r.start + r.length >= start);
    ranges
}

#[cfg(test)]
mod tests {
    use crate::SourceDocument;

    /// The names `not_prose` finds in the whole source.
    fn names(source: &str) -> Vec<String> {
        let units: Vec<u16> = source.encode_utf16().collect();
        SourceDocument::new(source)
            .not_prose(0, units.len() as u32)
            .iter()
            .map(|r| {
                String::from_utf16_lossy(&units[r.start as usize..(r.start + r.length) as usize])
            })
            .collect()
    }

    #[test]
    fn names_but_not_prose() {
        assert_eq!(names("\\usepackage[utf8]{inputenc}"), ["utf8", "inputenc"]);
        assert_eq!(
            names("see \\cite[p.~3]{knuth, lamport} and \\cref*{fig:a}."),
            ["p.~3", "knuth, lamport", "fig:a"]
        );
        assert_eq!(
            names("\\includegraphics[width=0.8\\linewidth]{plots/a b}"),
            ["width=0.8\\linewidth", "plots/a b"]
        );
        // Only the first braced argument: a frame's title is prose.
        assert_eq!(
            names("\\begin{frame}{Title} \\emph{x} \\\\ \\%cite{y}"),
            ["frame"]
        );
        assert_eq!(
            names("\\usepackage{amsmath,\n  {amssymb}}"),
            ["amsmath,\n  {amssymb}"]
        );
        // Not in a comment, nor past a blank line.
        assert_eq!(names("% \\cite{x}\n\\input{a\n\nprose}"), ["a"]);
    }

    #[test]
    fn from_the_paragraph_start() {
        let source = "\\usepackage{amsmath,\n  amssymb}\n\nText";
        let doc = SourceDocument::new(source);
        let found = doc.not_prose(25, 1); // in "amssymb"
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].start, 12);
        assert!(doc.not_prose(36, 2).is_empty()); // in "Text"
    }

    #[test]
    fn arguments_can_start_on_the_next_line() {
        assert_eq!(
            names("\\usepackage\n[utf8]\n{inputenc}"),
            ["utf8", "inputenc"]
        );
        assert_eq!(names("😀 \\cite\n{𐐀key}"), ["𐐀key"]);
    }

    #[test]
    fn comments_inside_arguments_stay_prose_and_do_not_close_the_argument() {
        let text = "\\usepackage{amsmath,% Speling }\n amssymb}";
        let ranges = SourceDocument::new(text).not_prose(0, text.len() as u32);
        let covered = |at: usize| {
            ranges
                .iter()
                .any(|r| r.start as usize <= at && at < (r.start + r.length) as usize)
        };
        assert!(!covered(text.find("Speling").unwrap()));
        assert!(covered(text.find("amssymb").unwrap()));
    }
}
