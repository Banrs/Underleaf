//! The commands by name, a JSON object of arguments in and the answer's JSON
//! out, as every host calls them: the C ABI and a wasm build forward here,
//! so each decodes the same shapes. An unknown command, or arguments that
//! aren't an object of the command's, answer none.

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use super::theme::{self, Rgba};
use super::{SnippetField, SourceDocument, Style, TextEdit, TextRange, map_selections};
use super::{headings, render};

/// The arguments the document's commands take, each what it needs; any left
/// out are empty, but for `autoPair` (true) and `step` (1).
#[derive(Deserialize)]
#[serde(default, rename_all = "camelCase")]
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
    /// What's typed.
    text: String,
    auto_pair: bool,
    at: u32,
    /// A change's range before it, and how many units longer it made it.
    old: TextRange,
    delta: i64,
    changing: Option<TextRange>,
    mirroring: bool,
    fields: Vec<SnippetField>,
    step: i64,
    up: bool,
    style: Option<Style>,
    template: String,
    edits: Vec<TextEdit>,
}

impl Default for Args {
    fn default() -> Self {
        Args {
            caret: 0,
            explicit: false,
            labels: vec![],
            citations: vec![],
            command: String::new(),
            id: String::new(),
            selection: TextRange::default(),
            selections: vec![],
            more: false,
            text: String::new(),
            auto_pair: true,
            at: 0,
            old: TextRange::default(),
            delta: 0,
            changing: None,
            mirroring: false,
            fields: vec![],
            step: 1,
            up: false,
            style: None,
            template: String::new(),
            edits: vec![],
        }
    }
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
    /// again (it answers null). Typing's (typing.rs), each the method of its
    /// name: "type" (`selection`, `text`, `autoPair`), "delete_backward"
    /// (`selection`, `autoPair`) and "insert_newline" (`selection`), each a
    /// `Keystroke`; "partner" (`at`); "follow" (`old`, `delta`, `changing`,
    /// `mirroring`) and "select" (`selection`, `mirroring`), which answer
    /// null; "start_snippet" (`fields`, `at`), "end_snippet", "tab"
    /// (`selections`, `step`), "mirror_snippet"; "move_lines" (`selections`,
    /// `up`), "toggle_style" (`selections`, `style`: "bold", "italic" or
    /// "underline"), "wrap" (`selections`, `template`) and "map_selections"
    /// (`edits`, `selections`); "reset_typing" forgets the closers and
    /// snippet, as when the document is shown again (it answers null).
    pub fn call(&mut self, command: &str, args_json: &str) -> Option<String> {
        let value: Value = serde_json::from_str(args_json).ok()?;
        if !value.is_object() {
            return None;
        }
        let Some(a) = args::<Args>(&value) else {
            return call_with(command, &value);
        };
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
            "type" => json(self.type_text(a.selection, &a.text, a.auto_pair)),
            "delete_backward" => json(self.delete_backward(a.selection, a.auto_pair)),
            "insert_newline" => json(self.insert_newline(a.selection)),
            "partner" => json(self.partner(a.at)),
            "follow" => {
                self.follow(a.old, a.delta, a.changing, a.mirroring);
                json(())
            }
            "select" => {
                self.select(a.selection, a.mirroring);
                json(())
            }
            "start_snippet" => json(self.start_snippet(&a.fields, a.at)),
            "end_snippet" => json(self.end_snippet()),
            "reset_typing" => {
                self.reset_typing();
                json(())
            }
            "tab" => json(self.tab(&a.selections, a.step)),
            "mirror_snippet" => json(self.mirror_snippet()),
            "move_lines" => json(self.move_lines(&a.selections, a.up)),
            "toggle_style" => json(self.toggle_style(&a.selections, a.style?)),
            "wrap" => json(self.wrap(&a.selections, &a.template)),
            "map_selections" => json(map_selections(&a.edits, &a.selections)),
            _ => call_with(command, &value),
        }
    }
}

/// The commands that need no document: "themes", the themes' colours;
/// "theme_colors", a theme's (`theme`, its id) legible in an appearance
/// (`theme::Appearance`'s fields), by highlight kind; "legible" (`color`,
/// `background`, `fill`, `increaseContrast`, `ratio`), one colour raised to
/// `ratio` (default 4.5, or 7 with `increaseContrast`); and
/// "contrast" (`a`, `b`), WCAG's ratio. "menus", the catalogue's templates,
/// heading levels and symbol groups; "document_class" (`text`), the class a
/// main file names, or null; "heading_styles" (`class`, `pointSize`,
/// `hasChapters`), the levels the class has, as it sets and numbers them.
/// "drop_text" (`path`, `kind`, `into`), what a project file dropped on the
/// editor does: {"insert": text} or {"open": true}, or null for a folder.
/// "math_svg" (`tex`, `display`, `size`, `color`) and "glyph_svg"
/// (`command`, `size`, `side`, `color`): `render::MathSvg`, or
/// {"error": why}.
pub fn call(command: &str, args_json: &str) -> Option<String> {
    let value: Value = serde_json::from_str(args_json).ok()?;
    if !value.is_object() {
        return None;
    }
    call_with(command, &value)
}

