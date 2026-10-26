use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::complete::SnippetField;
use super::edit::{Style, map_selections};
use super::{Checker, SourceDocument, TextEdit, TextRange};
use super::{catalog, headings, render};
use crate::service::parse;

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
