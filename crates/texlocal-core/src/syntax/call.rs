//! The commands by name: a JSON object of arguments in, the answer's JSON out, as the C ABI forwards them.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::edit::map_selections;
use super::theme::{self, Rgba};
use super::{SourceDocument, TextEdit, TextRange};
use super::{catalog, headings, render};
use crate::projects::Query;

fn json(value: impl Serialize) -> Option<String> {
    serde_json::to_string(&value).ok()
}

/// A command is sent what it needs, never given the text's start for an argument left out.
fn get<T: DeserializeOwned>(args: &Value, key: &str) -> Option<T> {
    T::deserialize(args.get(key).unwrap_or(&Value::Null)).ok()
}

fn optional<T: DeserializeOwned>(args: &Value, key: &str, default: T) -> Option<T> {
    get::<Option<T>>(args, key).map(|value| value.unwrap_or(default))
}

fn object(args_json: &str) -> Option<Value> {
    serde_json::from_str(args_json)
        .ok()
        .filter(Value::is_object)
}

impl SourceDocument {
    pub fn call(&mut self, command: &str, args_json: &str) -> Option<String> {
        let a = &object(args_json)?;
        let caret = || get::<u32>(a, "caret");
        let selection = || get::<TextRange>(a, "selection");
        let selections = || get::<Vec<TextRange>>(a, "selections");
        let string = |key| get::<String>(a, key);
        let auto_pair = || optional(a, "autoPair", true);
        match command {
            "completions" => json(self.completions(caret()?, optional(a, "explicit", false)?)),
            "toggle_comment" => json(self.toggle_comment(&selections()?)),
            "set_heading" => json(self.set_heading(caret()?, &string("command")?)),
            "insert_block" => json(self.insert_block(&string("id")?, selection()?)),
            "insert_symbol" => json(self.insert_symbol(&string("command")?, selection()?)),
            "math_at" => json(self.math_at(caret()?)),
            "text_styles" => json(self.text_styles(selection()?)),
            "code_ranges" => json(self.code_ranges(selection()?, get(a, "for")?)),
            "words" => json(json!({ "words": self.words(TextRange::deserialize(a).ok()?) })),
            "find" => {
                let (case, whole) = (
                    optional(a, "matchCase", false)?,
                    optional(a, "wholeWord", false)?,
                );
                json(self.find(&Query::new(&string("query")?, case, whole)))
            }
            "type" => json(self.type_text(selection()?, &string("text")?, auto_pair()?)),
            "delete_backward" => json(self.delete_backward(selection()?, auto_pair()?)),
            "insert_newline" => json(self.insert_newline(selection()?)),
            "partner" => json(self.partner(get(a, "at")?)),
            "definition" => json(self.definition(get(a, "at")?)),
            "start_snippet" => {
                json(self.start_snippet(&get::<Vec<_>>(a, "fields")?, get(a, "at")?))
            }
            "end_snippet" => json(self.end_snippet()),
            "tab" => json(self.tab(&selections()?, optional(a, "step", 1)?)),
            "move_lines" => json(self.move_lines(&selections()?, get(a, "up")?)),
            "duplicate_lines" => json(self.duplicate_lines(&selections()?)),
            "delete_lines" => json(self.delete_lines(&selections()?)),
            "toggle_style" => json(self.toggle_style(&selections()?, get(a, "style")?)),
            "wrap" => json(self.wrap(&selections()?, &string("template")?)),
            "map_selections" => json(map_selections(
                &get::<Vec<TextEdit>>(a, "edits")?,
                &selections()?,
            )),
            _ => None,
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
    let a = &object(args_json)?;
    let string = |key, default: &str| optional(a, key, default.to_owned());
    let color = || optional(a, "color", BLACK);
    match command {
        "drop_text" => {
            let (kind, into) = (string("kind", "")?, string("into", "tex")?);
            json(dropped(&get::<String>(a, "path")?, &kind, &into))
        }
        "themes" => json(theme::THEMES.map(|t| json!({ "id": t.id, "title": t.title }))),
        "math_svg" => rendered(render::math_svg(
            &string("tex", "")?,
            optional(a, "display", false)?,
            optional(a, "size", 13.0)?,
            color()?,
        )),
        "glyph_svg" => rendered(render::glyph_svg(
            &string("command", "")?,
            optional(a, "size", 19.0)?,
            optional(a, "side", 24.0)?,
            color()?,
        )),
        "menus" => {
            let catalog = &*catalog::CATALOG;
            json(json!({ "templates": catalog.templates, "symbolGroups": catalog.symbol_groups }))
        }
        "heading_styles" => json(headings::heading_styles(None, false)),
        "theme_colors" => {
            let theme = theme::theme(&get::<String>(a, "theme")?)?;
            json(theme::theme_colors(
                theme,
                &Deserialize::deserialize(a).ok()?,
            ))
        }
        "legible" => {
            let increase_contrast = optional(a, "increaseContrast", false)?;
            let ratio = optional(a, "ratio", theme::text_contrast(increase_contrast))?;
            let (background, fill) = (get(a, "background")?, get(a, "fill")?);
            json(theme::legible(get(a, "color")?, background, fill, ratio))
        }
        _ => None,
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
