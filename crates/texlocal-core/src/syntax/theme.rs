//! The editor's syntax colours (Overleaf, TeXstudio and System, light and dark) and WCAG's contrast maths that
//! raises a colour to a legible contrast on the editor's background and current line.

pub type Rgba = [f64; 4];

/// A theme's colour for a kind: sRGB in each appearance, or a system colour by its AppKit name that each host
/// resolves itself, with Apple's published values as the fallback.
#[derive(Clone, Copy, Debug)]
pub struct ThemeColor {
    pub system: Option<&'static str>,
    pub light: Rgba,
    pub dark: Rgba,
}

#[derive(Clone, Copy, Debug)]
pub struct Theme {
    pub id: &'static str,
    pub title: &'static str,
    /// By `HighlightKind`; invalid's is a foreground only.
    pub colors: [ThemeColor; 5],
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
    // Overleaf's source editor themes ("textmate", "overleaf_dark"), by the lezer tags it gives LaTeX's nodes; its
    // `.tok-keyword` has no kind here.
    Theme {
        id: "overleaf",
        title: "Overleaf",
        colors: [
            rgb(0x0000FF, 0x8BE9FD),
            rgb(0x318495, 0xFFB86C),
            rgb(0x036A07, 0xF1FA8C),
            rgb(0x4C886B, 0x6272A4),
            rgb(0xFF0000, 0xFF79C6),
        ],
    },
    // TeXstudio's formats (defaultFormats.qxf, defaultFormatsDark.qxf); invalid is "braceMismatch", whose fill Light
    // takes and whose text Dark takes, the fill not being drawn.
    Theme {
        id: "texstudio",
        title: "TeXstudio",
        colors: [
            rgb(0x800000, 0x60CDF2),
            rgb(0x008000, 0x60F260),
            rgb(0x509600, 0x85F218),
            rgb(0x808080, 0x667299),
            rgb(0xC00000, 0xF2F218),
        ],
    },
    Theme {
        id: "system",
        title: "System",
        colors: [
            system("systemPink", hex(0xFF2D55), hex(0xFF375F)),
            system("systemTeal", hex(0x30B0C7), hex(0x40C8E0)),
            system("systemPurple", hex(0xAF52DE), hex(0xBF5AF2)),
            system(
                "secondaryLabelColor",
                [0.0, 0.0, 0.0, 0.5],
                [1.0, 1.0, 1.0, 0.55],
            ),
            system("systemRed", hex(0xFF3B30), hex(0xFF453A)),
        ],
    },
];

pub fn theme(id: &str) -> Option<&'static Theme> {
    THEMES.iter().find(|t| t.id == id)
}

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

pub fn contrast(a: Rgba, b: Rgba) -> f64 {
    let (a, b) = (luminance(a), luminance(b));
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

pub fn blend(a: Rgba, b: Rgba, fraction: f64) -> Rgba {
    std::array::from_fn(|i| a[i] * (1.0 - fraction) + b[i] * fraction)
}

/// Mixed by sRGB's components, as the window server mixes them.
pub fn over(color: Rgba, background: Rgba) -> Rgba {
    let mut shown = blend(background, color, color[3]);
    shown[3] = 1.0;
    shown
}

/// Towards black on a light background or white on a dark one, as little as gives `ratio`, so it keeps its hue.
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

/// The HIG's 4.5:1 for text under 18 points, or WCAG's 7:1 with Increase Contrast.
pub fn text_contrast(increase_contrast: bool) -> f64 {
    if increase_contrast { 7.0 } else { 4.5 }
}

/// A colour raised to `ratio` on the editor's background and its current line, over which a translucent `fill` is mixed.
pub fn legible(color: Rgba, background: Rgba, fill: Rgba, ratio: f64) -> Rgba {
    let line = over(fill, background);
    contrasting(
        contrasting(over(color, background), background, ratio),
        line,
        ratio,
    )
}

#[derive(Clone, Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Appearance {
    pub dark: bool,
    #[serde(default)]
    pub increase_contrast: bool,
    pub background: Rgba,
    pub fill: Rgba,
    #[serde(default)]
    pub system: std::collections::HashMap<String, Rgba>,
}

pub fn theme_colors(theme: &Theme, appearance: &Appearance) -> Vec<Rgba> {
    let ratio = text_contrast(appearance.increase_contrast);
    theme
        .colors
        .iter()
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
    use crate::syntax::highlight::HighlightKind::Command;

    /// The Mac's text background and current line fill, resolved in Light and Dark (27.2).
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
        let colors = theme_colors(theme("overleaf").unwrap(), &appearance(false, false));
        assert_eq!(colors[Command as usize], [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn a_colour_is_raised_as_little_as_it_takes() {
        let white = [1.0; 4];
        let comment = hex(0x4C886B);
        assert!(contrast(comment, white) < 4.5);
        let raised = contrasting(comment, white, 4.5);
        assert_eq!(raised, blend(comment, [0.0, 0.0, 0.0, 1.0], 0.05));
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
    }
}
