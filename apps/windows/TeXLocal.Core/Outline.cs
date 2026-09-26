using System.Text.RegularExpressions;

namespace TeXLocal;

public sealed record OutlineItem(int Level, string Title, int Line);

/// <summary>A heading and the headings it encloses.</summary>
public sealed record OutlineNode(OutlineItem Item, IReadOnlyList<OutlineNode> Children);

/// <summary>A document's outline, words and lines, read in one pass.</summary>
public sealed record DocumentStats(IReadOnlyList<OutlineItem> Outline, int Words, int Lines);

/// <summary>
/// Sectioning commands in a document, as the browser version's outline reads
/// them (web/src/state.js SECTION_RE), and the word count read alongside.
/// </summary>
public static partial class Outline
{
    private static readonly string[] Levels = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph"];

    [GeneratedRegex(@"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}")]
    private static partial Regex Section();

    public static IReadOnlyList<OutlineItem> Parse(string text) => Analyze(text).Outline;

    /// <summary>
    /// The outline, words and lines (web/src/state.js analyzeDoc). Lines break
    /// at CR LF, CR or LF, as CodeMirror breaks them.
    /// </summary>
    public static DocumentStats Analyze(string text)
    {
        var items = new List<OutlineItem>();
        var words = 0;
        var lines = text.Split(["\r\n", "\r", "\n"], StringSplitOptions.None);
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (IsComment(line))
            {
                continue;
            }
            if (Section().Match(line) is { Success: true } match)
            {
                var title = match.Groups[2].Value;
                items.Add(new OutlineItem(Array.IndexOf(Levels, match.Groups[1].Value), title is "" ? "(untitled)" : title, i + 1));
            }
            words += LineWords(line);
        }
        return new DocumentStats(items, words, lines.Length);
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

    // ---------- word count ----------

    // web/src/state.js lineWords's regular expressions, spelled out on
    // JavaScript's terms so every line counts the same (as apps/macos does).
    // Every character involved is in the BMP, so UTF-16 units serve.

    /// <summary>JavaScript's \s.</summary>
    private static bool IsSpace(char c) =>
        c is '\t' or '\n' or '\u000B' or '\u000C' or '\r' or ' ' or '\u00A0' or '\u1680'
            or (>= '\u2000' and <= '\u200A') or '\u2028' or '\u2029' or '\u202F' or '\u205F' or '\u3000' or '\uFEFF';

    /// <summary>TeX's special characters, which separate words like spaces do.</summary>
    private static bool IsSpecial(char c) => c is '{' or '}' or '$' or '&' or '_' or '^' or '~' or '\\' or '%';

    private static bool IsComment(string line) => line.FirstOrDefault(c => !IsSpace(c)) == '%';

    /// <summary>
    /// Rough word count of a prose line: drop the comment, then commands with
    /// a star and one [argument], then TeX's special characters, and count
    /// the runs left that contain a letter.
    /// </summary>
    public static int LineWords(string line)
    {
        var text = CommentStart(line) is { } comment ? line[..comment] : line;
        var words = 0;
        var letter = false;
        var i = 0;
        // One step past the end, as a space, closes the last run.
        while (i <= text.Length)
        {
            var c = i < text.Length ? text[i] : ' ';
            // A backslash is special, so a command ends the run before it too.
            var separator = IsSpace(c) || IsSpecial(c);
            if (separator && letter)
            {
                words++;
            }
            letter = !separator && (letter || char.IsAsciiLetter(c) || c is >= '\u00C0' and <= '\u017E');
            if (c == '\\' && i + 1 < text.Length && char.IsAsciiLetter(text[i + 1]))
            {
                i++;
                while (i < text.Length && char.IsAsciiLetter(text[i]))
                {
                    i++;
                }
                if (i < text.Length && text[i] == '*')
                {
                    i++;
                }
                if (i < text.Length && text[i] == '[' && text.IndexOf(']', i + 1) is var close and >= 0)
                {
                    i = close + 1;
                }
                continue;
            }
            i++;
        }
        return words;
    }

    /// <summary>
    /// The first % no backslash escapes. JavaScript's . stops at U+2028 and
    /// U+2029, so a % with either after it starts no comment there.
    /// </summary>
    private static int? CommentStart(string text)
    {
        var from = text.LastIndexOfAny(['\u2028', '\u2029']) + 1;
        for (var i = from; i < text.Length; i++)
        {
            if (text[i] == '%' && (i == 0 || text[i - 1] != '\\'))
            {
                return i;
            }
        }
        return null;
    }
}
