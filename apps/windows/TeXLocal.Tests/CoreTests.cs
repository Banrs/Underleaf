using System.Text.Json;
using TeXLocal.Bridge;

namespace TeXLocal.Tests;

/// The bridge: calls, events and the source's marshalling, and that the core's answers decode into the app's records.
/// What the answers say is the core's to test.
public sealed class CoreTests : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("tl-test-").FullName;
    readonly string outside = Directory.CreateTempSubdirectory("tl-folder-").FullName;
    readonly Core core;

    public CoreTests() => core = Core.Open(dir, a => a());

    public void Dispose()
    {
        core.Dispose();
        foreach (var folder in (string[])[dir, outside])
            try { Directory.Delete(folder, true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
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

    /// open_path's project and file, and session_open's name, which titles an opened folder.
    [Fact]
    public async Task OpenedFoldersDecode()
    {
        var tex = Path.Combine(outside, "main.tex");
        File.WriteAllText(tex, "\\documentclass{article}\n");
        var opened = await core.CallAsync<OpenedPath>("open_path", new { path = tex });
        Assert.Equal(("main.tex", true, false), (opened.File, opened.Project.Opened, opened.Project.Missing));
        Assert.Equal(Path.GetFileName(outside), Path.GetFileName(opened.Project.Path));
        const ulong session = 5;
        Assert.Equal(Path.GetFileName(outside), (await core.CallAsync<SessionOpened>("session_open", new { id = opened.Project.Id, session })).Name);
        await core.CallAsync("session_close", new { session });
    }

    /// Home draws a page for each of these ids (PagePreview); Prefs' engine for new projects is pdflatex until one is chosen.
    [Fact]
    public async Task CatalogueNamesHomesTemplatesAndEngines()
    {
        var (templates, engines) = await core.CallAsync<Catalogue>("catalogue");
        Assert.Equal(new[] { "blank", "article", "report", "beamer" }, templates.Select(t => t.Id));
        Assert.Equal("Presentation", templates[3].Title);
        Assert.Contains(engines, e => e.Id == "pdflatex");
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
        Assert.Equal("main.tex", opened.Settings.GetProperty("mainFile").GetString());
        Assert.Empty(opened.Ui.ExpandedFolders);
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

    /// Search's hits by file, and usages' as theirs under their heading; Replace's edits of the open document at its
    /// version, and the other files counted.
    [Fact]
    public async Task SearchUsagesAndReplaceDecode()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Search" });
        File.WriteAllText(Path.Combine(dir, made.Id, "notes.tex"), "a needle\n");
        const ulong session = 3;
        await core.CallAsync("session_open", new { id = made.Id, session });
        await core.CallAsync("session_open_document", new { session, path = "main.tex" });
        using var source = core.SessionSource(session, "main.tex")!;
        source.Edit(0, 0, "needle \\label{x} ");
        var found = await core.CallAsync<SearchFile[]>("session_search", new { session, query = "needle" });
        var hit = Assert.Single(Assert.Single(found, f => f.File == "notes.tex").Hits);
        Assert.Equal(("a ", "needle", 1, 2, 6), (hit.Before, hit.Match, hit.Line, hit.Column, hit.Length));
        var usages = (await core.CallAsync<Usages?>("session_usages", new { session, path = "main.tex", offset = 14 }))!;
        Assert.Equal("\\label{x}", usages.Name);
        Assert.Equal(("main.tex", 14), (usages.Groups[0].File, Assert.Single(usages.Groups[0].Hits).Column));
        var replaced = await core.CallAsync<Replaced>("session_replace", new { session, query = "needle", replacement = "pin" });
        Assert.Equal("main.tex", replaced.Edits?.Path);
        Assert.Equal(source.Call<ulong?>("version", new { }), replaced.Edits?.Version);
        Assert.Equal(new[] { new TextEdit(0, 6, "pin") }, replaced.Edits?.Edits);
        Assert.Equal(new[] { new FileCount("notes.tex", 1) }, replaced.Written);
        await core.CallAsync("session_close", new { session });
    }

    /// A place sent and Back's answer, as the workspace's jumps and menu read them.
    [Fact]
    public async Task PlacesGoBack()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Places" });
        const ulong session = 11;
        await core.CallAsync("session_open", new { id = made.Id, session });
        await core.CallAsync("session_navigate", new { session, from = new Spot("main.tex", 1) });
        var back = await core.CallAsync<Trail>("session_back", new { session, at = new Spot("main.tex", 3) });
        Assert.Equal(new Trail(false, true, new Spot("main.tex", 1)), back);
        await core.CallAsync("session_close", new { session });
    }

    /// Go to all's results: a heading and a label, each with its place.
    [Fact]
    public async Task GoToAllDecodes()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Quick" });
        File.WriteAllText(Path.Combine(dir, made.Id, "main.tex"), "\\section{Intro}\\label{sec:intro}\n");
        const ulong session = 13;
        await core.CallAsync("session_open", new { id = made.Id, session });
        QuickItem[] found = [new("heading", "Intro", "Section · main.tex", "main.tex", 1), new("label", "sec:intro", "Intro", "main.tex", 1)];
        Assert.Equal(found, await core.CallAsync<QuickItem[]>("session_quick_open", new { session, query = "intro" }));
        await core.CallAsync("session_close", new { session });
    }

    /// session_history_list's entries and session_history_compare's rows, as docs/core-api.md has them.
    [Fact]
    public void HistoryDecodes()
    {
        const string listed = """[{"id":"a1","time":"2026-10-22T09:41:00Z","name":null,"reason":"Before Replace All","changed":[{"path":"main.tex","change":"changed"}]}]""";
        var snapshot = Assert.Single(JsonSerializer.Deserialize<Snapshot[]>(listed, Core.Json)!);
        Assert.Equal(("a1", null, "Before Replace All"), (snapshot.Id, snapshot.Name, snapshot.Reason));
        Assert.Equal(new DateTimeOffset(2026, 10, 22, 9, 41, 0, TimeSpan.Zero), snapshot.Time);
        Assert.Equal(new SnapshotChange("main.tex", "changed"), Assert.Single(snapshot.Changed));
        Assert.Equal([new DiffRow(null, "a", null, null), new DiffRow(null, null, null, 2)], JsonSerializer.Deserialize<DiffRow[]>("""[{"removed":"a"},{"skipped":2}]""", Core.Json)!);
    }

    /// The checks the session sends as it opens, as the issues panel lists them.
    [Fact]
    public async Task ChecksDecode()
    {
        var made = await core.CallAsync<ProjectInfo>("create_project", new { name = "Checks" });
        File.WriteAllText(Path.Combine(dir, made.Id, "main.tex"), "\\documentclass{article}\n\\begin{document}\n\\ref{nowhere}\n\\end{document}\n");
        const ulong session = 9;
        var checks = new TaskCompletionSource<LogItem[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        core.Event += e =>
        {
            if (e.Type == "checks" && e.Session == session) checks.TrySetResult(e.Json.Deserialize<DocEvent>(Core.Json)!.Items!);
        };
        await core.CallAsync("session_open", new { id = made.Id, session });
        var check = Assert.Single(await checks.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(("warning", "main.tex", 3), (check.Type, check.File, check.Line));
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
