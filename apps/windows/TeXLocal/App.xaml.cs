using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.VisualBasic.FileIO;
using Microsoft.Windows.AppLifecycle;
using TeXLocal.Bridge;

namespace TeXLocal;

public partial class App : Application
{
    public static Core? Core { get; private set; }
    public static MainWindow Window { get; private set; } = null!;
    public static readonly bool Smoke = Environment.GetCommandLineArgs().Contains("--smoke");
    static readonly TaskCompletionSource<MainWindow> shown = new();

    public App()
    {
        InitializeComponent();
        // Written to stderr in any run, for a run whose stderr is redirected; a smoke run fails on it.
        UnhandledException += (_, e) =>
        {
            Console.Error.WriteLine(e.Exception);
            if (Smoke) Environment.Exit(1);
        };
    }

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

    public static Task<ContentDialogResult> Show(ContentDialog dialog)
    {
        var root = (FrameworkElement)Window.Content;
        dialog.XamlRoot = root.XamlRoot;
        dialog.RequestedTheme = root.ActualTheme;
        dialog.Style = (Style)Current.Resources["DefaultContentDialogStyle"];
        return dialog.ShowAsync().AsTask();
    }

    /// In a smoke run, which no one reads, an alert is its failure.
    public static Task Alert(string title, string message)
    {
        if (Smoke) ExitSmoke($"{title}: {message}");
        return Show(new ContentDialog { Title = title, Content = message, CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close });
    }

    /// A later launch handed over by Program.Main, heard on a pool thread from before the window is made: AppInstance
    /// drops one that arrives with no handler, as Explorer's several files opened at once would.
    internal static async void Arrived(object? sender, AppActivationArguments e)
    {
        var words = Program.Arguments(e);
        var window = await shown.Task;
        window.DispatcherQueue.TryEnqueue(() => window.Arrive(words));
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var error = OpenCore();
        Window = new MainWindow();
        Window.Activate();
        shown.SetResult(Window);
        _ = Window.Import(Program.Arguments(AppInstance.GetCurrent().GetActivatedEventArgs()));
        if (!Smoke) return;
        // A new blank project, opened: the workspace ends the run once its session is open.
        if (Core is null) ExitSmoke(error);
        try { Window.OpenProject((await Core!.CallAsync<ProjectInfo>("create_project", new { name = "Smoke", template = "blank" })).Id); }
        catch (CoreException ex) { ExitSmoke(ex.Message); }
    }
}
