mod common;

use std::ops::RangeInclusive;

use common::run;
use serde_json::{Value, json};
use texlocal_latex::syntax::{Source, SourceDocument, TextRange};
use texlocal_latex::utf16;

const FRAGMENTS: &[&str] = &[
    "\\begin{",
    "\\end{",
    "align}",
    "itemize}",
    "verbatim}",
    "\\item ",
    "$",
    "$$",
    "\\(",
    "\\)",
    "\\[",
    "\\]",
    "%",
    "{",
    "}",
    "[",
    "]",
    "\\verb|",
    "|",
    "\\",
    "\\section{A}",
    "\\label{a}",
    "\\ref{",
    "\\cite{k,",
    "\\input{ch}",
    "\\newcommand{\\R}{\\mathbb{R}}",
    "\\R",
    "\\textbf{",
    "x",
    "word ",
    " ",
    "\t",
    "\n",
    "\n\n",
    "\r\n",
    "é",
    "😀",
];

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    fn chance(&mut self, in_n: usize) -> bool {
        self.below(in_n) == 0
    }

    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }

    fn text(&mut self, most: usize) -> String {
        (0..self.below(most + 1))
            .map(|_| *self.pick(FRAGMENTS))
            .collect()
    }

    fn offset(&mut self, len: usize) -> u32 {
        match self.below(20) {
            0 => u32::MAX - self.below(3) as u32,
            1 => (len + self.below(8)) as u32,
            _ => self.below(len + 1) as u32,
        }
    }

    fn range(&mut self, len: usize) -> Value {
        let start = self.offset(len);
        let length = if self.chance(20) {
            u32::MAX
        } else {
            self.below(12) as u32
        };
        json!({ "start": start, "length": length })
    }

    /// Selections as the editor gives them, in order and apart, though now and then out of order or past the end.
    fn ranges(&mut self, len: usize) -> Value {
        let count = 1 + self.below(3);
        if self.chance(10) {
            return Value::Array((0..count).map(|_| self.range(len)).collect());
        }
        let mut bounds: Vec<usize> = (0..2 * count).map(|_| self.below(len + 1)).collect();
        bounds.sort_unstable();
        let range = |pair: &[usize]| json!({ "start": pair[0], "length": pair[1] - pair[0] });
        Value::Array(bounds.chunks(2).map(range).collect())
    }
}

fn end(range: &Value) -> u64 {
    range["start"].as_u64().unwrap() + range["length"].as_u64().unwrap()
}

/// Whether each range starts at or after the end of the one before, and the last ends by `len`.
fn in_order(ranges: &[Value], len: usize) -> bool {
    let apart = |pair: &[Value]| pair[1]["start"].as_u64().unwrap() >= end(&pair[0]);
    ranges.windows(2).all(apart) && ranges.last().is_none_or(|last| end(last) <= len as u64)
}

/// The selections a call is given, one or several.
fn given(args: &Value) -> Vec<Value> {
    match args.get("selections") {
        Some(selections) => selections.as_array().unwrap().clone(),
        None => args.get("selection").into_iter().cloned().collect(),
    }
}

/// The text's length once in-order `edits` inside it are made.
fn edited(len: usize, edits: &[Value]) -> u64 {
    let grown = |edit: &Value| {
        utf16::len(edit["text"].as_str().unwrap()) as i64 - edit["length"].as_i64().unwrap()
    };
    (len as i64 + edits.iter().map(grown).sum::<i64>()) as u64
}

/// The ends of what an answer has the editor select once its edits are made: a change's selections, a keystroke's
/// selection, an insertion's caret or a snippet's next field.
fn selected_ends(answer: &Value) -> Vec<u64> {
    let selections = answer["selections"].as_array().into_iter().flatten();
    let one = [&answer["selection"], &answer["field"]]
        .into_iter()
        .filter(|r| r.is_object());
    let mut ends: Vec<u64> = selections.chain(one).map(end).collect();
    ends.extend(answer["caret"].as_u64());
    ends
}

