namespace TeXLocal.Tests;

public sealed class OutlineTests
{
    [Fact]
    public void SectionsWithDepthTitlesAndLines()
    {
        const string text = """
            \documentclass{article}
            \section{Intro}
            % \section{Commented out}
            \subsection*[short]{Details}
            text \section{}
            """;
        var items = Outline.Parse(text.ReplaceLineEndings("\r\n"));
        Assert.Equal(new[] { "Intro", "Details", "(untitled)" }, items.Select(i => i.Title));
        Assert.Equal(new[] { 2, 3, 2 }, items.Select(i => i.Level));
        Assert.Equal(new[] { 2, 4, 5 }, items.Select(i => i.Line));
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
