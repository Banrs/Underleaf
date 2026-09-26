using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// Settings as a page in the Windows 11 style: grouped cards, each applied
/// the moment it changes. The engine belongs to the open project; the rest
/// to the app.
/// </summary>
public sealed partial class SettingsView : UserControl
{
    private static MainWindow Main => MainWindow.Instance;

    private static readonly string[] Themes = ["system", "light", "dark"];
    private static readonly string[] Papers = ["white", "dark", "auto"];
    private static readonly string[] Palettes = ["onedark", "xcode"];
    private static readonly string[] Fonts = ["system", "jetbrains"];
    private static readonly string[] Engines = ["pdflatex", "xelatex", "lualatex"];

    // Set while Render fills the controls, whose change events would
    // otherwise write the values straight back.
    private bool rendering;

    public SettingsView()
    {
        InitializeComponent();
        foreach (var scale in Preferences.UiScales)
        {
            ScaleBox.Items.Add($"{scale}%");
        }
        AboutIcon.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.png")));
        VersionText.Text = $"Version {typeof(App).Assembly.GetName().Version?.ToString(3)}";
    }

    private static int Index(string[] values, string value) => Math.Max(0, Array.IndexOf(values, value));

    internal void Render()
    {
        rendering = true;
        var prefs = Main.Preferences;
        ThemeBox.SelectedIndex = Index(Themes, prefs.Theme);
        ScaleBox.SelectedIndex = Math.Max(0, Array.IndexOf(Preferences.UiScales, prefs.UiScale));
        PaperBox.SelectedIndex = Index(Papers, prefs.PdfPaper);
        PaletteBox.SelectedIndex = Index(Palettes, prefs.EditorPalette);
        FontBox.SelectedIndex = Index(Fonts, prefs.EditorFont);
        SizeBox.Value = prefs.EditorFontSize;
        WordCountSwitch.IsOn = prefs.ShowWordCount;
        AutoCompileSwitch.IsOn = prefs.AutoCompile;

        var project = Main.Project;
        EngineBox.IsEnabled = project is not null;
        EngineBox.SelectedIndex = Index(Engines, project?.Settings?.Engine ?? "pdflatex");
        EngineDescription.Text = project is null
            ? "Open a project to choose the engine it compiles with"
            : $"The engine {project.Id} compiles with";

        var tex = Main.Tex;
        TexDescription.Text = tex switch
        {
            null => "Looking for TeX…",
            { Available: true } => $"{tex.Version ?? "Installed"}\n"
                + (tex.TexDir is { } dir ? $"Using {dir}" : tex.Found is { } found ? $"Found automatically in {found}" : "Found automatically"),
            { TexDir: { } dir } => $"latexmk in {dir} didn’t run.",
            _ => "Not found. Install MiKTeX or TeX Live, or choose the folder it’s in.",
        };
        GetTex.Visibility = tex is { Available: false } ? Visibility.Visible : Visibility.Collapsed;
        AutomaticTex.Visibility = tex?.TexDir is null ? Visibility.Collapsed : Visibility.Visible;
        rendering = false;
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) => Apply();

    private void OnToggled(object sender, RoutedEventArgs e) => Apply();

    private void Apply()
    {
        if (rendering)
        {
            return;
        }
        var prefs = Main.Preferences;
        prefs.Theme = Themes[Math.Max(0, ThemeBox.SelectedIndex)];
        prefs.UiScale = Preferences.UiScales[Math.Max(0, ScaleBox.SelectedIndex)];
        prefs.PdfPaper = Papers[Math.Max(0, PaperBox.SelectedIndex)];
        prefs.EditorPalette = Palettes[Math.Max(0, PaletteBox.SelectedIndex)];
        prefs.EditorFont = Fonts[Math.Max(0, FontBox.SelectedIndex)];
        prefs.ShowWordCount = WordCountSwitch.IsOn;
        prefs.AutoCompile = AutoCompileSwitch.IsOn;
        Main.SavePreferences();
        Main.ApplyTheme();
    }

    private void OnSizeChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (rendering || double.IsNaN(args.NewValue))
        {
            return;
        }
        Main.Preferences.EditorFontSize = (int)Math.Clamp(args.NewValue, 10, 28);
        Main.SavePreferences();
        Main.AppearanceChanged();
    }

    private void OnEngineChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!rendering && Main.Project is { } project)
        {
            _ = project.SetEngineAsync(Engines[Math.Max(0, EngineBox.SelectedIndex)]);
        }
    }

    private void OnBrowseTex(object sender, RoutedEventArgs e) => _ = Main.ChooseTexFolderAsync();

    private void OnAutomaticTex(object sender, RoutedEventArgs e) => _ = Main.SetTexDirAsync(null);

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            Main.CloseSettings();
        }
    }
}
