using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;

namespace TeXLocal.Pages;

public sealed class OutlineItem(OutlineNode node, string title, bool expanded, List<OutlineItem>? children)
{
    public OutlineNode Node => node;
    public string Title => title;
    public string Place => $"{node.File}:{node.Line}";
    public bool IsExpanded { get; set; } = expanded;
    public List<OutlineItem>? Children => children;
}

public sealed class ResultItem(SearchHit hit)
{
    public SearchHit Hit => hit;
    public string Line => hit.Line.ToString();
    public string Spoken => $"Line {hit.Line}: {hit.Before}{hit.Match}{hit.After}";
}

public sealed class ResultGroup(string file, IEnumerable<ResultItem> items) : List<ResultItem>(items)
{
    public string File => file;
    public string Total => Count.ToString();
}

/// The navigation pane, as Word's: Files, the Outline of the document the file belongs to, and project search's
/// Results; and the word count. Outline, words and hits are the core's (analyze_project, outline_current, search_project).
public sealed partial class WorkspacePage
{
    Microsoft.UI.Dispatching.DispatcherQueueTimer? searchTimer, caretTimer;
    Analysis? analysis;
    List<OutlineItem> outline = [];
    HashSet<string> folded = [];
    string searched = "";
    int searches;

    void SetUpNavigation()
    {
        searchTimer = DispatcherQueue.CreateTimer();
        searchTimer.Interval = TimeSpan.FromMilliseconds(250);
        searchTimer.IsRepeating = false;
        searchTimer.Tick += async (_, _) => await Search();
        caretTimer = DispatcherQueue.CreateTimer();
        caretTimer.Interval = TimeSpan.FromMilliseconds(150);
        caretTimer.IsRepeating = false;
        caretTimer.Tick += (_, _) => CaretSettled();
        Editor.CaretMoved += () =>
        {
            caretTimer.Stop();
            caretTimer.Start();
        };
    }

    static AutoSuggestBox SearchBox => App.Window.Search;

    void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    {
        if (e.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        searchTimer!.Stop();
        searchTimer.Start();
    }

    async void OnSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs e)
    {
        searchTimer!.Stop();
        await Search();
        if (Results.Visibility == Visibility.Visible) Results.Focus(FocusState.Keyboard);
    }

