#![allow(dead_code)]

use std::sync::Arc;

use serde_json::{Value, json};
use texlocal_latex::facts::Facts;
use texlocal_latex::file_kind;
use texlocal_latex::project::Scan;
use texlocal_latex::syntax::{Installed, Source, SourceDocument, TextEdit};

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

pub fn scan(files: &[(&str, &str)], installed: Installed) -> Scan {
    let read = |&(name, text): &(&str, &str)| {
        (
            name.to_owned(),
            Arc::new(Facts::read(text, file_kind(name))),
        )
    };
    let names = files.iter().map(|(name, _)| (*name).to_owned()).collect();
    Scan::new(files.iter().map(read).collect(), names, Arc::new(installed))
}
