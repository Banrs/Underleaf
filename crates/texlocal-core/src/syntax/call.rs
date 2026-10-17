//! The commands by name, a JSON object of arguments in and the answer's JSON
//! out, as the C ABI forwards them. An unknown command, or arguments that
//! aren't an object of the command's, answer none.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::theme::{self, Rgba};
use super::{Checker, SnippetField, SourceDocument, Style, TextEdit, TextRange, map_selections};
use super::{catalog, headings, render};

/// The arguments of the document's commands, one struct for each shape. What
/// a command needs it is sent: an argument left out is no call, not the
/// text's start. Optional ones say what they are when left out.
#[derive(Deserialize)]
struct Caret {
    caret: u32,
}

#[derive(Deserialize)]
struct At {
    at: u32,
}

#[derive(Deserialize)]
struct Selection {
    selection: TextRange,
}

#[derive(Deserialize)]
struct Selections {
    selections: Vec<TextRange>,
}

#[derive(Deserialize)]
struct Offer {
    caret: u32,
    /// Asked for by the user, not typed.
    #[serde(default)]
    explicit: bool,
}

#[derive(Deserialize)]
struct Heading {
    caret: u32,
    /// A sectioning command, or none for plain text.
    command: String,
}

#[derive(Deserialize)]
struct Block {
    id: String,
    selection: TextRange,
}

#[derive(Deserialize)]
struct Symbol {
    command: String,
    selection: TextRange,
}

#[derive(Deserialize)]
struct Checking {
    selection: TextRange,
    #[serde(rename = "for")]
    checker: Checker,
}

