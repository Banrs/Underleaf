//! The answers that read the text from its start (maths and code to skip,
//! name arguments, text styles, maths at a point) are the same however
//! they're reached: resumed from kept points, after edits that forget some
//! of them, as on a document read fresh. How far a question reads is
//! checked beside the scanner (maths.rs).

use texlocal_core::syntax::{SourceDocument, TextRange, math_mode_at};

/// How many of a random test's documents or rounds: fewer in a debug build, where
/// each takes about ten times as long, and still every kind of each.
const fn runs(release: usize, debug: usize) -> usize {
    if cfg!(debug_assertions) {
        debug
    } else {
        release
    }
}

const PIECES: &[&str] = &[
    "\\cite{",
    "}",
    "}",
    "}",
    "{",
    "$",
    "$$",
    "\\[",
    "\\]",
    "\\begin{equation}",
    "\\end{equation}",
    "\\begin{verbatim}",
    "\\end{verbatim}",
    "\\verb|",
    "|",
    "\\textbf{",
    "\\emph{",
    "\\text{",
    "\\textit{",
    "% c",
    "\n",
    "\n",
    "\n\n",
    " word ",
    " prose ",
    "x^2",
    "\\usepackage[opt]{pkg}",
    "\\usepackage\n[a]\n{b}",
    "\\label{x}",
    "\\ref{",
    "\\input{a",
    "[",
    "]",
    "\\\\",
    "\\",
    " \n",
];

struct Seeded(u32);

impl Seeded {
    fn next(&mut self, n: usize) -> usize {
        self.0 = self.0.wrapping_mul(1_103_515_245).wrapping_add(12_345);
        (self.0 >> 8) as usize % n
    }
}

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
}

#[test]
fn answers_after_edits_are_a_fresh_reading_s() {
    let mut seed = Seeded(5);
    for document in 0..runs(12, 6) {
        // Several kept points' worth; every third with no blank line at all.
        let source: String = (0..3_000)
            .map(|_| {
                loop {
                    let piece = PIECES[seed.next(PIECES.len())];
                    if document % 3 != 0 || !piece.contains("\n\n") {
                        break piece;
                    }
                }
            })
            .collect();
        let mut doc = SourceDocument::new(&source);
        let mut len = source.encode_utf16().count();
        for round in 0..40 {
            if round % 3 == 0 {
                let at = seed.next(len + 1);
                let cut = seed.next(8).min(len - at);
                let piece = PIECES[seed.next(PIECES.len())];
                doc.edit(at as u32, cut as u32, piece);
                len = len - cut + piece.encode_utf16().count();
            }
            let start = seed.next(len + 1);
            let length = [0, 1, seed.next(400)][seed.next(3)].min(len - start);
            let selection = range(start as u32, length as u32);
            let text = doc.text();
            let mut fresh = SourceDocument::new(&text);
            let at = format!("document {document}, round {round}, {start}+{length}");
            assert_eq!(
                doc.not_prose(selection.start, selection.length),
                fresh.not_prose(selection.start, selection.length),
                "{at}"
            );
            assert_eq!(
                doc.text_styles(selection),
                fresh.text_styles(selection),
                "{at}"
            );
            // And against one reading from the start, kept points aside.
            let units: Vec<u16> = text.encode_utf16().collect();
            let symbol = doc.insert_symbol("\\alpha", selection).edit.text;
            assert_eq!(symbol == "\\alpha", math_mode_at(&units[..start]), "{at}");
        }
    }
}

/// What the pieces above lack: CRLF line ends, characters of two units, and
/// whole commands and environments, the document's own among them.
const MORE: &[&str] = &[
    "\r\n",
    "\r\n\r\n",
    "😀",
    "𐐀",
    "é",
    "%",
    "\\ref{x}",
    "\\cite[p.~3]{key}",
    "\\(",
    "\\)",
    "\\begin{align*}",
    "\\end{align*}",
    "\\begin{document}",
    "\\end{document}",
    "\\underline{",
    "\\verb*+a+",
];

