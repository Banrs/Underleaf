namespace TeXLocal.Core;

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