/// Whether typing closes brackets for the user; true when left out.
fn closing() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Typed {
    selection: TextRange,
    text: String,
    #[serde(default = "closing")]
    auto_pair: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Deleting {
    selection: TextRange,
    #[serde(default = "closing")]
    auto_pair: bool,
}

#[derive(Deserialize)]
struct Fields {
    fields: Vec<SnippetField>,
    at: u32,
}

/// Which way Tab goes; 1, forwards, when left out.
fn forwards() -> i64 {
    1
}

#[derive(Deserialize)]
struct Tabbing {
    selections: Vec<TextRange>,
    #[serde(default = "forwards")]
    step: i64,
}

#[derive(Deserialize)]
struct Moving {
    selections: Vec<TextRange>,
    up: bool,
}

#[derive(Deserialize)]
struct Styling {
    selections: Vec<TextRange>,
    style: Style,
}

#[derive(Deserialize)]
struct Wrapping {
    selections: Vec<TextRange>,
    template: String,
}

#[derive(Deserialize)]
struct Mapping {
    edits: Vec<TextEdit>,
    selections: Vec<TextRange>,
}

fn json(value: impl Serialize) -> Option<String> {
    serde_json::to_string(&value).ok()
}

/// `args_json`, if it is a JSON object.
fn object(args_json: &str) -> Option<Value> {
    serde_json::from_str(args_json)
        .ok()
        .filter(Value::is_object)
}

fn args<T: DeserializeOwned>(args: &Value) -> Option<T> {
    T::deserialize(args).ok()
}

/// The answer `command` gives to arguments of the shape `T`, as JSON.
fn answer<T: DeserializeOwned, R: Serialize>(
    value: &Value,
    command: impl FnOnce(T) -> R,
) -> Option<String> {
    json(command(args(value)?))
}

impl SourceDocument {
    /// The commands on the document's text: "completions" (`caret`,
    /// `explicit`), "toggle_comment" (`selections`), "set_heading" (`caret`,
    /// `command`), "insert_block" (`id`, `selection`), "insert_symbol"
    /// (`command`, `selection`), "math_at" (`caret`), "text_styles"
    /// (`selection`) and "code_ranges" (`selection`, `for`: "spelling" or
    /// "writingTools"). Typing's (typing.rs), each the method of its name:
    /// "type" (`selection`, `text`, `autoPair`), "delete_backward"
    /// (`selection`, `autoPair`) and "insert_newline" (`selection`), each a
    /// `Keystroke`; "partner" (`at`); "start_snippet" (`fields`, `at`),
    /// "end_snippet", "tab" (`selections`, `step`); "move_lines"
    /// (`selections`, `up`), "toggle_style" (`selections`, `style`: "bold",
    /// "italic" or "underline"), "wrap" (`selections`, `template`) and
    /// "map_selections" (`edits`, `selections`). An edit's following and a
    /// selection's are the C ABI's own (`tl_source_edit`, `tl_source_select`),
    /// as is the text; those that need no document are `call`'s.
    pub fn call(&mut self, command: &str, args_json: &str) -> Option<String> {
        let a = &object(args_json)?;
        match command {
            "completions" => answer(a, |o: Offer| {
                self.completions(o.caret, o.explicit, &self.labels, &self.citations)
            }),
            "toggle_comment" => answer(a, |s: Selections| self.toggle_comment(&s.selections)),
            "set_heading" => answer(a, |h: Heading| self.set_heading(h.caret, &h.command)),
            "insert_block" => answer(a, |b: Block| self.insert_block(&b.id, b.selection)),
            "insert_symbol" => answer(a, |s: Symbol| self.insert_symbol(&s.command, s.selection)),
            "math_at" => answer(a, |c: Caret| self.math_at(c.caret)),
            "text_styles" => answer(a, |s: Selection| self.text_styles(s.selection)),
            "code_ranges" => answer(a, |c: Checking| self.code_ranges(c.selection, c.checker)),
            "type" => answer(a, |t: Typed| {
                self.type_text(t.selection, &t.text, t.auto_pair)
            }),
            "delete_backward" => answer(a, |d: Deleting| {
                self.delete_backward(d.selection, d.auto_pair)
            }),
            "insert_newline" => answer(a, |s: Selection| self.insert_newline(s.selection)),
            "partner" => answer(a, |p: At| self.partner(p.at)),
            "start_snippet" => answer(a, |f: Fields| self.start_snippet(&f.fields, f.at)),
            "end_snippet" => json(self.end_snippet()),
            "tab" => answer(a, |t: Tabbing| self.tab(&t.selections, t.step)),
            "move_lines" => answer(a, |m: Moving| self.move_lines(&m.selections, m.up)),
            "toggle_style" => answer(a, |s: Styling| self.toggle_style(&s.selections, s.style)),
            "wrap" => answer(a, |w: Wrapping| self.wrap(&w.selections, &w.template)),
            "map_selections" => answer(a, |m: Mapping| map_selections(&m.edits, &m.selections)),
            _ => None,
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct Maths {
    tex: String,
    display: bool,
    command: String,
    size: Option<f64>,
    side: Option<f64>,
    color: Option<Rgba>,
}

/// An SVG, or why there's none.
fn rendered(result: Result<render::MathSvg, String>) -> Option<String> {
    match result {
        Ok(svg) => json(svg),
        Err(error) => json(json!({ "error": error })),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Legible {
    color: Rgba,
    background: Rgba,
    fill: Rgba,
    #[serde(default)]
    increase_contrast: bool,
    /// The contrast to raise to; without it, text's (`theme::text_contrast`).
    ratio: Option<f64>,
}

/// The document class the levels are for; without a `class`, none.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Styles {
    class: Option<String>,
    /// The class option, 10 when left out.
    #[serde(default = "ten")]
    point_size: u32,
    #[serde(default)]
    has_chapters: bool,
}

fn ten() -> u32 {
    10
}

/// What a file dropped on the editor does: an image or PDF dropped on a
/// LaTeX file is `\includegraphics` to put at the caret; any other file
/// opens. `kind` is the file's `file_tree` kind, none for a folder (which
/// does nothing); `into` the kind of the file dropped on.
fn dropped(path: &str, kind: &str, into: &str) -> Value {
    match kind {
        "" => Value::Null,
        "image" | "pdf" if into == "tex" => {
            json!({ "insert": format!("\\includegraphics{{{path}}}") })
        }
        _ => json!({ "open": true }),
    }
}

/// The commands that need no document: "themes", the themes' colours;
/// "theme_colors", a theme's (`theme`, its id) legible in an appearance
/// (`theme::Appearance`'s fields), by highlight kind; "legible" (`color`,
/// `background`, `fill`, `increaseContrast`, `ratio`), one colour raised to
/// `ratio` (default 4.5, or 7 with `increaseContrast`). "menus", the
/// catalogue's templates and symbol groups; "heading_styles" (`class`,
/// `pointSize`, `hasChapters`), the levels the class has, as it sets and
/// numbers them (a session's analysis answers the main file's). "drop_text" (`path`, `kind`,
/// `into`), what a project file dropped on the editor does: {"insert": text}
/// or {"open": true}, or null for a folder. "math_svg" (`tex`, `display`,
/// `size`, `color`) and "glyph_svg" (`command`, `size`, `side`, `color`):
/// `render::MathSvg`, or {"error": why}.
pub fn call(command: &str, args_json: &str) -> Option<String> {
    let value = object(args_json)?;
    let string = |key: &str| value.get(key).and_then(Value::as_str);
    match command {
        "drop_text" => json(dropped(
            string("path")?,
            string("kind").unwrap_or_default(),
            string("into").unwrap_or("tex"),
        )),
        "themes" => json(theme::THEMES),
        "math_svg" | "glyph_svg" => {
            let m: Maths = args(&value)?;
            let color = m.color.unwrap_or([0.0, 0.0, 0.0, 1.0]);
            rendered(if command == "math_svg" {
                render::math_svg(&m.tex, m.display, m.size.unwrap_or(13.0), color)
            } else {
                let (size, side) = (m.size.unwrap_or(19.0), m.side.unwrap_or(24.0));
                render::glyph_svg(&m.command, size, side, color)
            })
        }
        "menus" => {
            let catalog = &*catalog::CATALOG;
            json(json!({ "templates": catalog.templates, "symbolGroups": catalog.symbol_groups }))
        }
        "heading_styles" => {
            let a: Styles = args(&value)?;
            let class = a.class.map(|name| headings::DocumentClass {
                name,
                point_size: a.point_size,
            });
            json(headings::heading_styles(class.as_ref(), a.has_chapters))
        }
        "theme_colors" => {
            let theme = theme::theme(string("theme")?)?;
            json(theme::theme_colors(theme, &args(&value)?))
        }
        "legible" => {
            let a: Legible = args(&value)?;
            let ratio = a.ratio.unwrap_or(theme::text_contrast(a.increase_contrast));
            json(theme::legible(a.color, a.background, a.fill, ratio))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::call;
    use crate::syntax::SourceDocument;
    use crate::syntax::theme::contrast;

    #[test]
    fn commands_answer_by_name() {
        let mut doc = SourceDocument::new("\\cite{kn");
        assert_eq!(doc.call("partner", r#"{"at": 0}"#).as_deref(), Some("null"));
        assert_eq!(doc.call("no such command", "{}"), None);
        assert_eq!(doc.call("partner", "[]"), None);
        assert_eq!(doc.call("toggle_comment", r#"{"selections": 3}"#), None);
        // An argument a command needs is not made up when left out; one that
        // is optional is.
        assert_eq!(doc.call("partner", "{}"), None);
        assert_eq!(doc.call("math_at", r#"{"selection": 1}"#), None);
        assert_eq!(doc.call("move_lines", r#"{"selections": []}"#), None);
        assert!(doc.call("completions", r#"{"caret": 3}"#).is_some());
        assert!(doc.call("tab", r#"{"selections": []}"#).is_some());
        // Those that need no document are only `call`'s.
        assert_eq!(doc.call("themes", "{}"), None);
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
        // Into any other file, or any other kind, it opens.
        let into_bib = r#"{"path": "a.pdf", "kind": "pdf", "into": "bib"}"#;
        assert_eq!(drop(into_bib).as_deref(), Some(r#"{"open":true}"#));
        let tex = r#"{"path": "ch1.tex", "kind": "tex"}"#;
        assert_eq!(drop(tex).as_deref(), Some(r#"{"open":true}"#));
        // A folder does nothing; a call without a path is no call.
        assert_eq!(drop(r#"{"path": "figs"}"#).as_deref(), Some("null"));
        assert_eq!(drop("{}"), None);
    }

    /// The answers' shapes, and the arguments reaching what answers them: the
    /// colours, headings and drawings themselves are tested beside them.
    #[test]
    fn the_free_commands_answer_by_name() {
        let themes = call("themes", "{}").unwrap();
        assert!(themes.starts_with(
            r#"[{"id":"overleaf","title":"Overleaf","command":{"light":[0.0,0.0,1.0,1.0]"#
        ));
        let light = r#"{"theme": "texstudio", "dark": false, "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0.08]}"#;
        let colors: Vec<[f64; 4]> =
            serde_json::from_str(&call("theme_colors", light).unwrap()).unwrap();
        assert_eq!(colors.len(), 9);
        assert_eq!(call("theme_colors", r#"{"theme": "solarized"}"#), None);
        // A ratio asked for is the one it is raised to; without one, text's.
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
        let levels = call("heading_styles", r#"{"class": "letter"}"#).unwrap();
        assert!(levels.starts_with(r#"[{"title":"Normal Text","command":"""#));
        let maths = call("math_svg", r#"{"tex": "x^2", "size": 10}"#);
        let maths: serde_json::Value = serde_json::from_str(&maths.unwrap()).unwrap();
        for key in ["svg", "width", "height", "baseline"] {
            assert!(maths.get(key).is_some(), "{key}");
        }
        let error = call("math_svg", r#"{"tex": "x^"}"#).unwrap();
        assert!(error.starts_with(r#"{"error":"#), "{error}");
        let glyph = call("glyph_svg", r#"{"command": "\\alpha"}"#).unwrap();
        assert!(glyph.contains(r#""width":24.0,"height":24.0"#), "{glyph}");
    }
}
