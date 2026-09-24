namespace TeXLocal;

// The core's JSON shapes (crates/texlocal-core), read with Core.Json's
// camelCase names.

public sealed record ProjectInfo(string Id, string Name, long Mtime, string MainFile)
{
    /// <summary>Mtime is milliseconds since 1970.</summary>
    public DateTimeOffset Modified => DateTimeOffset.FromUnixTimeMilliseconds(Mtime);
}

public sealed record TreeNode(string Type, string Name, string Path, IReadOnlyList<TreeNode>? Children)
{
    public bool IsDirectory => Type == "dir";
}

public sealed record TexStatus(bool Available, string? Version);

public sealed record ProjectSettings(string MainFile, string Engine, bool ShellEscape);

public sealed record LogItem(string Type, string? File, int? Line, string Message)
{
    public bool IsError => Type == "error";
}

public sealed record CompileResult(
    bool Ok,
    long DurationMs,
    string? Pdf,
    IReadOnlyList<LogItem> Errors,
    IReadOnlyList<LogItem> Warnings,
    string Log);

public sealed record Symbols(IReadOnlyList<string> Citations, IReadOnlyList<string> Labels);

public sealed record SearchHit(string File, int Line, string Before, string Match, string After)
{
    public string Location => $"{File}:{Line}";
}

public sealed record FileText(string Text);

/// <summary>
/// A SyncTeX box in PDF points, origin at the page's top-left: the baseline
/// point (H, V) and the box's width and height above it — the shape the PDF
/// page's highlight() takes.
/// </summary>
public sealed record ForwardLoc(double Page, double? H, double? V, double? Width, double? Height);

public sealed record InverseLoc(string File, int Line);

public sealed record ImportResult(IReadOnlyList<string> Saved);

/// <summary>rename_entry's result: both paths as the core normalised them.</summary>
public sealed record RenameResult(string From, string To, string MainFile);

public static class TextFiles
{
    /// <summary>
    /// The extensions the core treats as text (projects.rs TEXT_EXT); anything
    /// else opens in its own app rather than the editor.
    /// </summary>
    private static readonly HashSet<string> Extensions =
    [
        "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
        "py", "r", "dat", "def", "clo", "tikz", "svg",
    ];

    public static bool IsText(string path) =>
        Extensions.Contains(System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant());
}
