use serde_json::{Value, json};
use texlocal_latex::syntax::{Source, SourceDocument};
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

    fn ranges(&mut self, len: usize) -> Value {
        Value::Array((0..1 + self.below(3)).map(|_| self.range(len)).collect())
    }
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
        "StylesAt" | "Words" | "InsertNewline" => json!({ "selection": selection }),
        "CodeRanges" => {
            json!({ "selection": selection, "checker": rng.pick(&["spelling", "writingTools"]) })
        }
        "TypeText" => {
            json!({ "selection": selection, "text": rng.text(1), "autoPair": rng.chance(2) })
        }
        "DeleteBackward" => json!({ "selection": selection, "autoPair": rng.chance(2) }),
        "Partner" | "DefinitionAt" | "SymbolAt" => json!({ "at": at }),
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
    let mut generator = schemars::SchemaGenerator::default();
    let described = Source::describe(&mut generator, &mut schemars::SchemaGenerator::default());
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

#[test]
fn random_edits_and_calls_never_panic_and_keep_the_text() {
    let calls = calls();
    for seed in 1..=100_u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        let mut model: Vec<u16> = rng.text(30).encode_utf16().collect();
        let mut doc =
            SourceDocument::named(&utf16::lossy(&model), rng.pick(&["main.tex", "refs.bib"]));
        for step in 0..200 {
            let len = model.len();
            let mut edits = Vec::new();
            if rng.chance(2) {
                let start = rng.below(len + 1);
                let length = rng.below(len - start + 1).min(rng.below(6));
                edits.push(json!({ "start": start, "length": length, "text": rng.text(3) }));
            } else {
                let call = *rng.pick(&calls);
                let answer = Source::call(&mut doc, call, args(&mut rng, call, len));
                let edit = answer.ok().and_then(|answer| answer.get("edit").cloned());
                edits.extend(edit.filter(Value::is_object));
            }
            for edit in edits {
                for mirror in apply(&mut doc, &mut model, &edit, false) {
                    apply(&mut doc, &mut model, &mirror, true);
                }
            }
            doc.highlights(rng.offset(len), rng.offset(len));
            doc.command_ranges(doc.line_at(rng.offset(len)), "\\section");
            assert_eq!(doc.text(), utf16::lossy(&model), "seed {seed}, step {step}");
            let lines = model.iter().filter(|&&u| u == u16::from(b'\n')).count();
            assert_eq!(doc.line_count() as usize, lines + 1);
        }
    }
}

fn run(doc: &mut SourceDocument, call: &str, args: Value) -> Value {
    Source::call(doc, call, args).expect(call)
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
    for seed in 1..=30_u64 {
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
    }
}
