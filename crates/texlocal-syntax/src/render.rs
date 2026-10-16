//! Maths as SVG, by RaTeX (KaTeX's layout in Rust): its parser and layout,
//! and its SVG export with every glyph an outline from the KaTeX fonts
//! compiled in, so the SVG holds only `<path>` and `<rect>` and needs no
//! fonts. Text the KaTeX fonts haven't (CJK, Cyrillic) is drawn as outlines
//! from the system's fonts, as KaTeX's page had the browser's: loading them
//! takes about half a second the first time. What has no outline, such as a
//! colour emoji on macOS, is an error.

use ratex_font::FontId;
use ratex_layout::{LayoutOptions, layout, to_display_list};
use ratex_svg::{SvgColorSyntax, SvgOptions, render_to_svg_with_color_syntax};
use ratex_types::color::Color;
use ratex_types::display_item::{DisplayItem, DisplayList};
use ratex_types::math_style::MathStyle;
use ratex_types::path_command::PathCommand;
use serde::Serialize;

use crate::theme::Rgba;

/// An SVG and its size, in the points (or pixels) of `size`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct MathSvg {
    pub svg: String,
    pub width: f64,
    pub height: f64,
    /// From the top: where the maths' baseline is, to set it on a line of text.
    pub baseline: f64,
}

/// No box or move is drawn larger than this, in ems: `\rule{1e9pt}{1pt}`
/// would otherwise ask the host for an image of millions of points.
const MAX_EM: f64 = 1000.0;

/// The type sizes drawn, in points.
const SIZES: std::ops::RangeInclusive<f64> = 1.0..=512.0;

/// RaTeX's display list for some maths, clamped, or why it has none.
fn display_list(tex: &str, display: bool, color: Rgba) -> Result<DisplayList, String> {
    let nodes = ratex_parser::parse(tex).map_err(|e| e.to_string())?;
    let style = if display {
        MathStyle::Display
    } else {
        MathStyle::Text
    };
    let [r, g, b, a] = color.map(|c| if c.is_finite() { c.clamp(0.0, 1.0) } else { 1.0 } as f32);
    let options = LayoutOptions::default()
        .with_style(style)
        .with_color(Color::new(r, g, b, a));
    let mut list = to_display_list(&layout(&nodes, &options));
    for item in &mut list.items {
        clamp_item(item);
    }
    list.width = length(list.width);
    list.height = coordinate(list.height);
    list.depth = coordinate(list.depth);
    // A box's height and depth can be negative; the drawing's can't.
    let total = (list.height + list.depth).clamp(0.0, MAX_EM);
    list.depth = total - list.height;
    Ok(list)
}

fn coordinate(v: f64) -> f64 {
    if v.is_finite() {
        v.clamp(-MAX_EM, MAX_EM)
    } else {
        0.0
    }
}

fn length(v: f64) -> f64 {
    coordinate(v).max(0.0)
}

fn clamp_item(item: &mut DisplayItem) {
    match item {
        DisplayItem::GlyphPath { x, y, scale, .. } => {
            (*x, *y, *scale) = (coordinate(*x), coordinate(*y), length(*scale));
        }
        DisplayItem::Line {
            x,
            y,
            width,
            thickness,
            ..
        } => {
            (*x, *y) = (coordinate(*x), coordinate(*y));
            (*width, *thickness) = (length(*width), length(*thickness));
        }
        DisplayItem::Rect {
            x,
            y,
            width,
            height,
            ..
        } => {
            (*x, *y) = (coordinate(*x), coordinate(*y));
            (*width, *height) = (length(*width), length(*height));
        }
        DisplayItem::Path { x, y, commands, .. } => {
            (*x, *y) = (coordinate(*x), coordinate(*y));
            for command in commands {
                for v in path_values(command) {
                    *v = coordinate(*v);
                }
            }
        }
    }
}

fn path_values(command: &mut PathCommand) -> Vec<&mut f64> {
    match command {
        PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => vec![x, y],
        PathCommand::QuadTo { x1, y1, x, y } => vec![x1, y1, x, y],
        PathCommand::CubicTo {
            x1,
            y1,
            x2,
            y2,
            x,
            y,
        } => vec![x1, y1, x2, y2, x, y],
        PathCommand::Close => vec![],
    }
}

