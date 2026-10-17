//! The commands by name, a JSON object of arguments in and the answer's JSON
//! out, as the C ABI forwards them. An unknown command, or arguments that
//! aren't an object of the command's, answer none.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::theme::{self, Rgba};
use super::{Checker, SnippetField, SourceDocument, Style, TextEdit, TextRange};
use super::{catalog::CATALOG, complete::completions, headings, map_selections, render};

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

/// `args_json` read as a `T`, if it is a JSON object: a struct would read
/// from an array as well.
fn object<T: DeserializeOwned>(args_json: &str) -> Option<T> {
    let object = args_json.trim_start().starts_with('{');
    object.then(|| serde_json::from_str(args_json).ok())?
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
        let a: Args = object(args_json)?;
        let auto_pair = a.auto_pair.unwrap_or(true);
        let symbols = (&self.labels[..], &self.citations[..]);
        match command {
            "completions" => json(completions(&mut self.text, (a.caret, a.explicit), symbols)),
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

/// The commands that need no document: "themes", the themes' colours;
/// "theme_colors", a theme's (`theme`, its id) legible in an appearance
/// (`theme::Appearance`'s fields), by highlight kind; "legible" (`color`,
/// `background`, `fill`, `increaseContrast`, `ratio`), one colour raised to
/// `ratio` (default 4.5, or 7 with `increaseContrast`). "menus", the
/// catalogue's templates and symbol groups; "heading_styles" (`class`,
/// `pointSize`, `hasChapters`), the levels the class has, as it sets and
/// numbers them (a session's analysis answers the main file's). "drop_text"
/// (`path`, `kind`, `into`), what a project file dropped on the editor does:
/// an image or PDF dropped on a LaTeX file is {"insert": its
/// `\includegraphics`} to put at the caret, any other file {"open": true},
/// and a folder (no `kind`) null. "math_svg" (`tex`, `display`, `size`,
/// `color`) and "glyph_svg" (`command`, `size`, `side`, `color`):
/// `render::MathSvg`, or {"error": why}.
pub fn call(command: &str, args_json: &str) -> Option<String> {
    let value: Value = object(args_json)?;
    let string = |key: &str| value.get(key).and_then(Value::as_str);
    match command {
        "drop_text" => {
            let path = string("path")?;
            json(match (string("kind").unwrap_or_default(), string("into")) {
                ("", _) => Value::Null,
                ("image" | "pdf", None | Some("tex")) => {
                    json!({ "insert": format!("\\includegraphics{{{path}}}") })
                }
                _ => json!({ "open": true }),
            })
        }
        "themes" => json(theme::THEMES),
        "math_svg" | "glyph_svg" => {
            let m: Maths = args(&value)?;
            let (size, color) = (m.size.unwrap_or(13.0), m.color.unwrap_or([0., 0., 0., 1.]));
            let drawn = match command {
                "math_svg" => render::math_svg(&m.tex, m.display, size, color),
                _ => {
                    let (size, side) = (m.size.unwrap_or(19.0), m.side.unwrap_or(24.0));
                    render::glyph_svg(&m.command, size, side, color)
                }
            };
            drawn.map_or_else(|error| json(json!({ "error": error })), json)
        }
        "menus" => json(&CATALOG.menus),
        "heading_styles" => {
            let point_size = value.get("pointSize").and_then(Value::as_u64).unwrap_or(10) as u32;
            let class = string("class").map(|name| {
                let name = name.to_owned();
                headings::DocumentClass { name, point_size }
            });
            let chapters = value.get("hasChapters").and_then(Value::as_bool);
            let levels = headings::heading_styles(class.as_ref(), chapters.unwrap_or(false));
            json(levels)
        }
        "theme_colors" => {
            let id = string("theme")?;
            let theme = theme::THEMES.iter().find(|t| t.id == id)?;
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
        assert_eq!(doc.call("partner", " {} ").as_deref(), Some("null"));
        let none = r#"no such|{};partner|[];partner|{} x;toggle_comment|{"selections":3}"#;
        for (command, args) in none.split(';').map(|c| c.split_once('|').unwrap()) {
            assert_eq!(doc.call(command, args), None, "{command} {args}");
        }
        // Those that need no document are only `call`'s.
        assert_eq!(doc.call("themes", "{}"), None);
        assert_eq!(call("themes", "[]"), None);
    }

    /// The answers' shapes, and the arguments reaching what answers them: the
    /// colours, headings and drawings themselves are tested beside them.
    #[test]
    fn the_free_commands_answer_by_name() {
        // Each a command, its arguments and its answer, or a part of it; or none.
        for case in [
            r#"drop_text {"path":"f/p.png","kind":"image"} {"insert":"\\includegraphics{f/p.png}"}"#,
            r#"drop_text {"path":"a.pdf","kind":"pdf","into":"tex"} {"insert":"\\includegraphics{a.pdf}"}"#,
            // Into any other file, or any other kind, it opens; a folder does nothing.
            r#"drop_text {"path":"a.pdf","kind":"pdf","into":"bib"} {"open":true}"#,
            r#"drop_text {"path":"ch1.tex","kind":"tex"} {"open":true}"#,
            r#"drop_text {"path":"figs"} null"#,
            r#"drop_text {} none"#,
            r#"themes {} [{"id":"overleaf","title":"Overleaf","command":{"light":[0.0,0.0,1.0,1.0]"#,
            r#"themes {} {"system":"systemPink","light":[1.0,"#,
            r#"theme_colors {"theme":"solarized"} none"#,
            r#"theme_colors {"theme":"texstudio","dark":false,"background":[1,1,1,1],"fill":[0,0,0,0]} [[0.50"#,
            r#"menus {} {"glyph":"α","command":"\\alpha"}"#,
            r#"heading_styles {"class":"letter"} [{"title":"Normal Text","command":"""#,
            r#"math_svg {"tex":"x^2","size":10} "width":"#,
            r#"math_svg {"tex":"x^"} {"error":"#,
            r#"glyph_svg {"command":"\\alpha"} "width":24.0,"height":24.0"#,
        ] {
            let (command, rest) = case.split_once(' ').unwrap();
            let (args, part) = rest.split_once(' ').unwrap();
            let answer = call(command, args).unwrap_or("none".into());
            assert!(answer.contains(part), "{case}: {answer}");
        }
        // A ratio asked for is the one it is raised to; without one, text's.
        let ratio_of = |extra: &str| {
            let grey = r#""color":[0.6,0.6,0.6,1],"background":[1,1,1,1],"fill":[0,0,0,0]"#;
            let raised = call("legible", &format!("{{{grey}{extra}}}")).unwrap();
            contrast(serde_json::from_str(&raised).unwrap(), [1.0; 4])
        };
        assert!((4.5..5.0).contains(&ratio_of("")));
        assert!((3.0..3.5).contains(&ratio_of(r#","ratio":3.0"#)));
        assert!((7.0..7.6).contains(&ratio_of(r#","increaseContrast":true"#)));
    }
}
