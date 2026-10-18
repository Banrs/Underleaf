//! The commands by name, a JSON object of arguments in and the answer's JSON
//! out, as the C ABI forwards them. An unknown command, or arguments that
//! aren't an object of the command's, answer none.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::theme::{self, Rgba};
use super::{Checker, SnippetField, SourceDocument, Style, TextEdit, TextRange, map_selections};
use super::{headings, render};

/// The arguments the document's commands take, each what it needs; any left
/// out are empty.
#[derive(Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct Args {
    caret: u32,
    explicit: bool,
    command: String,
    id: String,
    selection: TextRange,
    selections: Vec<TextRange>,
    /// What's typed.
    text: String,
    /// Whether typing closes brackets for the user; true when left out.
    auto_pair: Option<bool>,
    at: u32,
    #[serde(rename = "for")]
    checker: Option<Checker>,
    fields: Vec<SnippetField>,
    /// Which way Tab goes; 1, forwards, when left out.
    step: Option<i64>,
    up: bool,
    style: Option<Style>,
    template: String,
    edits: Vec<TextEdit>,
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

impl SourceDocument {
    /// The commands on the document's text: "completions", "toggle_comment",
    /// "set_heading", "insert_block", "insert_symbol", "math_at",
    /// "text_styles" and "code_ranges" (`selection`, `for`: "spelling" or
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
        let a: Args = args(&object(args_json)?)?;
        let auto_pair = a.auto_pair.unwrap_or(true);
        match command {
            "completions" => {
                json(self.completions(a.caret, a.explicit, &self.labels, &self.citations))
            }
            "toggle_comment" => json(self.toggle_comment(&a.selections)),
            "set_heading" => json(self.set_heading(a.caret, &a.command)),
            "insert_block" => json(self.insert_block(&a.id, a.selection)),
            "insert_symbol" => json(self.insert_symbol(&a.command, a.selection)),
            "math_at" => json(self.math_at(a.caret)),
            "text_styles" => json(self.text_styles(a.selection)),
            "code_ranges" => json(self.code_ranges(a.selection, a.checker?)),
            "type" => json(self.type_text(a.selection, &a.text, auto_pair)),
            "delete_backward" => json(self.delete_backward(a.selection, auto_pair)),
            "insert_newline" => json(self.insert_newline(a.selection)),
            "partner" => json(self.partner(a.at)),
            "start_snippet" => json(self.start_snippet(&a.fields, a.at)),
            "end_snippet" => json(self.end_snippet()),
            "tab" => json(self.tab(&a.selections, a.step.unwrap_or(1))),
            "move_lines" => json(self.move_lines(&a.selections, a.up)),
            "toggle_style" => json(self.toggle_style(&a.selections, a.style?)),
            "wrap" => json(self.wrap(&a.selections, &a.template)),
            "map_selections" => json(map_selections(&a.edits, &a.selections)),
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

/// What a file dropped on the editor does: an image or PDF dropped on a
/// LaTeX file is `\includegraphics` to put at the caret; any other file
/// opens, as does one whose path TeX can't read as written. `kind` is the
/// file's `file_tree` kind, none for a folder (which does nothing); `into`
/// the kind of the file dropped on.
fn dropped(path: &str, kind: &str, into: &str) -> Value {
    match kind {
        "" => Value::Null,
        "image" | "pdf" if into == "tex" && tex_reads(path) => {
            json!({ "insert": format!("\\includegraphics{{{path}}}") })
        }
        _ => json!({ "open": true }),
    }
}

/// Whether `\includegraphics` reads `path` as written, in pdfTeX, XeTeX and LuaTeX
/// alike: `%`, `#` and `\` mean something else to TeX there, and its braces must
/// pair. The rest (spaces, `_`, `&`, `$`, `^`, `~`) it takes as they are.
fn tex_reads(path: &str) -> bool {
    let mut depth = 0i32;
    for c in path.chars() {
        depth += match c {
            '%' | '#' | '\\' => return false,
            '{' => 1,
            '}' => -1,
            _ => 0,
        };
        if depth < 0 {
            return false;
        }
    }
    depth == 0
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
        "menus" => json(super::catalog::menus()),
        "heading_styles" => {
            let class = string("class").map(|name| headings::DocumentClass {
                name: name.to_owned(),
                point_size: value.get("pointSize").and_then(Value::as_u64).unwrap_or(10) as u32,
            });
            let chapters = value.get("hasChapters").and_then(Value::as_bool);
            let styles = headings::heading_styles(class.as_ref(), chapters.unwrap_or(false));
            json(styles)
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
    use serde_json::json;

    use super::call;
    use crate::syntax::SourceDocument;
    use crate::syntax::theme::contrast;

    #[test]
    fn commands_answer_by_name() {
        let mut doc = SourceDocument::new("\\cite{kn");
        assert_eq!(doc.call("partner", "{}").as_deref(), Some("null"));
        assert_eq!(doc.call("no such command", "{}"), None);
        assert_eq!(doc.call("partner", "[]"), None);
        assert_eq!(doc.call("toggle_comment", r#"{"selections": 3}"#), None);
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
        // A path TeX reads as written goes in; one it can't opens.
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
        let menus = call("menus", "{}").unwrap();
        assert!(menus.contains(r#"{"glyph":"α","command":"\\alpha"}"#));
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
