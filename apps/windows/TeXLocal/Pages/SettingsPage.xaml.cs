using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;

namespace TeXLocal.Pages;

public sealed partial class SettingsPage : Page
{
    bool ready;

    public SettingsPage()
    {
        InitializeComponent();
        FolderText.Text = Core.DefaultDataDir;
        VersionText.Text = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0];
        ThemeBox.SelectedIndex = MainWindow.Pref("theme", 0);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (App.Core is { } core) Show(await core.CallAsync<TexStatus>("status"));
        ready = true;
    }

    void Show(TexStatus status)
    {
        TexIcon.Glyph = status.Available ? "\uE73E" : "\uE7BA";
        TexTitle.Text = status.Available ? "TeX found" : "TeX isn't installed";
        TexDetail.Text = status.Available
            ? string.Join(" · ", new[] { status.Version, status.Found }.Where(s => !string.IsNullOrEmpty(s)))
            : "TeXLocal compiles with TeX Live.";
        TexLink.Visibility = status.Available ? Visibility.Collapsed : Visibility.Visible;
        ready = false;
        LocationBox.SelectedIndex = status.TexDir is null ? 0 : 1;
        ready = true;
    }

    void OnTheme(object sender, SelectionChangedEventArgs e)
    {
        MainWindow.Prefs["theme"] = ThemeBox.SelectedIndex;
        App.Window.ApplyTheme((ElementTheme)ThemeBox.SelectedIndex);
    }

    void OnOpenFolder(object sender, RoutedEventArgs e) => App.Reveal($"\"{Core.DefaultDataDir}\"");

    async void OnLocation(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || App.Core is not { } core) return;
        string? dir = null;
        if (LocationBox.SelectedIndex == 1)
        {
            dir = (await new FolderPicker(App.Window.AppWindow.Id).PickSingleFolderAsync())?.Path;
            if (dir is null)
            {
                Show(await core.CallAsync<TexStatus>("status"));
                return;
            }
        }
        try { Show(await core.CallAsync<TexStatus>("set_tex_dir", new { dir })); }
        catch (CoreException ex) { await App.Alert("Can't use this folder", ex.Message); }
    }
}