/// The edits an answer asks for, which the editor makes back to front.
fn edits(call: &str, answer: &Value) -> Vec<Value> {
    let edits = match call {
        "ToggleComment" => answer,
        _ if answer["edit"].is_object() => return vec![answer["edit"].clone()],
        _ => &answer["edits"],
    };
    edits.as_array().cloned().unwrap_or_default()
}

fn args(rng: &mut Rng, call: &str, len: usize) -> Value {
    let (at, selection, selections) = (rng.offset(len), rng.range(len), rng.ranges(len));
    match call {
        "Complete" => json!({ "caret": at, "explicit": rng.chance(2) }),
        "ToggleComment" | "DuplicateLines" | "DeleteLines" => json!({ "selections": selections }),
        "SetHeading" => {
            json!({ "caret": at, "command": rng.pick(&["section", "chapter", "", "bogus"]) })
        }
        "InsertBlock" => {
            json!({ "id": rng.pick(&["figure", "itemize", "nothing"]), "selection": selection })
        }
        "InsertSymbol" => {
            json!({ "command": rng.pick(&["\\alpha", "\\frac{#{}}{#{}}", ""]), "selection": selection })
        }
        "MathAt" => json!({ "caret": at }),
        "StylesAt" | "Words" | "InsertNewline" | "SelectsCommand" => {
            json!({ "selection": selection })
        }
        "CodeRanges" => {
            json!({ "selection": selection, "checker": rng.pick(&["spelling", "writingTools"]) })
        }
        "TypeText" => {
            json!({ "selection": selection, "text": rng.text(1), "autoPair": rng.chance(2) })
        }
        "DeleteBackward" => json!({ "selection": selection, "autoPair": rng.chance(2) }),
        "PasteTable" => {
            json!({ "selection": selection, "cells": rng.pick(&["a\tb\n1\t2", "a,b", "a"]), "booktabs": rng.chance(2) })
        }
        "Partner" | "DefinitionAt" | "SymbolAt" | "ReferenceAt" => json!({ "at": at }),
        "Cite" => json!({ "key": rng.pick(&["k", "a,b", ""]), "selection": selection }),
        "StartSnippet" => {
            let mut field = || json!({ "start": rng.below(8), "length": rng.below(4), "index": 0 });
            json!({ "fields": [field(), field()], "at": at })
        }
        "EndSnippet" | "Folds" => json!({}),
        "InsertTab" => json!({ "selections": selections, "step": rng.below(3) as i64 - 1 }),
        "MoveLines" => json!({ "selections": selections, "up": rng.chance(2) }),
        "ToggleStyle" => {
            json!({ "selections": selections, "style": rng.pick(&["bold", "italic", "underline"]) })
        }
        "Wrap" => {
            json!({ "selections": selections, "template": rng.pick(&["$$0$", "\\emph{$0}", "$0"]) })
        }
        "MapSelections" => {
            let edit =
                json!({ "start": rng.offset(len), "length": rng.below(4), "text": rng.text(1) });
            json!({ "edits": [edit], "selections": selections })
        }
        other => panic!("no arguments for {other}"),
    }
}

fn calls() -> Vec<&'static str> {
    let schemas = schemars::SchemaGenerator::default;
    let described = Source::describe(&mut schemas(), &mut schemas());
    described.into_iter().map(|call| call.name).collect()
}

fn apply(
    doc: &mut SourceDocument,
    model: &mut Vec<u16>,
    edit: &Value,
    mirroring: bool,
) -> Vec<Value> {
    let start = (edit["start"].as_u64().unwrap() as usize).min(model.len());
    let length = (edit["length"].as_u64().unwrap() as usize).min(model.len() - start);
    let text = edit["text"].as_str().unwrap();
    model.splice(start..start + length, text.encode_utf16());
    let mirrors = doc.apply_edit(start as u32, length as u32, text, None, mirroring);
    mirrors.iter().map(|edit| json!(edit)).collect()
}

fn each_seed(seeds: RangeInclusive<u64>, run: impl Fn(u64) + Sync) {
    std::thread::scope(|scope| {
        for seed in seeds {
            let run = &run;
            scope.spawn(move || run(seed));
        }
    });
}

