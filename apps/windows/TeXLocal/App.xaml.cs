using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.VisualBasic.FileIO;
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

    public static void ExitSmoke(int code, string? why = null)
    {
        if (why is not null) Console.Error.WriteLine(why);
        Core?.Dispose();
        Environment.Exit(code);
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

    public static Task Alert(string title, string message) =>
        Show(new ContentDialog { Title = title, Content = message, CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close });

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        OpenCore();
        Window = new MainWindow();
        Window.Activate();
    }
}
