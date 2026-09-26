using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace TeXLocal;

/// <summary>
/// One open project: its files, the document in the editor, and its builds.
/// Every menu, toolbar and editor command lands here; behaviour follows web/src/workspace.js.
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

    private void Set<T>(ref T store, T value, [CallerMemberName] string name = "")
    {
        if (EqualityComparer<T>.Default.Equals(store, value))
        {
            return;
        }
        store = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public ProjectSettings? Settings { get; private set => Set(ref field, value); }
    public IReadOnlyList<TreeNode> Tree { get; private set => Set(ref field, value); } = [];
    public string? OpenPath { get; private set => Set(ref field, value); }

    /// <summary>The open .tex file's outline, words and lines, read on open and on save; null for other files, as in the web.</summary>
    public DocumentStats? Stats { get; private set => Set(ref field, value); }
    public IReadOnlyList<OutlineItem> Sections => Stats?.Outline ?? [];

    public int CursorLine { get; private set => Set(ref field, value); } = 1;

    /// <summary>The first line showing at the top of the editor: the outline follows it.</summary>
    public int TopLine { get; private set => Set(ref field, value); } = 1;

    public bool Dirty { get; private set => Set(ref field, value); }
    public bool Saving { get; private set => Set(ref field, value); }
    public bool Compiling { get; private set => Set(ref field, value); }
    public CompileResult? Result { get; private set => Set(ref field, value); }

    // Only a successful build moves the PDF on screen, so a new main file keeps
    // showing the last PDF until its own exists; PdfVersion counts each new one.
    public string? PdfPath { get; private set; }
    public int PdfVersion { get; private set => Set(ref field, value); }

    /// <summary>The latest forward-search target; raised even when it repeats, so a spot can flash twice.</summary>
    public ForwardLoc? Highlight { get; private set { field = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Highlight))); } }

    /// <summary>How the PDF on screen differs from the source, or null when it is current.</summary>
    public PdfFreshness? Freshness { get; private set => Set(ref field, value); }

    /// <summary>The panel below the editors, and which of its tabs shows.</summary>
    public bool ShowLogs { get; set => Set(ref field, value); }
    public PanelTab PanelTab { get; set => Set(ref field, value); }

    public string SearchQuery
    {
        get;
        set
        {
            Set(ref field, value);
            ScheduleSearch();
        }
    } = "";

    public IReadOnlyList<SearchHit> SearchHits { get; private set => Set(ref field, value); } = [];

    public int ErrorCount => Result?.Errors.Count ?? 0;
    public int WarningCount => Result?.Warnings.Count ?? 0;
    public bool TexAvailable => app.Tex?.Available ?? false;
    private bool AutoCompile => app.Preferences.AutoCompile;

    /// <summary>A failure: what couldn't be done, then the core's reason.</summary>
    private void Report(CoreException error, string title) => app.Report(title, error.Message);

    /// <summary>Run core calls, reporting a failure under the title given; false when one failed.</summary>
    private async Task<bool> TryAsync(Func<Task> action, string failure)
    {
        try
        {
            await action();
            return true;
        }
        catch (CoreException e)
        {
            Report(e, failure);
            return false;
        }
    }

    private static string Name(string path) => path[(path.LastIndexOf('/') + 1)..];

    // Set once the project is closed: its late results and queued follow-ups
    // must not act on the next project.
    private bool closed;

    public async Task LoadAsync()
    {
        editor.Changed = Edited;
        editor.CursorMoved = line => CursorLine = line;
        editor.Scrolled = line => TopLine = line;
        editor.Command = id =>
        {
            if (MenuCommands.FromId(id) is { } command)
            {
                app.Perform(command);
            }
        };
        editor.Crashed += OnEditorCrashed;
        editor.Reloaded += OnEditorReloaded;
        await TryAsync(async () =>
        {
            var loaded = await core.CallAsync<ProjectSettings>("get_settings", new { id = Id });
            Settings = loaded;
            await ReloadTreeAsync();
            await RefreshSymbolsAsync();
            await OpenAsync(loaded.MainFile);
        }, "Couldn’t open the project");
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
        diskCheck?.Cancel();
        watcher?.Dispose();
        watcher = null;
        editor.Changed = null;
        editor.CursorMoved = null;
        editor.Scrolled = null;
        editor.Command = null;
        editor.Crashed -= OnEditorCrashed;
        editor.Reloaded -= OnEditorReloaded;
    }

    public Task ReloadTreeAsync() =>
        TryAsync(async () => Tree = await core.CallAsync<List<TreeNode>>("file_tree", new { id = Id }), "Couldn’t refresh the file list");

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

    private int openRequest;

    /// <summary>Open a file: text in the editor, anything else in its own app.</summary>
    public async Task OpenAsync(string path, int? line = null)
    {
        if (!TextFiles.IsText(path))
        {
            await TryAsync(async () => Shell.Open(await core.CallAsync<string>("raw_path", new { id = Id, path })), $"Couldn’t open “{Name(path)}”");
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
                Report(e, $"Couldn’t open “{Name(path)}”");
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
        CursorLine = TopLine = 1;
        diskText = file.Text;
        _ = WatchOpenFileAsync();
        Analyze(path, file.Text);
        await editor.OpenAsync($"{Id}/{path}", file.Text);
        return true;
    }

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
        // The open waits for a save that read its text before the crash.
        await OpenAsync(path);
        // The editor shows the disk text again, which the PDF was built from unless a save landed since.
        if (Freshness == PdfFreshness.Edited && writes == builtWrites)
        {
            Freshness = null;
        }
        if (lostInCrash)
        {
            lostInCrash = false;
            app.Report("Unsaved changes were lost", $"The editor stopped unexpectedly. Changes to {path} since it was last saved were lost.");
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
        if (PdfVersion > 0 && Freshness is null)
        {
            Freshness = PdfFreshness.Edited;
        }
        autosave?.Cancel();
        var pending = autosave = new CancellationTokenSource();
        try
        {
            // Soon enough for an automatic compile to follow typing, long enough not to save every keystroke.
            await Task.Delay(700, pending.Token);
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

    // Writes to the open file, this app's and other apps', and how many of them
    // the PDF on screen was built after: it is current only while they match.
    private int writes;
    private int builtWrites;

    private Task<bool> SaveAsync() => saves = SaveAfterAsync(saves);

    private async Task<bool> SaveAfterAsync(Task<bool> previous)
    {
        await previous;
        if (!Dirty)
        {
            return true;
        }
        // Not over another app's change until the user says which to keep.
        if (OpenPath is not { } path || diskConflict)
        {
            return false;
        }
        // Clean before the text is read, not after: an edit that arrives while
        // the page answers marks it dirty again and is saved next, not lost.
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
                    // The edits went with the renderer; OnEditorReloaded says so.
                    return true;
                }
                Dirty = true;
                app.Report($"“{Name(path)}” wasn’t saved", "The editor’s text couldn’t be read. Your changes are still in the editor, and TeXLocal saves them again after your next edit.");
                return false;
            }
            // Before the write, whose own change notice then matches it.
            diskText = text;
            await core.PerformAsync("write_file", new { id = Id, path, text });
            writes++;
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
            Report(e, $"“{Name(path)}” wasn’t saved");
            return false;
        }
        finally
        {
            readingText = false;
            Saving = false;
        }
    }

    /// <summary>
    /// Save until no edit arrived during the last write, before a compile, close or quit.
    /// False, and the edits stay in the editor, when a save failed.
    /// </summary>
    public async Task<bool> FlushAsync()
    {
        autosave?.Cancel();
        do
        {
            if (!await SaveAsync())
            {
                return false;
            }
        }
        while (Dirty);
        return true;
    }

    /// <summary>A flush for a save the user asked for, or before a switch, rename or delete; the cancelled autosave's compile still happens.</summary>
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

    private FileSystemWatcher? watcher;
    private CancellationTokenSource? diskCheck;

    // The open file's text as this app last read or wrote it, which tells
    // another app's change from its own save.
    private string? diskText;

    // Asking which to keep: saves wait for the answer.
    private bool diskConflict;

    /// <summary>Watch the open file, so another app's change (an editor, a sync, git) shows here rather than being saved over.</summary>
    private async Task WatchOpenFileAsync()
    {
        var path = OpenPath;
        string full;
        try
        {
            full = await core.CallAsync<string>("raw_path", new { id = Id, path });
        }
        catch (CoreException)
        {
            return;
        }
        if (path != OpenPath || closed)
        {
            return;
        }
        watcher?.Dispose();
        watcher = new FileSystemWatcher(Path.GetDirectoryName(full)!, Path.GetFileName(full))
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName,
        };
        // Editors that save by moving a new file over this one raise Created or Renamed, not Changed.
        void Changed(object sender, FileSystemEventArgs e) => app.DispatcherQueue.TryEnqueue(ScheduleDiskCheck);
        watcher.Changed += Changed;
        watcher.Created += Changed;
        watcher.Renamed += Changed;
        watcher.EnableRaisingEvents = true;
    }

    /// <summary>Changes come in bursts (the text, then its size and date): read once they settle.</summary>
    private async void ScheduleDiskCheck()
    {
        diskCheck?.Cancel();
        var pending = diskCheck = new CancellationTokenSource();
        try
        {
            await Task.Delay(250, pending.Token);
        }
        catch (TaskCanceledException)
        {
            return;
        }
        await CheckDiskAsync();
    }

    /// <summary>Nothing unsaved: the editor takes the text on disk. Unsaved edits: ask which to keep.</summary>
    private async Task CheckDiskAsync()
    {
        var before = saves;
        await before;
        if (OpenPath is not { } path || closed || diskConflict)
        {
            return;
        }
        FileText file;
        try
        {
            file = await core.CallAsync<FileText>("read_file", new { id = Id, path });
        }
        catch (CoreException)
        {
            // Gone or locked for now; the tree shows a delete.
            return;
        }
        // A save that started meanwhile may be what was read, half written;
        // its own change notice checks again.
        if (path != OpenPath || closed || saves != before || file.Text == diskText)
        {
            return;
        }
        diskText = file.Text;
        // The PDF no longer matches what is on disk.
        writes++;
        if (PdfVersion > 0)
        {
            Freshness = PdfFreshness.Edited;
        }
        if (Dirty)
        {
            autosave?.Cancel();
            await ResolveConflictAsync(path);
        }
        else
        {
            await ShowDiskTextAsync(path, file.Text);
            await CompileIfAutoAsync();
        }
    }

    /// <summary>The file changed on disk while it has edits here: revert, or keep editing and save over it.</summary>
    private async Task ResolveConflictAsync(string path)
    {
        diskConflict = true;
        var revert = await Dialogs.ConfirmAsync(app.Content.XamlRoot, $"“{Path.GetFileName(path)}” changed on disk",
            $"Another app changed {path} while it has unsaved changes here. Revert to the version on disk, or keep editing and save over it.",
            "Revert", cancel: "Keep editing");
        diskConflict = false;
        if (closed || path != OpenPath)
        {
            return;
        }
        if (revert)
        {
            await ShowDiskTextAsync(path, diskText!);
            await CompileIfAutoAsync();
        }
        else
        {
            await SaveNowAsync();
        }
    }

    /// <summary>The editor shows the file as it is on disk, at the same place, keeping focus where it is.</summary>
    private async Task ShowDiskTextAsync(string path, string text)
    {
        var top = TopLine;
        autosave?.Cancel();
        Dirty = false;
        Analyze(path, text);
        await editor.OpenAsync($"{Id}/{path}", text, focus: false);
        await editor.RevealAsync(top, atTop: true, focus: false);
        CursorLine = await editor.CurrentLineAsync();
    }

    private bool compileQueued;

    private Task CompileIfAutoAsync() => AutoCompile ? CompileAsync(auto: true) : Task.CompletedTask;

    /// <summary>
    /// Compile the project; a request during a compile runs once it ends. Automatic
    /// compiles report failures in the log only, so a typing pause never interrupts.
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
            var built = writes;
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
                builtWrites = built;
                // Edits made, or saves landed, while it built aren't in it.
                Freshness = Dirty || writes != built ? PdfFreshness.Edited : null;
            }
            else if (!result.Ok)
            {
                if (PdfVersion > 0)
                {
                    Freshness = PdfFreshness.LastSuccessful;
                }
                // TeX can stop without an error the parser recognises; then the log is the only explanation.
                PanelTab = result.Errors.Count > 0 ? PanelTab.Issues : PanelTab.Log;
                ShowLogs = true;
            }
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
                Report(e, "Couldn’t compile");
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

    /// <summary>Stop the build in progress: its process tree is killed and the compile returns failed.</summary>
    public void StopCompile()
    {
        if (Compiling)
        {
            compileQueued = false;
            core.KillAll();
        }
    }

    private Task<bool> PatchSettingsAsync(object patch, string failure) =>
        TryAsync(async () => Settings = await core.CallAsync<ProjectSettings>("set_settings", new { id = Id, patch }), failure);

    public Task SetShellEscapeAsync(bool on) => PatchSettingsAsync(new { shellEscape = on }, "Couldn’t change shell escape");

    public async Task SetEngineAsync(string engine)
    {
        // A new engine only means something once a build uses it.
        if (engine != Settings?.Engine && await PatchSettingsAsync(new { engine }, "Couldn’t change the engine"))
        {
            await CompileAsync(auto: true);
        }
    }

    /// <summary>The PDF is named after the main file, so a new main file means a new build.</summary>
    public async Task SetMainFileAsync(string path)
    {
        if (await PatchSettingsAsync(new { mainFile = path }, "Couldn’t change the main file"))
        {
            await CompileAsync(auto: true);
        }
    }

    public async Task ForwardSyncAsync()
    {
        // Saved first, so SyncTeX reads the line against the text on disk.
        if (OpenPath is not { } path || !await SaveNowAsync())
        {
            return;
        }
        var line = await editor.CurrentLineAsync();
        try
        {
            var loc = await core.CallAsync<ForwardLoc>("synctex_forward", new { id = Id, file = path, line });
            // Shown, and the panel hidden, so the spot is in view.
            app.ShowPdf();
            Highlight = loc;
        }
        catch (CoreException)
        {
            app.Report("No PDF location found", "Compile first, then try again.", Microsoft.UI.Xaml.Controls.InfoBarSeverity.Informational);
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
            app.Report("No source location found", "Nothing in the source matches this part of the PDF.", Microsoft.UI.Xaml.Controls.InfoBarSeverity.Informational);
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

    public Task CreateEntryAsync(string path, bool directory) => TryAsync(async () =>
    {
        await core.PerformAsync("create_entry", new { id = Id, path, dir = directory });
        await ReloadTreeAsync();
        if (!directory)
        {
            await OpenAsync(path);
        }
    }, $"Couldn’t create “{Name(path)}”");

    public async Task RenameEntryAsync(string from, string to)
    {
        if (to == from || !await SaveNowAsync())
        {
            return;
        }
        try
        {
            var renamed = await core.CallAsync<RenameResult>("rename_entry", new { id = Id, from, to });
            // A renamed folder carries the open file along; the next save must write to the new path.
            if (ProjectPaths.Contains(renamed.From, OpenPath))
            {
                var moved = ProjectPaths.Remap(OpenPath, renamed.From, renamed.To)!;
                await editor.RenameAsync($"{Id}/{OpenPath}", $"{Id}/{moved}");
                OpenPath = moved;
                _ = WatchOpenFileAsync();
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
            Report(e, $"Couldn’t rename “{Name(from)}”");
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
            // The buffer stays until the delete succeeded, so a failed one leaves the text to save or copy.
            if (ProjectPaths.Contains(path, OpenPath))
            {
                Dirty = false;
                OpenPath = null;
                Stats = null;
                watcher?.Dispose();
                watcher = null;
            }
            await ReloadTreeAsync();
        }
        catch (CoreException e)
        {
            Report(e, $"Couldn’t move “{Name(path)}” to the Recycle Bin");
        }
    }

    /// <summary>Copy files and folders from elsewhere into the project, at the root or into a folder.</summary>
    public async Task ImportFilesAsync(IReadOnlyList<string> paths, string dir = "")
    {
        await TryAsync(() => core.CallAsync<ImportResult>("import_files", new { id = Id, dir, paths }), "Couldn’t add the files");
        // Even after a failure: the files copied before it are there.
        await ReloadTreeAsync();
        await RefreshSymbolsAsync();
    }

    public Task RevealAsync(string path) =>
        TryAsync(async () => Shell.Reveal(await core.CallAsync<string>("raw_path", new { id = Id, path })), "Couldn’t open the file location");

    public Task ExportZipAsync(string destination) => TryAsync(async () =>
    {
        await core.PerformAsync("export_zip", new { id = Id, dest = destination });
        Shell.Reveal(destination);
    }, "Couldn’t export the project");

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
            app.Report("Couldn’t save the PDF", e.Message);
        }
    }

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

    public void Format(string name, string? arg = null) => _ = editor.CommandAsync(name, arg);

    public void Reveal(int line, bool atTop = false, bool focus = true) => _ = editor.RevealAsync(line, atTop, focus);
}

/// <summary>How the PDF on screen differs from the source.</summary>
internal enum PdfFreshness
{
    /// <summary>The source has changed since it was built.</summary>
    Edited,

    /// <summary>The latest build failed; this is the one before it.</summary>
    LastSuccessful,
}

internal enum PanelTab
{
    Issues,
    Log,
}