#[derive(Deserialize)]
struct Maths {
    #[serde(default)]
    tex: String,
    #[serde(default)]
    display: bool,
    #[serde(default)]
    command: String,
    size: Option<f64>,
    side: Option<f64>,
    color: Option<Rgba>,
}

/// An SVG, or why there's none.
#[derive(serde::Serialize)]
#[serde(untagged)]
enum Rendered {
    Svg(render::MathSvg),
    Error { error: String },
}

fn rendered(result: Result<render::MathSvg, String>) -> Option<String> {
    json(match result {
        Ok(svg) => Rendered::Svg(svg),
        Err(error) => Rendered::Error { error },
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Legible {
    color: Rgba,
    background: Rgba,
    fill: Rgba,
    #[serde(default)]
    increase_contrast: bool,
    /// The contrast to raise to; without it, 4.5, or 7 with `increase_contrast`.
    ratio: Option<f64>,
}

/// What a file dropped on the editor does.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
enum Dropped {
    /// Put this LaTeX at the caret.
    Insert(String),
    /// Open the file.
    Open(bool),
}

/// An image or PDF dropped on a LaTeX file is `\includegraphics`; any other
/// file opens. `kind` is the file's `file_tree` kind, none for a folder (which
/// does nothing); `into` the kind of the file dropped on.
fn dropped(path: &str, kind: &str, into: &str) -> Option<Dropped> {
    match kind {
        "" => None,
        "image" | "pdf" if into == "tex" => {
            Some(Dropped::Insert(format!("\\includegraphics{{{path}}}")))
        }
        _ => Some(Dropped::Open(true)),
    }
}

fn call_with(command: &str, value: &Value) -> Option<String> {
    let string = |key: &str| value.get(key).and_then(Value::as_str);
    match command {
        "drop_text" => json(dropped(
            string("path")?,
            string("kind").unwrap_or_default(),
            string("into").unwrap_or("tex"),
        )),
        "themes" => json(theme::THEMES),
        "math_svg" | "glyph_svg" => {
            let m: Maths = args(value)?;
            let color = m.color.unwrap_or([0.0, 0.0, 0.0, 1.0]);
            rendered(if command == "math_svg" {
                render::math_svg(&m.tex, m.display, m.size.unwrap_or(13.0), color)
            } else {
                let (size, side) = (m.size.unwrap_or(19.0), m.side.unwrap_or(24.0));
                render::glyph_svg(&m.command, size, side, color)
            })
        }
        "menus" => json(super::catalog::menus()),
        "document_class" => json(headings::document_class(string("text")?)),
        "heading_styles" => {
            let class = string("class").map(|name| headings::DocumentClass {
                name: name.to_owned(),
                point_size: value.get("pointSize").and_then(Value::as_u64).unwrap_or(10) as u32,
            });
            let chapters = value.get("hasChapters").and_then(Value::as_bool);
            json(headings::heading_styles(
                class.as_ref(),
                chapters.unwrap_or(false),
            ))
        }
        "theme_colors" => {
            let theme = theme::theme(string("theme")?)?;
            json(theme::theme_colors(theme, &args(value)?))
        }
        "legible" => {
            let a: Legible = args(value)?;
            json(match a.ratio {
                Some(ratio) => theme::legible_at(a.color, a.background, a.fill, ratio),
                None => theme::legible(a.color, a.background, a.fill, a.increase_contrast),
            })
        }
        "contrast" => {
            let [a, b]: [Rgba; 2] = [args(value.get("a")?)?, args(value.get("b")?)?];
            json(theme::contrast(a, b))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::syntax::SourceDocument;

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

    #[test]
    fn a_dropped_file_is_inserted_or_opened() {
        let drop = |args: &str| super::call("drop_text", args);
        let image = r#"{"path": "figs/plot.png", "kind": "image"}"#;
        assert_eq!(
            drop(image).as_deref(),
            Some(r#"{"insert":"\\includegraphics{figs/plot.png}"}"#)
        );
        let pdf = r#"{"path": "a.pdf", "kind": "pdf", "into": "tex"}"#;
        assert!(drop(pdf).unwrap().contains("includegraphics{a.pdf}"));
        // Into any other file, or any other kind, it opens.
        let into_bib = r#"{"path": "a.pdf", "kind": "pdf", "into": "bib"}"#;
        assert_eq!(drop(into_bib).as_deref(), Some(r#"{"open":true}"#));
        let tex = r#"{"path": "ch1.tex", "kind": "tex"}"#;
        assert_eq!(drop(tex).as_deref(), Some(r#"{"open":true}"#));
        // A folder does nothing; a call without a path is no call.
        assert_eq!(drop(r#"{"path": "figs"}"#).as_deref(), Some("null"));
        assert_eq!(drop("{}"), None);
    }

    #[test]
    fn resetting_typing_answers_null() {
        let mut doc = SourceDocument::new("");
        assert_eq!(doc.call("reset_typing", "{}").as_deref(), Some("null"));
    }

    #[test]
    fn colours_answer_by_name() {
        let themes = super::call("themes", "{}").unwrap();
        assert!(themes.starts_with(
            r#"[{"id":"overleaf","title":"Overleaf","command":{"light":[0.0,0.0,1.0,1.0]"#
        ));
        let light = r#"{"theme": "texstudio", "dark": false, "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0.08]}"#;
        let colors: Vec<[f64; 4]> =
            serde_json::from_str(&super::call("theme_colors", light).unwrap()).unwrap();
        assert_eq!(colors.len(), 9);
        assert_eq!(
            super::call("theme_colors", r#"{"theme": "solarized"}"#),
            None
        );
        let black = r#"{"color": [0, 0, 0, 1], "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0]}"#;
        assert_eq!(
            super::call("legible", black).as_deref(),
            Some("[0.0,0.0,0.0,1.0]")
        );
        // A ratio asked for is the one it is raised to.
        let grey = r#"[0.6, 0.6, 0.6, 1]"#;
        let args = |extra: &str| {
            format!(
                r#"{{"color": {grey}, "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0]{extra}}}"#
            )
        };
        let ratio_of = |extra: &str| {
            let raised: [f64; 4] =
                serde_json::from_str(&super::call("legible", &args(extra)).unwrap()).unwrap();
            super::call(
                "contrast",
                &format!(r#"{{"a": {raised:?}, "b": [1, 1, 1, 1]}}"#),
            )
            .unwrap()
            .parse::<f64>()
            .unwrap()
        };
        let plain = ratio_of("");
        assert!((4.5..5.0).contains(&plain), "{plain}");
        assert_eq!(ratio_of(r#", "ratio": 4.5"#), plain);
        let border = ratio_of(r#", "ratio": 3.0"#);
        assert!((3.0..3.5).contains(&border), "{border}");
        let enhanced = ratio_of(r#", "increaseContrast": true"#);
        assert!((7.0..7.6).contains(&enhanced), "{enhanced}");
        let ratio = super::call("contrast", r#"{"a": [0, 0, 0, 1], "b": [1, 1, 1, 1]}"#).unwrap();
        assert_eq!(ratio, "21.0");
        let menus = super::call("menus", "{}").unwrap();
        assert!(menus.contains(
            r#"{"title":"Reference","body":"\\ref{$0}","symbol":"number.sign","inline":true}"#
        ));
        assert!(menus.contains(r#"{"glyph":"α","command":"\\alpha"}"#));
        let class = super::call(
            "document_class",
            r#"{"text": "\\documentclass[11pt]{book}"}"#,
        );
        assert_eq!(class.as_deref(), Some(r#"{"name":"book","pointSize":11}"#));
        let levels = super::call("heading_styles", r#"{"class": "letter"}"#).unwrap();
        assert_eq!(
            levels,
            r#"[{"title":"Normal Text","command":"","font":{"scale":1.0,"bold":false,"shape":"upright"},"marker":null}]"#
        );
        let maths = super::call(
            "math_svg",
            r#"{"tex": "x^2", "size": 10, "color": [1, 0, 0, 1]}"#,
        );
        let maths: serde_json::Value = serde_json::from_str(&maths.unwrap()).unwrap();
        assert!(maths["svg"].as_str().unwrap().starts_with("<svg"));
        assert!(maths["width"].as_f64().unwrap() > 0.0 && maths["baseline"].as_f64().is_some());
        let error = super::call("math_svg", r#"{"tex": "x^"}"#).unwrap();
        assert!(error.starts_with(r#"{"error":"#), "{error}");
        let glyph = super::call("glyph_svg", r#"{"command": "\\alpha"}"#).unwrap();
        assert!(glyph.contains(r#""width":24.0,"height":24.0"#), "{glyph}");
        // A document answers them too.
        assert!(SourceDocument::new("").call("themes", "{}").is_some());
    }
}
