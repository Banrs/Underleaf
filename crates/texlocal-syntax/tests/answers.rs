//! The answers that read the text from its start (maths and code to skip,
//! text styles, maths at a point) are the same however they're reached:
//! resumed from kept points, after edits that forget some of them.

use texlocal_syntax::{SourceDocument, TextRange};

const PIECES: [&str; 32] = [
    "\\cite{",
    "}",
    "}",
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
    "% c",
    "\n",
    "\n",
    "\n\n",
    " word ",
    " prose ",
    "\\usepackage[opt]{pkg}",
    "\\label{x}",
    "\\textit{",
    "x^2",
    "\\\\",
    "\\",
];

struct Seeded(u32);

impl Seeded {
    fn next(&mut self, n: usize) -> usize {
        self.0 = self.0.wrapping_mul(1_103_515_245).wrapping_add(12_345);
        (self.0 >> 8) as usize % n
    }
}

/// FNV-1a over each answer's JSON, for documents of 3,000 seeded pieces
/// (several kept points' worth), asked about at seeded places between
/// seeded edits.
fn seeded_answers_fingerprint() -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    let mut add = |json: String| {
        for byte in json.bytes() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3);
        }
    };
    let mut seed = Seeded(5);
    for _ in 0..4 {
        let pieces = 3_000;
        let source: String = (0..pieces)
            .map(|_| PIECES[seed.next(PIECES.len())])
            .collect();
        let mut doc = SourceDocument::new(&source);
        let mut len = source.encode_utf16().count();
        for round in 0..60 {
            if round % 3 == 0 {
                let at = seed.next(len + 1);
                let cut = seed.next(8).min(len - at);
                let piece = PIECES[seed.next(PIECES.len())];
                doc.edit(at as u32, cut as u32, piece);
                len = len - cut + piece.encode_utf16().count();
            }
            let start = seed.next(len + 1);
            let length = seed.next(400).min(len - start);
            let selection = TextRange {
                start: start as u32,
                length: length as u32,
            };
            let json = |value| serde_json::to_string(&value).unwrap();
            add(json(serde_json::json!([
                doc.not_prose(selection.start, selection.length),
                doc.text_styles(selection),
                doc.insert_symbol("\\alpha", selection),
            ])));
        }
        add(doc.text());
    }
    hash
}

#[test]
fn answers_are_as_reading_from_the_start_gave_them() {
    // The fingerprint when every answer read the text from its start.
    assert_eq!(seeded_answers_fingerprint(), 17_598_375_653_573_153_450);
}

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
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
fn maths_running_over_a_kept_point_keeps_its_start() {
    let maths = "x = 1 \\\\\n\n".repeat(1_000);
    let source = format!("Text \\begin{{equation}}\n{maths}\\end{{equation}} prose");
    let doc = SourceDocument::new(&source);
    let found = doc.not_prose(9_000, 5);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].start, 5);
}

#[test]
fn questions_about_a_long_text_read_only_near_them() {
    // 2.8 million units, with no braces left open: each question had read
    // it all from the start, some 15 ms each in a release build.
    let source = "A paragraph with $x^2$ and \\textbf{bold \\emph{words}}.\n\n".repeat(50_000);
    let len = source.encode_utf16().count() as u32;
    let mut doc = SourceDocument::new(&source);
    let started = std::time::Instant::now();
    for k in 0..200 {
        let at = len - 1_000 - k * 37;
        doc.not_prose(at, 40);
        doc.text_styles(range(at, 3));
        if k % 20 == 0 {
            doc.edit(at + 500, 0, "x");
        }
    }
    let elapsed = started.elapsed();
    assert!(elapsed < std::time::Duration::from_secs(10), "{elapsed:?}");
    let at = doc.text().rfind("words").unwrap() as u32;
    assert!(doc.text_styles(range(at, 5)).bold.is_some());
}
