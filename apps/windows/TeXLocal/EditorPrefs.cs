using TeXLocal.Bridge;
using Windows.UI;

namespace TeXLocal;

/// The syntax colours the editor and the Settings preview draw with.
static class EditorPrefs
{
    /// A syntax theme's colours by highlight kind, made legible by the core on the editor's background and
    /// current line; none in a high-contrast theme, which draws every kind in the window text colour. The System
    /// theme's secondary text is Windows' (`secondary`, opaque).
    internal static Color[] Colors(string theme, bool dark, Color background, Color fill, Color secondary)
    {
        static byte Byte(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        var colours = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? null
            : Source.SyntaxCall<double[][]>("theme_colors", new
            {
                theme,
                dark,
                background = Rgba(background),
                fill = Rgba(fill),
                system = new Dictionary<string, double[]> { ["secondaryLabelColor"] = Rgba(secondary) },
            });
        return [.. (colours ?? []).Select(c => Color.FromArgb(255, Byte(c[0]), Byte(c[1]), Byte(c[2])))];
    }

    internal static double[] Rgba(Color c) => [c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0];

    /// A translucent colour laid over an opaque one: RichEdit ignores alpha.
    internal static Color Over(Color c, Color under)
    {
        byte Mix(byte a, byte b) => (byte)((a * c.A + b * (255 - c.A)) / 255);
        return Color.FromArgb(255, Mix(c.R, under.R), Mix(c.G, under.G), Mix(c.B, under.B));
    }
}
