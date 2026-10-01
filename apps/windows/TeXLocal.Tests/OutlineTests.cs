using System.Text.RegularExpressions;

namespace TeXLocal.Tests;

// The Rust core opens its library folder from TEXLOCAL_DATA, a process-wide
// setting, so the tests that open one run one at a time.
[CollectionDefinition("Rust core", DisableParallelization = true)]
public sealed class RustCoreCollection;

[Collection("Rust core")]
public sealed class OutlineTests
{
    /// <summary>The core's analysis of a scratch project whose main.tex holds the text, beside the other files.</summary>
    private static async Task<DocumentStats> AnalyzeAsync(string text, params (string Name, string Text)[] others)
    {
        var data = Directory.CreateTempSubdirectory("texlocal-test-").FullName;
        Environment.SetEnvironmentVariable("TEXLOCAL_DATA", data);
        try
        {
            Directory.CreateDirectory(Path.Combine(data, "P"));
            foreach (var (name, body) in others.Prepend(("main.tex", text)))
            {
                File.WriteAllText(Path.Combine(data, "P", name), body);
            }
            return await Outline.AnalyzeAsync(new Core(), "P", "main.tex");
        }
        finally
        {
            Directory.Delete(data, recursive: true);
        }
    }

    // The core's own fixtures (crates/texlocal-core/tests/fixtures/analyze.json)
    // hold the reading's cases; these check what reaches the app.
    [Fact]
    public async Task HeadingsComeWithTheirLevelsTitlesAndLines()
    {
        const string text = """
            \documentclass{article}
            \section{Intro}
            % \section{Commented out}
            \subsection*[short]{Details}
            text \section{}
            """;
        var doc = await AnalyzeAsync(text.ReplaceLineEndings("\r\n"));
        Assert.Equal(new[] { "Intro", "Details", "(untitled)" }, doc.Outline.Select(i => i.Title));
        Assert.Equal(new[] { 2, 3, 2 }, doc.Outline.Select(i => i.Level));
        Assert.Equal(new[] { 2, 4, 5 }, doc.Outline.Select(i => i.Line));
    }

    [Fact]
    public async Task LinesBreakWhereTheEditorBreaksThemAndCommentsHoldNoWords()
    {
        var doc = await AnalyzeAsync("\\section{One} two words\r\n  % three four\rfive\n");
        Assert.Equal(4, doc.Lines);
        Assert.Equal(4, doc.Words);
        Assert.Equal("One", Assert.Single(doc.Outline).Title);
        Assert.Equal(1, (await AnalyzeAsync("")).Lines);
    }

    [Fact]
    public async Task TheDocumentReadsItsInputsInPlace()
    {
        var doc = await AnalyzeAsync("\\section{Intro}\n\\input{a}\n\\section{End}", ("a.tex", "\\section{A} one"));
        Assert.Equal(new[] { "Intro", "A", "End" }, doc.Outline.Select(i => i.Title));
        Assert.Equal(new[] { "main.tex", "a.tex", "main.tex" }, doc.Outline.Select(i => i.File));
        Assert.Equal(3, doc.Lines);
    }

    [Fact]
    public void TheCurrentHeadingFollowsTheFile()
    {
        OutlineItem[] items = [new(1, "A", 1, "main.tex"), new(2, "A1", 3, "a.tex"), new(2, "A2", 5, "a.tex"), new(1, "B", 9, "main.tex")];
        Assert.Equal(2, Outline.Current(items, "a.tex", 6));
        Assert.Equal(-1, Outline.Current(items, "a.tex", 1));
        Assert.Equal(0, Outline.Current(items, "main.tex", 8));
        Assert.Equal(-1, Outline.Current(items, "notes.tex", 1));
        Assert.Equal(new[] { "A", "A2" }, Outline.Enclosing(items, 2).Select(i => i.Title));
        Assert.Empty(Outline.Enclosing(items, -1));
    }

    [Fact]
    public void TheBreadcrumbIsTheChainOfEnclosingHeadings()
    {
        OutlineItem[] outline = [new(1, "A", 1), new(2, "B", 2), new(3, "C", 3), new(2, "D", 4)];
        Assert.Equal(new[] { "A", "B", "C" }, Outline.Chain(outline, 3).Select(i => i.Title));
        Assert.Equal(new[] { "A", "D" }, Outline.Chain(outline, 5).Select(i => i.Title));
        Assert.Empty(Outline.Chain(outline, 0));
    }

    [Fact]
    public void HeadingsNestAsTheDocumentDoes()
    {
        // A subsection before any section sits flush; a chapter's sections sit under it.
        OutlineItem[] items = [new(3, "A", 1), new(1, "B", 2), new(2, "C", 3), new(3, "D", 4), new(2, "E", 5), new(1, "(untitled)", 6)];
        Assert.Equal(new[] { 0, 0, 1, 2, 1, 0 }, Outline.Depths(items));

        var tree = Outline.Tree(items);
        Assert.Equal(new[] { "A", "B", "(untitled)" }, tree.Select(n => n.Item.Title));
        Assert.Equal(new[] { "C", "E" }, tree[1].Children.Select(n => n.Item.Title));
        Assert.Equal("D", Assert.Single(tree[1].Children[0].Children).Item.Title);
        Assert.Empty(tree[0].Children);
        Assert.Equal("Untitled chapter", Outline.DisplayTitle(tree[2].Item));
        Assert.Equal("B", Outline.DisplayTitle(tree[1].Item));
    }

    [Fact]
    public void FoldKeysTellHeadingsOfTheSameNameApart()
    {
        OutlineItem[] items = [new(2, "A", 1), new(3, "B", 2), new(2, "A", 3), new(2, "(untitled)", 4)];
        Assert.Equal(new[] { "\t2:A#1", "\t3:B#1", "\t2:A#2", "\t2:(untitled)#1" }, Outline.FoldKeys(items));
        // A line added above keeps every key.
        Assert.Equal(Outline.FoldKeys(items), Outline.FoldKeys(items.Select(i => i with { Line = i.Line + 1 }).ToList()));
    }

    [Fact]
    public void TheSectionLevelIsTheCaretLinesHeading()
    {
        OutlineItem[] items = [new(2, "A", 2), new(5, "B", 4)];
        Assert.Equal("Normal text", LatexTemplates.LevelAt(items, 1));
        Assert.Equal("Section", LatexTemplates.LevelAt(items, 2));
        Assert.Equal("Normal text", LatexTemplates.LevelAt(items, 3));
        Assert.Equal("Paragraph", LatexTemplates.LevelAt(items, 4));
    }

    [Fact]
    public void TheSymbolsAreTheBrowserVersions()
    {
        var source = WebSource.Read("sourcebar.js");
        var table = source[source.IndexOf("SYMBOL_GROUPS", StringComparison.Ordinal)..];
        table = table[..table.IndexOf("];", StringComparison.Ordinal)];
        var web = Regex.Matches(table, @"\['([^']+)', '((?:[^'\\]|\\.)+)'\]")
            .Select(m => (m.Groups[1].Value, Regex.Unescape(m.Groups[2].Value)))
            .ToList();
        Assert.Equal(web, LatexTemplates.SymbolGroups.SelectMany(g => g.Symbols));
    }

    [Fact]
    public void OnlyTextFilesOpenInTheEditor()
    {
        Assert.True(TextFiles.IsText("chapters/intro.TEX"));
        Assert.True(TextFiles.IsText("refs.bib"));
        Assert.False(TextFiles.IsText("figures/plot.png"));
        Assert.False(TextFiles.IsText("Makefile"));
    }
}
