//! The editor's syntax colours (Settings › Editor › Theme): Overleaf,
//! TeXstudio and System, light and dark for each highlight kind, and WCAG's
//! maths that raises a colour to a legible contrast on the editor's
//! background and on its current line. Hosts resolve their backgrounds and
//! system colours and map the sRGB answers to their own colour type.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// sRGB components and alpha, 0 to 1.
pub type Rgba = [f64; 4];

/// A theme's colour for a kind: sRGB in each appearance, or a system colour
/// by its AppKit name (`systemPink`), which each host resolves in its own
/// appearance; `light` and `dark` are then Apple's published values, for a
/// host without such a colour.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct ThemeColor {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system: Option<&'static str>,
    pub light: Rgba,
    pub dark: Rgba,
}

/// Text, braces and brackets are plain in every theme.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct Theme {
    pub id: &'static str,
    pub title: &'static str,
    /// `\command`, `\begin`, `\end`, escapes.
    pub command: ThemeColor,
    /// Environment, label, reference, citation, file and package-option names.
    pub argument: ThemeColor,
    /// Maths' delimiters and what is in it, verbatim.
    pub maths: ThemeColor,
    pub comment: ThemeColor,
    /// Foreground only: a stray brace, what maths can't hold.
    pub invalid: ThemeColor,
}

const fn hex(rgb: u32) -> Rgba {
    let [_, r, g, b] = rgb.to_be_bytes();
    [r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0, 1.0]
}

const fn rgb(light: u32, dark: u32) -> ThemeColor {
    system("", hex(light), hex(dark))
}

/// A system colour by name, or none for "".
const fn system(name: &'static str, light: Rgba, dark: Rgba) -> ThemeColor {
    let system = if name.is_empty() { None } else { Some(name) };
    ThemeColor { system, light, dark }
}

pub const THEMES: [Theme; 3] = [
    // Overleaf's source editor themes (services/web/frontend/js/features/
    // source-editor/themes/cm6/): "textmate" in Light, "overleaf_dark" in
    // Dark, by the lezer tags it gives LaTeX's nodes. command: .tok-typeName;
    // argument: .tok-attributeValue; maths: .tok-string; comment:
    // .tok-comment; invalid: .tok-invalid's text. Its .tok-keyword
    // (`\documentclass`, `\cite`, `\ref`, `\label`, `~`, `&`, `\\`) has no
    // kind here.
    Theme {
        id: "overleaf",
        title: "Overleaf",
        command: rgb(0x0000FF, 0x8BE9FD),
        argument: rgb(0x318495, 0xFFB86C),
        maths: rgb(0x036A07, 0xF1FA8C),
        comment: rgb(0x4C886B, 0x6272A4),
        invalid: rgb(0xFF0000, 0xFF79C6),
    },
    // TeXstudio's formats, utilities/qxs/defaultFormats.qxf (Light) and
    // defaultFormatsDark.qxf (Dark). command: "keyword"; argument:
    // "referencePresent", "citationPresent" and "packagePresent", one
    // colour; maths: "math-delimiter"; comment: "comment"; invalid:
    // "braceMismatch", whose fill Light takes and whose text Dark takes, the
    // fill not being drawn.
    Theme {
        id: "texstudio",
        title: "TeXstudio",
        command: rgb(0x800000, 0x60CDF2),
        argument: rgb(0x008000, 0x60F260),
        maths: rgb(0x509600, 0x85F218),
        comment: rgb(0x808080, 0x667299),
        invalid: rgb(0xC00000, 0xF2F218),
    },
    // The system's colours, which follow the appearance.
    Theme {
        id: "system",
        title: "System",
        command: system("systemPink", hex(0xFF2D55), hex(0xFF375F)),
        argument: system("systemTeal", hex(0x30B0C7), hex(0x40C8E0)),
        maths: system("systemPurple", hex(0xAF52DE), hex(0xBF5AF2)),
        comment: system("secondaryLabelColor", [0., 0., 0., 0.5], [1., 1., 1., 0.55]),
        invalid: system("systemRed", hex(0xFF3B30), hex(0xFF453A)),
    },
];

/// WCAG's relative luminance.
pub fn luminance(c: Rgba) -> f64 {
    let linear = |v: f64| match v <= 0.04045 {
        true => v / 12.92,
        false => ((v + 0.055) / 1.055).powf(2.4),
    };
    0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
}

