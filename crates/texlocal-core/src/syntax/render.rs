use ratex_layout::{LayoutOptions, layout, to_display_list};
use ratex_lexer::token::Token;
use ratex_parser::macro_expander::{MacroDefinition, MacroExpander};
use ratex_parser::{ParseResult, Parser};
use ratex_svg::{SvgColorSyntax, SvgOptions, render_to_svg_with_color_syntax};
use ratex_types::display_item::DisplayList;
use ratex_types::math_style::MathStyle;
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct MathSvg {
    pub svg: String,
    pub width: f64,
    pub height: f64,
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

fn display_list(tex: &str, display: bool) -> Result<DisplayList, String> {
    let mut parser = Parser::new(tex);
    let optional = MacroDefinition::Function(optional);
    parser
        .gullet
        .set_macro("\\texlocal@optional".into(), optional);
    let nodes = parser.parse().map_err(|e| e.to_string())?;
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
    Ok(list)
}

fn svg(list: &DisplayList, size: f64) -> Result<String, String> {
    let options = SvgOptions {
        font_size: size,
        padding: 0.0,
        stroke_width: 1.5 * size / 40.0,
        embed_glyphs: true,
        font_dir: String::new(),
    };
    let svg = render_to_svg_with_color_syntax(list, &options, SvgColorSyntax::Rgb);
    if svg.contains("<text") || svg.contains("<image") {
        return Err("The maths fonts can't draw this".into());
    }
    if svg.contains("inf") || svg.contains("NaN") {
        return Err("The maths is too large to draw".into());
    }
    Ok(svg)
}

pub fn math_svg(tex: &str, display: bool, size: f64) -> Result<MathSvg, String> {
    if !size.is_finite() {
        return Err("No such size".into());
    }
    let size = size.clamp(1.0, 512.0);
    let list = display_list(tex, display)?;
    Ok(MathSvg {
        svg: svg(&list, size)?,
        width: list.width * size,
        height: (list.height + list.depth) * size,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn elements(svg: &str) -> Vec<&str> {
        svg.split('<')
            .skip(1)
            .filter(|e| !e.starts_with('/'))
            .map(|e| e.split([' ', '>', '/']).next().unwrap())
            .collect()
    }

    #[test]
    fn maths_is_paths_and_rects_only() {
        let fraction = math_svg(r"\frac{a}{b} + \sqrt{x^2}", true, 20.0).unwrap();
        let mut names = elements(&fraction.svg);
        names.sort_unstable();
        names.dedup();
        assert_eq!(names, ["path", "rect", "svg"], "{}", fraction.svg);
        assert!(fraction.width > 20.0 && fraction.height > 20.0);
        assert!(fraction.svg.contains(r#"fill="rgb(0,0,0)""#));
        let inline = math_svg(r"\sum_{i=1}^n i", false, 10.0).unwrap();
        let display = math_svg(r"\sum_{i=1}^n i", true, 10.0).unwrap();
        assert!(display.height > inline.height);
        let double = math_svg(r"\sum_{i=1}^n i", false, 20.0).unwrap();
        assert!((double.width - 2.0 * inline.width).abs() < 1e-9);
    }

    #[test]
    fn what_cant_be_drawn_is_an_error() {
        assert!(math_svg(r"x^", false, 10.0).is_err());
        assert!(math_svg(r"\frac{1}", false, 10.0).is_err());
        assert!(math_svg(r"\text{😀}", false, 10.0).is_err());
        assert!(math_svg(r"\def\a{\a}\a", false, 10.0).is_err());
        assert!(math_svg("x", false, f64::NAN).is_err());
        assert!(math_svg(r"\text{café} \alpha", false, 10.0).is_ok());
        for tex in [r"\text{日本} + x", r"\text{Привет} \alpha"] {
            let drawn = math_svg(tex, false, 10.0).unwrap();
            assert!(
                drawn.svg.contains("<path") && !drawn.svg.contains("<text"),
                "{tex}"
            );
        }
    }

    #[test]
    fn absurd_sizes_are_clamped() {
        for tex in [
            r"\rule{100000em}{1em}",
            r"\rule{1em}{100000em}",
            r"a\kern100000em b",
            r"\hspace{1e9pt}x",
        ] {
            let svg = math_svg(tex, false, 10.0).unwrap();
            assert!(
                svg.width <= MAX_EM * 10.0 && svg.height <= MAX_EM * 10.0,
                "{tex}"
            );
        }
        let huge = math_svg("x", false, 1e12).unwrap();
        assert!(huge.width < 1e4);
        let digits = "9".repeat(310);
        for tex in [
            format!(r"\rule{{{digits}pt}}{{1pt}}"),
            format!(r"a\kern{digits}em b"),
        ] {
            if let Ok(svg) = math_svg(&tex, false, 10.0) {
                assert!(
                    svg.width <= MAX_EM * 10.0 && !svg.svg.contains("inf"),
                    "{tex}"
                );
            }
        }
    }
}
