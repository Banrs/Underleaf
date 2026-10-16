using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;
using TeXLocal.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace TeXLocal.Pages;

/// A row of the sidebar's trees: a file or folder, a heading, or a search hit under its file.
public sealed class NavItem
{
    readonly string? spoken;

    public string Lead { get; init; } = "";
    /// The search match, in SemiBold between Lead and Tail.
    public string Strong { get; init; } = "";
    public string Tail { get; init; } = "";
    public string Glyph { get; init; } = "";
    public bool HasGlyph => Glyph.Length > 0;
    /// A file's hit count or a hit's line.
    public string Trailing { get; init; } = "";
    public bool IsMain { get; init; }
    public string Tip { get; init; } = "";
    public int Lines { get; init; } = 1;
    /// What its expansion is kept by in the project's UI state: a folder's path, a heading's fold.
    public string Key { get; init; } = "";
    public bool IsExpanded { get; set; }
    /// The TreeNode, OutlineNode or SearchHit it shows.
    public object? Target { get; init; }
    public List<NavItem>? Children { get; init; }
    public string Spoken { get => spoken ?? Lead + Strong + Tail + (IsMain ? ", main file" : ""); init => spoken = value; }
}

/// The sidebar, as Word's navigation pane: Files, the Outline of the shown file's document, and project search's Results
/// as VS Code's search view. Outline, words and hits are the core's (analyze_project, outline_current, search_project).
public sealed partial class WorkspacePage
{
    readonly RenameFlyout rename = new();
    HashSet<string> expanded = [], folded = [];
    TreeNode[] tree = [];
    string treeJson = "", searched = "";
    string? searchError;
    int searches;
    Analysis? analysis;

    TreeView[] SideTrees => [FilesTree, OutlineTree, ResultsTree];
    TreeNode? Picked => (FilesTree.SelectedItem as NavItem)?.Target as TreeNode;

    static string Glyph(string? kind) => kind switch { null => "\uE8B7", "tex" => "\uE8A5", "bib" => "\uE8F1", "image" => "\uE91B", "pdf" => "\uEA90", _ => "\uE7C3" };

    List<NavItem> Files(TreeNode[] nodes) => [.. nodes.Select(n => new NavItem
    {
        Lead = n.Name, Glyph = Glyph(n.Kind), Tip = n.Path, Key = n.Path, IsMain = n.Path == mainFile,
        IsExpanded = expanded.Contains(n.Path), Target = n, Children = n.Children is { } c ? Files(c) : null,
    })];

    List<NavItem> Headings(OutlineNode[] nodes) => [.. nodes.Select(n => new NavItem
    {
        Lead = Title(n), Tip = Title(n), Key = n.FoldKey, IsExpanded = !folded.Contains(n.FoldKey), Target = n,
        Children = n.Children is { } c ? Headings(c) : null,
    })];

    /// An empty heading by its level, "Untitled subsection", until the core names them (core gap 18).
    static string Title(OutlineNode n) => n.Title != "(untitled)" ? n.Title
        : $"Untitled {(n.Depth < Catalogue.HeadingLevels.Length ? Catalogue.HeadingLevels[n.Depth].Title : "section").ToLowerInvariant()}";

    static List<NavItem> Results(SearchHit[] hits) => [.. hits.GroupBy(h => h.File).Select(g => new NavItem
    {
        Lead = g.Key, Glyph = "\uE8A5", Trailing = $"{g.Count()}", Tip = g.Key, IsExpanded = true,
        Spoken = $"{g.Key}, {g.Count()} {(g.Count() == 1 ? "result" : "results")}",
        Children = [.. g.Select(h => new NavItem
        {
            Lead = h.Before, Strong = h.Match, Tail = h.After, Lines = 2, Trailing = $"{h.Line}", Tip = h.Before + h.Match + h.After,
            Spoken = $"Line {h.Line}: {h.Before}{h.Match}{h.After}", Target = h,
        })],
    })];