/// WCAG's contrast ratio, 1 to 21.
pub fn contrast(a: Rgba, b: Rgba) -> f64 {
    let (a, b) = (luminance(a), luminance(b));
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

/// `a` mixed with `fraction` of `b`, component by component.
fn blend(a: Rgba, b: Rgba, fraction: f64) -> Rgba {
    std::array::from_fn(|i| a[i] * (1.0 - fraction) + b[i] * fraction)
}

/// A translucent colour as it shows on an opaque background, mixed by sRGB's
/// components, as the window server mixes them.
fn over(color: Rgba, background: Rgba) -> Rgba {
    let [r, g, b, _] = blend(background, color, color[3]);
    if color[3] >= 1.0 { color } else { [r, g, b, 1.0] }
}

/// Mixed towards black on a light background or white on a dark one, by
/// twentieths, as little as gives `ratio` on it, so it keeps its hue; as it
/// is when it has that already.
fn contrasting(color: Rgba, background: Rgba, ratio: f64) -> Rgba {
    // Where black and white contrast equally with a colour.
    let light = luminance(background) > 0.179;
    let ink = if light { [0., 0., 0., 1.] } else { [1.0; 4] };
    let mut mixes = (0..=20).map(|step| blend(color, ink, f64::from(step) / 20.0));
    let enough = |&mixed: &Rgba| contrast(mixed, background) >= ratio;
    mixes.find(enough).unwrap_or(ink)
}

/// The contrast text wants: the HIG's 4.5:1 for text under 18 points, or
/// WCAG's enhanced 7:1 with Increase Contrast.
pub fn text_contrast(increase_contrast: bool) -> f64 {
    if increase_contrast { 7.0 } else { 4.5 }
}

/// A colour on the editor's background and on its current line, the
/// (translucent) `fill` over the background, raised to `ratio`: text's
/// (`text_contrast`), or 3:1, the HIG's for large text and graphics, such as
/// a border.
pub fn legible(color: Rgba, background: Rgba, fill: Rgba, ratio: f64) -> Rgba {
    let on_background = contrasting(over(color, background), background, ratio);
    contrasting(on_background, over(fill, background), ratio)
}

/// What the host resolved for one appearance.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Appearance {
    pub dark: bool,
    #[serde(default)]
    pub increase_contrast: bool,
    pub background: Rgba,
    pub fill: Rgba,
    /// The system theme's colours by name, as resolved; a name left out
    /// takes its `ThemeColor`'s published value.
    #[serde(default)]
    pub system: HashMap<String, Rgba>,
}

/// A theme's legible colours in an appearance, by highlight kind, in
/// `HighlightKind`'s order.
pub fn theme_colors(t: &Theme, a: &Appearance) -> Vec<Rgba> {
    let (command, argument, maths) = (t.command, t.argument, t.maths);
    let by_kind = [command, argument, maths, maths, maths, t.comment, t.invalid, maths, argument];
    let legible = |c: ThemeColor| {
        let published = if a.dark { c.dark } else { c.light };
        let resolved = c.system.and_then(|name| a.system.get(name).copied());
        let ratio = text_contrast(a.increase_contrast);
        legible(resolved.unwrap_or(published), a.background, a.fill, ratio)
    };
    by_kind.into_iter().map(legible).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_themes_are_legible() {
        let appearances = [(false, false), (true, false), (false, true), (true, true)];
        for (dark, increase_contrast) in appearances {
            // The Mac's text background and its current line's fill, resolved in
            // Light and Dark (27.2): white and 30, the fill giving 235 and 48.
            let ground = if dark { 30.0 / 255.0 } else { 1.0 };
            let ink = if dark { 1.0 } else { 0.0 };
            let (background, fill) = ([ground, ground, ground, 1.0], [ink, ink, ink, 0.08]);
            let system = HashMap::from([("systemPink".into(), [0., 0., 0., 1.])]);
            let a = Appearance { dark, increase_contrast, background, fill, system };
            let ratio = text_contrast(increase_contrast);
            let grounds = [background, over(fill, background)];
            for theme in &THEMES {
                let colors = theme_colors(theme, &a);
                assert_eq!(colors.len(), 9);
                for (color, ground) in colors.iter().flat_map(|&c| grounds.map(|g| (c, g))) {
                    let c = contrast(color, ground);
                    assert!(c >= ratio, "{} {color:?} on {ground:?}: {c}", theme.id);
                }
            }
            if !dark && !increase_contrast {
                // Overleaf's Light commands, at 8.6:1, are its own blue; the System
                // theme's are the host's.
                assert_eq!(theme_colors(&THEMES[0], &a)[0], [0.0, 0.0, 1.0, 1.0]);
                assert_eq!(theme_colors(&THEMES[2], &a)[0], [0.0, 0.0, 0.0, 1.0]);
            }
        }
    }

    #[test]
    fn a_colour_is_raised_as_little_as_it_takes() {
        let white = [1.0; 4];
        // Overleaf's comments, 4.2:1 on white, a twentieth towards black.
        let comment = hex(0x4C886B);
        assert!(contrast(comment, white) < 4.5);
        let darker = blend(comment, [0., 0., 0., 1.], 0.05);
        assert_eq!(contrasting(comment, white, 4.5), darker);
        // On a dark background, towards white.
        let dark = [0.1, 0.1, 0.1, 1.0];
        let raised = contrasting(hex(0x333333), dark, 4.5);
        assert!(raised[0] > 0.2 && contrast(raised, dark) >= 4.5);
        // A translucent label shows as its mix with the background.
        assert_eq!(over([0.0, 0.0, 0.0, 0.5], white), [0.5, 0.5, 0.5, 1.0]);
        assert!((contrast([0.0, 0.0, 0.0, 1.0], white) - 21.0).abs() < 1e-9);
    }
}
