namespace TeXLocal;

/// <summary>A heading: Level runs from 0 for \part to 5 for \paragraph.</summary>
public sealed record OutlineItem(int Level, string Title, int Line);

/// <summary>A heading and the headings it encloses.</summary>
public sealed record OutlineNode(OutlineItem Item, IReadOnlyList<OutlineNode> Children);

/// <summary>A document's outline, words and lines, as the core's analyze reads them.</summary>
public sealed record DocumentStats(IReadOnlyList<OutlineItem> Outline, int Words, int Lines);

public static class Outline
{
    private static readonly string[] Levels = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph"];

    // analyze's own shape: the web's names, depth for Level.
    private sealed record Heading(int Depth, string Title, int Line);

    private sealed record Analysis(IReadOnlyList<Heading> Outline, int Words, int Lines);

    /// <summary>
    /// The outline, words and lines, from the core (crates/texlocal-core
    /// analyze.rs, the browser version's reading ported once), so every app
    /// counts the same. Lines break where the editor breaks them.
    /// </summary>
    public static async Task<DocumentStats> AnalyzeAsync(Core core, string text)
    {
        var analysis = await core.CallAsync<Analysis>("analyze", new { text });
        return new DocumentStats(
            analysis.Outline.Select(h => new OutlineItem(h.Depth, h.Title, h.Line)).ToList(),
            analysis.Words,
            analysis.Lines);
    }

    /// <summary>The headings that enclose a line, outermost first: the breadcrumb (web/src/state.js outlineChain).</summary>
    public static IReadOnlyList<OutlineItem> Chain(IReadOnlyList<OutlineItem> outline, int line) =>
        outline.TakeWhile(item => item.Line <= line).Aggregate(new List<OutlineItem>(), Enclose);

    /// <summary>
    /// How many headings enclose each heading. A subsection before any section
    /// sits flush, not under a parent that isn't there (apps/macos Outline.swift).
    /// </summary>
    public static IReadOnlyList<int> Depths(IReadOnlyList<OutlineItem> outline)
    {
        var stack = new List<OutlineItem>();
        return outline.Select(item => Enclose(stack, item).Count - 1).ToList();
    }

    /// <summary>Pushes a heading onto the stack of those enclosing it, after popping its peers and juniors.</summary>
    private static List<OutlineItem> Enclose(List<OutlineItem> stack, OutlineItem item)
    {
        while (stack.Count > 0 && stack[^1].Level >= item.Level)
        {
            stack.RemoveAt(stack.Count - 1);
        }
        stack.Add(item);
        return stack;
    }

    /// <summary>The outline as a tree by how the headings nest, for a sidebar with expanders.</summary>
    public static IReadOnlyList<OutlineNode> Tree(IReadOnlyList<OutlineItem> outline)
    {
        var depths = Depths(outline);
        var index = 0;
        List<OutlineNode> Children(int depth)
        {
            var nodes = new List<OutlineNode>();
            while (index < outline.Count && depths[index] == depth)
            {
                var item = outline[index++];
                nodes.Add(new OutlineNode(item, Children(depth + 1)));
            }
            return nodes;
        }
        return Children(0);
    }

    /// <summary>
    /// A fold's key per heading, surviving renumbered lines: level, title and
    /// which of the headings so named it is (apps/macos Outline.swift foldKeys).
    /// </summary>
    public static IReadOnlyList<string> FoldKeys(IReadOnlyList<OutlineItem> outline)
    {
        var seen = new Dictionary<string, int>();
        return outline.Select(item =>
        {
            var key = $"{item.Level}:{item.Title}";
            seen[key] = seen.GetValueOrDefault(key) + 1;
            return $"{key}#{seen[key]}";
        }).ToList();
    }

    /// <summary>An empty heading by its kind — "Untitled subsection" — where the web writes "(untitled)".</summary>
    public static string DisplayTitle(OutlineItem item) =>
        item.Title != "(untitled)" ? item.Title : "Untitled " + (Levels.ElementAtOrDefault(item.Level) ?? "section");

}
