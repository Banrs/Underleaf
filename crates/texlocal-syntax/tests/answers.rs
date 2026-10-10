//! The answers that read the text from its start (maths and code to skip,
//! name arguments, text styles, maths at a point) are the same however
//! they're reached: resumed from kept points, after edits that forget some
//! of them, as on a document read fresh.

use std::time::{Duration, Instant};

use texlocal_syntax::{math_mode_at, SourceDocument, TextRange};

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
    for document in 0..12 {
        // Several kept points' worth; every third with no blank line at all.
        let source: String = (0..3_000)
            .map(|_| loop {
                let piece = PIECES[seed.next(PIECES.len())];
                if document % 3 != 0 || !piece.contains("\n\n") {
                    break piece;
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
            let fresh = SourceDocument::new(&text);
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

#[test]
fn a_point_that_read_past_the_question_is_not_resumed_from() {
    // Reading the line feed before 4096 looked at the one after, which made
    // it a blank line and closed the $: but the text before 4096 alone
    // leaves the $ open, as the caret there sees it.
    let source = format!("${}\n\n", "a".repeat(4094));
    let doc = SourceDocument::new(&source);
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
    let doc = SourceDocument::new(&source);
    let found = doc.not_prose(9_000, 5);
    assert_eq!(
        found,
        [range(10, 8_995)],
        "from the argument's start to the question's end"
    );
    let after = source.find("fig").unwrap() as u32;
    assert_eq!(doc.not_prose(after, 3), [range(after, 3)]);
}

/// 200 spelling and style questions near the end of a long text, between
/// edits, then the time they took.
fn questions_near_the_end(source: &str) -> Duration {
    let len = source.encode_utf16().count() as u32;
    let mut doc = SourceDocument::new(source);
    let started = Instant::now();
    for k in 0..200 {
        let at = len - 1_000 - k * 37;
        doc.not_prose(at, 40);
        doc.text_styles(range(at, 3));
        doc.insert_symbol("\\alpha", range(at, 0));
        if k % 20 == 0 {
            doc.edit(at + 500, 0, "x");
        }
    }
    started.elapsed()
}

#[test]
fn questions_about_a_long_text_read_only_near_them() {
    // 2.8 million units, braces closed and paragraphs short: each question
    // had read it all from the start, 52 s in a test build for these.
    let source = "A paragraph with $x^2$ and \\textbf{bold \\emph{words}}.\n\n".repeat(50_000);
    let elapsed = questions_near_the_end(&source);
    assert!(elapsed < Duration::from_secs(10), "{elapsed:?}");
}

#[test]
fn braces_nobody_closes_cost_no_more_as_they_pile_up() {
    // 20,000 lines, a brace left open on each and no blank line: kept points
    // had been dropped above 64 open groups, and each question read the
    // whole text from the start, twice.
    let source: String = (0..20_000).map(|n| format!("{{ line {n} word\n")).collect();
    let elapsed = questions_near_the_end(&source);
    assert!(elapsed < Duration::from_secs(10), "{elapsed:?}");
}
