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

/// <summary>StopOnFirstError halts a build at its first error; by default it compiles past them.</summary>
public sealed record ProjectSettings(string MainFile, string Engine, bool ShellEscape, bool StopOnFirstError);

public sealed record LogItem(string Type, string? File, int? Line, string Message)
{
    public bool IsError => Type == "error";
}

/// <summary>
/// A build's outcome. Pdf is set whenever this build wrote one, errors or
/// not, since builds compile past them; Stopped when Stop, a newer build or
/// quitting ended it.
/// </summary>
public sealed record CompileResult(
    bool Ok,
    long DurationMs,
    string? Pdf,
    IReadOnlyList<LogItem> Errors,
    IReadOnlyList<LogItem> Warnings,
    string Log,
    bool Stopped)
{
    /// <summary>Failed by itself: a stopped build isn't a failure.</summary>
    public bool Failed => !Ok && !Stopped;
}

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

/// <summary>
/// import_files' result. Asked nothing about names already taken, it
/// writes nothing and lists them in Existing, each with its Keep Both name.
/// </summary>
public sealed record ImportResult(IReadOnlyList<string> Saved, IReadOnlyList<ImportClash> Existing);

public sealed record ImportClash(string Path, string KeepBoth);

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
