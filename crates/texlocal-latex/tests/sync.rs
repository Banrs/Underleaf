use std::io::Write;

use serde_json::{Value, json};
use texlocal_latex::synctex::SyncTex;
use texlocal_latex::wordmatch::{PdfPage, find_in_pdf, find_in_source};

const TWO_PAGES: &[u8] = include_bytes!("fixtures/two-pages.synctex");

fn pages(pages: Value) -> Vec<PdfPage> {
    serde_json::from_value(pages).unwrap()
}

fn in_pdf(line: &str, column: usize, on: &[PdfPage]) -> Value {
    json!(find_in_pdf(line, column, on))
}

#[test]
fn synctex_goes_from_a_line_to_its_page_and_back() {
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    gz.write_all(TWO_PAGES).unwrap();
    for bytes in [TWO_PAGES.to_vec(), gz.finish().unwrap()] {
        let synctex = SyncTex::read(bytes).unwrap();
        let inputs: Vec<(i32, &str)> = synctex.inputs().collect();
        assert!(inputs.contains(&(1, "/p/./main.tex")), "{inputs:?}");
        for (line, page) in [(4, 1), (7, 2)] {
            let shown = synctex.forward(1, line);
            let at = shown.first().unwrap();
            assert_eq!(at.page, page);
            for h in [at.h + 5.0, 1.0] {
                let back = synctex.inverse(page, h, at.v - at.height / 2.0);
                assert_eq!(back, Some(("/p/./main.tex", line)));
            }
        }
        assert!(synctex.forward(9, 1).is_empty());
    }
    assert!(SyncTex::read(b"not SyncTeX".to_vec()).is_none());
}

#[test]
fn a_live_synctex_keeps_the_inputs_read_after_one_has_ended() {
    let live = b"SyncTeX Version:1\nInput:1:sub/main.tex\nInput:2:article.cls\n/2\nInput:3:part.tex\n/3\nOutput:pdf\nMagnification:1000\nUnit:1\nX Offset:0\nY Offset:0\nContent:\n!100\n{1\n[1,4:4736287,46220575:26673152,41484288,0\n(1,4:8799519,8865055:22609920,469238,127139\ng3,1:10492314,8865055\n)\n]\n}1\nPostamble:\n";
    let synctex = SyncTex::read(live.to_vec()).unwrap();
    let inputs: Vec<(i32, &str)> = synctex.inputs().collect();
    assert_eq!(
        inputs,
        [(3, "part.tex"), (2, "article.cls"), (1, "sub/main.tex")]
    );
    assert_eq!(synctex.forward(3, 1).first().map(|at| at.page), Some(1));
}

#[test]
fn a_word_is_found_in_the_pdf_by_the_words_around_it() {
    let text = pages(json!([{ "page": 3, "text": "the world and the world turns", "near": [] }]));
    let hit = in_pdf("the \\emph{world} turns", 11, &text);
    assert_eq!(hit, json!({ "page": 3, "start": 18, "end": 23 }));
    let ligature = pages(json!([{ "page": 1, "text": "the ﬁrst", "near": [] }]));
    assert_eq!(
        in_pdf("the first", 5, &ligature),
        json!({ "page": 1, "start": 4, "end": 8 })
    );
    let short = pages(json!([{ "page": 1, "text": "world", "near": [] }]));
    assert_eq!(in_pdf("worldwide", 2, &short), Value::Null);
}

#[test]
fn a_word_twice_in_the_pdf_needs_the_box_synctex_gives() {
    let twice = json!([{ "page": 1, "text": "a cat. a cat.", "near": [] }]);
    assert_eq!(in_pdf("cat", 1, &pages(twice)), Value::Null);
    let near = pages(
        json!([{ "page": 1, "text": "a cat. a cat.", "near": [{ "start": 9, "length": 3 }] }]),
    );
    assert_eq!(
        in_pdf("cat", 1, &near),
        json!({ "page": 1, "start": 9, "end": 12 })
    );
}

#[test]
fn a_click_in_the_pdf_is_found_in_the_source_near_its_line() {
    let source = "world\nHello \\emph{world}.\nthree";
    assert_eq!(find_in_source(source, 2, "Hello world.", 7), Some((2, 13)));
    assert_eq!(find_in_source(source, 2, "Hello world.", 40), None);
}
