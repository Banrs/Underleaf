//! The commands by name: a JSON object of arguments in, the answer's JSON out, as the C ABI forwards them.
//! An argument a command needs is required: one left out is no call, never the text's start.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::complete::SnippetField;
use super::edit::{Style, map_selections};
use super::theme::{self, Appearance, Rgba};
use super::{Checker, SourceDocument, TextEdit, TextRange};
use super::{catalog, headings, render};
use crate::projects::Query;
use crate::service::parse;

/// A source's commands; docs/core-api.md lists them.
#[derive(Deserialize)]
#[serde(
    tag = "call",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
enum Command {
    Completions {
        caret: u32,
        #[serde(default)]
        explicit: bool,
    },
    ToggleComment {
        selections: Vec<TextRange>,
    },
    SetHeading {
        caret: u32,
        command: String,
    },
    InsertBlock {
        id: String,
        selection: TextRange,
    },
    InsertSymbol {
        command: String,
        selection: TextRange,
    },
    MathAt {
        caret: u32,
    },
    TextStyles {
        selection: TextRange,
    },
    CodeRanges {
        selection: TextRange,
        #[serde(rename = "for")]
        checker: Checker,
    },
    Words {
        #[serde(flatten)]
        range: TextRange,
    },
    Find {
        query: String,
        #[serde(default)]
        match_case: bool,
        #[serde(default)]
        whole_word: bool,
    },
    Type {
        selection: TextRange,
        text: String,
        auto_pair: Option<bool>,
    },
    DeleteBackward {
        selection: TextRange,
        auto_pair: Option<bool>,
    },
    InsertNewline {
        selection: TextRange,
    },
    Partner {
        at: u32,
    },
    Definition {
        at: u32,
    },
    StartSnippet {
        fields: Vec<SnippetField>,
        at: u32,
    },
    EndSnippet,
    Tab {
        selections: Vec<TextRange>,
        step: Option<i64>,
    },
    MoveLines {
        selections: Vec<TextRange>,
        up: bool,
    },
    DuplicateLines {
        selections: Vec<TextRange>,
    },
    DeleteLines {
        selections: Vec<TextRange>,
    },
    ToggleStyle {
        selections: Vec<TextRange>,
        style: Style,
    },
    Wrap {
        selections: Vec<TextRange>,
        template: String,
    },
    MapSelections {
        edits: Vec<TextEdit>,
        selections: Vec<TextRange>,
    },
}

/// The commands that need no document.
#[derive(Deserialize)]
#[serde(
    tag = "call",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
enum Free {
    DropText {
        path: String,
        kind: Option<String>,
        into: Option<String>,
    },
    Themes,
    MathSvg {
        #[serde(default)]
        tex: String,
        #[serde(default)]
        display: bool,
        size: Option<f64>,
        color: Option<Rgba>,
    },
    GlyphSvg {
        #[serde(default)]
        command: String,
        size: Option<f64>,
        side: Option<f64>,
        color: Option<Rgba>,
    },
    Menus,
    HeadingStyles,
    ThemeColors {
        theme: String,
        #[serde(flatten)]
        appearance: Appearance,
    },
    Legible {
        color: Rgba,
        background: Rgba,
        fill: Rgba,
        #[serde(default)]
        increase_contrast: bool,
        ratio: Option<f64>,
    },
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
            Command::Find {
                query,
                match_case,
                whole_word,
            } => json(self.find(&Query::new(&query, match_case, whole_word))),
            Command::Type {
                selection,
                text,
                auto_pair,
            } => json(self.type_text(selection, &text, auto_pair.unwrap_or(true))),
            Command::DeleteBackward {
                selection,
                auto_pair,
            } => json(self.delete_backward(selection, auto_pair.unwrap_or(true))),
            Command::InsertNewline { selection } => json(self.insert_newline(selection)),
            Command::Partner { at } => json(self.partner(at)),
            Command::Definition { at } => json(self.definition(at)),
            Command::StartSnippet { fields, at } => json(self.start_snippet(&fields, at)),
            Command::EndSnippet => json(self.end_snippet()),
            Command::Tab { selections, step } => json(self.tab(&selections, step.unwrap_or(1))),
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
        }
    }
}

