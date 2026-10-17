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

use super::theme::Rgba;

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

/// RaTeX's display list for some maths, clamped, or why it has none.
fn display_list(tex: &str, display: bool, color: Rgba) -> Result<DisplayList, String> {
    let nodes = ratex_parser::parse(tex).map_err(|e| e.to_string())?;
    let style = [MathStyle::Text, MathStyle::Display][display as usize];
    let [r, g, b, a] = color.map(|c| if c.is_finite() { c.clamp(0.0, 1.0) } else { 1.0 } as f32);
    let color = Color::new(r, g, b, a);
    let options = LayoutOptions::default().with_style(style).with_color(color);
    let mut list = to_display_list(&layout(&nodes, &options));
    for item in &mut list.items {
        let (points, lengths): (Vec<&mut f64>, Vec<&mut f64>) = match item {
            DisplayItem::GlyphPath { x, y, scale, .. } => (vec![x, y], vec![scale]),
            DisplayItem::Line { x, y, width, thickness: height, .. }
            | DisplayItem::Rect { x, y, width, height, .. } => (vec![x, y], vec![width, height]),
            DisplayItem::Path { x, y, commands, .. } => {
                let values = commands.iter_mut().flat_map(path_values);
                ([x, y].into_iter().chain(values).collect(), vec![])
            }
        };
        points.into_iter().for_each(|v| *v = coordinate(*v));
        lengths.into_iter().for_each(|v| *v = coordinate(*v).max(0.0));
    }
    list.width = coordinate(list.width).max(0.0);
    (list.height, list.depth) = (coordinate(list.height), coordinate(list.depth));
    // A box's height and depth can be negative; the drawing's can't.
    list.depth = (list.height + list.depth).clamp(0.0, MAX_EM) - list.height;
    Ok(list)
}

fn coordinate(v: f64) -> f64 {
    let v = if v.is_finite() { v } else { 0.0 };
    v.clamp(-MAX_EM, MAX_EM)
}

