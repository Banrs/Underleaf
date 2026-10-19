using System.Text.Json;
using TeXLocal.Bridge;

namespace TeXLocal.Tests;

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
    public async Task StatusAnswersAvailable()
    {
        var status = await core.CallAsync("status");
        Assert.True(status.GetProperty("available").ValueKind is JsonValueKind.True or JsonValueKind.False);
    }

    [Fact]
    public async Task UnknownCommandIs404()
    {
        var e = await Assert.ThrowsAsync<CoreException>(() => core.CallAsync("no_such_command"));
        Assert.Equal(404, e.Status);
    }

    [Fact]
    public async Task NullArgsListNothing()
    {
        Assert.Empty(await core.CallAsync<ProjectInfo[]>("list_projects"));
    }

    [Fact]
    public async Task NamesRoundTripAsUtf8()
    {
        const string name = "Thèse ✓ 😀";
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name });
        Assert.Equal(name, made.Name);
        Assert.Contains(await core.CallAsync<ProjectInfo[]>("list_projects"), p => p.Id == made.Id && p.Name == name);
        Assert.True(Directory.Exists(Path.Combine(dir, made.Id)));
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
        using (var source = core.SessionSource(session, "main.tex"))
        {
            Assert.NotNull(source);
            source.Edit(0, 0, "% x\n");
        }
        await core.CallAsync("session_save", new { session });
        await saved.Task.WaitAsync(TimeSpan.FromSeconds(10));
        var text = File.ReadAllText(Path.Combine(dir, made.Id, "main.tex"));
        Assert.StartsWith("% x", text);
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
        Assert.Equal("Untitled Section", untitled.Title);
        Assert.Equal("", analysis.HeadingStyles[0].Command);
        Assert.Contains(analysis.HeadingStyles, s => s.Command == "chapter");
        Assert.Equal<int?>(untitled.Index, await core.CallAsync<int?>("session_outline_current", new { session, path = "main.tex", line = 5 }));
        Assert.Null(await core.CallAsync<int?>("session_outline_current", new { session, path = "main.tex", line = 1 }));
        await core.CallAsync("session_close", new { session });
    }

    [Fact]
    public async Task SearchAnswersByFile()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Search" });
        File.WriteAllText(Path.Combine(dir, made.Id, "notes.tex"), "a needle\nNeedle b\n");
        var notes = Assert.Single(await core.CallAsync<SearchFile[]>("search_project", new { id = made.Id, query = "needle" }));
        Assert.Equal("notes.tex", notes.File);
        Assert.Equal(new[] { 1, 2 }, notes.Hits.Select(h => h.Line));
        Assert.Equal(("a ", "needle", 2, 6), (notes.Hits[0].Before, notes.Hits[0].Match, notes.Hits[0].Column, notes.Hits[0].Length));
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
        Assert.Contains(source.Highlights(0, text.Length), run => run.Kind == 0 && run.Start == 3);
    }

    [Fact]
    public void MathsRenderAsSvg()
    {
        var maths = Source.SyntaxCall<MathSvg>("math_svg", new { tex = "x^2", display = false, size = 14.0, color = new[] { 0.0, 0.0, 0.0, 1.0 } });
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
    public void EditMovesLines()
    {
        using var source = Source.New("abc");
        var lines = source.LineCount;
        source.Edit(3, 0, "\ny");
        Assert.Equal(lines + 1, source.LineCount);
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

    [Fact]
    public void SnippetFieldsMirror()
    {
        using var source = Source.New("\\begin{}\n\\end{}");
        source.Call("start_snippet", new { fields = new[] { new SnippetField(7, 0, 0), new SnippetField(14, 0, 0) }, at = 0 });
        Assert.Equal(new[] { new TextEdit(15, 0, "x") }, source.Edit(7, 0, "x"));
        Assert.Null(source.Edit(15, 0, "x", mirroring: true));
        source.Select(new(8, 0), false);
        Assert.Equal("\\begin{x}\n\\end{x}", source.Text);
        source.Select(new(0, 0), false);
        Assert.Null(source.Edit(0, 0, "%"));
    }
}
