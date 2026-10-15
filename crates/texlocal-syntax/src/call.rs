//! The commands by name, a JSON object of arguments in and the answer's JSON
//! out, as every host calls them: the C ABI and a wasm build forward here,
//! so each decodes the same shapes. An unknown command, or arguments that
//! aren't an object of the command's, answer none.

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::{SourceDocument, TextRange};

/// The arguments the document's first commands take, each what it needs;
/// any left out are empty.
#[derive(Deserialize, Default)]
#[serde(default)]
struct Args {
    caret: u32,
    explicit: bool,
    labels: Vec<String>,
    citations: Vec<String>,
    command: String,
    id: String,
    selection: TextRange,
    selections: Vec<TextRange>,
    more: bool,
}

fn json(value: impl serde::Serialize) -> Option<String> {
    serde_json::to_string(&value).ok()
}

fn args<T: DeserializeOwned>(args: &Value) -> Option<T> {
    T::deserialize(args).ok()
}

impl SourceDocument {
    /// The commands on the document's text, and those of `call`:
    /// "completions", "toggle_comment", "indent", "set_heading",
    /// "insert_block", "insert_symbol", "math_at", "text_styles",
    /// "not_prose" (the `selection`'s), "text", and "set_symbols", whose
    /// `labels` and `citations` "completions" offers until they are set
    /// again (it answers null).
    pub fn call(&mut self, command: &str, args_json: &str) -> Option<String> {
        let value: Value = serde_json::from_str(args_json).ok()?;
        if !value.is_object() {
            return None;
        }
        let a: Args = args(&value)?;
        match command {
            "completions" => {
                json(self.completions(a.caret, a.explicit, &self.labels, &self.citations))
            }
            "toggle_comment" => json(self.toggle_comment(&a.selections)),
            "indent" => json(self.indent(&a.selections, a.more)),
            "set_heading" => json(self.set_heading(a.caret, &a.command)),
            "insert_block" => json(self.insert_block(&a.id, a.selection)),
            "insert_symbol" => json(self.insert_symbol(&a.command, a.selection)),
            "math_at" => json(self.math_at(a.caret)),
            "text_styles" => json(self.text_styles(a.selection)),
            "not_prose" => json(self.not_prose(a.selection.start, a.selection.length)),
            "text" => json(self.text()),
            "set_symbols" => {
                self.set_symbols(a.labels, a.citations);
                json(())
            }
            _ => call_with(command, &value),
        }
    }
}

/// The commands that need no document.
pub fn call(command: &str, args_json: &str) -> Option<String> {
    let value: Value = serde_json::from_str(args_json).ok()?;
    if !value.is_object() {
        return None;
    }
    call_with(command, &value)
}

fn call_with(command: &str, _value: &Value) -> Option<String> {
    #[allow(clippy::match_single_binding)]
    match command {
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::SourceDocument;

    #[test]
    fn commands_answer_by_name() {
        let mut doc = SourceDocument::new("\\cite{kn");
        let symbols = r#"{"labels": [], "citations": ["knuth84"]}"#;
        assert_eq!(doc.call("set_symbols", symbols).as_deref(), Some("null"));
        let offer = doc.call("completions", r#"{"caret": 8}"#).unwrap();
        assert!(offer.contains(r#""label":"knuth84""#), "{offer}");
        assert_eq!(doc.call("text", "{}").as_deref(), Some(r#""\\cite{kn""#));
        assert_eq!(doc.call("no such command", "{}"), None);
        assert_eq!(doc.call("text", "[]"), None);
        assert_eq!(doc.call("indent", r#"{"selections": 3}"#), None);
    }
}
