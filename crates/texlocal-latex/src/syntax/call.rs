use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::complete::SnippetField;
use super::edit::{Style, map_selections};
use super::{Checker, SourceDocument, TextEdit, TextRange};
use super::{catalog, headings, render};

#[derive(Deserialize)]
#[serde(tag = "call", rename_all = "snake_case", rename_all_fields = "camelCase")]
#[rustfmt::skip]
enum SourceCommand {
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
enum SyntaxCommand {
    MathSvg { tex: String, display: bool, size: f64 },
    Menus,
    HeadingStyles,
}

fn json(value: impl Serialize) -> Option<String> {
    serde_json::to_string(&value).ok()
}

fn read<T: DeserializeOwned>(command: &str, args_json: &str) -> Option<T> {
    let mut args: Value = serde_json::from_str(args_json).ok()?;
    args.as_object_mut()?.insert("call".into(), command.into());
    T::deserialize(args).ok()
}

impl SourceDocument {
    pub fn call(&mut self, command: &str, args_json: &str) -> Option<String> {
        match read(command, args_json)? {
            SourceCommand::Completions { caret, explicit } => {
                json(self.completions(caret, explicit))
            }
            SourceCommand::ToggleComment { selections } => json(self.toggle_comment(&selections)),
            SourceCommand::SetHeading { caret, command } => json(self.set_heading(caret, &command)),
            SourceCommand::InsertBlock { id, selection } => json(self.insert_block(&id, selection)),
            SourceCommand::InsertSymbol { command, selection } => {
                json(self.insert_symbol(&command, selection))
            }
            SourceCommand::MathAt { caret } => json(self.math_at(caret)),
            SourceCommand::TextStyles { selection } => json(self.text_styles(selection)),
            SourceCommand::CodeRanges { selection, checker } => {
                json(self.code_ranges(selection, checker))
            }
            SourceCommand::Words { range } => json(json!({ "words": self.words(range) })),
            SourceCommand::Type {
                selection,
                text,
                auto_pair,
            } => json(self.type_text(selection, &text, auto_pair)),
            SourceCommand::DeleteBackward {
                selection,
                auto_pair,
            } => json(self.delete_backward(selection, auto_pair)),
            SourceCommand::InsertNewline { selection } => json(self.insert_newline(selection)),
            SourceCommand::Partner { at } => json(self.partner(at)),
            SourceCommand::Definition { at } => json(self.definition(at)),
            SourceCommand::StartSnippet { fields, at } => json(self.start_snippet(&fields, at)),
            SourceCommand::EndSnippet => json(self.end_snippet()),
            SourceCommand::Tab { selections, step } => json(self.tab(&selections, step)),
            SourceCommand::MoveLines { selections, up } => json(self.move_lines(&selections, up)),
            SourceCommand::DuplicateLines { selections } => json(self.duplicate_lines(&selections)),
            SourceCommand::DeleteLines { selections } => json(self.delete_lines(&selections)),
            SourceCommand::ToggleStyle { selections, style } => {
                json(self.toggle_style(&selections, style))
            }
            SourceCommand::Wrap {
                selections,
                template,
            } => json(self.wrap(&selections, &template)),
            SourceCommand::MapSelections { edits, selections } => {
                json(map_selections(&edits, &selections))
            }
            SourceCommand::Folds => json(self.folds()),
        }
    }
}

pub fn call(command: &str, args_json: &str) -> Option<String> {
    match read(command, args_json)? {
        SyntaxCommand::MathSvg { tex, display, size } => {
            json(render::math_svg(&tex, display, size))
        }
        SyntaxCommand::Menus => {
            let catalog = &*catalog::CATALOG;
            json(json!({ "templates": catalog.templates, "symbolGroups": catalog.symbol_groups }))
        }
        SyntaxCommand::HeadingStyles => json(headings::heading_styles(None)),
    }
}
