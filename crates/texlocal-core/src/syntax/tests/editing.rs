//! The editing commands' answers, case by case: maths at a place, the maths
//! to preview, completions, headings, blocks, and comments and indentation.

use super::{cited, units};
use crate::syntax::{Insertion, SourceDocument, Symbols, range};

fn marked(source: &str) -> (SourceDocument, u32) {
    let at = units(&source[..source.find('|').unwrap()]);
    (SourceDocument::new(&source.replacen('|', "", 1)), at)
}

fn in_math(source: &str) -> bool {
    let (mut doc, at) = marked(source);
    doc.insert_symbol("\\alpha", range(at, 0)).edit.text == "\\alpha"
}

#[test]
fn math_mode_is_known_at_a_place() {
    #[rustfmt::skip]
    let cases = [
        ("Let |$x$ be", false),
        ("Let $|x$ be", true),
        ("Let $x|$ be", true),
        ("Let $x$| be", false),
        ("$a$ and $b$ and |", false),
        ("$a$ and $b$ and $|", true),
        ("$|$", true), // an empty pair, the caret between
        ("a $x$$|y$", true), // two inline spans back to back
        ("a $x$$y$ |", false),
        ("$$|$$", true),
        ("$$ x + |y $$", true),
        ("$$ x + y $$ |", false),
        ("$$\nx = 1\n|\n$$", true),
        ("\\(|x\\)", true),
        ("\\(x\\)|", false),
        ("\\[\n  a = |b\n\\]", true),
        ("\\[ a = b \\] |", false),
        ("one\\\\[2pt] |two", false), // a line break with a length is not display maths
        ("\\begin{itemize}\n\\item |\n\\end{itemize}", false),
        ("\\begin{align}\n\\begin{cases} x |\\end{cases}\n\\end{align}", true),
        ("\\begin{equation}\n\\begin{cases} x \\end{cases} |\n\\end{equation}", true),
        ("\\begin{align}\na &= b \\\\\nc &= |d\n\\end{align}", true), // \\ does not end it
        ("$x \\text{ for |all } y$", false),
        ("$x \\text{ for all } |y$", true),
        ("$x \\text{ if $|y$ } z$", true), // maths inside the text
        ("\\begin{align} a \\intertext{so |} b \\end{align}", false),
        ("\\textbf{bold |}", false), // a text command in text
        ("It costs \\$5 and |", false),
        ("It costs \\$5 and \\$6 |", false),
        ("$ \\$ |$", true), // an escaped $ inside maths
        ("\\\\$|x$", true), // an escaped backslash, then a real $
        ("% a $ in a comment\n|", false),
        ("text % $\n|", false),
        ("$x % comment $\n|y$", true),
        ("100\\% $|x$", true), // an escaped percent is not a comment
        ("% \\begin{equation}\n|", false),
        ("\\verb+$+ and |", false),
        ("\\verb+$|+ x", false), // inside \verb
        ("\\verb*+x+ $a|", true),
        ("a \\verb+x\n$y|", true),
        ("\\verb\n$y|", true),
        ("$ \\verb+x|", false),
        ("$ \\verb+x\ny|", true),
        ("a \\verb+x\n$y$ |", false),
        ("\\begin{verbatim}\n$x\n\\end{verbatim}\n|", false),
        ("an unclosed $x\n\nnext paragraph |", false),
        ("an unclosed $x\nsame paragraph |", true),
        ("\\[ x\n  \n |", false),
        ("$x\r\n\r\ny|", false),
        ("$x\n \t\ny|", false),
        ("$x\r\ny|", true),
        ("\\section{Intro $x} |", false),
    ];
    for (source, expected) in cases {
        assert_eq!(in_math(source), expected, "{source}");
    }
    for name in [
        "equation", "align", "gather", "multline", "eqnarray", "alignat", "flalign",
    ] {
        for env in [name.to_owned(), format!("{name}*")] {
            let (begin, end) = (format!("\\begin{{{env}}}"), format!("\\end{{{env}}}"));
            assert!(in_math(&format!("{begin}\n  a |= b\n{end}")), "{env}");
            assert!(!in_math(&format!("{begin}\n  a = b\n{end}\n|")), "{env}");
            assert!(!in_math(&format!("|{begin}a{end}")), "{env}");
        }
    }
}