    static NavItem? Find(IEnumerable<NavItem>? items, Func<NavItem, bool> match) =>
        items?.Select(i => match(i) ? i : Find(i.Children, match)).FirstOrDefault(i => i is not null);

    /// Selects a row; its container, for a flyout to open at, when it's drawn.
    static FrameworkElement? Select(TreeView view, Func<NavItem, bool> match)
    {
        if (Find(view.ItemsSource as List<NavItem>, match) is not { } item) return null;
        view.SelectedItem = item;
        view.UpdateLayout();
        return view.ContainerFromItem(item) as FrameworkElement;
    }

    /// The project's files. The core sends the tree with each change, often the same one (core gap 24).
    void ShowTree(TreeNode[] nodes, bool force = false)
    {
        var json = JsonSerializer.Serialize(nodes, Core.Json);
        if (!force && json == treeJson) return;
        (tree, treeJson) = (nodes, json);
        var selected = (FilesTree.SelectedItem as NavItem)?.Key;
        FilesTree.ItemsSource = Files(nodes);
        if (selected is not null) Select(FilesTree, i => i.Key == selected);
    }

    async Task RefreshTree() => ShowTree(await Core.CallAsync<TreeNode[]>("file_tree", new { id }));

    /// The active tab's tree, or its note: an empty outline, no search yet, no hits, or the search's error.
    void ShowSide()
    {
        if (ResultsTree is null) return;
        var tab = SideTabs.SelectedItem;
        var outlined = OutlineTree.ItemsSource is List<NavItem> { Count: > 0 };
        var hits = ResultsTree.ItemsSource is List<NavItem> { Count: > 0 };
        var hidden = OutlineTree.Visibility == Visibility.Collapsed;
        FilesTree.Visibility = Vis(tab == FilesTab);
        OutlineTree.Visibility = Vis(tab == OutlineTab && outlined);
        ResultsTree.Visibility = Vis(tab == ResultsTab && hits);
        // A tree selects a row it hasn't drawn in name only: the caret's heading again once the tree shows.
        if (hidden && OutlineTree.Visibility == Visibility.Visible && OutlineTree.SelectedItem is { } current)
            DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                OutlineTree.SelectedItem = null;
                OutlineTree.SelectedItem = current;
            });
        SideNote.Text = tab == OutlineTab && !outlined ? Editor.Path is null ? "Open a file to see its outline." : "No sections in this document."
            : tab != ResultsTab || hits ? ""
            : searchError ?? (searched.Length == 0 ? "Search the project with the box in the title bar (Ctrl+Shift+F)." : $"No results for “{searched}”.");
        SideNote.Visibility = Vis(SideNote.Text.Length > 0);
    }

    void OnSideTab(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => ShowSide();

    void OnShowOutline(object sender, RoutedEventArgs e)
    {
        Split.IsPaneOpen = true;
        SideTabs.SelectedItem = OutlineTab;
        (OutlineTree.Visibility == Visibility.Visible ? (Control)OutlineTree : SideTabs).Focus(FocusState.Keyboard);
    }

    void OnExpanding(TreeView sender, TreeViewExpandingEventArgs args) => Fold(sender, args.Item, true);
    void OnCollapsed(TreeView sender, TreeViewCollapsedEventArgs args) => Fold(sender, args.Item, false);

    /// Folders open and headings folded, kept together in the project's UI state.
    void Fold(TreeView view, object item, bool open)
    {
        if (item is not NavItem row) return;
        row.IsExpanded = open;
        var changed = view == FilesTree ? (open ? expanded.Add(row.Key) : expanded.Remove(row.Key))
            : view == OutlineTree && (open ? folded.Remove(row.Key) : folded.Add(row.Key));
        if (changed) SaveFolds();
    }

    void SaveFolds() => _ = Core.CallAsync("set_ui_state", new { id, patch = new { expandedFolders = expanded.Order(), foldedHeadings = folded.Order() } });

    async void OnInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        switch ((args.InvokedItem as NavItem)?.Target)
        {
            case TreeNode { Type: not "dir" } node:
                await OpenDocument(node.Path, node.Kind);
                break;
            case OutlineNode { File: { } file } heading:
                await Reveal(file, heading.Line);
                break;
            case SearchHit hit:
                await Reveal(hit.File, hit.Line, hit.Column, hit.Length);
                break;
        }
    }

    // MARK: the outline

    /// The outline and words of the document the shown file is in, again after each save.
    async Task Analyze()
    {
        if (Editor.Path is not { } path) return;
        try { analysis = await Core.CallAsync<Analysis>("analyze_project", new { id, file = path }); }
        catch (CoreException) { return; }
        if (Editor.Path != path) return;
        Words.Text = analysis.Words == 1 ? "1 word" : $"{analysis.Words:N0} words";
        OutlineTree.ItemsSource = Headings(analysis.Tree);
        ShowSide();
        await ReadHeadingStyles();
        CaretSettled();
    }

    /// The caret's heading, selected in the outline and checked in Insert › Heading.
    void CaretSettled() => Run(null, async () =>
    {
        if (analysis is not { } shown || Editor.Path is not { } path) return;
        var line = Editor.Caret.Line;
        ShowInsertChecks(shown.Outline.FirstOrDefault(h => h.File == path && h.Line == line));
        var index = await Core.CallAsync<int?>("outline_current", new { outline = shown.Outline, file = path, line });
        if (analysis == shown && Find(OutlineTree.ItemsSource as List<NavItem>, i => i.Target is OutlineNode n && n.Index == index) is { } item
            && OutlineTree.SelectedItem != item)
            OutlineTree.SelectedItem = item;
    });

    // MARK: project search

    void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    {
        if (e.Reason == AutoSuggestionBoxTextChangeReason.UserInput) Restart(searchTimer);
    }

    async void OnSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs e)
    {
        searchTimer.Stop();
        await Search();
        if (ResultsTree.Visibility == Visibility.Visible) ResultsTree.Focus(FocusState.Keyboard);
    }

    void OnSearchKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Escape || App.Window.Search.Text.Length == 0) return;
        App.Window.Search.Text = "";
        _ = Search();
        e.Handled = true;
    }

    void OnFindInProject(object sender, RoutedEventArgs e) => App.Window.Search.Focus(FocusState.Keyboard);

    /// The hits by file; a later search's answer wins over an earlier one's.
    async Task Search()
    {
        var query = App.Window.Search.Text.Trim();
        var generation = ++searches;
        SearchHit[] hits = [];
        string? error = null;
        if (query.Length > 0)
            try { hits = await Core.CallAsync<SearchHit[]>("search_project", new { id, query }); }
            catch (CoreException ex) { error = ex.Message; }
        if (generation != searches) return;
        (searched, searchError) = (query, error);
        ResultsTree.ItemsSource = Results(hits);
        if (query.Length > 0)
        {
            Split.IsPaneOpen = true;
            SideTabs.SelectedItem = ResultsTab;
            Announce(App.Window.Search, hits.Length switch { 0 => "No results", 1 => "1 result", var n => $"{n} results" }, "search");
        }
        ShowSide();
    }

    // MARK: files

    string TargetDir(NavItem? item) => item?.Target is TreeNode n ? n.Type == "dir" ? n.Path : ParentOf(n.Path) : "";

    static string ParentOf(string path) => path.LastIndexOf('/') is var i and > 0 ? path[..i] : "";

    static string Join(string dir, string name) => dir.Length == 0 ? name : $"{dir}/{name}";

    void OnFilesContext(UIElement sender, ContextRequestedEventArgs args) =>
        FilesTree.SelectedItem = (args.OriginalSource as FrameworkElement)?.DataContext as NavItem;

    /// The main file can't be deleted: setting another as the main file comes first.
    void OnFileMenuOpening(object sender, object e)
    {
        var node = Picked;
        RenameItem.IsEnabled = RevealItem.IsEnabled = node is not null;
        DeleteItem.IsEnabled = node is not null && node.Path != mainFile;
        MainItem.IsEnabled = node is { Kind: "tex" } && node.Path != mainFile;
    }

    /// A new entry beside the selection, named in place as File Explorer's New folder is.
    void Create(string name, bool dir) => Run("Can't create this", async () =>
    {
        var parent = TargetDir(FilesTree.SelectedItem as NavItem);
        var made = (await Core.CallAsync("create_entry", new { id, path = Join(parent, name), dir, free = true })).GetProperty("path").GetString()!;
        if (parent.Length > 0 && expanded.Add(parent)) SaveFolds();
        await RefreshTree();
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (Select(FilesTree, i => i.Key == made) is { } row && Picked is { } node) Rename(node, row);
        });
    });

    void OnNewFile(object sender, RoutedEventArgs e) => Create("untitled.tex", false);
    void OnNewFolder(object sender, RoutedEventArgs e) => Create("untitled folder", true);

    void OnSetMain(object sender, RoutedEventArgs e)
    {
        if (Picked is not { Kind: "tex" } node) return;
        Run("Can't set the main file", async () =>
        {
            mainFile = MainFile(await Core.CallAsync("session_set_settings", new { session, patch = new { mainFile = node.Path } }));
            ShowTree(tree, true);
        });
    }

    void OnRename(object sender, RoutedEventArgs e)
    {
        if (Picked is { } node && FilesTree.ContainerFromItem(FilesTree.SelectedItem) is FrameworkElement row) Rename(node, row);
    }

    /// The core's refusal shows in the flyout. A rename above the main file moves it, so the settings are read again.
    void Rename(TreeNode node, FrameworkElement row) => rename.Show(row, node.Name, async name =>
    {
        var to = Join(ParentOf(node.Path), name);
        await Core.CallAsync("session_rename", new { session, from = node.Path, to });
        mainFile = MainFile(await Core.CallAsync("get_settings", new { id }));
        await RefreshTree();
        Select(FilesTree, i => i.Key == to);
    });

    void OnReveal(object sender, RoutedEventArgs e)
    {
        if (Picked is { } node) App.Reveal(Full(node.Path), select: true);
    }

    void OnDelete(object sender, RoutedEventArgs e)
    {
        if (Picked is not { } node || node.Path == mainFile) return;
        Run("Can't delete this", async () =>
        {
            await Core.CallAsync("session_prepare_delete", new { session, path = node.Path });
            var trashed = false;
            try
            {
                await App.Recycle(Full(node.Path));
                trashed = true;
            }
            catch (Exception ex) { await App.Alert("Can't delete this", ex.Message); }
            await Core.CallAsync("session_deleted", new { session, path = node.Path, trashed });
            await RefreshTree();
        });
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems)) e.AcceptedOperation = DataPackageOperation.Copy;
    }

    /// Files dropped from File Explorer, into the folder they're dropped on; a clash asks as File Explorer does.
    async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var deferral = e.GetDeferral();
        var dropped = await e.DataView.GetStorageItemsAsync();
        deferral.Complete();
        var dir = TargetDir((e.OriginalSource as FrameworkElement)?.DataContext as NavItem);
        var paths = dropped.Select(i => i.Path).Where(p => p.Length > 0).ToArray();
        Run("Can't add these files", async () =>
        {
            var imported = await Core.CallAsync<Imported>("import_files", new { id, dir, paths });
            if (imported.Existing.Length > 0)
            {
                var conflict = await App.Show(new ContentDialog
                {
                    Title = "Replace existing files?",
                    Content = string.Join("\n", imported.Existing.Select(c => c.Path)),
                    PrimaryButtonText = "Replace",
                    SecondaryButtonText = "Keep both",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Secondary,
                }) switch
                {
                    ContentDialogResult.Primary => "replace",
                    ContentDialogResult.Secondary => "keepBoth",
                    _ => null,
                };
                if (conflict is null) return;
                await Core.CallAsync("import_files", new { id, dir, paths, conflict });
            }
            await RefreshTree();
        });
    }
}
