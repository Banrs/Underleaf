using System.Diagnostics;

namespace TeXLocal;

/// <summary>Handing files to Windows: their own apps, and File Explorer.</summary>
internal static class Shell
{
    /// <summary>Open a file in the app Windows associates with it.</summary>
    public static void Open(string path) =>
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();

    /// <summary>Show a file selected in File Explorer.</summary>
    public static void Reveal(string path) =>
        Process.Start("explorer.exe", $"/select,\"{path}\"")?.Dispose();
}