fn svg(list: &DisplayList, size: f64) -> Result<String, String> {
    let options = SvgOptions {
        font_size: size,
        padding: 0.0,
        // RaTeX's 1.5 at its default 40 points.
        stroke_width: 1.5 * size / 40.0,
        embed_glyphs: true,
        font_dir: String::new(),
    };
    let svg = render_to_svg_with_color_syntax(list, &options, SvgColorSyntax::Rgb);
    // A glyph without an outline falls back to text in a font the host may lack.
    if svg.contains("<text") || svg.contains("<image") {
        return Err("The maths fonts can't draw this".into());
    }
    Ok(svg)
}

fn checked_size(size: f64) -> Result<f64, String> {
    if size.is_finite() {
        Ok(size.clamp(*SIZES.start(), *SIZES.end()))
    } else {
        Err("No such size".into())
    }
}

/// Maths at `size` points (an em), in `color`, displayed or in text style.
pub fn math_svg(tex: &str, display: bool, size: f64, color: Rgba) -> Result<MathSvg, String> {
    let size = checked_size(size)?;
    let list = display_list(tex, display, color)?;
    Ok(MathSvg {
        svg: svg(&list, size)?,
        width: list.width * size,
        height: (list.height + list.depth) * size,
        baseline: list.height * size,
    })
}

/// The ink a display list covers, in ems: (left, top, right, bottom).
fn ink(list: &DisplayList) -> Option<(f64, f64, f64, f64)> {
    let mut bounds: Option<(f64, f64, f64, f64)> = None;
    let mut add = |x0: f64, y0: f64, x1: f64, y1: f64| {
        let b = bounds.get_or_insert((x0, y0, x1, y1));
        *b = (b.0.min(x0), b.1.min(y0), b.2.max(x1), b.3.max(y1));
    };
    for item in &list.items {
        match item {
            DisplayItem::GlyphPath {
                x,
                y,
                scale,
                font,
                char_code,
                ..
            } => {
                let Some(id) = FontId::parse(font) else {
                    continue;
                };
                let Some(bytes) =
                    ratex_katex_fonts::ttf_bytes(&format!("KaTeX_{}.ttf", id.as_str()))
                else {
                    continue;
                };
                let Ok(face) = ttf_parser::Face::parse(&bytes, 0) else {
                    continue;
                };
                let c = ratex_font::katex_ttf_glyph_char(id, *char_code);
                let Some(rect) = face.glyph_index(c).and_then(|g| face.glyph_bounding_box(g))
                else {
                    continue;
                };
                let s = scale / face.units_per_em() as f64;
                add(
                    x + rect.x_min as f64 * s,
                    y - rect.y_max as f64 * s,
                    x + rect.x_max as f64 * s,
                    y - rect.y_min as f64 * s,
                );
            }
            DisplayItem::Line {
                x,
                y,
                width,
                thickness,
                ..
            } => add(*x, y - thickness / 2.0, x + width, y + thickness / 2.0),
            DisplayItem::Rect {
                x,
                y,
                width,
                height,
                ..
            } => add(*x, *y, x + width, y + height),
            DisplayItem::Path { x, y, commands, .. } => {
                for command in commands {
                    let mut command = *command;
                    let values = path_values(&mut command);
                    for point in values.chunks(2) {
                        add(x + *point[0], y + *point[1], x + *point[0], y + *point[1]);
                    }
                }
            }
        }
    }
    bounds
}