#[test]
fn the_maths_to_preview_is_found_around_a_place() {
    #[rustfmt::skip]
    let cases = [
        ("Let $x|+1$ be", Some((4, "x+1", false))),
        ("\\$5 and $x|$", Some((8, "x", false))),
        ("text |$x$", None),
        ("$x$|", None),
        ("$$ a |+ b $$", Some((0, "a + b", true))),
        ("$$x$$|", Some((0, "x", true))),
        ("$$ |$$", None),
        ("\\(x|\\)", Some((0, "x", false))),
        ("\\[ x \\label{eq:1} |\\]", Some((0, "x", true))),
        ("see\n\\begin{equation*}\n  E = mc^2 \\tag{1} |\n\\end{equation*}", Some((4, "E = mc^2", true))),
        ("\\begin{align}\n  a &= b \\nonumber\\\\\n  c &|= d\n\\end{align}", Some((0, "\\begin{aligned}a &= b \\\\\n  c &= d\\end{aligned}", true))),
        ("\\begin{gather}\n  a |\n\\end{gather}", Some((0, "\\begin{gathered}a\\end{gathered}", true))),
        ("\\begin{cases} a |\\end{cases}", Some((0, "\\begin{cases}a\\end{cases}", true))),
        ("\\begin{itemize} |x \\end{itemize}", None),
        ("\\begin{equation} a |", None),
        ("$a\n|b$", Some((0, "a\nb", false))),
        ("% costs $5 and $|6", None),
        ("It costs \\$5 and \\$|6", None),
        ("\\begin{lstlisting}\n$ make |all $\n\\end{lstlisting}", None),
        ("$$ x|\n\nprose $$ y $$", None),
    ];
    let found = |source: &str| {
        let (mut doc, at) = marked(source);
        doc.math_at(at).map(|m| (m.start, m.tex, m.display))
    };
    for (source, expected) in cases {
        let expected = expected.map(|(start, tex, display)| (start, tex.to_owned(), display));
        assert_eq!(found(source), expected, "{source}");
    }
    let between = format!("{}$$ a $$ prose| $$ b $$", "x ".repeat(15_000));
    assert_eq!(found(&between), None);
}

#[test]
fn completions_are_offered_for_what_is_typed() {
    #[rustfmt::skip]
    let cases = [
        ("\\footnote{see \\cite{kn", false, Some((20, "knuth84", "citation"))),
        ("\\section{Proof of \\ref{", false, Some((23, "sec:intro", "label"))),
        ("\\cite[p.~5]{kn", false, Some((12, "knuth84", "citation"))),
        ("\\cite[a[b]{kn", false, Some((11, "knuth84", "citation"))),
        ("\\cite{a,kn", false, Some((8, "knuth84", "citation"))),
        ("\\cite{a, kn", false, Some((9, "knuth84", "citation"))),
        ("\\cite{a,  kn", false, Some((10, "knuth84", "citation"))),
        ("\\cite{a, ", false, Some((9, "knuth84", "citation"))),
        ("\\begin{document, ite", false, Some((17, "itemize", "environment"))),
        ("\\begin{ite", false, Some((7, "itemize", "environment"))),
        ("\\emph{x", false, None),
        ("\\frac{\\al", false, Some((6, "\\alpha", "command"))),
        ("x \\", false, None),
        ("\\", true, Some((0, "\\alpha", "command"))),
        ("\\{", false, None),
        ("@inp", false, Some((0, "@inproceedings", "entryType"))),
        ("  @inp", false, Some((2, "@inproceedings", "entryType"))),
        ("write to jane@m", false, None),
        ("a@b", false, None),
        ("\\@in", false, None),
        ("x\n@art", false, Some((2, "@article", "entryType"))),
    ];
    for (before, explicit, expected) in cases {
        let mut doc = SourceDocument::new(before);
        doc.set_symbols(std::sync::Arc::new(Symbols {
            labels: vec!["sec:intro".into()],
            citations: cited(&["knuth84"]),
            ..Symbols::default()
        }));
        let found = doc.completions(units(before), explicit);
        let place = found
            .as_ref()
            .map(|c| (c.start, serde_json::to_value(c.kind).unwrap()));
        let expected_place = expected.map(|(at, _, kind)| (at, kind.into()));
        assert_eq!(place, expected_place, "{before}");
        if let (Some(found), Some((_, item, _))) = (found, expected) {
            assert!(found.items.iter().any(|i| i.label == item), "{before}");
        }
    }
}

#[test]
fn a_line_becomes_a_heading() {
    #[rustfmt::skip]
    let cases = [
        ("\\section[Short]{A Long Title}", "subsection", "\\subsection[Short]{A Long Title}", 31),
        ("\\section[Short]{A Long Title}", "", "A Long Title", 12),
        ("Intro text \\section{X} more", "chapter", "Intro text \\chapter{X} more", 21),
        ("Intro text \\section{X}", "", "Intro text X", 12),
        ("  \\section*{A {b} c} % note", "part", "  \\part*{A {b} c} % note", 16),
        ("  Plain words", "section", "  \\section{Plain words}", 22),
        ("\\section[S]{T} x", "paragraph", "\\paragraph[S]{T} x", 15),
        ("🙂 \\section{A \\{set}", "subsection", "🙂 \\subsection{A \\{set}", 22),
        ("\\section{A \\} note}", "", "A \\} note", 9),
        ("\\subsection{Unclosed {title", "section", "\\section{Unclosed {title", 24),
        ("\\section{A title that", "", "\\section{A title that", 1),
        ("Intro text \\section{X} % c", "", "Intro text X % c", 13),
        ("Introduction % TODO reword", "section", "\\section{Introduction} % TODO reword", 21),
        ("Intro   % c", "section", "\\section{Intro}   % c", 14),
        ("% note", "section", "\\section{}% note", 9),
        ("\\section{Title} % \\section{x}", "subsection", "\\subsection{Title} % \\section{x}", 17),
        ("50\\% done", "section", "\\section{50\\% done}", 18),
        ("a \\\\% c", "section", "\\section{a \\\\}% c", 13),
        ("   ", "section", "   \\section{}", 12),
        ("\\sectionmark{x} words", "chapter", "\\chapter{\\sectionmark{x} words}", 30),
    ];
    for (line, command, text, cursor) in cases {
        let doc = SourceDocument::new(&format!("above\n{line}\nbelow"));
        let Insertion { edit, caret, .. } = doc.set_heading(7, command);
        let found = (edit.start, edit.length, edit.text.as_str(), caret);
        let expected = (6, units(line), text, 6 + cursor);
        assert_eq!(found, expected, "{line} as {command}");
    }
    let doc = SourceDocument::new("Intro\r\nbelow");
    let Insertion { edit, .. } = doc.set_heading(0, "section");
    assert_eq!(
        (edit.start, edit.length, edit.text.as_str()),
        (0, 5, "\\section{Intro}")
    );
}

