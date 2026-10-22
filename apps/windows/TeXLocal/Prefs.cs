using System.Runtime.InteropServices;
using TeXLocal.Bridge;
using Windows.Foundation.Collections;

namespace TeXLocal;

/// The host's preferences, typed, in LocalSettings (the registry, under HKCU\Software\Classes\Local Settings\Software\TeXLocal)
/// until the core keeps validated shared ones; a run on a scratch library (TEXLOCAL_DATA) keeps its own, as "TeXLocal Dev".
/// Settings › Editor's six raise EditorChanged.
public static unsafe partial class Prefs
{
    static readonly IPropertySet values = Microsoft.Windows.Storage.ApplicationData.GetForUnpackaged("TeXLocal",
        Environment.GetEnvironmentVariable("TEXLOCAL_DATA") is null ? "TeXLocal" : "TeXLocal Dev").LocalSettings.Values;
    static string[]? families;

    public static double SidebarWidth { get => Get("sidebarWidth", 280.0); set => values["sidebarWidth"] = value; }
    public static double SplitRatio { get => Get("splitRatio", 0.5); set => values["splitRatio"] = value; }
    public static double IssuesHeight { get => Get("issuesHeight", 200.0); set => values["issuesHeight"] = value; }
    public static bool AutoCompile { get => Get("autoCompile", true); set => values["autoCompile"] = value; }
    public static bool SyncAfterCompile { get => Get("syncAfterCompile", false); set => values["syncAfterCompile"] = value; }
    /// The catalogue's id of the engine a new project starts with.
    public static string Engine { get => Get("engine", "pdflatex"); set => values["engine"] = value; }
    internal static int Theme { get => Get("theme", 0); set => values["theme"] = value; }
    internal static string Bounds { get => Get("bounds", ""); set => values["bounds"] = value; }
    internal static bool Maximized { get => Get("maximized", false); set => values["maximized"] = value; }

    public static string EditorFont { get => Get("editorFont", "Cascadia Mono"); set => Set("editorFont", value, EditorFont); }
    public static double EditorFontSize { get => Get("editorFontSize", 14.0); set => Set("editorFontSize", Math.Clamp(value, 10, 28), EditorFontSize); }
    /// A saved theme the core no longer lists is the default.
    public static string EditorTheme { get => Themes.FirstOrDefault(t => t.Id == Get("editorTheme", ""))?.Id ?? "overleaf"; set => Set("editorTheme", value, EditorTheme); }
    public static bool AutoPair { get => Get("editorAutoPair", true); set => Set("editorAutoPair", value, AutoPair); }
    public static bool AutoComplete { get => Get("editorAutoComplete", true); set => Set("editorAutoComplete", value, AutoComplete); }
    public static bool LineNumbers { get => Get("editorLineNumbers", true); set => Set("editorLineNumbers", value, LineNumbers); }

    public static event Action? EditorChanged;

    public static Choice[] Themes => field ??= Source.SyntaxCall<Choice[]>("themes", new { }) ?? [];

    static T Get<T>(string key, T fallback) => values.TryGetValue(key, out var v) && v is T t ? t : fallback;

    static void Set<T>(string key, T value, T current) where T : notnull
    {
        if (EqualityComparer<T>.Default.Equals(value, current)) return;
        values[key] = value;
        EditorChanged?.Invoke();
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
