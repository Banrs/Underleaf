using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;

namespace TeXLocal.Pages;

public sealed partial class SettingsPage : Page
{
    const string Sample = "\\section{Results}\n% Measured at room temperature\nThe energy is $E = mc^2$, as \\cite{einstein} found.";
    readonly double[] sizes = [.. new double[] { 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28 }.Append(EditorPrefs.FontSize).Distinct().Order()];
    bool ready;

    public SettingsPage()
    {
        InitializeComponent();
        FolderText.Text = Core.DefaultDataDir;
        VersionText.Text = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0];
        ThemeBox.SelectedIndex = MainWindow.Pref("theme", 0);

        var families = EditorPrefs.MonospaceFamilies();
        string[] fonts = families.Contains(EditorPrefs.Font) ? families : [.. families, EditorPrefs.Font];
        FontBox.ItemsSource = fonts;
        FontBox.SelectedIndex = Array.IndexOf(fonts, EditorPrefs.Font);
        SizeBox.ItemsSource = sizes;
        SizeBox.SelectedIndex = Array.IndexOf(sizes, EditorPrefs.FontSize);
        SyntaxBox.ItemsSource = EditorPrefs.Themes.Select(t => t.Title).ToArray();
        SyntaxBox.SelectedIndex = Array.FindIndex(EditorPrefs.Themes, t => t.Id == EditorPrefs.Theme);
        PairSwitch.IsOn = EditorPrefs.AutoPair;
        CompleteSwitch.IsOn = EditorPrefs.AutoComplete;
        Loaded += (_, _) => ShowPreview();
        ActualThemeChanged += (_, _) => DispatcherQueue.TryEnqueue(ShowPreview);
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

    void OnFont(object sender, SelectionChangedEventArgs e)
    {
        if (FontBox.SelectedItem is string font) EditorPrefs.Font = font;
        ShowPreview();
    }

    void OnFontSize(object sender, SelectionChangedEventArgs e)
    {
        if (SizeBox.SelectedIndex >= 0) EditorPrefs.FontSize = sizes[SizeBox.SelectedIndex];
        ShowPreview();
    }

    void OnSyntaxTheme(object sender, SelectionChangedEventArgs e)
    {
        if (SyntaxBox.SelectedIndex >= 0) EditorPrefs.Theme = EditorPrefs.Themes[SyntaxBox.SelectedIndex].Id;
        ShowPreview();
    }

    void OnAutoPair(object sender, RoutedEventArgs e) => EditorPrefs.AutoPair = PairSwitch.IsOn;

    void OnAutoComplete(object sender, RoutedEventArgs e) => EditorPrefs.AutoComplete = CompleteSwitch.IsOn;

    /// The sample in the editor's font, coloured as the editor colours it.
    void ShowPreview()
    {
        if (!IsLoaded) return;
        Preview.FontFamily = new FontFamily(EditorPrefs.Font);
        Preview.FontSize = EditorPrefs.FontSize;
        var inks = EditorPrefs.Colors(ActualTheme == ElementTheme.Dark, ((SolidColorBrush)PaperInk.Fill).Color, ((SolidColorBrush)LineInk.Fill).Color);
        using var source = Source.New(Sample);
        Preview.Inlines.Clear();
        var at = 0;
        foreach (var run in source.Highlights(0, Sample.Length))
        {
            if (run.Kind >= inks.Length || run.Start < at) continue;
            Preview.Inlines.Add(new Run { Text = Sample[at..run.Start] });
            Preview.Inlines.Add(new Run { Text = Sample.Substring(run.Start, run.Length), Foreground = new SolidColorBrush(inks[run.Kind]) });
            at = run.Start + run.Length;
        }
        Preview.Inlines.Add(new Run { Text = Sample[at..] });
    }
}
