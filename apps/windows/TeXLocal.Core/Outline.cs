using System.Text.RegularExpressions;

namespace TeXLocal;

public sealed record OutlineItem(int Level, string Title, int Line);

/// <summary>
/// Sectioning commands in a document, as the browser version's outline reads
/// them (web/src/state.js SECTION_RE).
/// </summary>
public static partial class Outline
{
    private static readonly string[] Levels = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph"];

    [GeneratedRegex(@"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}")]
    private static partial Regex Section();

    public static IReadOnlyList<OutlineItem> Parse(string text)
    {
        var items = new List<OutlineItem>();
        var lines = text.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (line.TrimStart().StartsWith('%'))
            {
                continue;
            }
            var match = Section().Match(line);
            if (!match.Success)
            {
                continue;
            }
            var title = match.Groups[2].Value;
            items.Add(new OutlineItem(
                Array.IndexOf(Levels, match.Groups[1].Value),
                title.Length == 0 ? "(untitled)" : title,
                i + 1));
        }
        return items;
    }
}
