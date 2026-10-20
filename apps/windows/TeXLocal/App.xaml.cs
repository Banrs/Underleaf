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

    internal static string? CoreError { get; private set; }

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

    public static bool OpenCore()
    {
        if (Core is not null) return true;
        var queue = DispatcherQueue.GetForCurrentThread();
        try { Core = Core.Open(Core.DefaultDataDir, a => queue.TryEnqueue(() => a())); }
        catch (Exception ex) { CoreError = ex.Message; }
        return Core is not null;
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

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        OpenCore();
        Window = new MainWindow();
        Window.Activate();
        // A later launch, handed over by Program.Main.
        AppInstance.GetCurrent().Activated += (_, e) =>
        {
            var words = Program.Arguments(e);
            Window.DispatcherQueue.TryEnqueue(() => Window.Arrive(words));
        };
        _ = Window.Import(Program.Arguments(AppInstance.GetCurrent().GetActivatedEventArgs()));
        if (!Smoke) return;
        // A new blank project, opened: the workspace ends the run once its session is open.
        if (Core is null) ExitSmoke(CoreError);
        try { Window.OpenProject((await Core!.CallAsync<ProjectInfo>("create_project", new { name = "Smoke", template = "blank" })).Id); }
        catch (CoreException ex) { ExitSmoke(ex.Message); }
    }
}
