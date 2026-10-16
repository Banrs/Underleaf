using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Controls;

namespace TeXLocal.Pages;

/// Changes apply at once; there is no Save.
public sealed partial class SettingsPage : Page
{
    const string Sample = "\\section{Results}\n% Measured at room temperature\nThe energy is $E = mc^2$, as \\cite{einstein} found.";
    readonly double[] sizes = [.. new double[] { 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28 }.Append(Prefs.EditorFontSize).Distinct().Order()];

    public SettingsPage()
    {
        InitializeComponent();
        About.Description = $"Version {typeof(App).Assembly.GetName().Version?.ToString(3)} · MIT License";
        ThemeBox.SelectedIndex = Prefs.Theme;
        var families = Prefs.MonospaceFamilies();
        FontBox.ItemsSource = families.Contains(Prefs.EditorFont) ? families : [.. families, Prefs.EditorFont];
        FontBox.SelectedItem = Prefs.EditorFont;
        SizeBox.ItemsSource = sizes;
        SizeBox.SelectedIndex = Array.IndexOf(sizes, Prefs.EditorFontSize);
        SyntaxBox.ItemsSource = Prefs.Themes;
        SyntaxBox.SelectedValue = Prefs.EditorTheme;
        PairSwitch.IsOn = Prefs.AutoPair;
        CompleteSwitch.IsOn = Prefs.AutoComplete;

        ThemeBox.SelectionChanged += (_, _) =>
        {
            Prefs.Theme = ThemeBox.SelectedIndex;
            App.Window.ApplyTheme((ElementTheme)Prefs.Theme);
        };
        FontBox.SelectionChanged += OnLook;
        SizeBox.SelectionChanged += OnLook;
        SyntaxBox.SelectionChanged += OnLook;
        PairSwitch.Toggled += (_, _) => Prefs.AutoPair = PairSwitch.IsOn;
        CompleteSwitch.Toggled += (_, _) => Prefs.AutoComplete = CompleteSwitch.IsOn;
        Loaded += (_, _) => ShowPreview();
        ActualThemeChanged += (_, _) => DispatcherQueue.TryEnqueue(ShowPreview);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (App.Core is { } core) ShowTex(await core.CallAsync<TexStatus>("status"));
    }

    void OnOpenFolder(object sender, RoutedEventArgs e) => App.Reveal(Core.DefaultDataDir);

    async void OnAutomatic(object sender, RoutedEventArgs e) => await SetTexDir(null);

    async void OnChooseTex(object sender, RoutedEventArgs e)
    {
        if (await new FolderPicker(App.Window.AppWindow.Id).PickSingleFolderAsync() is { } picked) await SetTexDir(picked.Path);
    }

    /// Sets the folder latexmk runs from (null: find it), then shows what the core reports, whatever happened.
    async Task SetTexDir(string? dir)
    {
        if (App.Core is not { } core) return;
        try { await core.CallAsync("set_tex_dir", new { dir }); }
        catch (CoreException ex) { await App.Alert("Can't use this folder", ex.Message); }
        ShowTex(await core.CallAsync<TexStatus>("status"));
    }

    void ShowTex(TexStatus status)
    {
        TexMissing.IsOpen = !status.Available;
        TexText.Text = status.Available ? string.Join(" · ", new[] { status.Version, status.Found }.Where(s => !string.IsNullOrEmpty(s))) : "Not found";
        AutomaticButton.Visibility = status.TexDir is null ? Visibility.Collapsed : Visibility.Visible;
    }

    void OnLook(object sender, SelectionChangedEventArgs e)
    {
        (Prefs.EditorFont, Prefs.EditorFontSize) = ((string)FontBox.SelectedItem, sizes[SizeBox.SelectedIndex]);
        if (SyntaxBox.SelectedValue is string theme) Prefs.EditorTheme = theme;
        ShowPreview();
    }

    /// The sample in the editor's font, coloured as the editor colours it.
    void ShowPreview()
    {
        if (!IsLoaded) return;
        Preview.FontFamily = new FontFamily(Prefs.EditorFont);
        Preview.FontSize = Prefs.EditorFontSize;
        var paper = ((SolidColorBrush)PaperInk.Fill).Color;
        var secondary = SourceView.Over(((SolidColorBrush)SecondaryInk.Fill).Color, paper);
        var inks = SourceView.SyntaxColors(Prefs.EditorTheme, ActualTheme == ElementTheme.Dark, paper, ((SolidColorBrush)LineInk.Fill).Color, secondary);
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
