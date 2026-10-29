use serde_json::{Value, json};
use texlocal_latex::syntax::{Source, SourceDocument, TextEdit};

pub fn run(doc: &mut SourceDocument, command: &str, args: Value) -> Value {
    Source::call(doc, command, args).expect(command)
}

pub fn caret(at: u32) -> Value {
    json!({ "start": at, "length": 0 })
}

pub fn apply(doc: &mut SourceDocument, edit: &Value) -> Vec<TextEdit> {
    let start = edit["start"].as_u64().unwrap() as u32;
    let length = edit["length"].as_u64().unwrap() as u32;
    doc.apply_edit(start, length, edit["text"].as_str().unwrap(), None, false)
}
