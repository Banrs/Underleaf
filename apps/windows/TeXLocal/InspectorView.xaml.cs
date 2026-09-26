using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeXLocal;

/// <summary>The details pane: the open file, the project's build settings, and facts about the document and the PDF.</summary>
public sealed partial class InspectorView : UserControl
{
    private static MainWindow Main => MainWindow.Instance;

    private ProjectModel? project;

    // Set while the controls are brought up to date, so that doesn't read as the user choosing.
    private bool rendering;

    public InspectorView()
    {
        InitializeComponent();
        EngineBox.ItemsSource = LatexTemplates.Engines.Select(e => e.Name).ToList();
    }

    internal void Render(ProjectModel p)
    {
        project = p;
        rendering = true;
        try
        {
            var settings = p.Settings;
            BuildSection.Opacity = settings is null ? 0.5 : 1;
            MainFileBox.IsEnabled = EngineBox.IsEnabled = ShellEscapeSwitch.IsEnabled = settings is not null;

            var texFiles = TexFiles(p.Tree).ToList();
            if (!texFiles.SequenceEqual(MainFileBox.Items.Cast<string>()))
            {
                MainFileBox.ItemsSource = texFiles;
            }
            MainFileBox.SelectedItem = settings?.MainFile;
            EngineBox.SelectedIndex = LatexTemplates.Engines.ToList().FindIndex(e => e.Id == (settings?.Engine ?? "pdflatex"));
            ShellEscapeSwitch.IsOn = settings?.ShellEscape ?? false;
            AutoCompileSwitch.IsOn = Main.Preferences.AutoCompile;

            // The open file heads the pane, as the selection heads Explorer's; with none open, the project does.
            if (p.OpenPath is { } path)
            {
                var slash = path.LastIndexOf('/');
                ItemGlyph.Glyph = "\uE8A5";
                ItemName.Text = path[(slash + 1)..];
                ItemFolder.Text = slash < 0 ? p.Id : $"{p.Id}/{path[..slash]}";
            }
            else
            {
                ItemGlyph.Glyph = "\uE8B7";
                ItemName.Text = p.Id;
                ItemFolder.Text = "No file open";
            }

            List<(string, string)> facts = p.OpenPath is not null && p.Stats is { } stats
                ?
                [
                    ("Words", $"{stats.Words:N0}"),
                    ("Lines", $"{stats.Lines:N0}"),
                    .. stats.Outline.Count > 0 ? [("Sections", $"{stats.Outline.Count:N0}")] : Array.Empty<(string, string)>(),
                ]
                : [];
            DocumentSection.Visibility = facts.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            Facts(DocumentFacts, facts);

            Facts(PdfFacts, p.Result is { } result
                ?
                [
                    ("Last build", result.Ok ? "Succeeded" : "Failed"),
                    ("Duration", $"{result.DurationMs / 1000.0:0.0} s"),
                    ("Errors", $"{p.ErrorCount:N0}"),
                    ("Warnings", $"{p.WarningCount:N0}"),
                    .. Freshness(p),
                ]
                : [("Last build", "Not compiled"), .. Freshness(p)]);
        }
        finally
        {
            rendering = false;
        }
    }

    private static IEnumerable<(string, string)> Freshness(ProjectModel p) => p.Freshness switch
    {
        PdfFreshness.Edited => [("Preview", "Out of date")],
        PdfFreshness.LastSuccessful => [("Preview", "Last successful build")],
        _ => [],
    };

    /// <summary>Label and value rows, the label in secondary text, in one column width for every section.</summary>
    private void Facts(Grid grid, IReadOnlyList<(string Label, string Value)> facts)
    {
        grid.Children.Clear();
        grid.RowDefinitions.Clear();
        if (grid.ColumnDefinitions.Count == 0)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }
        for (var i = 0; i < facts.Count; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = facts[i].Label, Style = (Style)Resources["FactLabelStyle"] };
            var value = new TextBlock { Text = facts[i].Value, Style = (Style)Resources["FactValueStyle"] };
            Grid.SetRow(label, i);
            Grid.SetRow(value, i);
            Grid.SetColumn(value, 1);
            grid.Children.Add(label);
            grid.Children.Add(value);
        }
    }

    private static IEnumerable<string> TexFiles(IEnumerable<TreeNode> nodes) => nodes.SelectMany(n =>
        n.IsDirectory ? TexFiles(n.Children ?? []) : n.Path.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) ? [n.Path] : []);

    private void OnMainFileChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!rendering && project is { } p && MainFileBox.SelectedItem is string path && path != p.Settings?.MainFile)
        {
            _ = p.SetMainFileAsync(path);
        }
    }

    private void OnEngineChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!rendering && project is { } p && EngineBox.SelectedIndex >= 0)
        {
            _ = p.SetEngineAsync(LatexTemplates.Engines[EngineBox.SelectedIndex].Id);
        }
    }

    private void OnShellEscapeToggled(object sender, RoutedEventArgs e)
    {
        if (!rendering && project is { } p && ShellEscapeSwitch.IsOn != (p.Settings?.ShellEscape ?? false))
        {
            _ = p.SetShellEscapeAsync(ShellEscapeSwitch.IsOn);
        }
    }

    private void OnAutoCompileToggled(object sender, RoutedEventArgs e)
    {
        if (!rendering && AutoCompileSwitch.IsOn != Main.Preferences.AutoCompile)
        {
            Main.Perform(MenuCommand.CompileToggleAuto);
        }
    }
}