fn path_values(command: &mut PathCommand) -> Vec<&mut f64> {
    match command {
        PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => vec![x, y],
        PathCommand::QuadTo { x1, y1, x, y } => vec![x1, y1, x, y],
        PathCommand::CubicTo { x1, y1, x2, y2, x, y } => vec![x1, y1, x2, y2, x, y],
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

/// A size in points, as drawn: 1 to 512.
fn checked_size(size: f64) -> Result<f64, String> {
    let size = size.is_finite().then(|| size.clamp(1.0, 512.0));
    size.ok_or_else(|| "No such size".into())
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

/// A KaTeX glyph's outline bounds, and its font's units per em.
fn glyph_bounds(font: &str, char_code: u32) -> Option<(ttf_parser::Rect, f64)> {
    let id = FontId::parse(font)?;
    let bytes = ratex_katex_fonts::ttf_bytes(&format!("KaTeX_{}.ttf", id.as_str()))?;
    let face = ttf_parser::Face::parse(&bytes, 0).ok()?;
    let c = ratex_font::katex_ttf_glyph_char(id, char_code);
    let rect = face.glyph_bounding_box(face.glyph_index(c)?)?;
    Some((rect, face.units_per_em() as f64))
}

/// The ink a display list covers, in ems: left, top, right and bottom.
fn ink(list: &DisplayList) -> Option<[f64; 4]> {
    let boxes = list.items.iter().flat_map(|item| match item {
        DisplayItem::GlyphPath { x, y, scale, font, char_code, .. } => {
            let bounds = glyph_bounds(font, *char_code).map(|(rect, units_per_em)| {
                let s = scale / units_per_em;
                let [x0, y0, x1, y1] =
                    [rect.x_min, rect.y_max, rect.x_max, rect.y_min].map(|v| v as f64 * s);
                [x + x0, y - y0, x + x1, y - y1]
            });
            bounds.into_iter().collect()
        }
        DisplayItem::Line { x, y, width, thickness, .. } => {
            vec![[*x, y - thickness / 2.0, x + width, y + thickness / 2.0]]
        }
        DisplayItem::Rect { x, y, width, height, .. } => vec![[*x, *y, x + width, y + height]],
        DisplayItem::Path { x, y, commands, .. } => {
            let mut commands = commands.clone();
            let values = commands.iter_mut().flat_map(path_values).map(|v| *v);
            let values: Vec<f64> = values.collect();
            let point = |p: &[f64]| [x + p[0], y + p[1], x + p[0], y + p[1]];
            values.chunks(2).map(point).collect()
        }
    });
    let bounds = |[l, t, r, b]: [f64; 4], [l2, t2, r2, b2]: [f64; 4]| {
        [l.min(l2), t.min(t2), r.max(r2), b.max(b2)]
    };
    boxes.reduce(bounds)
}

/// A symbol's command as the palette shows it: as TeX sets it in text
/// style, at `size` points, its ink centred in a square `side` points wide.
pub fn glyph_svg(command: &str, size: f64, side: f64, color: Rgba) -> Result<MathSvg, String> {
    let (size, side) = (checked_size(size)?, checked_size(side)?);
    let list = display_list(command, false, color)?;
    let inner = svg(&list, size)?;
    let [left, top, right, bottom] = ink(&list).unwrap_or([0.0, 0.0, list.width, list.height]);
    let dx = side / 2.0 - (left + right) / 2.0 * size;
    let dy = side / 2.0 - (top + bottom) / 2.0 * size;
    // RaTeX's drawing, without its own <svg> element, moved into the square.
    let (_, rest) = inner.split_once('>').unwrap_or_default();
    let body = rest.strip_suffix("</svg>").unwrap_or_default();
    // As RaTeX writes its numbers: six places at most, no trailing zeros.
    let n = |v: f64| {
        let s = format!("{v:.6}");
        let s = s.trim_end_matches('0').trim_end_matches('.');
        let zero = matches!(s, "" | "-" | "-0");
        (if zero { "0" } else { s }).to_owned()
    };
    let baseline = list.height * size + dy;
    let (s, dx, dy) = (n(side), n(dx), n(dy));
    let svg = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}" width="{s}pt" height="{s}pt"><g transform="translate({dx} {dy})">{body}</g></svg>"#
    );
    Ok(MathSvg { svg, width: side, height: side, baseline })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    const BLACK: Rgba = [0.0, 0.0, 0.0, 1.0];

    /// The SVG's elements' names, each once.
    fn elements(tex: &str) -> String {
        let svg = math_svg(tex, false, 10.0, BLACK).unwrap().svg;
        let opened = svg.split('<').skip(1).filter(|e| !e.starts_with('/'));
        let names = opened.map(|e| &e[..e.find([' ', '>', '/']).unwrap()]);
        Vec::from_iter(BTreeSet::from_iter(names)).join(" ")
    }

    #[test]
    fn maths_is_paths_and_rects_only() {
        let draw = |tex, display, size, color| math_svg(tex, display, size, color).unwrap();
        let fraction = draw(r"\frac{a}{b} + \sqrt{x^2}", true, 20.0, BLACK);
        assert_eq!(elements(r"\frac{a}{b} + \sqrt{x^2}"), "path rect svg");
        assert!(fraction.width > 20.0 && fraction.height > 20.0);
        assert!(0.0 < fraction.baseline && fraction.baseline < fraction.height);
        assert!(fraction.svg.contains(r#"fill="rgb(0,0,0)""#));
        // Displayed is larger than inline, and twice the size twice as large.
        let sum = |display, size| draw(r"\sum_{i=1}^n i", display, size, BLACK);
        assert!(sum(true, 10.0).height > sum(false, 10.0).height);
        assert!((sum(false, 20.0).width - 2.0 * sum(false, 10.0).width).abs() < 1e-9);
        // Colour and its alpha.
        let red = draw("x", false, 10.0, [1.0, 0.0, 0.0, 0.5]).svg;
        let alpha = r#"fill="rgb(255,0,0)" fill-opacity="0.5""#;
        assert!(red.contains(alpha), "{red}");
        // Latin text and accents are the fonts', and Cyrillic the system's.
        assert_eq!(elements(r"\text{café} \alpha"), "path svg");
        assert_eq!(elements(r"\text{Привет} \alpha"), "path svg");
        // So is CJK where the system has a font for it, as the Mac and Windows
        // have. Linux has none where RaTeX looks for one (Noto Sans CJK at
        // Debian's path): its fallback takes the locale's, DejaVu Sans, which
        // has no CJK, and the text is a <text> the host can't trust.
        if cfg!(any(target_os = "macos", target_os = "windows")) {
            assert!(math_svg(r"\text{日本} + x", false, 10.0, BLACK).is_ok());
        }
    }

    #[test]
    fn what_cant_be_drawn_is_an_error() {
        for tex in [r"x^", r"\frac{1}", r"\def\a{\a}\a"] {
            assert!(math_svg(tex, false, 10.0, BLACK).is_err(), "{tex}");
        }
        assert!(math_svg("x", false, f64::NAN, BLACK).is_err());
        assert!(glyph_svg(r"\nosuchcommand", 19.0, 24.0, BLACK).is_err());
        // A colour emoji has no outline to draw where the system's emoji font is bitmaps
        // alone, as macOS's is; Windows' has outlines.
        if cfg!(target_os = "macos") {
            assert!(math_svg(r"\text{😀}", false, 10.0, BLACK).is_err());
        }
    }

    #[test]
    fn absurd_sizes_are_clamped() {
        let cases = r"\rule{100000em}{1em};\rule{1em}{100000em};a\kern100000em b";
        let most = MAX_EM * 10.0;
        for tex in cases.split(';').chain([r"\hspace{1e9pt}x"]) {
            let svg = math_svg(tex, false, 10.0, BLACK).unwrap();
            assert!(svg.width <= most && svg.height <= most, "{tex}");
        }
        assert!(math_svg("x", false, 1e12, BLACK).unwrap().width < 1e4);
    }

    #[test]
    fn a_symbols_ink_is_centred() {
        let square = r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24""#;
        for command in [r"\alpha", r"\sum", r"\sqrt{}", r"\notin", r"\Omega"] {
            let glyph = glyph_svg(command, 19.0, 24.0, BLACK).unwrap();
            assert_eq!((glyph.width, glyph.height), (24.0, 24.0));
            let drawn = glyph.svg.starts_with(square) && glyph.svg.contains("<path");
            assert!(drawn, "{command}");
            let [l, t, r, b] = ink(&display_list(command, false, BLACK).unwrap()).unwrap();
            assert!(r > l && b > t, "{command}");
        }
    }
}
