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
        try { Directory.Delete(dir, true); } catch (IOException) { }
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
    public async Task ProjectRoundTrip()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Probe" });
        Assert.Contains(await core.CallAsync<ProjectInfo[]>("list_projects"), p => p.Name == "Probe");
        var renamed = await core.CallAsync<ProjectInfo>("rename_project", new { id = made.Id, name = "Probe 2" });
        Assert.Equal("Probe 2", renamed.Name);
        var tree = await core.CallAsync<TreeNode[]>("file_tree", new { id = renamed.Id });
        Assert.Contains(tree, n => n.Path == "main.tex");
        Assert.True(Directory.Exists((await core.CallAsync("project_root", new { id = renamed.Id })).GetString()));
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
}
