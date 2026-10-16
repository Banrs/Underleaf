namespace TeXLocal.Bridge;

/// <param name="Mtime">Milliseconds since the epoch; list_projects sorts newest first.</param>
public sealed record ProjectInfo(string Id, string Name, long Mtime, string MainFile)
{
    public override string ToString() => Name;
}

/// <param name="Type">file or dir.</param>
/// <param name="Kind">tex, bib, image, pdf, text or other; null for a folder.</param>
public sealed record TreeNode(string Type, string Name, string Path, string? Kind, TreeNode[]? Children);

/// <param name="Found">The folder the working latexmk runs from.</param>
public sealed record TexStatus(bool Available, string? Version, string? TexDir, string? Found);

public sealed record SessionOpened(ulong Session, string Root, string? Pdf, TreeNode[] Tree);

public sealed record Clash(string Path);

public sealed record Imported(string[] Saved, Clash[] Existing);

/// <param name="Type">error or warning.</param>
public sealed record LogItem(string Type, string? File, int? Line, string Message, string Short, string? Command);

/// <param name="Pdf">Relative to the project root.</param>
/// <param name="PdfChanged">True only when this run finished and wrote the PDF it returns.</param>
public sealed record CompileResult(bool Ok, bool Stopped, long DurationMs, string? Pdf, LogItem[] Errors, LogItem[] Warnings, string Log, bool PdfChanged);

/// An `issues` event's line: the first issue on it, and the messages of the rest.
public sealed record IssueLine(int Line, bool Error, string Message, string Short, string? Command, string[] Others);

/// <param name="Page">From 1; the box in TeX points from the page's top left.</param>
public sealed record ForwardSync(double Page, double? H, double? V, double? Width, double? Height);

public sealed record InverseSync(string File, int Line, int? Column);

/// UTF-16 offsets, as the editor counts.
public sealed record SourceRange(int Start, int Length)
{
    public int End => Start + Length;
}

public sealed record TextEdit(int Start, int Length, string Text);

/// What a key does in place of the editor's default: an edit, where the selection goes, a bracket's partner to show,
/// and what the completion list does (keep, offer or close). With neither edit nor selection the editor types as usual.
public sealed record Keystroke(TextEdit? Edit, SourceRange? Selection, int? Partner, string Completions);

/// Edits applied from the last as one undo step, and the selections after them.
public sealed record Change(TextEdit[] Edits, SourceRange[] Selections);

/// Tab: a snippet's field to select, or without a snippet the lines' indentation.
public sealed record Tabbing(SourceRange? Field, TextEdit[] Edits);

public sealed record SnippetField(int Start, int Length, int Index);

public sealed record Completion(string Label, string Text, SnippetField[] Fields);

/// <param name="Kind">command, environment, label, citation or entryType.</param>
public sealed record Completions(int Start, string Kind, Completion[] Items);

public sealed record Insertion(TextEdit Edit, int Caret, SnippetField[] Fields);

public sealed record MathPreview(int Start, string Tex, bool Display);

/// Each style the whole selection has, as the edits that would take it off.
public sealed record TextStyles(TextEdit[]? Bold, TextEdit[]? Italic, TextEdit[]? Underline);

/// RaTeX's SVG and its size in the points of the size asked for, or why there's none.
public sealed record MathSvg(string? Svg, double Width, double Height, string? Error);

/// <param name="Depth">0 for \part to 5 for \paragraph.</param>
/// <param name="Title">Plain text, "(untitled)" when empty.</param>
public sealed record Heading(int Depth, string Title, int Line, string? File);

/// A heading and what nests under it; FoldKey names its fold in the project's UI state.
public sealed record OutlineNode(int Index, int Depth, string Title, int Line, string? File, string FoldKey, OutlineNode[]? Children);

/// analyze_project: the outline in reading order, the words, and the outline as a tree.
public sealed record Analysis(Heading[] Outline, int Words, OutlineNode[] Tree);

/// <param name="Column">Where the match starts in its line, in UTF-16 units from 0.</param>
public sealed record SearchHit(string File, int Line, int Column, int Length, string Before, string Match, string After);

public sealed record DocumentClass(string Name, int PointSize);

/// <param name="Shape">upright, italic or smallCaps.</param>
public sealed record HeadingFont(double Scale, bool Bold, string Shape);

/// A level the class has, as it sets and numbers it; Normal Text first, with no command.
public sealed record HeadingStyle(string Title, string Command, HeadingFont Font, string? Marker);

/// A block of the catalogue's by id, or with Inline a command around "$0" (wrap's template).
public sealed record Template(string Title, string Body, string? Symbol, bool Inline);

public sealed record Templates(Template[] Math, Template[] Insert, Template[] List, Template[] References);

public sealed record HeadingLevel(string Title, string Command);

public sealed record MathSymbol(string Glyph, string Command);

public sealed record SymbolGroup(string Title, MathSymbol[] Symbols);

/// The catalogue the Insert menu and the palette are made from.
public sealed record Menus(Templates Templates, HeadingLevel[] HeadingLevels, SymbolGroup[] SymbolGroups);
