namespace TeXLocal.Tests;

// The Rust core opens its library folder from TEXLOCAL_DATA, a process-wide
// setting, so the tests that open one run one at a time.
[CollectionDefinition("Rust core", DisableParallelization = true)]
public sealed class RustCoreCollection;

[Collection("Rust core")]
public sealed class OutlineTests
{
    /// <summary>The core's analyze, on a scratch library folder.</summary>
    private static async Task<DocumentStats> AnalyzeAsync(string text)
    {
        var data = Directory.CreateTempSubdirectory("texlocal-test-").FullName;
        Environment.SetEnvironmentVariable("TEXLOCAL_DATA", data);
        try
        {
            return await Outline.AnalyzeAsync(new Core(), text);
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
    public void TheBreadcrumbIsTheChainOfEnclosingHeadings()
    {
        OutlineItem[] outline = [new(1, "A", 1), new(2, "B", 2), new(3, "C", 3), new(2, "D", 4)];
        Assert.Equal(new[] { "A", "B", "C" }, Outline.Chain(outline, 3).Select(i => i.Title));
        Assert.Equal(new[] { "A", "D" }, Outline.Chain(outline, 5).Select(i => i.Title));
        Assert.Empty(Outline.Chain(outline, 0));
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
