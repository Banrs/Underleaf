namespace TeXLocal.Bridge;

/// <param name="Mtime">Milliseconds since the epoch; list_projects sorts newest first.</param>
public sealed record ProjectInfo(string Id, string Name, long Mtime, string MainFile);

/// <param name="Type">file or dir.</param>
/// <param name="Kind">tex, bib, image, pdf, text or other; null for a folder.</param>
public sealed record TreeNode(string Type, string Name, string Path, string? Kind, TreeNode[]? Children);

/// <param name="Found">The folder the working latexmk runs from.</param>
/// <param name="Texpresso">The TeXpresso program live preview would run.</param>
public sealed record TexStatus(bool Available, string? Version, string? TexDir, string? Found, string? Texpresso, string? TexpressoDir);

public sealed record SessionOpened(ulong Session, string Root, string? Pdf, TreeNode[] Tree);

public sealed record Clash(string Path, string KeepBoth);

public sealed record Imported(string[] Saved, Clash[] Existing);

/// <param name="Type">error or warning.</param>
public sealed record LogItem(string Type, string? File, int? Line, string Message, string Short, string? Command);

/// <param name="Pdf">Relative to the project root.</param>
public sealed record CompileResult(bool Ok, bool Stopped, long DurationMs, string? Pdf, LogItem[] Errors, LogItem[] Warnings, string Log);

/// An `issues` event's line: the first issue on it, and the messages of the rest.
public sealed record IssueLine(int Line, bool Error, string Message, string Short, string? Command, string[] Others);

/// <param name="Page">From 1; the box in TeX points from the page's top left.</param>
public sealed record ForwardSync(double Page, double? H, double? V, double? Width, double? Height);

public sealed record InverseSync(string File, int Line, int? Column);
