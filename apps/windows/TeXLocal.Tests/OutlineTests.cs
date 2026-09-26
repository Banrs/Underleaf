using System.Text.RegularExpressions;

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
    public void HeadingsNestAsTheDocumentDoes()
    {
        // A subsection before any section sits flush; a chapter's sections sit under it.
        var items = Outline.Parse("\\subsection{A}\n\\chapter{B}\n\\section{C}\n\\subsection{D}\n\\section{E}\n\\chapter{}");
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
        var items = Outline.Parse("\\section{A}\n\\subsection{B}\n\\section{A}\n\\section{}");
        Assert.Equal(new[] { "2:A#1", "3:B#1", "2:A#2", "2:(untitled)#1" }, Outline.FoldKeys(items));
        // A line added above keeps every key.
        Assert.Equal(Outline.FoldKeys(items), Outline.FoldKeys(Outline.Parse("x\n\\section{A}\n\\subsection{B}\n\\section{A}\n\\section{}")));
    }

    [Fact]
    public void TheSectionLevelIsTheCaretLinesHeading()
    {
        var items = Outline.Parse("intro\n\\section{A}\ntext\n\\paragraph{B} more");
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