#[test]
fn blocks_go_in_with_their_fields() {
    #[rustfmt::skip]
    let cases: [(&str, &str, &str, &[u32]); 4] = [
        ("Some text", "equation", "\n\\begin{equation}\n  \n  \\label{eq:}\n\\end{equation}\n", &[20, 33]),
        ("", "figure", "\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n", &[71, 84, 99]),
        ("  ", "itemize", "\\begin{itemize}\n    \\item \n  \\end{itemize}\n  ", &[26]),
        ("", "description", "\\begin{description}\n  \\item[] \n\\end{description}\n", &[28, 30]),
    ];
    for (before, id, text, fields) in cases {
        let doc = SourceDocument::new(before);
        let end = units(before);
        let block = doc.insert_block(id, range(end, 0)).unwrap();
        assert_eq!(block.caret, end + block.fields[0].start, "{id}");
        let found: Vec<_> = block.fields.iter().map(|f| (f.start, f.length)).collect();
        let fields: Vec<_> = fields.iter().map(|&start| (start, 0)).collect();
        let found = (block.edit.text.as_str(), found);
        assert_eq!(found, (text, fields), "{id} after {before:?}");
    }
    let nothing = SourceDocument::new("").insert_block("nothing", range(0, 0));
    assert!(nothing.is_none());
}

#[test]
fn comments_and_indentation_go_by_line() {
    #[rustfmt::skip]
    type Case<'a> = (&'a str, &'a str, &'a [(u32, u32)], &'a [(u32, u32, &'a str)]);
    #[rustfmt::skip]
    let cases: [Case; 9] = [
        ("a\n  b\n\nc", "comment", &[(0, 8)], &[(0, 0, "% "), (2, 0, "% "), (7, 0, "% ")]),
        ("% a\n  %b\n", "comment", &[(0, 9)], &[(0, 2, ""), (6, 1, "")]),
        // A selection that ends at a line's start leaves that line alone.
        ("a\nb", "comment", &[(0, 2)], &[(0, 0, "% ")]),
        ("a\n b\n", "indent", &[(0, 3), (5, 0)], &[(0, 0, "  "), (2, 0, "  "), (5, 0, "  ")]),
        ("   a\nb", "outdent", &[(0, 6)], &[(1, 2, "")]),
        // CRLF: the carriage return is no indentation, and an empty line is blank.
        ("a\r\n  \r\n b", "outdent", &[(0, 9)], &[(3, 2, ""), (7, 1, "")]),
        ("a\r\n\r\nb", "comment", &[(0, 6)], &[(0, 0, "% "), (5, 0, "% ")]),
        ("a\r\n\r\nb", "outdent", &[(0, 6)], &[]),
        ("🙂\n\tb\n \tc\n    d", "outdent", &[(3, 12)], &[(3, 1, "  "), (7, 1, " "), (12, 2, "")]),
    ];
    for (text, command, selections, edits) in cases {
        let doc = SourceDocument::new(text);
        let selections: Vec<_> = selections.iter().map(|&(s, l)| range(s, l)).collect();
        let found = match command {
            "comment" => doc.toggle_comment(&selections),
            more => doc.indent(&selections, more == "indent"),
        };
        let found: Vec<_> = found
            .iter()
            .map(|e| (e.start, e.length, &*e.text))
            .collect();
        assert_eq!(found, edits, "{command} {text:?}");
    }
}

#[test]
fn symbols_go_in_as_maths() {
    let mut doc = SourceDocument::new("text $x$ and $");
    let in_text = doc.insert_symbol("\\alpha", range(5, 0));
    assert_eq!((in_text.edit.text, in_text.caret), ("$\\alpha$".into(), 13));
    let in_maths = doc.insert_symbol("\\alpha", range(14, 0));
    assert_eq!(in_maths.edit.text, "\\alpha");
}
