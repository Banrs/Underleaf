using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.VisualBasic.FileIO;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;

namespace TeXLocal;

public partial class App : Application
{
    public static Core? Core { get; private set; }
    public static MainWindow Window { get; private set; } = null!;
    public static readonly bool Smoke = Environment.GetCommandLineArgs().Contains("--smoke");
    static readonly TaskCompletionSource<MainWindow> shown = new();
    static readonly SemaphoreSlim dialogs = new(1, 1);
    static Catalogue? catalogue;

    public App()
    {
        InitializeComponent();
        // Written to stderr in any run, for a run whose stderr is redirected; a smoke run fails on it, and any other goes on.
        UnhandledException += (_, e) =>
        {
            Console.Error.WriteLine(e.Exception);
            if (Smoke) Environment.Exit(1);
            e.Handled = true;
        };
    }

    /// Every handler's awaited work goes through here, since an exception out of an async void method ends the app:
    /// what it throws is alerted, titled `failure`; with no title, a refusal of the core's is dropped, as when the place
    /// a jump asked for has gone.
    public static async void Run(string? failure, Func<Task> work)
    {
        try { await work(); }
        catch (CoreException) when (failure is null) { }
        catch (Exception ex) { await Alert(failure ?? "Something went wrong", ex.Message); }
    }

    /// The core's templates and engines, which don't change while the app runs.
    public static async Task<Catalogue> Catalogue() => catalogue ??= await Core!.CallAsync<Catalogue>("catalogue");

    /// Why the library can't open, or null once it has.
    public static string? OpenCore()
    {
        if (Core is not null) return null;
        var queue = DispatcherQueue.GetForCurrentThread();
        try { Core = Core.Open(Core.DefaultDataDir, a => queue.TryEnqueue(() => a())); }
        catch (Exception ex) { return ex.Message; }
        return null;
    }

    public static void ExitSmoke(string? error)
    {
        if (error is not null) Console.Error.WriteLine(error);
        Core?.Dispose();
        Environment.Exit(error is null ? 0 : 1);
    }

    /// Opens a folder in File Explorer, or with `select` its parent with the item selected.
    public static void Reveal(string path, bool select = false) =>
        Process.Start("explorer.exe", select ? $"/select,\"{path}\"" : $"\"{path}\"");

    /// A project's files as a ZIP, where the save picker says; the core archives what is on disk. For arXiv, it adds the
    /// compiled bibliography and arXiv's 00README, or says why it can't.
    public static async Task ExportZip(string id, string name, bool forArxiv = false)
    {
        var picker = new FileSavePicker(Window.AppWindow.Id) { SuggestedFileName = forArxiv ? $"{name} arXiv" : name };
        picker.FileTypeChoices.Add("ZIP archive", [".zip"]);
        if (await picker.PickSaveFileAsync() is { } picked) await Core!.CallAsync("export_zip", new { id, dest = picked.Path, forArxiv });
    }

    /// Windows.Storage's DeleteAsync deletes outright when unpackaged.
    public static Task Recycle(string path) => Task.Run(() =>
    {
        if (Directory.Exists(path)) FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        else FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
    });

    /// The files of a drop from File Explorer, read while the drop waits: its data goes once the handler returns.
    public static async Task<string[]> Dropped(DragEventArgs e)
    {
        var deferral = e.GetDeferral();
        var items = await e.DataView.GetStorageItemsAsync();
        deferral.Complete();
        return [.. items.Select(i => i.Path).Where(p => p.Length > 0)];
    }

    /// One at a time, as WinUI allows: a dialog asked for while another shows, as for a file changed on disk, waits its
    /// turn.
    public static async Task<ContentDialogResult> Show(ContentDialog dialog)
    {
        await dialogs.WaitAsync();
        try
        {
            var root = (FrameworkElement)Window.Content;
            dialog.XamlRoot = root.XamlRoot;
            dialog.RequestedTheme = root.ActualTheme;
            dialog.Style = (Style)Current.Resources["DefaultContentDialogStyle"];
            return await dialog.ShowAsync();
        }
        finally { dialogs.Release(); }
    }

    /// A question with Cancel, whose safe answer is the default unless another is preferred.
    public static Task<ContentDialogResult> Ask(string title, string content, string primary, string? secondary = null,
        ContentDialogButton preferred = ContentDialogButton.Close) => Show(new ContentDialog
    {
        Title = title, Content = content, PrimaryButtonText = primary, SecondaryButtonText = secondary ?? "", CloseButtonText = "Cancel", DefaultButton = preferred,
    });

    /// In a smoke run, which no one reads, an alert is its failure.
    public static Task Alert(string title, string message)
    {
        if (Smoke) ExitSmoke($"{title}: {message}");
        return Show(new ContentDialog { Title = title, Content = message, CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close });
    }

    /// A later launch handed over by Program.Main, heard on a pool thread from before the window is made: AppInstance
    /// drops one that arrives with no handler, as Explorer's several files opened at once would.
    internal static void Arrived(object? sender, AppActivationArguments e)
    {
        var words = Program.Arguments(e);
        _ = shown.Task.ContinueWith(t => t.Result.DispatcherQueue.TryEnqueue(() => t.Result.Arrive(words)), TaskScheduler.Default);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var error = OpenCore();
        Window = new MainWindow();
        Window.Activate();
        shown.SetResult(Window);
        if (Smoke && Core is null) ExitSmoke(error);
        // As on the Mac, the project open at the last close comes back, unless the launch names what to open. A smoke run
        // opens a new blank project instead, and the workspace ends the run once its session is open.
        var words = Program.Arguments(AppInstance.GetCurrent().GetActivatedEventArgs());
        if (Smoke) Run("Can't create a project", async () =>
            Window.OpenProject((await Core!.CallAsync<ProjectInfo>("create_project", new { name = "Smoke", template = "blank" })).Id));
        else if (words.Length > 1) Window.Open(words);
        else if (Core is not null && Prefs.LastProject is { Length: > 0 } last) Run(null, async () =>
        {
            if ((await Core.CallAsync<ProjectInfo[]>("list_projects")).Any(p => p.Id == last && !p.Missing)) Window.OpenProject(last);
        });
    }
}
