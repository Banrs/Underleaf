using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TeXLocal;

/// <summary>The last compile's errors and warnings, and its raw log.</summary>
public sealed partial class LogsView : UserControl
{
    internal ProjectModel? Project { get; set; }

    public LogsView()
    {
        InitializeComponent();
        // Selected here rather than in XAML, where the change would reach
        // OnTabChanged before the panes it toggles exist.
        Tabs.SelectedItem = IssuesTab;
    }

    /// <summary>Show the project's latest compile result.</summary>
    internal void Render()
    {
        var result = Project?.Result;
        List<LogRow> rows = result is null ? [] : result.Errors.Concat(result.Warnings).Select(i => new LogRow(i)).ToList();
        Issues.ItemsSource = rows;
        NoIssues.Text = result is null ? "Not compiled yet" : rows.Count == 0 ? "No issues" : "";
        RawText.Text = result?.Log ?? "";
        if (result is null)
        {
            OutcomeIcon.Glyph = OutcomeText.Text = DurationText.Text = "";
            return;
        }
        OutcomeIcon.Glyph = result.Ok ? "" : "";
        OutcomeIcon.Foreground = (Brush)Application.Current.Resources[
            result.Ok ? "SystemFillColorSuccessBrush" : "SystemFillColorCriticalBrush"];
        OutcomeText.Text = result.Ok ? "Compiled" : "Failed";
        DurationText.Text = $"{result.DurationMs / 1000.0:0.0}s";
    }

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var raw = sender.SelectedItem == RawTab;
        Raw.Visibility = raw ? Visibility.Visible : Visibility.Collapsed;
        Issues.Visibility = NoIssues.Visibility = raw ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnIssueClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LogRow { Item.File: { } file } row && Project is { } project)
        {
            _ = project.OpenAsync(file, row.Item.Line);
        }
    }

    private void OnClose(object sender, RoutedEventArgs e)
    {
        if (Project is { } project)
        {
            project.ShowLogs = false;
        }
    }
}
