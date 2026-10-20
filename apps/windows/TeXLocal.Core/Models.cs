using System.Text.Json;

namespace TeXLocal.Bridge;

/// <param name="Mtime">Milliseconds since the epoch; list_projects sorts newest first.</param>
public sealed record ProjectInfo(string Id, string Name, long Mtime, string MainFile)
{
    public override string ToString() => Name;
}

/// <param name="Path">"" for the project's folder.</param>
public sealed record Located(string Id, string Path);

/// <param name="Type">file or dir.</param>
/// <param name="Kind">tex, bib, image, pdf, text or other; null for a folder.</param>
public sealed record TreeNode(string Type, string Name, string Path, string? Kind, TreeNode[]? Children);

/// <param name="Found">The folder the working latexmk runs from.</param>
public sealed record TexStatus(bool Available, string? Version, string? TexDir, string? Found);

/// <param name="Pdf">The last build's, absolute, if it is on disk.</param>
/// <param name="Ui">The project's UI state, as set_ui_state patches it.</param>
public sealed record SessionOpened(ulong Session, string Root, string? Pdf, TreeNode[] Tree, JsonElement Settings, JsonElement Ui);

public sealed record Clash(string Path);

public sealed record Imported(Clash[] Existing);

/// <param name="Type">error or warning.</param>
public sealed record LogItem(string Type, string? File, int? Line, string Message, string Short);

/// <param name="Pdf">Absolute.</param>
/// <param name="PdfChanged">True only when this run finished and wrote the PDF it returns.</param>
public sealed record CompileResult(bool Ok, bool Stopped, long DurationMs, string? Pdf, LogItem[] Errors, LogItem[] Warnings, string Log, bool PdfChanged);

/// An `issues` event's line: the first issue on it, and the messages of the rest.
/// <param name="Compact">For an undefined command, fewer words that keep its name.</param>
/// <param name="Tokens">Where the line has that command, from the line's start.</param>
public sealed record IssueLine(int Line, bool Error, string Message, string Short, string? Compact, SourceRange[] Tokens, string[] Others);

/// A session event's fields, each type setting its own (docs/core-api.md, Events).
public sealed record DocEvent(string? Path, string? Error, bool Held, string? Text, string? From, string? To, string? Kind,
    IssueLine[]? Lines, bool Compiling, bool Auto, bool Outdated, bool Announce, CompileResult? Result, TreeNode[]? Tree);

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

/// <param name="Kind">command, environment, label, citation, entryType or file (a project file, in \input or \includegraphics).</param>
public sealed record Completions(int Start, string Kind, Completion[] Items);

public sealed record Insertion(TextEdit Edit, int Caret, SnippetField[] Fields);

public sealed record MathPreview(int Start, string Tex, bool Display);

/// Each style the whole selection has, as the edits that would take it off.
public sealed record TextStyles(TextEdit[]? Bold, TextEdit[]? Italic, TextEdit[]? Underline);

/// RaTeX's SVG and its size in the points of the size asked for, or why there's none.
public sealed record MathSvg(string? Svg, double Width, double Height, string? Error);

/// Index: its place in the outline read in order; FoldKey names its fold in the project's UI state.
/// <param name="Command">Its sectioning command without the backslash: "section".</param>
/// <param name="Title">Plain text; untitled, its level's: "Untitled Section".</param>
public sealed record OutlineNode(int Index, string Command, string Title, bool Untitled, int Line, string? File, string FoldKey,
    OutlineNode[]? Children)
{
    public IEnumerable<OutlineNode> AndBelow => [this, .. (Children ?? []).SelectMany(c => c.AndBelow)];
}

public sealed record Analysis(OutlineNode[] Tree, int Words, HeadingStyle[] HeadingStyles)
{
    public IEnumerable<OutlineNode> Outline => Tree.SelectMany(n => n.AndBelow);
}

/// <param name="Column">Where the match starts in its line, in UTF-16 units from 0.</param>
public sealed record SearchHit(string File, int Line, int Column, int Length, string Before, string Match, string After);

public sealed record SearchFile(string File, SearchHit[] Hits);

/// <param name="Shape">upright, italic or smallCaps.</param>
public sealed record HeadingFont(double Scale, bool Bold, string Shape);

/// A level the class has, as it sets and numbers it; Normal Text first, with no command.
public sealed record HeadingStyle(string Title, string Command, HeadingFont Font, string? Marker);

/// A block of the catalogue's by id, or with Inline a command around "$0" (wrap's template).
public sealed record Template(string Title, string Body, bool Inline);

public sealed record Templates(Template[] Math, Template[] Insert, Template[] List, Template[] References);

public sealed record MathSymbol(string Command);

public sealed record SymbolGroup(string Title, MathSymbol[] Symbols);

public sealed record Menus(Templates Templates, SymbolGroup[] SymbolGroups);
