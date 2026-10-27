use ratex_layout::{LayoutOptions, layout, to_display_list};
use ratex_lexer::token::Token;
use ratex_parser::macro_expander::{MacroDefinition, MacroExpander};
use ratex_parser::{ParseResult, Parser};
use ratex_svg::{SvgColorSyntax, SvgOptions, render_to_svg_with_color_syntax};
use ratex_types::display_item::DisplayList;
use ratex_types::math_style::MathStyle;
use schemars::JsonSchema;
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Serialize, JsonSchema)]
pub(crate) struct MathSvg {
    pub(crate) svg: String,
    pub(crate) width: f64,
    pub(crate) height: f64,
}

const MAX_EM: f64 = 1000.0;

fn optional(gullet: &mut MacroExpander) -> ParseResult<Vec<Token>> {
    let name = gullet.pop_token();
    let mut option = gullet.consume_arg(None)?.tokens;
    gullet.consume_spaces();
    if gullet.future().text == "[" {
        gullet.pop_token();
        option = gullet.consume_arg(Some(&["]"]))?.tokens;
    }
    let brace = |text| Token::new(text, name.loc.start, name.loc.end);
    let mut tokens = vec![brace("}")];
    tokens.extend(option);
    tokens.extend([brace("{"), name]);
    Ok(tokens)
}

fn display_list(tex: &str, display: bool) -> Option<DisplayList> {
    let mut parser = Parser::new(tex);
    let optional = MacroDefinition::Function(optional);
    parser
        .gullet
        .set_macro("\\texlocal@optional".into(), optional);
    let nodes = parser.parse().ok()?;
    let style = if display {
        MathStyle::Display
    } else {
        MathStyle::Text
    };
    let options = LayoutOptions::default().with_style(style);
    let mut list = to_display_list(&layout(&nodes, &options));
    let clamp = |v: f64| {
        if v.is_finite() {
            v.clamp(-MAX_EM, MAX_EM)
        } else {
            0.0
        }
    };
    list.width = clamp(list.width).max(0.0);
    list.height = clamp(list.height);
    list.depth = (list.height + clamp(list.depth)).clamp(0.0, MAX_EM) - list.height;
    Some(list)
}

fn svg(list: &DisplayList, size: f64) -> Option<String> {
    let options = SvgOptions {
        font_size: size,
        padding: 0.0,
        stroke_width: 1.5 * size / 40.0,
        embed_glyphs: true,
        font_dir: String::new(),
    };
    let svg = render_to_svg_with_color_syntax(list, &options, SvgColorSyntax::Rgb);
    let undrawable = ["<text", "<image", "inf", "NaN"];
    (!undrawable.iter().any(|bad| svg.contains(bad))).then_some(svg)
}

pub(crate) fn math_svg(tex: &str, display: bool, size: f64) -> Option<MathSvg> {
    if !size.is_finite() {
        return None;
    }
    let size = size.clamp(1.0, 512.0);
    let list = display_list(tex, display)?;
    Some(MathSvg {
        svg: svg(&list, size)?,
        width: list.width * size,
        height: (list.height + list.depth) * size,
    })
}
