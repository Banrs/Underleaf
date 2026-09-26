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

/// <summary>TexDir is the folder the user chose (null: found automatically); Found is where latexmk runs from.</summary>
public sealed record TexStatus(bool Available, string? Version, string? TexDir = null, string? Found = null);

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
    /// <summary>Under its file's heading in the results, a match needs only its line.</summary>
    public string LineLabel => $"Line {Line:N0}";
}

public sealed record FileText(string Text);

/// <summary>
/// A SyncTeX box in PDF points from the page's top-left: baseline point (H, V),
/// width and height above it, as the PDF page's highlight() takes it.
/// </summary>
public sealed record ForwardLoc(double Page, double? H, double? V, double? Width, double? Height);

public sealed record InverseLoc(string File, int Line);

public sealed record ImportResult(IReadOnlyList<string> Saved);

/// <summary>rename_entry's result: both paths as the core normalised them.</summary>
public sealed record RenameResult(string From, string To, string MainFile);

public static class TextFiles
{
    /// <summary>The core's text extensions (projects.rs TEXT_EXT); anything else opens in its own app.</summary>
    private static readonly HashSet<string> Extensions =
    [
        "tex", "bib", "cls", "sty", "bst", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "lua",
        "py", "r", "dat", "def", "clo", "tikz", "svg",
    ];

    public static bool IsText(string path) =>
        Extensions.Contains(System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant());
}
