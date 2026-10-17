//! The editor's syntax colours (Settings › Editor › Theme): Overleaf,
//! TeXstudio and System, light and dark for each highlight kind, and WCAG's
//! maths that raises a colour to a legible contrast on the editor's
//! background and on its current line. Hosts resolve their backgrounds and
//! system colours and map the sRGB answers to their own colour type.

use serde::Serialize;

use super::HighlightKind;

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
    [
        (rgb >> 16 & 0xff) as f64 / 255.0,
        (rgb >> 8 & 0xff) as f64 / 255.0,
        (rgb & 0xff) as f64 / 255.0,
        1.0,
    ]
}

const fn rgb(light: u32, dark: u32) -> ThemeColor {
    ThemeColor {
        system: None,
        light: hex(light),
        dark: hex(dark),
    }
}

const fn system(name: &'static str, light: Rgba, dark: Rgba) -> ThemeColor {
    ThemeColor {
        system: Some(name),
        light,
        dark,
    }
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
        comment: system(
            "secondaryLabelColor",
            [0.0, 0.0, 0.0, 0.5],
            [1.0, 1.0, 1.0, 0.55],
        ),
        invalid: system("systemRed", hex(0xFF3B30), hex(0xFF453A)),
    },
];

pub fn theme(id: &str) -> Option<&'static Theme> {
    THEMES.iter().find(|t| t.id == id)
}

impl Theme {
    /// The colour of a highlight kind.
    pub fn color(&self, kind: HighlightKind) -> &ThemeColor {
        use HighlightKind::*;
        match kind {
            Command => &self.command,
            Argument | Builtin => &self.argument,
            MathDelimiter | MathIdentifier | Number | StringLiteral => &self.maths,
            Comment => &self.comment,
            Invalid => &self.invalid,
        }
    }
}

/// WCAG's relative luminance.
pub fn luminance(c: Rgba) -> f64 {
    let linear = |v: f64| {
        if v <= 0.04045 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
}

/// WCAG's contrast ratio, 1 to 21.
pub fn contrast(a: Rgba, b: Rgba) -> f64 {
    let (a, b) = (luminance(a), luminance(b));
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

/// `a` mixed with `fraction` of `b`, component by component.
pub fn blend(a: Rgba, b: Rgba, fraction: f64) -> Rgba {
    std::array::from_fn(|i| a[i] * (1.0 - fraction) + b[i] * fraction)
}

/// A translucent colour as it shows on an opaque background, mixed by sRGB's
/// components, as the window server mixes them.
pub fn over(color: Rgba, background: Rgba) -> Rgba {
    let alpha = color[3];
    if alpha >= 1.0 {
        return color;
    }
    let mut shown = blend(background, color, alpha);
    shown[3] = 1.0;
    shown
}

/// Mixed towards black on a light background or white on a dark one, by
/// twentieths, as little as gives `ratio` on it, so it keeps its hue; as it
/// is when it has that already.
pub fn contrasting(color: Rgba, background: Rgba, ratio: f64) -> Rgba {
    // Where black and white contrast equally with a colour.
    let ink = if luminance(background) > 0.179 {
        [0.0, 0.0, 0.0, 1.0]
    } else {
        [1.0, 1.0, 1.0, 1.0]
    };
    let mut mixed = color;
    for step in 1..=20 {
        if contrast(mixed, background) >= ratio {
            break;
        }
        mixed = blend(color, ink, f64::from(step) / 20.0);
    }
    mixed
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
    let line = over(fill, background);
    contrasting(
        contrasting(over(color, background), background, ratio),
        line,
        ratio,
    )
}

/// What the host resolved for one appearance.
#[derive(Clone, Debug, serde::Deserialize)]
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
    pub system: std::collections::HashMap<String, Rgba>,
}

/// A theme's legible colours in an appearance, by highlight kind, in
/// `HighlightKind`'s order.
pub fn theme_colors(theme: &Theme, appearance: &Appearance) -> Vec<Rgba> {
    let ratio = text_contrast(appearance.increase_contrast);
    let colors = HighlightKind::ALL.into_iter().map(|kind| theme.color(kind));
    colors
        .map(|color| {
            let published = if appearance.dark {
                color.dark
            } else {
                color.light
            };
            let system = color.system.and_then(|name| appearance.system.get(name));
            let resolved = system.copied().unwrap_or(published);
            legible(resolved, appearance.background, appearance.fill, ratio)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use HighlightKind::Command;

    /// The Mac's text background and its current line's fill, resolved in
    /// Light and Dark (27.2): white and 30, the fill giving 235 and 48.
    fn appearance(dark: bool, increase_contrast: bool) -> Appearance {
        let (ground, ink) = if dark {
            (30.0 / 255.0, 1.0)
        } else {
            (1.0, 0.0)
        };
        Appearance {
            dark,
            increase_contrast,
            background: [ground, ground, ground, 1.0],
            fill: [ink, ink, ink, 0.08],
            system: Default::default(),
        }
    }

    #[test]
    fn the_themes_are_legible() {
        for (dark, increase_contrast) in
            [(false, false), (true, false), (false, true), (true, true)]
        {
            let a = appearance(dark, increase_contrast);
            let line = over(a.fill, a.background);
            let ratio = if increase_contrast { 7.0 } else { 4.5 };
            for theme in &THEMES {
                for color in theme_colors(theme, &a) {
                    for ground in [a.background, line] {
                        let c = contrast(color, ground);
                        assert!(c >= ratio, "{} {color:?} on {ground:?}: {c}", theme.id);
                    }
                }
            }
        }
        // Overleaf's Light commands, at 8.6:1, are its own blue.
        let colors = theme_colors(theme("overleaf").unwrap(), &appearance(false, false));
        assert_eq!(colors[Command as usize], [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn a_colour_is_raised_as_little_as_it_takes() {
        let white = [1.0; 4];
        // Overleaf's comments, 4.2:1 on white, a twentieth towards black.
        let comment = hex(0x4C886B);
        assert!(contrast(comment, white) < 4.5);
        let raised = contrasting(comment, white, 4.5);
        assert_eq!(raised, blend(comment, [0.0, 0.0, 0.0, 1.0], 0.05));
        // On a dark background, towards white.
        let dark = [0.1, 0.1, 0.1, 1.0];
        let raised = contrasting(hex(0x333333), dark, 4.5);
        assert!(raised[0] > 0.2 && contrast(raised, dark) >= 4.5);
        // A translucent label shows as its mix with the background.
        assert_eq!(over([0.0, 0.0, 0.0, 0.5], white), [0.5, 0.5, 0.5, 1.0]);
        assert!((contrast([0.0, 0.0, 0.0, 1.0], white) - 21.0).abs() < 1e-9);
    }

    #[test]
    fn system_colours_are_the_hosts() {
        let mut a = appearance(false, false);
        a.system.insert("systemPink".into(), [0.0, 0.0, 0.0, 1.0]);
        let colors = theme_colors(theme("system").unwrap(), &a);
        assert_eq!(colors[Command as usize], [0.0, 0.0, 0.0, 1.0]);
        let json = serde_json::to_string(&THEMES[2].command).unwrap();
        assert!(
            json.starts_with(r#"{"system":"systemPink","light":[1.0,"#),
            "{json}"
        );
        let json = serde_json::to_string(&THEMES[0].command).unwrap();
        assert!(!json.contains("system"), "{json}");
    }
}