const PROSE: &[&str] = &[
    "Some words in a line.\n",
    "More of them, on a line that ends as Windows ends one.\r\n",
    "\\textbf{bold \\emph{nested \\underline{deep} words} more} ",
    "\\textit{slanted \\textbf{and bold}} ",
    "and $x^2$ maths ",
    "\\[ a = b \\]\n",
    "see \\ref{fig} ",
    "😀 𐐀 ",
    "\\verb|co$de| ",
    "% a comment\r\n",
    "{a group \\emph{in it}} ",
    "\n\n",
];

/// The scanner's keep interval.
const SPACING: usize = 4096;

/// An article of a few kept points' length: its text is in a document
/// environment, styled groups nested in it, and a \cite's and a \ref's
/// arguments each run over a kept point. Without `paragraphs` it has no
/// blank line, so an argument an edit leaves open runs on over the rest.
fn article(seed: &mut Seeded, paragraphs: bool) -> String {
    let mut prose = |pieces: usize| -> String {
        (0..pieces)
            .map(|_| PROSE[seed.next(PROSE.len() - !paragraphs as usize)])
            .collect()
    };
    format!(
        "\\documentclass{{article}}\r\n\\usepackage[utf8]{{inputenc}}\r\n\\begin{{document}}\r\n\
         {}\\cite{{{}}} {}\\ref{{{}}} {}\\end{{document}}\r\n",
        prose(30),
        "key𐐀, ".repeat(650),
        prose(30),
        "fig:a-".repeat(720),
        prose(30),
    )
}

#[test]
fn every_answer_after_every_edit_is_a_fresh_reading_s() {
    // The selections found in a text style, which the test is to ask about.
    let mut styled = 0;
    let (documents, rounds) = (runs(4, 2), runs(200, 120));
    for document in 1..=documents {
        let mut seed = Seeded(document as u32);
        let mut doc = SourceDocument::new("");
        let mut units: Vec<u16> = Vec::new();
        for round in 0..rounds {
            let len = units.len();
            let (at, cut, piece) = if round % 20 == 0 {
                // Random edits leave less and less of a document to ask
                // about, so every so often a new one is pasted over it.
                (0, len, article(&mut seed, round % 40 == 0))
            } else {
                // Anywhere, a surrogate pair's middle too, or just past a
                // kept point, where what runs over it ends.
                let at = match seed.next(2) {
                    0 => seed.next(len + 1),
                    _ => (SPACING * (1 + seed.next(2)) + seed.next(1_500)).min(len),
                };
                let cut = [0, seed.next(8), seed.next(200)][seed.next(3)].min(len - at);
                let k = seed.next(PIECES.len() + MORE.len() + 8);
                let piece = PIECES.iter().chain(MORE).nth(k).copied();
                (at, cut, piece.unwrap_or_default().to_string())
            };
            doc.edit(at as u32, cut as u32, &piece);
            units.splice(at..at + cut, piece.encode_utf16());
            let text = String::from_utf16_lossy(&units);
            assert_eq!(doc.text(), text, "document {document}, round {round}");
            let mut fresh = SourceDocument::new(&text);
            let len = units.len();
            // Half the time the text's end first, which keeps every point.
            if seed.next(2) == 0 {
                let (from, length) = (len.saturating_sub(40) as u32, 40);
                assert_eq!(
                    doc.not_prose(from, length),
                    fresh.not_prose(from, length),
                    "document {document}, round {round}, the end"
                );
            }
            // Every answer about a place anywhere, or by the edit.
            let start = [seed.next(len + 1), (at + seed.next(64)).min(len)][round % 2];
            let length = [0, 1, seed.next(400)][seed.next(3)].min(len - start);
            let (from, length) = (start as u32, length as u32);
            let selection = range(from, length);
            let at = format!("document {document}, round {round}, {start}+{length}");
            assert_eq!(
                doc.not_prose(from, length),
                fresh.not_prose(from, length),
                "{at}"
            );
            assert_eq!(
                doc.text_styles(selection),
                fresh.text_styles(selection),
                "{at}"
            );
            let symbol = doc.insert_symbol("\\alpha", selection);
            assert_eq!(symbol, fresh.insert_symbol("\\alpha", selection), "{at}");
            let in_maths = math_mode_at(&units[..start]);
            assert_eq!(symbol.edit.text == "\\alpha", in_maths, "{at}");
            assert_eq!(
                doc.highlights(from, length),
                fresh.highlights(from, length),
                "{at}"
            );
            // And the styles of a few units just inside a brace group, which
            // the document's are nested in.
            let from = seed.next(len + 1);
            let brace = units[from..].iter().position(|&u| u == '{' as u16);
            let start = (from + brace.unwrap_or_default() + 1 + seed.next(3)).min(len);
            let selection = range(start as u32, seed.next(12).min(len - start) as u32);
            let styles = doc.text_styles(selection);
            assert_eq!(styles, fresh.text_styles(selection), "{at}, {selection:?}");
            styled += (styles != Default::default()) as usize;
        }
    }
    let asked = documents * rounds;
    assert!(
        styled > asked / 8,
        "{styled} of {asked} selections in a text style"
    );
}