    void OnSearchKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Escape || SearchBox.Text.Length == 0) return;
        SearchBox.Text = "";
        _ = Search();
        e.Handled = true;
    }

    void OnSideTab(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => ShowSide();

    void ShowSide()
    {
        if (OutlineTree is null) return;
        var tab = SideTabs.SelectedItem;
        Tree.Visibility = tab == FilesTab ? Visibility.Visible : Visibility.Collapsed;
        var hidden = OutlineTree.Visibility == Visibility.Collapsed;
        OutlineTree.Visibility = tab == OutlineTab && outline.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // A tree selects an item it hasn't drawn only in name: the caret's heading again once it shows.
        if (hidden && OutlineTree.Visibility == Visibility.Visible && OutlineTree.SelectedItem is { } current)
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                OutlineTree.SelectedItem = null;
                OutlineTree.SelectedItem = current;
            });
        Results.Visibility = tab == ResultsTab && Results.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var note = tab == OutlineTab && outline.Count == 0
            ? Editor.Path is null ? "Open a file to see its outline." : "No sections in this document."
            : tab == ResultsTab && Results.Items.Count == 0 && searched.Length > 0 ? $"No results for “{searched}”." : "";
        SideNote.Text = note;
        SideNote.Visibility = note.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void OnShowOutline(object sender, RoutedEventArgs e)
    {
        if (!Split.IsPaneOpen) ShowPane(sidebarWanted = true);
        SideTabs.SelectedItem = OutlineTab;
        (outline.Count > 0 ? (Control)OutlineTree : SideTabs).Focus(FocusState.Keyboard);
    }

    /// The outline and words of the document the shown file is in, again after each save.
    async Task Analyze()
    {
        if (Editor.Path is not { } path) return;
        try { analysis = await Core.CallAsync<Analysis>("analyze_project", new { id, file = path }); }
        catch (CoreException) { return; }
        if (Editor.Path != path) return;
        WordsText.Text = analysis.Words == 1 ? "1 word" : $"{analysis.Words:N0} words";
        outline = Build(analysis.Tree);
        OutlineTree.ItemsSource = outline;
        ShowSide();
        await ReadHeadingStyles();
        CaretSettled();
    }

    List<OutlineItem> Build(OutlineNode[] nodes) => [.. nodes.Select(n => new OutlineItem(n,
        n.Title == "(untitled)" ? $"Untitled {(n.Depth < Catalogue.HeadingLevels.Length ? Catalogue.HeadingLevels[n.Depth].Title : "section").ToLowerInvariant()}" : n.Title,
        !folded.Contains(n.FoldKey), n.Children is { } c ? Build(c) : null))];

    static OutlineItem? Find(int index, List<OutlineItem> within)
    {
        foreach (var item in within)
        {
            if (item.Node.Index == index) return item;
            if (item.Children is { } c && Find(index, c) is { } found) return found;
        }
        return null;
    }

    /// The caret's heading in the outline, and the Insert menu's checks.
    async void CaretSettled()
    {
        if (analysis is not { } shown || Editor.Path is not { } path) return;
        var line = Editor.Caret.Line;
        UpdateInsertChecks(shown.Outline.FirstOrDefault(h => h.File == path && h.Line == line));
        var index = await Core.CallAsync<int?>("outline_current", new { outline = shown.Outline, file = path, line });
        if (analysis != shown || index is null || Find(index.Value, outline) is not { } item) return;
        if (OutlineTree.SelectedItem != item) OutlineTree.SelectedItem = item;
    }

    async void OnOutlineInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is OutlineItem { Node: { File: { } file } node }) await Reveal(file, node.Line, 0);
    }

    void OnOutlineExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Item is not OutlineItem item) return;
        item.IsExpanded = true;
        if (folded.Remove(item.Node.FoldKey)) PersistFolds();
    }

    void OnOutlineCollapsed(TreeView sender, TreeViewCollapsedEventArgs args)
    {
        if (args.Item is not OutlineItem item) return;
        item.IsExpanded = false;
        if (folded.Add(item.Node.FoldKey)) PersistFolds();
    }

    void PersistFolds() => _ = Core.CallAsync("set_ui_state", new { id, patch = new { foldedHeadings = folded.Order() } });

    void OnFindInProject(object sender, RoutedEventArgs e) => SearchBox.Focus(FocusState.Keyboard);

    async Task Search()
    {
        var query = SearchBox.Text.Trim();
        var generation = ++searches;
        if (query.Length == 0)
        {
            searched = "";
            Results.ItemsSource = null;
            ResultsTab.Visibility = Visibility.Collapsed;
            if (SideTabs.SelectedItem == ResultsTab) SideTabs.SelectedItem = FilesTab;
            ShowSide();
            return;
        }
        SearchHit[] hits;
        try { hits = await Core.CallAsync<SearchHit[]>("search_project", new { id, query }); }
        catch (CoreException ex)
        {
            hits = [];
            SideNote.Text = ex.Message;
        }
        if (generation != searches) return;
        searched = query;
        var groups = hits.GroupBy(h => h.File).Select(g => new ResultGroup(g.Key, g.Select(h => new ResultItem(h)))).ToList();
        Results.ItemsSource = new CollectionViewSource { IsSourceGrouped = true, Source = groups }.View;
        ResultsTab.Visibility = Visibility.Visible;
        if (!Split.IsPaneOpen) ShowPane(sidebarWanted = true);
        SideTabs.SelectedItem = ResultsTab;
        ShowSide();
        var peer = FrameworkElementAutomationPeer.FromElement(SearchBox) ?? FrameworkElementAutomationPeer.CreatePeerForElement(SearchBox);
        var spoken = hits.Length switch { 0 => "No results", 1 => "1 result", var n => $"{n} results" };
        peer.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, spoken, "search");
    }

    async void OnResultClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ResultItem { Hit: var hit }) return;
        if (Editor.Path != hit.File && !await OpenDocument(hit.File)) return;
        Editor.GoTo(hit.Line, hit.Column, hit.Length);
    }
}
