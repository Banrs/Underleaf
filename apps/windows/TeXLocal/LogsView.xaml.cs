using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace TeXLocal;

/// <summary>The last compile's errors and warnings, and its whole log, with a filter over both.</summary>
public sealed partial class LogsView : UserControl
{
    internal ProjectModel? Project { get; set; }

    private int issueCount;

    // What the log box shows. Kept here because the box hands its text back
    // with CR line ends, so it can't be compared with the log.
    private string logShown = "";

    // The log's text changed since it was last scrolled into place. The box
    // lays out only while shown, so a log that arrives behind the Issues tab
    // is scrolled when the tab turns.
    private bool logMoved;

    public LogsView()
    {
        InitializeComponent();
        // Selected here rather than in XAML, where the change would reach
        // OnTabChanged before the panes it toggles exist.
        Tabs.SelectedItem = IssuesTab;
    }

    private bool ShowingLog => Tabs.SelectedItem == LogTab;

    /// <summary>Show the project's latest compile result, on the tab the project asks for.</summary>
    internal void Render()
    {
        var result = Project?.Result;
        Tabs.SelectedItem = Project?.PanelTab == PanelTab.Log ? LogTab : IssuesTab;

        var errors = result?.Errors.Count ?? 0;
        var warnings = result?.Warnings.Count ?? 0;
        SuccessIcon.Visibility = result is not null && errors == 0 ? Visibility.Visible : Visibility.Collapsed;
        FailureIcon.Visibility = errors > 0 ? Visibility.Visible : Visibility.Collapsed;
        WarningIcon.Visibility = WarningText.Visibility = warnings > 0 ? Visibility.Visible : Visibility.Collapsed;
        OutcomeText.Text = result is null ? "Not compiled yet"
            : errors > 0 ? Count(errors, "error")
            : result.Ok ? "Compiled"
            : "Failed";
        WarningText.Text = Count(warnings, "warning");
        DurationText.Text = result is null ? "" : $"{result.DurationMs / 1000.0:0.0} s";
        WarningsToggle.IsEnabled = warnings > 0;
        CopyButton.IsEnabled = !string.IsNullOrEmpty(result?.Log);
        Filter();
    }

    private static string Count(int n, string noun) => n == 1 ? $"1 {noun}" : $"{n:N0} {noun}s";

    /// <summary>The issues and log lines that match the filter, warnings only when asked for.</summary>
    private void Filter()
    {
        var result = Project?.Result;
        var filter = FilterBox.Text.Trim();
        bool Matches(string? text) => text?.Contains(filter, StringComparison.CurrentCultureIgnoreCase) == true;

        var items = result is null ? [] : result.Errors.Concat(WarningsToggle.IsChecked == true ? result.Warnings : []);
        List<LogRow> rows = items
            .Where(i => filter.Length == 0 || Matches(i.Message) || Matches(i.File))
            .Select(i => new LogRow(i))
            .ToList();
        Issues.ItemsSource = rows;
        issueCount = rows.Count;

        // The filter is the log's find: only the lines that match.
        var log = result?.Log ?? "";
        var shown = filter.Length == 0 ? log : string.Join('\n', log.Split('\n').Where(Matches));
        // Setting the same text again would throw away the reader's place and selection.
        if (logShown != shown)
        {
            logShown = LogText.Text = shown;
            logMoved = true;
        }
        ShowState();
    }

    /// <summary>The list, the log or what's missing, for the tab and the filter.</summary>
    private void ShowState()
    {
        var result = Project?.Result;
        var filter = FilterBox.Text.Trim();
        (string Glyph, string Title, string Detail)? empty = ShowingLog
            ? string.IsNullOrEmpty(result?.Log) ? ("\uE8A5", "No log yet", "Compile to see the log here.")
            : logShown.Length == 0 ? ("\uE721", "No matches", $"No lines match “{filter}”.")
            : null
            : result is null ? ("\uE90F", "Not compiled yet", "Compile to see errors and warnings here.")
            : issueCount > 0 ? null
            : filter.Length > 0 ? ("\uE721", "No matches", $"No issues match “{filter}”.")
            : result.Ok ? ("\uE73E", "No issues", "")
            // TeX stopped without an error the log parser recognises (a
            // missing format, a crash): the log is the only explanation.
            : ("\uE783", "Build failed", "The compile failed without a recognisable error. See the build log for TeX’s own output.");

        Issues.Visibility = !ShowingLog && empty is null ? Visibility.Visible : Visibility.Collapsed;
        LogText.Visibility = ShowingLog && empty is null ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = empty is null ? Visibility.Collapsed : Visibility.Visible;
        if (empty is { } state)
        {
            EmptyGlyph.Glyph = state.Glyph;
            EmptyTitle.Text = state.Title;
            EmptyDetail.Text = state.Detail;
            EmptyDetail.Visibility = state.Detail.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        if (LogText.Visibility == Visibility.Visible && logMoved)
        {
            // Once the box has laid out its new text.
            DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, ScrollLog);
        }
    }

    /// <summary>Unfiltered, the log opens at its end, where the error usually is; filtered, at its first match.</summary>
    private void ScrollLog()
    {
        if (LogText.Visibility != Visibility.Visible || Descendant<ScrollViewer>(LogText) is not { } scroller)
        {
            return;
        }
        logMoved = false;
        scroller.UpdateLayout();
        var end = FilterBox.Text.Trim().Length == 0;
        scroller.ChangeView(0, end ? scroller.ScrollableHeight : 0, null, disableAnimation: true);
    }

    private static T? Descendant<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if ((child as T ?? Descendant<T>(child)) is { } found)
            {
                return found;
            }
        }
        return null;
    }

    private void OnLogLoaded(object sender, RoutedEventArgs e) => ScrollLog();

    private void OnTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var log = ShowingLog;
        WarningsToggle.Visibility = log ? Visibility.Collapsed : Visibility.Visible;
        CopyButton.Visibility = log ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(FilterBox, log ? "Filter log" : "Filter issues");
        ShowState();
        Project?.PanelTab = log ? PanelTab.Log : PanelTab.Issues;
    }

    private void OnFilterChanged(object sender, TextChangedEventArgs e) => Filter();

    private void OnToggleWarnings(object sender, RoutedEventArgs e)
    {
        var shown = WarningsToggle.IsChecked == true;
        var tip = shown ? "Hide warnings" : "Show warnings";
        ToolTipService.SetToolTip(WarningsToggle, tip);
        AutomationProperties.SetName(WarningsToggle, tip);
        Filter();
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(Project?.Result?.Log ?? "");
        Clipboard.SetContent(package);
    }

    /// <summary>An issue opens its line — in the main file when the log names none, as the web's does.</summary>
    private void OnIssueClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not LogRow { Item: var item } || Project is not { } project)
        {
            return;
        }
        var file = item.File ?? (item.Line is null ? null : project.Settings?.MainFile);
        if (file is not null)
        {
            _ = project.OpenAsync(file, item.Line);
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Project?.ShowLogs = false;
}