fn rendered(result: Result<render::MathSvg, String>) -> Option<String> {
    match result {
        Ok(svg) => json(svg),
        Err(error) => json(json!({ "error": error })),
    }
}

/// What a file dropped on the editor does: an image or PDF on a LaTeX file is `\includegraphics` at the caret;
/// any other file opens.
fn dropped(path: &str, kind: &str, into: &str) -> Value {
    match kind {
        "" => Value::Null,
        "image" | "pdf" if into == "tex" && tex_reads(path) => {
            json!({ "insert": format!("\\includegraphics{{{path}}}") })
        }
        _ => json!({ "open": true }),
    }
}

const BLACK: Rgba = [0.0, 0.0, 0.0, 1.0];

/// Whether `\includegraphics` reads `path` as written, in pdfTeX, XeTeX and LuaTeX
/// alike: `%`, `#` and `\` mean something else to TeX there, and its braces must
/// pair. The rest (spaces, `_`, `&`, `$`, `^`, `~`) it takes as they are.
fn tex_reads(path: &str) -> bool {
    path.chars().try_fold(0u32, |depth, c| match c {
        '%' | '#' | '\\' => None,
        '{' => Some(depth + 1),
        '}' => depth.checked_sub(1),
        _ => Some(depth),
    }) == Some(0)
}

