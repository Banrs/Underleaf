using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace TeXLocal;

/// <summary>
/// One open project: its files, the document in the editor, and its builds.
/// Every command the menus, toolbar and editor shortcuts can run lands here.
/// Behaviour follows the browser version (web/src/workspace.js, sidebar.js).
/// </summary>
internal sealed class ProjectModel : INotifyPropertyChanged
{
    public string Id { get; }

    private readonly Core core;
    private readonly EditorBridge editor;
    private readonly MainWindow app;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ProjectModel(string id, Core core, EditorBridge editor, MainWindow app)
    {
        Id = id;
        this.core = core;
        this.editor = editor;
        this.app = app;
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string name = "")
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return;
        }
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private void Raise([CallerMemberName] string name = "") =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public ProjectSettings? Settings { get => settings; private set => Set(ref settings, value); }
    private ProjectSettings? settings;

    public IReadOnlyList<TreeNode> Tree { get => tree; private set => Set(ref tree, value); }
    private IReadOnlyList<TreeNode> tree = [];

    public string? OpenPath { get => openPath; private set => Set(ref openPath, value); }
    private string? openPath;

    /// <summary>
    /// The open document's outline, words and lines, read when it opens and
    /// whenever it is saved; null unless it is a .tex file, as in the web.
    /// </summary>
    public DocumentStats? Stats { get => stats; private set => Set(ref stats, value); }
    private DocumentStats? stats;

    public IReadOnlyList<OutlineItem> Sections => Stats?.Outline ?? [];

    public int CursorLine { get => cursorLine; private set => Set(ref cursorLine, value); }
    private int cursorLine = 1;

    /// <summary>File › section › subsection at the cursor (web/src/workspace.js renderCrumbs).</summary>
    public IReadOnlyList<string> Breadcrumb
    {
        get
        {
            if (OpenPath is not { } path)
            {
                return [];
            }
            return [path[(path.LastIndexOf('/') + 1)..], .. Outline.Chain(Sections, CursorLine).Select(s => s.Title)];
        }
    }

    public bool Dirty { get => dirty; private set => Set(ref dirty, value); }
    private bool dirty;

    public bool Saving { get => saving; private set => Set(ref saving, value); }
    private bool saving;

    public bool Compiling { get => compiling; private set => Set(ref compiling, value); }
    private bool compiling;

    public CompileResult? Result { get => result; private set => Set(ref result, value); }
    private CompileResult? result;

    /// <summary>
    /// The PDF on screen, and a counter bumped whenever a new one is on disk.
    /// Only a successful build moves it, so a new main file keeps showing the
    /// last PDF until its own exists.
    /// </summary>
    public string? PdfPath { get; private set; }
    public int PdfVersion { get => pdfVersion; private set => Set(ref pdfVersion, value); }
    private int pdfVersion;

    /// <summary>The latest forward-search target; raised even when it repeats, so a spot can flash twice.</summary>
    public ForwardLoc? Highlight { get => highlight; private set { highlight = value; Raise(); } }
    private ForwardLoc? highlight;

    public bool ShowLogs { get => showLogs; set => Set(ref showLogs, value); }
    private bool showLogs;

    public string SearchQuery
    {
        get => searchQuery;
        set
        {
            Set(ref searchQuery, value);
            ScheduleSearch();
        }
    }
    private string searchQuery = "";

    public IReadOnlyList<SearchHit> SearchHits { get => searchHits; private set => Set(ref searchHits, value); }
    private IReadOnlyList<SearchHit> searchHits = [];

    public int ErrorCount => Result?.Errors.Count ?? 0;
    public int WarningCount => Result?.Warnings.Count ?? 0;
    public bool TexAvailable => app.Tex?.Available ?? false;
    private bool AutoCompile => app.Preferences.AutoCompile;

    public string Status =>
        Compiling ? "Compiling…" : Saving ? "Saving…" : Dirty ? "Unsaved changes" : "Saved";

    private void Report(CoreException error) => app.Report(error.Message);

    // Set once the project is closed: its late results and queued follow-ups
    // must not act on the next project.
    private bool closed;

    // ---------- loading ----------

    public async Task LoadAsync()
    {
        editor.Changed = Edited;
        editor.CursorMoved = line => CursorLine = line;
        editor.Command = id =>
        {
            if (MenuCommands.FromId(id) is { } command)
            {
                app.Perform(command);
            }
        };
        editor.Crashed += OnEditorCrashed;
        editor.Reloaded += OnEditorReloaded;
        try
        {
            var loaded = await core.CallAsync<ProjectSettings>("get_settings", new { id = Id });
            Settings = loaded;
            await ReloadTreeAsync();
            await RefreshSymbolsAsync();
            await OpenAsync(loaded.MainFile);
        }
        catch (CoreException e)
        {
            Report(e);
        }
        var pdf = await CompiledPdfAsync();
        if (pdf is not null && File.Exists(pdf))
        {
            PdfPath = pdf;
            PdfVersion++;
        }
        else if (AutoCompile)
        {
            await CompileAsync(auto: true);
        }
    }

    /// <summary>Stop listening to the shared editor; the next project takes it over.</summary>
    public void Detach()
    {
        closed = true;
        autosave?.Cancel();
        searchCancel?.Cancel();
        editor.Changed = null;
        editor.CursorMoved = null;
        editor.Command = null;
        editor.Crashed -= OnEditorCrashed;
        editor.Reloaded -= OnEditorReloaded;
    }

    public async Task ReloadTreeAsync()
    {
        try
        {
            Tree = await core.CallAsync<List<TreeNode>>("file_tree", new { id = Id });
        }
        catch (CoreException e)
        {
            app.Report($"Couldn’t refresh the file list: {e.Message}");
        }
    }

    private async Task RefreshSymbolsAsync()
    {
        try
        {
            await editor.SetSymbolsAsync(await core.CallAsync<Symbols>("scan_symbols", new { id = Id }));
        }
        catch (CoreException)
        {
            // Completions only; the next save tries again.
        }
    }

    /// <summary>Where the main file's PDF is built, whether or not it exists yet.</summary>
    private async Task<string?> CompiledPdfAsync()
    {
        try
        {
            return await core.CallAsync<string>("pdf_path", new { id = Id });
        }
        catch (CoreException)
        {
            return null;
        }
    }

    // ---------- editing ----------

    private int openRequest;

    /// <summary>Open a file: text in the editor, anything else in its own app.</summary>
    public async Task OpenAsync(string path, int? line = null)
    {
        if (!TextFiles.IsText(path))
        {
            try
            {
                Shell.Open(await core.CallAsync<string>("raw_path", new { id = Id, path }));
            }
            catch (CoreException e)
            {
                Report(e);
            }
            return;
        }
        if (path != OpenPath && !await SwitchToAsync(path))
        {
            return;
        }
        if (line is { } l)
        {
            await editor.RevealAsync(l);
        }
    }

    private async Task<bool> SwitchToAsync(string path)
    {
        var request = ++openRequest;
        if (!await SaveNowAsync())
        {
            return false;
        }
        FileText file;
        try
        {
            file = await core.CallAsync<FileText>("read_file", new { id = Id, path });
        }
        catch (CoreException e)
        {
            if (request == openRequest)
            {
                Report(e);
            }
            return false;
        }
        // A newer open won, or an edit arrived during the read: that edit
        // belongs to the old file, so it is saved before the switch.
        if (request != openRequest || !await SaveNowAsync() || request != openRequest)
        {
            return false;
        }
        OpenPath = path;
        CursorLine = 1;
        Analyze(path, file.Text);
        await editor.OpenAsync($"{Id}/{path}", file.Text);
        return true;
    }

    /// <summary>The outline, breadcrumb and word count; as in the web, only a .tex file has them.</summary>
    private void Analyze(string path, string text) =>
        Stats = path.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) ? Outline.Analyze(text) : null;

    // Whether unsaved edits were in the editor page when its renderer died.
    private bool lostInCrash;
    private bool readingText;

    private void OnEditorCrashed()
    {
        lostInCrash = Dirty || readingText;
        autosave?.Cancel();
        Dirty = false;
    }

    /// <summary>The page lost its document in a crash: show the file again from disk.</summary>
    private async void OnEditorReloaded()
    {
        if (OpenPath is not { } path)
        {
            return;
        }
        OpenPath = null;
        await OpenAsync(path);
        if (lostInCrash)
        {
            lostInCrash = false;
            app.Report($"The editor stopped unexpectedly. Changes to {path} since it was last saved were lost.");
        }
    }

    private CancellationTokenSource? autosave;

    private async void Edited()
    {
        if (OpenPath is null)
        {
            return;
        }
        Dirty = true;
        autosave?.Cancel();
        var pending = autosave = new CancellationTokenSource();
        try
        {
            await Task.Delay(1200, pending.Token);
        }
        catch (TaskCanceledException)
        {
            return;
        }
        // An edit during the save starts its own countdown, and its compile.
        if (await SaveAsync() && !Dirty)
        {
            await CompileIfAutoAsync();
        }
    }

    // Saves run one after another, so a save never overtakes one in flight
    // and a flush that returns true means the latest text is on disk.
    private Task<bool> saves = Task.FromResult(true);

    private Task<bool> SaveAsync()
    {
        var previous = saves;
        return saves = SaveAfterAsync(previous);
    }

    private async Task<bool> SaveAfterAsync(Task<bool> previous)
    {
        await previous;
        if (!Dirty)
        {
            return true;
        }
        if (OpenPath is not { } path)
        {
            return false;
        }
        // Clean before the text is read, not after: an edit that arrives
        // while the page answers marks it dirty again and is saved next,
        // rather than being overwritten here.
        Dirty = false;
        Saving = true;
        try
        {
            var crashes = editor.Crashes;
            readingText = true;
            var text = await editor.GetTextAsync();
            readingText = false;
            if (text is null)
            {
                if (editor.Crashes != crashes)
                {
                    // The edits went with the page's renderer; OnEditorReloaded
                    // says so. There is nothing left to save.
                    return true;
                }
                Dirty = true;
                app.Report("TeXLocal couldn’t read the document from the editor, so it was not saved.");
                return false;
            }
            await core.PerformAsync("write_file", new { id = Id, path, text });
            if (path == OpenPath)
            {
                Analyze(path, text);
            }
            await RefreshSymbolsAsync();
            return true;
        }
        catch (CoreException e)
        {
            Dirty = true;
            app.Report($"Save failed: {e.Message}");
            return false;
        }
        finally
        {
            readingText = false;
            Saving = false;
        }
    }

    /// <summary>
    /// Save until no edit arrived during the last write, cancelling the
    /// pending autosave — before a compile, a project close or quit. False,
    /// and the edits stay in the editor, when a save failed.
    /// </summary>
    public async Task<bool> FlushAsync()
    {
        autosave?.Cancel();
        if (!await SaveAsync())
        {
            return false;
        }
        while (Dirty)
        {
            if (!await SaveAsync())
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// A save the user asked for, or one before a file switch, rename or
    /// delete: like a flush, but the compile the cancelled autosave would
    /// have started still happens.
    /// </summary>
    public async Task<bool> SaveNowAsync()
    {
        var edited = Dirty;
        var saved = await FlushAsync();
        if (saved && edited)
        {
            _ = CompileIfAutoAsync();
        }
        return saved;
    }

    // ---------- compile ----------

    private bool compileQueued;

    private Task CompileIfAutoAsync() => AutoCompile ? CompileAsync(auto: true) : Task.CompletedTask;

    /// <summary>
    /// Compile the project. A request during a compile runs once it ends.
    /// Automatic compiles report failures in the log only, never in a
    /// message, so a typing pause cannot interrupt the writer.
    /// </summary>
    public async Task CompileAsync(bool auto = false)
    {
        if (closed || !TexAvailable)
        {
            return;
        }
        if (Compiling)
        {
            compileQueued = true;
            return;
        }
        // Busy from the first moment, so a second request queues rather than
        // starting a parallel compile while this one saves.
        Compiling = true;
        var saved = false;
        try
        {
            saved = await FlushAsync();
            if (!saved)
            {
                return;
            }
            var result = await core.CallAsync<CompileResult>("compile", new { id = Id });
            if (closed)
            {
                return;
            }
            Result = result;
            if (result.Ok && await CompiledPdfAsync() is { } pdf)
            {
                PdfPath = pdf;
                PdfVersion++;
            }
            ShowLogs = !result.Ok;
            app.NotifyCompiled(result);
        }
        catch (CoreException e)
        {
            if (auto || closed)
            {
                Debug.WriteLine($"Auto-compile failed: {e.Message}");
            }
            else
            {
                Report(e);
            }
        }
        finally
        {
            Compiling = false;
            if (compileQueued)
            {
                compileQueued = false;
                if (saved && !closed)
                {
                    _ = CompileAsync(auto: true);
                }
            }
        }
    }

    public async Task SetEngineAsync(string engine)
    {
        if (engine == Settings?.Engine)
        {
            return;
        }
        try
        {
            Settings = await core.CallAsync<ProjectSettings>("set_settings", new { id = Id, patch = new { engine } });
            // A new engine only means something once a build uses it.
            await CompileAsync(auto: true);
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    // ---------- SyncTeX ----------

    public async Task ForwardSyncAsync()
    {
        if (OpenPath is not { } path)
        {
            return;
        }
        var line = await editor.CurrentLineAsync();
        try
        {
            var loc = await core.CallAsync<ForwardLoc>("synctex_forward", new { id = Id, file = path, line });
            ShowLogs = false;
            app.ShowPdf();
            Highlight = loc;
        }
        catch (CoreException)
        {
            app.Report("No PDF location found. Compile first, then try again.", Microsoft.UI.Xaml.Controls.InfoBarSeverity.Informational);
        }
    }

    public async Task InverseSyncAsync(int page, double x, double y)
    {
        InverseLoc loc;
        try
        {
            loc = await core.CallAsync<InverseLoc>("synctex_inverse", new { id = Id, page, x, y });
        }
        catch (CoreException)
        {
            app.Report("No source location found for this part of the PDF.", Microsoft.UI.Xaml.Controls.InfoBarSeverity.Informational);
            return;
        }
        await OpenAsync(loc.File);
        // The open can lose to a newer one or fail; the line belongs to this file only.
        if (OpenPath == loc.File)
        {
            await editor.RevealAsync(loc.Line);
            editor.Focus();
        }
    }

    // ---------- files ----------

    public async Task CreateEntryAsync(string path, bool directory)
    {
        try
        {
            await core.PerformAsync("create_entry", new { id = Id, path, dir = directory });
            await ReloadTreeAsync();
            if (!directory)
            {
                await OpenAsync(path);
            }
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    public async Task RenameEntryAsync(string from, string to)
    {
        if (to == from || !await SaveNowAsync())
        {
            return;
        }
        try
        {
            var renamed = await core.CallAsync<RenameResult>("rename_entry", new { id = Id, from, to });
            // A renamed folder carries the open file along; the next save
            // must write to the new path, not recreate the old one.
            if (ProjectPaths.Contains(renamed.From, OpenPath))
            {
                var moved = ProjectPaths.Remap(OpenPath, renamed.From, renamed.To)!;
                await editor.RenameAsync($"{Id}/{OpenPath}", $"{Id}/{moved}");
                OpenPath = moved;
            }
            else
            {
                await editor.ForgetAsync($"{Id}/{renamed.From}");
            }
            var mainChanged = renamed.MainFile != Settings?.MainFile;
            if (Settings is { } current)
            {
                Settings = current with { MainFile = renamed.MainFile };
            }
            await ReloadTreeAsync();
            if (mainChanged)
            {
                await CompileAsync(auto: true);
            }
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    public async Task DeleteEntryAsync(string path)
    {
        if (!await SaveNowAsync())
        {
            return;
        }
        try
        {
            await core.PerformAsync("delete_entry", new { id = Id, path });
            await editor.ForgetAsync($"{Id}/{path}");
            // The buffer stays until the delete succeeded, so a failed one
            // leaves the text to save or copy.
            if (ProjectPaths.Contains(path, OpenPath))
            {
                Dirty = false;
                OpenPath = null;
                Stats = null;
            }
            await ReloadTreeAsync();
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    /// <summary>The PDF is named after the main file, so a new main file means a new build.</summary>
    public async Task SetMainFileAsync(string path)
    {
        try
        {
            Settings = await core.CallAsync<ProjectSettings>("set_settings", new { id = Id, patch = new { mainFile = path } });
            await CompileAsync(auto: true);
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    /// <summary>Copy files and folders from elsewhere into the project, at the root or into a folder.</summary>
    public async Task ImportFilesAsync(IReadOnlyList<string> paths, string dir = "")
    {
        try
        {
            await core.CallAsync<ImportResult>("import_files", new { id = Id, dir, paths });
            await ReloadTreeAsync();
            await RefreshSymbolsAsync();
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    public async Task RevealAsync(string path)
    {
        try
        {
            Shell.Reveal(await core.CallAsync<string>("raw_path", new { id = Id, path }));
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    // ---------- export ----------

    public async Task ExportZipAsync(string destination)
    {
        try
        {
            await core.PerformAsync("export_zip", new { id = Id, dest = destination });
            Shell.Reveal(destination);
        }
        catch (CoreException e)
        {
            Report(e);
        }
    }

    public void SavePdf(string destination)
    {
        if (PdfPath is null)
        {
            return;
        }
        try
        {
            File.Copy(PdfPath, destination, overwrite: true);
            Shell.Reveal(destination);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            app.Report(e.Message);
        }
    }

    // ---------- search ----------

    private CancellationTokenSource? searchCancel;

    private async void ScheduleSearch()
    {
        searchCancel?.Cancel();
        var query = SearchQuery;
        if (string.IsNullOrWhiteSpace(query))
        {
            SearchHits = [];
            return;
        }
        var pending = searchCancel = new CancellationTokenSource();
        try
        {
            await Task.Delay(200, pending.Token);
            var hits = await core.CallAsync<List<SearchHit>>("search_project", new { id = Id, query });
            if (!pending.IsCancellationRequested)
            {
                SearchHits = hits;
            }
        }
        catch (TaskCanceledException)
        {
        }
        catch (CoreException)
        {
            SearchHits = [];
        }
    }

    // ---------- editor commands ----------

    public void Format(string name, string? arg = null) => _ = editor.CommandAsync(name, arg);

    public void Reveal(int line) => _ = editor.RevealAsync(line);
}
