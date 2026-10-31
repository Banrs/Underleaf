use super::catalog::{Menus, menus};
use super::complete::{Completions, Definition, SnippetField, SymbolName};
use super::edit::{Change, TextStyle, include_graphics, map_selections};
use super::folds::Fold;
use super::headings::{HeadingStyle, heading_styles};
use super::preview::MathPreview;
use super::render::{MathSvg, math_svg};
use super::snippet::Tabbing;
use super::style::TextStyles;
use super::typing::Keystroke;
use super::{Checker, Insertion, SourceDocument, TextEdit, TextRange};
use crate::protocol::calls;

calls! {
    Source(doc: &mut SourceDocument) {
        Complete { caret: u32, explicit: bool } -> Option<&Completions> = doc.complete(caret, explicit);
        AcceptCompletion { index: u32, caret: u32 } -> Option<Insertion> = doc.accept_completion(index, caret);
        ToggleComment { selections: Vec<TextRange> } -> Vec<TextEdit> = doc.toggle_comment(&selections);
        SetHeading { caret: u32, command: String } -> Insertion = doc.set_heading(caret, &command);
        InsertBlock { id: String, selection: TextRange } -> Option<Insertion> = doc.insert_block(&id, selection);
        InsertSymbol { command: String, selection: TextRange } -> Insertion = doc.insert_symbol(&command, selection);
        MathAt { caret: u32 } -> Option<MathPreview> = doc.math_at(caret);
        StylesAt { selection: TextRange } -> TextStyles = doc.text_styles(selection);
        CodeRanges { selection: TextRange, checker: Checker } -> Vec<TextRange> = doc.code_ranges(selection, checker);
        Words { selection: TextRange } -> usize = doc.words(selection);
        TypeText { selection: TextRange, text: String, auto_pair: bool } -> Keystroke = doc.type_text(selection, &text, auto_pair);
        DeleteBackward { selection: TextRange, auto_pair: bool } -> Keystroke = doc.delete_backward(selection, auto_pair);
        InsertNewline { selection: TextRange } -> Keystroke = doc.insert_newline(selection);
        Partner { at: u32 } -> Option<u32> = doc.partner(at);
        SelectsCommand { selection: TextRange } -> bool = doc.selects_command(selection);
        DefinitionAt { at: u32 } -> Option<Definition> = doc.definition(at);
        SymbolAt { at: u32 } -> Option<SymbolName> = doc.symbol(at);
        StartSnippet { fields: Vec<SnippetField>, at: u32 } -> Option<TextRange> = doc.start_snippet(&fields, at);
        EndSnippet {} -> bool = doc.end_snippet();
        InsertTab { selections: Vec<TextRange>, step: i64 } -> Tabbing = doc.tab(&selections, step);
        MoveLines { selections: Vec<TextRange>, up: bool } -> Option<Change> = doc.move_lines(&selections, up);
        DuplicateLines { selections: Vec<TextRange> } -> Change = doc.duplicate_lines(&selections);
        DeleteLines { selections: Vec<TextRange> } -> Change = doc.delete_lines(&selections);
        ToggleStyle { selections: Vec<TextRange>, style: TextStyle } -> Change = doc.toggle_style(&selections, style);
        Wrap { selections: Vec<TextRange>, template: String } -> Change = doc.wrap(&selections, &template);
        MapSelections { edits: Vec<TextEdit>, selections: Vec<TextRange> } -> Vec<TextRange> = map_selections(&edits, &selections);
        Folds {} -> Vec<Fold> = doc.folds();
    }
}

calls! {
    Syntax {
        RenderMath { tex: String, display: bool, size: f64 } -> Option<MathSvg> = math_svg(&tex, display, size);
        ListMenus {} -> Menus = menus();
        HeadingStyles {} -> Vec<HeadingStyle> = heading_styles(None);
        IncludeGraphics { path: String, into: String } -> Option<String> = include_graphics(&path, &into);
    }
}
