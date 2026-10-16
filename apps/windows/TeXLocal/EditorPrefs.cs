using System.Runtime.InteropServices;
using TeXLocal.Bridge;
using Windows.UI;

namespace TeXLocal;

public sealed record SyntaxTheme(string Id, string Title);

/// Settings › Editor, in the host's store until the core keeps validated shared preferences.
public static unsafe partial class EditorPrefs
{
    static SyntaxTheme[]? themes;
    static string[]? families;

    public static string Font { get => MainWindow.Pref("editorFont", "Cascadia Mono"); set => Set("editorFont", value, Font); }
    public static double FontSize { get => MainWindow.Pref("editorFontSize", 14.0); set => Set("editorFontSize", Math.Clamp(value, 10, 28), FontSize); }
    public static string Theme { get => MainWindow.Pref("editorTheme", "overleaf"); set => Set("editorTheme", value, Theme); }
    public static bool AutoPair { get => MainWindow.Pref("editorAutoPair", true); set => Set("editorAutoPair", value, AutoPair); }
    public static bool AutoComplete { get => MainWindow.Pref("editorAutoComplete", true); set => Set("editorAutoComplete", value, AutoComplete); }

    public static event Action? Changed;

    public static SyntaxTheme[] Themes => themes ??= Source.SyntaxCall<SyntaxTheme[]>("themes", new { }) ?? [];

    static void Set<T>(string key, T value, T current) where T : notnull
    {
        if (EqualityComparer<T>.Default.Equals(value, current)) return;
        MainWindow.Prefs[key] = value;
        Changed?.Invoke();
    }

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

    /// GDI's fixed-pitch families, without vertical (@) faces, bitmap fonts or the families GDI makes
    /// of a font's other weights ("Cascadia Code SemiBold").
    public static string[] MonospaceFamilies()
    {
        if (families is not null) return families;
        var found = new SortedSet<string>(StringComparer.CurrentCultureIgnoreCase);
        using var handle = new GCHandle<SortedSet<string>>(found);
        var font = new LogFont { CharSet = 1 }; // DEFAULT_CHARSET
        var dc = GetDC(0);
        EnumFontFamiliesExW(dc, &font, &Found, GCHandle<SortedSet<string>>.ToIntPtr(handle), 0);
        ReleaseDC(0, dc);
        return families = [.. found.Where(f => !found.Any(g => f.StartsWith(g + " ", StringComparison.Ordinal)))];
    }

    [UnmanagedCallersOnly]
    static int Found(LogFont* font, void* metric, uint type, nint found)
    {
        var name = new string(font->FaceName);
        if ((font->PitchAndFamily & 3) == 1 && (type & 1) == 0 && !name.StartsWith('@'))
            GCHandle<SortedSet<string>>.FromIntPtr(found).Target.Add(name);
        return 1;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct LogFont
    {
        public int Height, Width, Escapement, Orientation, Weight;
        public byte Italic, Underline, StrikeOut, CharSet, OutPrecision, ClipPrecision, Quality, PitchAndFamily;
        public fixed char FaceName[32];
    }

    [LibraryImport("gdi32.dll")]
    private static partial int EnumFontFamiliesExW(nint dc, LogFont* font, delegate* unmanaged<LogFont*, void*, uint, nint, int> proc, nint param, uint flags);

    [LibraryImport("user32.dll")]
    private static partial nint GetDC(nint hwnd);

    [LibraryImport("user32.dll")]
    private static partial int ReleaseDC(nint hwnd, nint dc);
}
