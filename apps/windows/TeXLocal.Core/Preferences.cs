using System.Text.Json;

namespace TeXLocal;

/// <summary>
/// The app's own settings, remembered across launches (the browser version
/// keeps the same ones in web/src/prefs.js). Kept in a JSON file because an
/// unpackaged app has no ApplicationData container.
/// </summary>
public sealed class Preferences
{
    /// <summary>"system", "light" or "dark".</summary>
    public string Theme { get; set; } = "system";

    /// <summary>"onedark" or "xcode".</summary>
    public string EditorPalette { get; set; } = "onedark";

    /// <summary>"system" or "jetbrains".</summary>
    public string EditorFont { get; set; } = "system";

    public int EditorFontSize { get; set; } = 14;
    public bool AutoCompile { get; set; } = true;
    public bool SidebarVisible { get; set; } = true;
    public bool PdfVisible { get; set; } = true;

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

    /// <summary>
    /// Best effort: settings are a convenience, so a full disk or a locked
    /// file costs the change, not the session.
    /// </summary>
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
