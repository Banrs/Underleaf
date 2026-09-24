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

public sealed class WordCountTests
{
    // Each count is what web/src/state.js lineWords gives, run in Node — the
    // cases apps/macos checks its own port against.
    [Theory]
    [InlineData("Hello world", 2)]
    [InlineData("\\section{Introduction} text here", 3)]
    [InlineData("A \\textbf{bold} and \\emph{it} word", 5)]
    [InlineData("Cost is 50\\% of total % a comment here", 4)]
    [InlineData("\\begin{itemize}[leftmargin=*] item", 3)]
    [InlineData("\\cite[p.~4]{knuth} says so", 3)]
    [InlineData("\\foo*[x bar", 2)]
    [InlineData("$x^2 + y_1$ is math", 4)]
    [InlineData("Ünïcödé naïve café", 3)]
    [InlineData("e\u0301t\u00E9", 1)]
    [InlineData("x=1 2 3 ---", 1)]
    [InlineData("tab\tseparated\u00A0words", 3)]
    [InlineData("don't stop", 2)]
    [InlineData("a\\\\%b c", 3)]
    [InlineData("50% off", 0)]
    [InlineData("a % b\u2028c d", 4)]
    [InlineData("a % b\u2028c % d", 3)]
    [InlineData("", 0)]
    public void WordsCountAsTheWebCountsThem(string line, int words)
    {
        Assert.Equal(words, Outline.LineWords(line));
    }

    [Fact]
    public void LinesBreakWhereTheEditorBreaksThemAndCommentsHoldNoWords()
    {
        var doc = Outline.Analyze("\\section{One} two words\r\n  % three four\rfive\n");
        Assert.Equal(4, doc.Lines);
        Assert.Equal(4, doc.Words);
        Assert.Equal("One", Assert.Single(doc.Outline).Title);
        Assert.Equal(1, Outline.Analyze("").Lines);
    }

    [Fact]
    public void TheBreadcrumbIsTheChainOfEnclosingHeadings()
    {
        var outline = Outline.Parse("\\chapter{A}\n\\section{B}\n\\subsection{C}\n\\section{D}\ntext");
        Assert.Equal(new[] { "A", "B", "C" }, Outline.Chain(outline, 3).Select(i => i.Title));
        Assert.Equal(new[] { "A", "D" }, Outline.Chain(outline, 5).Select(i => i.Title));
        Assert.Empty(Outline.Chain(outline, 0));
    }
}
