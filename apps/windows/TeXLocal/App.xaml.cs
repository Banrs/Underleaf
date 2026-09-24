using Microsoft.UI.Xaml;

namespace TeXLocal;

public partial class App : Application
{
    private Window? window;

    public App()
    {
        // WebView2 keeps its profile beside the exe unless told otherwise,
        // and an installed app's folder is not writable.
        Environment.SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TeXLocal", "WebView2"));
        InitializeComponent();
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
    }
}
