//! The commands by name, a JSON object of arguments in and the answer's JSON
//! out, as the C ABI forwards them. An unknown command, or arguments that
//! aren't an object with the command's, answer none.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::theme::{self, Rgba};
use super::{SourceDocument, TextEdit, TextRange, map_selections};
use super::{catalog, headings, render};

fn json(value: impl Serialize) -> Option<String> {
    serde_json::to_string(&value).ok()
}

/// The argument `key`: none when it is left out or isn't of its type, as a
/// command is sent what it needs, never given the text's start for it.
fn get<T: DeserializeOwned>(args: &Value, key: &str) -> Option<T> {
    T::deserialize(args.get(key)?).ok()
}

/// An optional argument: `default` when it is left out or null, none when
/// it isn't of its type.
fn optional<T: DeserializeOwned>(args: &Value, key: &str, default: T) -> Option<T> {
    match args.get(key) {
        None | Some(Value::Null) => Some(default),
        Some(value) => T::deserialize(value).ok(),
    }
}

/// `args_json`, if it is a JSON object.
fn object(args_json: &str) -> Option<Value> {
    serde_json::from_str(args_json)
        .ok()
        .filter(Value::is_object)
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
    /// "map_selections" (`edits`, `selections`). `explicit` is false when
    /// left out, `autoPair` true and `step` 1 (forwards). An edit's
    /// following and a selection's are the C ABI's own (`tl_source_edit`,
    /// `tl_source_select`), as is the text; those that need no document are
    /// `call`'s.
    pub fn call(&mut self, command: &str, args_json: &str) -> Option<String> {
        let a = &object(args_json)?;
        let caret = || get::<u32>(a, "caret");
        let selection = || get::<TextRange>(a, "selection");
        let selections = || get::<Vec<TextRange>>(a, "selections");
        let string = |key| get::<String>(a, key);
        let auto_pair = || optional(a, "autoPair", true);
        match command {
            "completions" => {
                let explicit = optional(a, "explicit", false)?;
                json(self.completions(caret()?, explicit, &self.labels, &self.citations))
            }
            "toggle_comment" => json(self.toggle_comment(&selections()?)),
            "set_heading" => json(self.set_heading(caret()?, &string("command")?)),
            "insert_block" => json(self.insert_block(&string("id")?, selection()?)),
            "insert_symbol" => json(self.insert_symbol(&string("command")?, selection()?)),
            "math_at" => json(self.math_at(caret()?)),
            "text_styles" => json(self.text_styles(selection()?)),
            "code_ranges" => json(self.code_ranges(selection()?, get(a, "for")?)),
            "type" => json(self.type_text(selection()?, &string("text")?, auto_pair()?)),
            "delete_backward" => json(self.delete_backward(selection()?, auto_pair()?)),
            "insert_newline" => json(self.insert_newline(selection()?)),
            "partner" => json(self.partner(get(a, "at")?)),
            "start_snippet" => {
                json(self.start_snippet(&get::<Vec<_>>(a, "fields")?, get(a, "at")?))
            }
            "end_snippet" => json(self.end_snippet()),
            "tab" => json(self.tab(&selections()?, optional(a, "step", 1)?)),
            "move_lines" => json(self.move_lines(&selections()?, get(a, "up")?)),
            "toggle_style" => json(self.toggle_style(&selections()?, get(a, "style")?)),
            "wrap" => json(self.wrap(&selections()?, &string("template")?)),
            "map_selections" => {
                let edits: Vec<TextEdit> = get(a, "edits")?;
                json(map_selections(&edits, &selections()?))
            }
            _ => None,
        }
    }
}

/// An SVG, or why there's none.
fn rendered(result: Result<render::MathSvg, String>) -> Option<String> {
    match result {
        Ok(svg) => json(svg),
        Err(error) => json(json!({ "error": error })),
    }
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

const BLACK: Rgba = [0.0, 0.0, 0.0, 1.0];

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

/// The commands that need no document: "themes", each theme's id and title;
/// "theme_colors", a theme's (`theme`, its id) legible in an appearance
/// (`theme::Appearance`'s fields), by highlight kind; "legible" (`color`,
/// `background`, `fill`, `increaseContrast`, `ratio`), one colour raised to
/// `ratio` (default 4.5, or 7 with `increaseContrast`). "menus", the
/// catalogue's templates and symbol groups; "heading_styles", every level as
/// the standard classes set and number them (a session's analysis answers
/// the main file's class's). "drop_text" (`path`, `kind`, `into`,
/// "tex" when left out), what a project file dropped on the editor does:
/// {"insert": text} or {"open": true}, or null for a folder. "math_svg"
/// (`tex`, `display`, `size`, 13 points, `color`, black) and "glyph_svg"
/// (`command`, `size`, 19, `side`, 24, `color`): `render::MathSvg`, or
/// {"error": why}.
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
        "math_svg" => {
            let (tex, display) = (string("tex", "")?, optional(a, "display", false)?);
            rendered(render::math_svg(
                &tex,
                display,
                optional(a, "size", 13.0)?,
                color()?,
            ))
        }
        "glyph_svg" => {
            let (size, side) = (optional(a, "size", 19.0)?, optional(a, "side", 24.0)?);
            rendered(render::glyph_svg(
                &string("command", "")?,
                size,
                side,
                color()?,
            ))
        }
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
        assert!(themes.starts_with(r#"[{"id":"overleaf","title":"Overleaf"},{"id":"#));
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