/// A symbol's command as the palette shows it: as TeX sets it in text
/// style, at `size` points, its ink centred in a square `side` points wide.
pub fn glyph_svg(command: &str, size: f64, side: f64, color: Rgba) -> Result<MathSvg, String> {
    let size = checked_size(size)?;
    let side = checked_size(side)?;
    let list = display_list(command, false, color)?;
    let inner = svg(&list, size)?;
    let (left, top, right, bottom) = ink(&list).unwrap_or((0.0, 0.0, list.width, list.height));
    let dx = side / 2.0 - (left + right) / 2.0 * size;
    let dy = side / 2.0 - (top + bottom) / 2.0 * size;
    // RaTeX's drawing, without its own <svg> element, moved into the square.
    let body = inner
        .split_once('>')
        .and_then(|(_, rest)| rest.strip_suffix("</svg>"))
        .unwrap_or_default();
    // As RaTeX writes its numbers: six places at most, no trailing zeros.
    let n = |v: f64| {
        let s = format!("{v:.6}");
        let s = s.trim_end_matches('0').trim_end_matches('.');
        if s.is_empty() || s == "-" || s == "-0" {
            "0".to_owned()
        } else {
            s.to_owned()
        }
    };
    let svg = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}" width="{s}pt" height="{s}pt"><g transform="translate({dx} {dy})">{body}</g></svg>"#,
        s = n(side),
        dx = n(dx),
        dy = n(dy),
    );
    Ok(MathSvg {
        svg,
        width: side,
        height: side,
        baseline: list.height * size + dy,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const BLACK: Rgba = [0.0, 0.0, 0.0, 1.0];

    /// The SVG's elements' names.
    fn elements(svg: &str) -> Vec<&str> {
        svg.split('<')
            .skip(1)
            .filter(|e| !e.starts_with('/'))
            .map(|e| e.split([' ', '>', '/']).next().unwrap())
            .collect()
    }

    #[test]
    fn maths_is_paths_and_rects_only() {
        let fraction = math_svg(r"\frac{a}{b} + \sqrt{x^2}", true, 20.0, BLACK).unwrap();
        let mut names = elements(&fraction.svg);
        names.sort();
        names.dedup();
        assert_eq!(names, ["path", "rect", "svg"], "{}", fraction.svg);
        assert!(fraction.width > 20.0 && fraction.height > 20.0);
        assert!(0.0 < fraction.baseline && fraction.baseline < fraction.height);
        assert!(fraction.svg.contains(r#"fill="rgb(0,0,0)""#));
        // Displayed is larger than inline, and twice the size twice as large.
        let inline = math_svg(r"\sum_{i=1}^n i", false, 10.0, BLACK).unwrap();
        let display = math_svg(r"\sum_{i=1}^n i", true, 10.0, BLACK).unwrap();
        assert!(display.height > inline.height);
        let double = math_svg(r"\sum_{i=1}^n i", false, 20.0, BLACK).unwrap();
        assert!((double.width - 2.0 * inline.width).abs() < 1e-9);
        // Colour and its alpha.
        let red = math_svg("x", false, 10.0, [1.0, 0.0, 0.0, 0.5]).unwrap();
        assert!(
            red.svg
                .contains(r#"fill="rgb(255,0,0)" fill-opacity="0.5""#),
            "{}",
            red.svg
        );
    }

    #[test]
    fn what_cant_be_drawn_is_an_error() {
        assert!(math_svg(r"x^", false, 10.0, BLACK).is_err());
        assert!(math_svg(r"\frac{1}", false, 10.0, BLACK).is_err());
        // A colour emoji has no outline to draw where the system's emoji font is bitmaps
        // alone, as macOS's is; Windows' and Linux's have outlines.
        if cfg!(target_os = "macos") {
            assert!(math_svg(r"\text{😀}", false, 10.0, BLACK).is_err());
        }
        assert!(math_svg(r"\def\a{\a}\a", false, 10.0, BLACK).is_err());
        assert!(math_svg("x", false, f64::NAN, BLACK).is_err());
        // Latin text and accents are the fonts'.
        assert!(math_svg(r"\text{café} \alpha", false, 10.0, BLACK).is_ok());
        // Text the KaTeX fonts haven't is drawn from the system's fonts, as KaTeX's page did in the browser's.
        for tex in [r"\text{日本} + x", r"\text{Привет} \alpha"] {
            let drawn = math_svg(tex, false, 10.0, BLACK).unwrap();
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
            let svg = math_svg(tex, false, 10.0, BLACK).unwrap();
            assert!(
                svg.width <= MAX_EM * 10.0 && svg.height <= MAX_EM * 10.0,
                "{tex}"
            );
        }
        let huge = math_svg("x", false, 1e12, BLACK).unwrap();
        assert!(huge.width < 1e4);
    }

    #[test]
    fn a_symbols_ink_is_centred() {
        for command in [r"\alpha", r"\sum", r"\sqrt{}", r"\notin", r"\Omega"] {
            let glyph = glyph_svg(command, 19.0, 24.0, BLACK).unwrap();
            assert_eq!((glyph.width, glyph.height), (24.0, 24.0));
            assert!(
                glyph
                    .svg
                    .starts_with(r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24""#)
            );
            assert!(glyph.svg.contains("<path"), "{command}");
            let list = display_list(command, false, BLACK).unwrap();
            let (l, t, r, b) = ink(&list).unwrap();
            assert!(r > l && b > t, "{command}");
        }
        assert!(glyph_svg(r"\nosuchcommand", 19.0, 24.0, BLACK).is_err());
    }
}
