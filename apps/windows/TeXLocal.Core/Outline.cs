namespace TeXLocal;

/// <summary>A heading: Level runs from 0 for \part to 5 for \paragraph.</summary>
public sealed record OutlineItem(int Level, string Title, int Line);

/// <summary>A document's outline, words and lines, as the core's analyze reads them.</summary>
public sealed record DocumentStats(IReadOnlyList<OutlineItem> Outline, int Words, int Lines);

public static class Outline
{
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

    /// <summary>
    /// The headings that enclose a line, outermost first: the breadcrumb
    /// (web/src/state.js outlineChain).
    /// </summary>
    public static IReadOnlyList<OutlineItem> Chain(IReadOnlyList<OutlineItem> outline, int line)
    {
        var stack = new List<OutlineItem>();
        foreach (var item in outline)
        {
            if (item.Line > line)
            {
                break;
            }
            while (stack.Count > 0 && stack[^1].Level >= item.Level)
            {
                stack.RemoveAt(stack.Count - 1);
            }
            stack.Add(item);
        }
        return stack;
    }
}
