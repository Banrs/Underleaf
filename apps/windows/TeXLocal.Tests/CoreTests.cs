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
        var opened = await core.CallAsync<SessionOpened>("session_open", new { id = made.Id });
        await core.CallAsync("session_open_document", new { session = opened.Session, path = "main.tex" });
        using (var source = core.SessionSource(opened.Session, "main.tex"))
        {
            Assert.NotNull(source);
            source.Edit(0, 0, "% x\n");
        }
        await core.CallAsync("session_save", new { session = opened.Session });
        await saved.Task.WaitAsync(TimeSpan.FromSeconds(10));
        var text = (await core.CallAsync("read_file", new { id = made.Id, path = "main.tex" })).GetProperty("text").GetString();
        Assert.StartsWith("% x", text);
        await core.CallAsync("session_close", new { session = opened.Session });
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
        Assert.Equal("a\0é\0\U0001F600", source.Call<string>("text", new { }));
        source.Reload("");
        Assert.Equal("", source.Call<string>("text", new { }));
    }
}
