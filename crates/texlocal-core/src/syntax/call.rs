//! The commands by name: a JSON object of arguments in, the answer's JSON out, as the C ABI forwards them.
//! An argument a command needs is required: one left out is no call, never the text's start.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::complete::SnippetField;
use super::edit::{Style, map_selections};
use super::{Checker, SourceDocument, TextEdit, TextRange};
use super::{catalog, headings, render};
use crate::service::parse;

/// A source's commands (docs/core-api.md): a table, one a line.
#[derive(Deserialize)]
#[serde(tag = "call", rename_all = "snake_case", rename_all_fields = "camelCase")]
#[rustfmt::skip]
enum Command {
    Completions { caret: u32, explicit: bool },
    ToggleComment { selections: Vec<TextRange> },
    SetHeading { caret: u32, command: String },
    InsertBlock { id: String, selection: TextRange },
    InsertSymbol { command: String, selection: TextRange },
    MathAt { caret: u32 },
    TextStyles { selection: TextRange },
    CodeRanges { selection: TextRange, #[serde(rename = "for")] checker: Checker },
    Words { #[serde(flatten)] range: TextRange },
    Type { selection: TextRange, text: String, auto_pair: bool },
    DeleteBackward { selection: TextRange, auto_pair: bool },
    InsertNewline { selection: TextRange },
    Partner { at: u32 },
    Definition { at: u32 },
    StartSnippet { fields: Vec<SnippetField>, at: u32 },
    EndSnippet,
    Tab { selections: Vec<TextRange>, step: i64 },
    MoveLines { selections: Vec<TextRange>, up: bool },
    DuplicateLines { selections: Vec<TextRange> },
    DeleteLines { selections: Vec<TextRange> },
    ToggleStyle { selections: Vec<TextRange>, style: Style },
    Wrap { selections: Vec<TextRange>, template: String },
    MapSelections { edits: Vec<TextEdit>, selections: Vec<TextRange> },
    Folds,
}

/// The commands that need no document.
#[derive(Deserialize)]
#[serde(tag = "call", rename_all = "snake_case", rename_all_fields = "camelCase")]
#[rustfmt::skip]
enum Free {
    MathSvg { tex: String, display: bool, size: f64 },
    Menus,
    HeadingStyles,
}

fn json(value: impl Serialize) -> Option<String> {
    serde_json::to_string(&value).ok()
}

fn read<T: DeserializeOwned>(command: &str, args_json: &str) -> Option<T> {
    parse(command, serde_json::from_str(args_json).ok()?).ok()
}

impl SourceDocument {
    pub fn call(&mut self, command: &str, args_json: &str) -> Option<String> {
        match read(command, args_json)? {
            Command::Completions { caret, explicit } => json(self.completions(caret, explicit)),
            Command::ToggleComment { selections } => json(self.toggle_comment(&selections)),
            Command::SetHeading { caret, command } => json(self.set_heading(caret, &command)),
            Command::InsertBlock { id, selection } => json(self.insert_block(&id, selection)),
            Command::InsertSymbol { command, selection } => {
                json(self.insert_symbol(&command, selection))
            }
            Command::MathAt { caret } => json(self.math_at(caret)),
            Command::TextStyles { selection } => json(self.text_styles(selection)),
            Command::CodeRanges { selection, checker } => {
                json(self.code_ranges(selection, checker))
            }
            Command::Words { range } => json(json!({ "words": self.words(range) })),
            Command::Type {
                selection,
                text,
                auto_pair,
            } => json(self.type_text(selection, &text, auto_pair)),
            Command::DeleteBackward {
                selection,
                auto_pair,
            } => json(self.delete_backward(selection, auto_pair)),
            Command::InsertNewline { selection } => json(self.insert_newline(selection)),
            Command::Partner { at } => json(self.partner(at)),
            Command::Definition { at } => json(self.definition(at)),
            Command::StartSnippet { fields, at } => json(self.start_snippet(&fields, at)),
            Command::EndSnippet => json(self.end_snippet()),
            Command::Tab { selections, step } => json(self.tab(&selections, step)),
            Command::MoveLines { selections, up } => json(self.move_lines(&selections, up)),
            Command::DuplicateLines { selections } => json(self.duplicate_lines(&selections)),
            Command::DeleteLines { selections } => json(self.delete_lines(&selections)),
            Command::ToggleStyle { selections, style } => {
                json(self.toggle_style(&selections, style))
            }
            Command::Wrap {
                selections,
                template,
            } => json(self.wrap(&selections, &template)),
            Command::MapSelections { edits, selections } => {
                json(map_selections(&edits, &selections))
            }
            Command::Folds => json(self.folds()),
        }
    }
}

fn rendered(result: Result<render::MathSvg, String>) -> Option<String> {
    match result {
        Ok(svg) => json(svg),
        Err(error) => json(json!({ "error": error })),
    }
}

/// The commands that need no document; docs/core-api.md lists them.
pub fn call(command: &str, args_json: &str) -> Option<String> {
    match read(command, args_json)? {
        Free::MathSvg { tex, display, size } => rendered(render::math_svg(&tex, display, size)),
        Free::Menus => {
            let catalog = &*catalog::CATALOG;
            json(json!({ "templates": catalog.templates, "symbolGroups": catalog.symbol_groups }))
        }
        Free::HeadingStyles => json(headings::heading_styles(None)),
    }
}

#[cfg(test)]
mod tests {
    use super::call;
    use crate::syntax::SourceDocument;

    #[test]
    fn commands_answer_by_name() {
        #[rustfmt::skip]
        let cases = [
            ("type", r#"{"selection": {"start": 0, "length": 0}, "text": "{", "autoPair": true}"#,
                Some(r#"{"edit":{"start":0,"length":0,"text":"{}"},"selection":{"start":1,"length":0},"partner":null,"completions":"offer"}"#)),
            ("type", r#"{"selection": {"start": 0, "length": 0}, "text": "{", "autoPair": false}"#,
                Some(r#"{"edit":null,"selection":null,"partner":null,"completions":"offer"}"#)),
            ("tab", r#"{"selections": [{"start": 0, "length": 0}]}"#, None),
            ("tab", r#"{"selections": [{"start": 0, "length": 0}], "step": 1}"#,
                Some(r#"{"field":null,"edits":[{"start":0,"length":0,"text":"  "}]}"#)),
            ("map_selections", r#"{"edits": [{"start": 0, "length": 0, "text": "ab"}], "selections": [{"start": 0, "length": 1}]}"#,
                Some(r#"[{"start":2,"length":1}]"#)),
            ("partner", r#"{"at": 0}"#, Some("null")),
            ("completions", r#"{"caret": 0, "explicit": false}"#, Some("null")),
            ("partner", "{}", None),
            ("partner", "[]", None),
            ("math_at", r#"{"selection": 1}"#, None),
            ("move_lines", r#"{"selections": []}"#, None),
            ("toggle_comment", r#"{"selections": 3}"#, None),
            ("toggle_style", r#"{"selections": [], "style": "strong"}"#, None),
            ("no such command", "{}", None),
            ("follow", r#"{"old": {"start": 0, "length": 0}, "delta": 2}"#, None),
            ("themes", "{}", None),
        ];
        let mut doc = SourceDocument::new("");
        for (command, args, answer) in cases {
            assert_eq!(doc.call(command, args).as_deref(), answer, "{command}");
        }
    }

    #[test]
    fn the_free_commands_answer_by_name() {
        let menus: serde_json::Value = serde_json::from_str(&call("menus", "{}").unwrap()).unwrap();
        let alpha = serde_json::json!({ "glyph": "α", "command": "\\alpha" });
        assert!(
            menus["symbolGroups"][0]["symbols"]
                .as_array()
                .unwrap()
                .contains(&alpha)
        );
        assert!(menus["templates"]["math"].is_array());
        let levels = call("heading_styles", "{}").unwrap();
        assert!(levels.starts_with(r#"[{"title":"Normal Text","command":"""#));
        let maths = call(
            "math_svg",
            r#"{"tex": "x^2", "display": false, "size": 10}"#,
        );
        let maths: serde_json::Value = serde_json::from_str(&maths.unwrap()).unwrap();
        for key in ["svg", "width", "height"] {
            assert!(maths.get(key).is_some(), "{key}");
        }
        let error = call("math_svg", r#"{"tex": "x^", "display": false, "size": 10}"#).unwrap();
        assert!(error.starts_with(r#"{"error":"#), "{error}");
    }
}