#[test]
fn random_edits_and_calls_never_panic_and_keep_the_text() {
    let calls = calls();
    each_seed(1..=100, |seed| {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        let mut model: Vec<u16> = rng.text(30).encode_utf16().collect();
        let mut doc =
            SourceDocument::named(&utf16::lossy(&model), rng.pick(&["main.tex", "refs.bib"]));
        for step in 0..200 {
            let len = model.len();
            let edits = if rng.chance(2) {
                let start = rng.below(len + 1);
                let length = rng.below(len - start + 1).min(rng.below(6));
                vec![json!({ "start": start, "length": length, "text": rng.text(3) })]
            } else {
                let call = *rng.pick(&calls);
                let args = args(&mut rng, call, len);
                let apart = in_order(&given(&args), len);
                let answer = run(&mut doc, call, args);
                let edits = edits(call, &answer);
                let edited = edited(len, &edits);
                let within = selected_ends(&answer).iter().all(|&end| end <= edited);
                assert!(
                    !apart || (in_order(&edits, len) && within),
                    "seed {seed}, step {step}: {call} {answer}"
                );
                edits
            };
            for edit in edits.iter().rev() {
                for mirror in apply(&mut doc, &mut model, edit, false) {
                    apply(&mut doc, &mut model, &mirror, true);
                }
            }
            doc.highlights(rng.offset(len), rng.offset(len));
            let (start, length) = (rng.offset(len), rng.below(12) as u32);
            doc.select(TextRange { start, length }, rng.chance(4));
            doc.command_ranges(doc.line_at(rng.offset(len)), "\\section");
            assert_eq!(doc.text(), utf16::lossy(&model), "seed {seed}, step {step}");
            let lines = model.iter().filter(|&&u| u == u16::from(b'\n')).count();
            assert_eq!(doc.line_count() as usize, lines + 1);
        }
    });
}

fn answers(doc: &mut SourceDocument, rng: &mut Rng) -> Vec<Value> {
    let text = doc.text();
    let len = utf16::len(&text);
    let window = (rng.below(len + 1) as u32, rng.below(2000) as u32);
    let highlights = |doc: &mut SourceDocument, (start, length): (u32, u32)| {
        let runs = doc.highlights(start, length).into_iter();
        runs.map(|h| json!([h.start, h.length, format!("{:?}", h.kind)]))
            .collect()
    };
    let whole = json!({ "start": 0, "length": len });
    let mut found = vec![highlights(doc, window), highlights(doc, (0, len as u32))];
    for checker in ["spelling", "writingTools"] {
        found.push(run(
            doc,
            "CodeRanges",
            json!({ "selection": whole, "checker": checker }),
        ));
    }
    found.push(run(doc, "Words", json!({ "selection": whole })));
    for _ in 0..4 {
        let (caret, selection) = (rng.below(len + 1), rng.range(len));
        found.push(run(doc, "MathAt", json!({ "caret": caret })));
        found.push(run(
            doc,
            "InsertSymbol",
            json!({ "command": "\\alpha", "selection": selection }),
        ));
        found.push(run(doc, "StylesAt", json!({ "selection": selection })));
    }
    found.push(run(doc, "Folds", json!({})));
    found
}

#[test]
fn incremental_answers_equal_a_fresh_documents() {
    each_seed(1..=30, |seed| {
        let mut rng = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03));
        let text: String = (0..2400).map(|_| *rng.pick(FRAGMENTS)).collect();
        let mut doc = SourceDocument::named(&text, "main.tex");
        for _ in 0..4 {
            answers(&mut doc, &mut rng);
            let len = utf16::len(&doc.text());
            let start = rng.below(len + 1);
            let length = rng.below(len - start + 1).min(rng.below(40));
            doc.apply_edit(start as u32, length as u32, &rng.text(4), None, false);
            let mut fresh = SourceDocument::named(&doc.text(), "main.tex");
            let probe = rng.next();
            let warm = answers(&mut doc, &mut Rng(probe));
            assert_eq!(warm, answers(&mut fresh, &mut Rng(probe)), "seed {seed}");
        }
    });
}
