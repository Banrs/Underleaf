using System.Text.Json;
using TeXLocal.Bridge;

namespace TeXLocal.Tests;

/// The bridge: calls, events and the source's marshalling, and that the core's answers decode into the app's records.
/// What the answers say is the core's to test.
public sealed class CoreTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("tl-test-").FullName;
    readonly Core core;

    public CoreTests() => core = Core.Open(dir, a => a());

    public void Dispose()
    {
        core.Dispose();
        try { Directory.Delete(dir, true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    [Fact]
    public async Task UnknownCommandIs404()
    {
        var e = await Assert.ThrowsAsync<CoreException>(() => core.CallAsync("no_such_command"));
        Assert.Equal(404, e.Status);
    }

    /// Null args, then a name through UTF-8 both ways.
    [Fact]
    public async Task ProjectsListAndNamesRoundTripAsUtf8()
    {
        Assert.Empty(await core.CallAsync<ProjectInfo[]>("list_projects"));
        const string name = "Thèse ✓ 😀";
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name });
        Assert.Equal(name, made.Name);
        Assert.Contains(await core.CallAsync<ProjectInfo[]>("list_projects"), p => p.Id == made.Id && p.Name == name);
    }

    /// Home draws a page for each of these ids (PagePreview).
    [Fact]
    public async Task CatalogueNamesHomesTemplates()
    {
        var templates = (await core.CallAsync<Catalogue>("catalogue")).Templates;
        Assert.Equal(new[] { "blank", "article", "report", "beamer" }, templates.Select(t => t.Id));
        Assert.Equal("Presentation", templates[3].Title);
    }

    [Fact]
    public async Task SessionEditSavesAndReports()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Session" });
        var saved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        core.Event += e => { if (e.Type == "saved") saved.TrySetResult(); };
        const ulong session = 1;
        await core.CallAsync("session_open", new { id = made.Id, session });
        await core.CallAsync("session_open_document", new { session, path = "main.tex" });
        using (var source = core.SessionSource(session, "main.tex")!) source.Edit(0, 0, "% x\n");
        await core.CallAsync("session_save", new { session });
        await saved.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.StartsWith("% x", File.ReadAllText(Path.Combine(dir, made.Id, "main.tex")));
        await core.CallAsync("session_close", new { session });
    }

    [Fact]
    public async Task SessionAnalysesTheShownFile()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Outline" });
        const string text = "\\documentclass{book}\n\\begin{document}\n\\chapter{One}\n\\section{}\nx\n\\end{document}\n";
        File.WriteAllText(Path.Combine(dir, made.Id, "main.tex"), text);
        const ulong session = 7;
        var opened = await core.CallAsync<SessionOpened>("session_open", new { id = made.Id, session });
        Assert.Equal(session, opened.Session);
        Assert.Equal("main.tex", opened.Settings.GetProperty("mainFile").GetString());
        Assert.Equal(JsonValueKind.Array, opened.Ui.GetProperty("expandedFolders").ValueKind);
        await core.CallAsync("session_open_document", new { session, path = "main.tex" });
        using (var source = core.SessionSource(session, "main.tex")) Assert.Equal(text, source?.Text);
        var analysis = await core.CallAsync<Analysis>("session_analyze", new { session, path = "main.tex" });
        Assert.Equal(new[] { "chapter", "section" }, analysis.Outline.Select(h => h.Command));
        var untitled = analysis.Outline.Last();
        Assert.True(untitled.Untitled);
        Assert.Contains(analysis.HeadingStyles, s => s.Command == "chapter");
        var at = new { session, path = "main.tex", line = 5 };
        Assert.Equal<int?>(untitled.Index, await core.CallAsync<int?>("session_outline_current", at));
        await core.CallAsync("session_close", new { session });
    }

    /// Search's hits by file; Replace's edits of the open document at its version, and the other files counted.
    [Fact]
    public async Task SearchAndReplaceDecode()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Search" });
        File.WriteAllText(Path.Combine(dir, made.Id, "notes.tex"), "a needle\n");
        const ulong session = 3;
        await core.CallAsync("session_open", new { id = made.Id, session });
        await core.CallAsync("session_open_document", new { session, path = "main.tex" });
        using var source = core.SessionSource(session, "main.tex")!;
        source.Edit(0, 0, "needle ");
        var found = await core.CallAsync<SearchFile[]>("session_search", new { session, query = "needle" });
        var hit = Assert.Single(Assert.Single(found, f => f.File == "notes.tex").Hits);
        Assert.Equal(("a ", "needle", 1, 2, 6), (hit.Before, hit.Match, hit.Line, hit.Column, hit.Length));
        var replaced = await core.CallAsync<Replaced>("session_replace", new { session, query = "needle", replacement = "pin" });
        Assert.Equal("main.tex", replaced.Edits?.Path);
        Assert.Equal(source.Call<ulong?>("version", new { }), replaced.Edits?.Version);
        Assert.Equal(new[] { new TextEdit(0, 6, "pin") }, replaced.Edits?.Edits);
        Assert.Equal(new[] { new FileCount("notes.tex", 1) }, replaced.Written);
        await core.CallAsync("session_close", new { session });
    }

    [Fact]
    public async Task ConcurrentCallsComplete()
    {
        var calls = Enumerable.Range(0, 20).Select(_ => core.CallAsync("list_projects"));
        Assert.Equal(20, (await Task.WhenAll(calls)).Length);
    }

    [Fact]
    public void SourceOffsetsAreUtf16()
    {
        const string text = "a\U0001F600\\b\nx";
        using var source = Source.New(text);
        var x = text.IndexOf('x');
        Assert.Equal(2, source.LineAt(x));
        Assert.Equal(x, source.LineStart(2));
        Assert.Equal(2, source.LineCount);
        Assert.Contains(source.Highlights(0, text.Length), run => run.Kind == 0 && run.Start == 3);
    }

    [Fact]
    public void MathsRenderAsSvg()
    {
        var args = new { tex = "x^2", display = false, size = 14.0, color = new[] { 0.0, 0.0, 0.0, 1.0 } };
        var maths = Source.SyntaxCall<MathSvg>("math_svg", args);
        Assert.StartsWith("<svg", maths?.Svg);
        Assert.True(maths!.Width > 0);
    }

    [Fact]
    public void MenusAndLevelsDecode()
    {
        var menus = Source.SyntaxCall<Menus>("menus", new { });
        Assert.NotEmpty(menus!.Templates.Insert);
        Assert.NotEmpty(menus.SymbolGroups);
        Assert.Equal("", Source.SyntaxCall<HeadingStyle[]>("heading_styles", new { })?[0].Command);
    }

    [Fact]
    public void NullAnswersAreDefault()
    {
        using var source = Source.New("x");
        Assert.Null(source.Call<MathPreview>("math_at", new { caret = 0 }));
        Assert.Null(source.Call<TextStyles>("no_such_command", new { }));
    }

    [Fact]
    public void DefinitionsDecode()
    {
        const string text = "\\label{a}\n\\ref{a}";
        using var source = Source.New(text);
        var defined = source.Call<Definition>("definition", new { at = text.LastIndexOf('a') })!;
        Assert.Equal(("label", "a"), (defined.Kind, defined.Name));
        Assert.Equal(new Place("", 1, 7, 1), Assert.Single(defined.Places));
    }

    [Fact]
    public void TextsPassWhole()
    {
        using var source = Source.New("a\0é");
        source.Edit(3, 0, "\0\U0001F600");
        Assert.Equal("a\0é\0\U0001F600", source.Text);
        source.Reload("");
        Assert.Equal("", source.Text);
    }

    /// Edit's answer and its mirroring flag, and Select's, across the C ABI.
    [Fact]
    public void SnippetFieldsMirror()
    {
        using var source = Source.New("\\begin{}\n\\end{}");
        source.Call<SourceRange>("start_snippet", new { fields = new[] { new SnippetField(7, 0, 0), new SnippetField(14, 0, 0) }, at = 0 });
        Assert.Equal(new[] { new TextEdit(15, 0, "x") }, source.Edit(7, 0, "x"));
        Assert.Null(source.Edit(15, 0, "x", mirroring: true));
        source.Select(new(0, 0), false);
        Assert.Null(source.Edit(0, 0, "%"));
    }
}
