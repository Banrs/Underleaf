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

    /// <summary>The first line showing at the top of the editor: the outline follows it.</summary>
    public int TopLine { get => topLine; private set => Set(ref topLine, value); }
    private int topLine = 1;

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

    /// <summary>How the PDF on screen differs from the source, or null when it is current.</summary>
    public PdfFreshness? Freshness { get => freshness; private set => Set(ref freshness, value); }
    private PdfFreshness? freshness;

    /// <summary>The panel below the editors, and which of its tabs shows.</summary>
    public bool ShowLogs { get => showLogs; set => Set(ref showLogs, value); }
    private bool showLogs;

    public PanelTab PanelTab { get => panelTab; set => Set(ref panelTab, value); }
    private PanelTab panelTab;

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

    /// <summary>A failure: what couldn't be done, then the core's reason.</summary>
    private void Report(CoreException error, string title) => app.Report(title, error.Message);

    /// <summary>A project path's last part, as a title names a file or folder.</summary>
    private static string Name(string path) => path[(path.LastIndexOf('/') + 1)..];

    // Set once the project is closed: its late results and queued follow-ups
    // must not act on the next project.
    private bool closed;

    // ---------- loading ----------

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
            Report(e, "Couldn’t open the project");
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

    public async Task ReloadTreeAsync()
    {
        try
        {
            Tree = await core.CallAsync<List<TreeNode>>("file_tree", new { id = Id });
        }
        catch (CoreException e)
        {
            Report(e, "Couldn’t refresh the file list");
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
                Report(e, $"Couldn’t open “{Name(path)}”");
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
        // The open waits for a save that read its text before the crash.
        await OpenAsync(path);
        // The editor shows the file as it is on disk again, which is what
        // the PDF was built from unless a save has landed since.
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
            // macOS's pause: soon enough that an automatic compile follows
            // typing closely, long enough not to save every keystroke.
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

    // Writes to the open file, this app's and other apps', and how many of
    // them the PDF on screen was built after: the preview is current only
    // while they match.
    private int writes;
    private int builtWrites;

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
        // Not over another app's change until the user says which to keep.
        if (OpenPath is not { } path || diskConflict)
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
    /// Save until no edit arrived during the last write, cancelling the
    /// pending autosave — before a compile, a project close or quit. False,
    /// and the edits stay in the editor, when a save failed.
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

    // ---------- changes on disk ----------

    private FileSystemWatcher? watcher;
    private CancellationTokenSource? diskCheck;

    // The open file's text as this app last read or wrote it, which tells
    // another app's change from its own save.
    private string? diskText;

    // Asking which to keep: saves wait for the answer.
    private bool diskConflict;

    /// <summary>
    /// Watch the open file, so a change another app makes (an editor, a
    /// sync, git) shows here rather than being saved over.
    /// </summary>
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
        // Editors that save by writing a new file and moving it over this
        // one raise Created or Renamed rather than Changed.
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
                // Edits made while it built still aren't in it, nor may a
                // save that landed meanwhile be.
                Freshness = Dirty || writes != built ? PdfFreshness.Edited : null;
            }
            else if (!result.Ok)
            {
                if (PdfVersion > 0)
                {
                    Freshness = PdfFreshness.LastSuccessful;
                }
                // TeX can stop without an error the parser recognises; then
                // the log is the only explanation.
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

    // ---------- settings ----------

    private async Task<bool> PatchSettingsAsync(object patch, string failure)
    {
        try
        {
            Settings = await core.CallAsync<ProjectSettings>("set_settings", new { id = Id, patch });
            return true;
        }
        catch (CoreException e)
        {
            Report(e, failure);
            return false;
        }
    }

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

    // ---------- SyncTeX ----------

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
            Report(e, $"Couldn’t create “{Name(path)}”");
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
            // The buffer stays until the delete succeeded, so a failed one
            // leaves the text to save or copy.
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
        try
        {
            await core.CallAsync<ImportResult>("import_files", new { id = Id, dir, paths });
        }
        catch (CoreException e)
        {
            Report(e, "Couldn’t add the files");
        }
        // Even after a failure: the files copied before it are there.
        await ReloadTreeAsync();
        await RefreshSymbolsAsync();
    }

    public async Task RevealAsync(string path)
    {
        try
        {
            Shell.Reveal(await core.CallAsync<string>("raw_path", new { id = Id, path }));
        }
        catch (CoreException e)
        {
            Report(e, "Couldn’t open the file location");
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
            Report(e, "Couldn’t export the project");
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
            app.Report("Couldn’t save the PDF", e.Message);
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