#[test]
fn a_kept_point_s_names_follow_an_edit_past_it() {
    // A \cite argument runs over the point kept at 4096 and closes at 5000.
    let source = format!(
        "\\cite{{{}}} word \\ref{{x}} {} end",
        "a".repeat(4994),
        "word ".repeat(1200)
    );
    let mut doc = SourceDocument::new(&source);
    assert!(doc.not_prose(9_000, 10).is_empty()); // keeps the points at 4096 and 8192
    doc.edit(5_000, 1, ""); // the closing brace goes: the argument runs on
    let mut fresh = SourceDocument::new(&doc.text());
    assert_eq!(doc.not_prose(9_000, 10), fresh.not_prose(9_000, 10));
    assert_eq!(doc.not_prose(9_000, 10), [range(6, 9_004)]);

    // The mirror: an unclosed \cite{ over the point is closed by a typed brace,
    // and a later unclosed \ref{ is a command again.
    let source = format!(
        "\\cite{{{} word \\ref{{ {} end",
        "a".repeat(5994),
        "word ".repeat(1200)
    );
    let mut doc = SourceDocument::new(&source);
    doc.not_prose(9_000, 10);
    doc.edit(5_000, 0, "}");
    let mut fresh = SourceDocument::new(&doc.text());
    assert_eq!(doc.not_prose(9_000, 10), fresh.not_prose(9_000, 10));
}

#[test]
fn a_point_that_read_past_the_question_is_not_resumed_from() {
    // Reading the line feed before 4096 looked at the one after, which made
    // it a blank line and closed the $: but the text before 4096 alone
    // leaves the $ open, as the caret there sees it.
    let source = format!("${}\n\n", "a".repeat(4094));
    let mut doc = SourceDocument::new(&source);
    doc.not_prose(4096, 0); // keeps the points up to 4096
    let symbol = doc.insert_symbol("\\alpha", range(4096, 0));
    assert_eq!(symbol.edit.text, "\\alpha");
}

#[test]
fn what_runs_over_a_kept_point_keeps_its_start() {
    let maths = "x = 1 \\\\\n\n".repeat(1_000);
    let source = format!("Text \\begin{{equation}}\n{maths}\\end{{equation}} prose");
    let found = SourceDocument::new(&source).not_prose(9_000, 5);
    assert_eq!(
        found,
        [range(5, 9_000)],
        "from the maths' start to the question's end"
    );

    // A name argument, the same: and what's in it is no command.
    let names = "key, \\label{inside} ".repeat(500);
    let source = format!("See \\cite{{{names}}} and \\ref{{fig}}.");
    let mut doc = SourceDocument::new(&source);
    let found = doc.not_prose(9_000, 5);
    assert_eq!(
        found,
        [range(10, 8_995)],
        "from the argument's start to the question's end"
    );
    let after = source.find("fig").unwrap() as u32;
    assert_eq!(doc.not_prose(after, 3), [range(after, 3)]);
}