/// The commands that need no document; docs/core-api.md lists them.
pub fn call(command: &str, args_json: &str) -> Option<String> {
    match read(command, args_json)? {
        Free::DropText { path, kind, into } => json(dropped(
            &path,
            kind.as_deref().unwrap_or(""),
            into.as_deref().unwrap_or("tex"),
        )),
        Free::Themes => json(theme::THEMES.map(|t| json!({ "id": t.id, "title": t.title }))),
        Free::MathSvg {
            tex,
            display,
            size,
            color,
        } => rendered(render::math_svg(
            &tex,
            display,
            size.unwrap_or(13.0),
            color.unwrap_or(BLACK),
        )),
        Free::GlyphSvg {
            command,
            size,
            side,
            color,
        } => rendered(render::glyph_svg(
            &command,
            size.unwrap_or(19.0),
            side.unwrap_or(24.0),
            color.unwrap_or(BLACK),
        )),
        Free::Menus => {
            let catalog = &*catalog::CATALOG;
            json(json!({ "templates": catalog.templates, "symbolGroups": catalog.symbol_groups }))
        }
        Free::HeadingStyles => json(headings::heading_styles(None, false)),
        Free::ThemeColors { theme, appearance } => {
            json(theme::theme_colors(theme::theme(&theme)?, &appearance))
        }
        Free::Legible {
            color,
            background,
            fill,
            increase_contrast,
            ratio,
        } => {
            let ratio = ratio.unwrap_or_else(|| theme::text_contrast(increase_contrast));
            json(theme::legible(color, background, fill, ratio))
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::call;
    use crate::syntax::SourceDocument;
    use crate::syntax::theme::contrast;

    #[test]
    fn commands_answer_by_name() {
        #[rustfmt::skip]
        let cases = [
            ("type", r#"{"selection": {"start": 0, "length": 0}, "text": "{"}"#,
                Some(r#"{"edit":{"start":0,"length":0,"text":"{}"},"selection":{"start":1,"length":0},"partner":null,"completions":"offer"}"#)),
            ("type", r#"{"selection": {"start": 0, "length": 0}, "text": "{", "autoPair": false}"#,
                Some(r#"{"edit":null,"selection":null,"partner":null,"completions":"offer"}"#)),
            ("tab", r#"{"selections": [{"start": 0, "length": 0}]}"#,
                Some(r#"{"field":null,"edits":[{"start":0,"length":0,"text":"  "}]}"#)),
            ("map_selections", r#"{"edits": [{"start": 0, "length": 0, "text": "ab"}], "selections": [{"start": 0, "length": 1}]}"#,
                Some(r#"[{"start":2,"length":1}]"#)),
            ("partner", r#"{"at": 0}"#, Some("null")),
            ("completions", r#"{"caret": 0}"#, Some("null")),
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
    fn find_answers_every_match_in_utf16_units() {
        let mut doc = SourceDocument::new("😀 Cat\ncat cats");
        let found = r#"[{"start":3,"length":3},{"start":7,"length":3},{"start":11,"length":3}]"#;
        assert_eq!(
            doc.call("find", r#"{"query": "cat"}"#).as_deref(),
            Some(found)
        );
    }

    #[test]
    fn a_dropped_file_is_inserted_or_opened() {
        let drop = |args: &str| call("drop_text", args);
        let image = r#"{"path": "figs/plot.png", "kind": "image"}"#;
        assert_eq!(
            drop(image).as_deref(),
            Some(r#"{"insert":"\\includegraphics{figs/plot.png}"}"#)
        );
        let pdf = r#"{"path": "a.pdf", "kind": "pdf", "into": "tex"}"#;
        assert!(drop(pdf).unwrap().contains("includegraphics{a.pdf}"));
        let into_bib = r#"{"path": "a.pdf", "kind": "pdf", "into": "bib"}"#;
        assert_eq!(drop(into_bib).as_deref(), Some(r#"{"open":true}"#));
        let tex = r#"{"path": "ch1.tex", "kind": "tex"}"#;
        assert_eq!(drop(tex).as_deref(), Some(r#"{"open":true}"#));
        let taken = r#"{"path": "figs/a b_c&{d}~$^.png", "kind": "image"}"#;
        assert!(
            drop(taken)
                .unwrap()
                .contains("includegraphics{figs/a b_c&{d}~$^.png}")
        );
        for path in ["50%.png", "a#1.png", "a\\\\b.png", "a}{.png", "a{.png"] {
            let args = json!({ "path": path, "kind": "image" }).to_string();
            assert_eq!(drop(&args).as_deref(), Some(r#"{"open":true}"#), "{path}");
        }
        assert_eq!(drop(r#"{"path": "figs"}"#).as_deref(), Some("null"));
        assert_eq!(drop("{}"), None);
    }

    #[test]
    fn the_free_commands_answer_by_name() {
        let themes = call("themes", "{}").unwrap();
        assert!(themes.starts_with(r#"[{"id":"overleaf","title":"Overleaf"},{"id":"#));
        let ratio_of = |extra: &str| {
            let args = format!(
                r#"{{"color": [0.6, 0.6, 0.6, 1], "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0]{extra}}}"#
            );
            let raised: [f64; 4] = serde_json::from_str(&call("legible", &args).unwrap()).unwrap();
            contrast(raised, [1.0; 4])
        };
        let plain = ratio_of("");
        assert!((4.5..5.0).contains(&plain), "{plain}");
        let border = ratio_of(r#", "ratio": 3.0"#);
        assert!((3.0..3.5).contains(&border), "{border}");
        let enhanced = ratio_of(r#", "increaseContrast": true"#);
        assert!((7.0..7.6).contains(&enhanced), "{enhanced}");
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
        let maths = call("math_svg", r#"{"tex": "x^2", "size": 10}"#);
        let maths: serde_json::Value = serde_json::from_str(&maths.unwrap()).unwrap();
        for key in ["svg", "width", "height"] {
            assert!(maths.get(key).is_some(), "{key}");
        }
        let error = call("math_svg", r#"{"tex": "x^"}"#).unwrap();
        assert!(error.starts_with(r#"{"error":"#), "{error}");
        let glyph = call("glyph_svg", r#"{"command": "\\alpha"}"#).unwrap();
        assert!(glyph.contains(r#""width":24.0,"height":24.0"#), "{glyph}");
    }
}
