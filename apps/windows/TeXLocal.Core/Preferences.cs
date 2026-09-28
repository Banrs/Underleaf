using System.Text.Json;

namespace TeXLocal;

/// <summary>
/// The app's settings (web/src/prefs.js keeps the same), in a JSON file since
/// an unpackaged app has no ApplicationData container.
/// </summary>
public sealed class Preferences
{
    /// <summary>"system", "light" or "dark".</summary>
    public string Theme { get; set; } = "system";

    /// <summary>"onedark" or "xcode".</summary>
    public string EditorPalette { get; set; } = "onedark";

    /// <summary>"system" or "jetbrains".</summary>
    public string EditorFont { get; set; } = "jetbrains";

    public int EditorFontSize { get; set; } = 14;

    /// <summary>The editor page's size in percent, one of UiScales.</summary>
    public int UiScale { get; set; } = 100;

    /// <summary>"white", "dark" (inverted) or "auto" (dark with the app).</summary>
    public string PdfPaper { get; set; } = "white";

    public bool ShowWordCount { get; set; } = true;
    public bool AutoCompile { get; set; } = true;
    public bool SidebarVisible { get; set; } = true;
    public bool PdfVisible { get; set; } = true;
    public bool OutlineOpen { get; set; } = true;
    public bool InspectorVisible { get; set; }

    // The layout as last dragged; null until then, for the workspace's defaults.
    public double? SidebarWidth { get; set; }

    /// <summary>The PDF's share of the source and PDF's width, 0–1.</summary>
    public double? PdfSplit { get; set; }

    public double? OutlineHeight { get; set; }

    /// <summary>The outline's folded headings, by project, file and <see cref="Outline.FoldKeys"/>.</summary>
    public List<string> OutlineFolded { get; set; } = [];

    public double? PanelHeight { get; set; }
    public double? InspectorWidth { get; set; }

    /// <summary>web/src/prefs.js UI_SCALES, stepped by the interface-size commands.</summary>
    public static readonly int[] UiScales = [80, 90, 100, 110, 120, 130];

    /// <summary>One step along UiScales, stopping at either end; an unknown size starts from 100.</summary>
    public static int StepUiScale(int current, int delta) =>
        Array.IndexOf(UiScales, current) is var i and >= 0 ? UiScales[Math.Clamp(i + delta, 0, UiScales.Length - 1)] : 100;

    /// <summary>The saved settings, or the defaults when there are none or they cannot be read.</summary>
    public static Preferences Load(string path)
    {
        try
        {
            return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path), Core.Json) ?? new();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return new();
        }
    }

    /// <summary>Best effort: a full disk or a locked file costs the change, not the session.</summary>
    public void Save(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, Core.Json));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
