using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using TeXLocal.Bridge;
using TeXLocal.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace TeXLocal.Pages;

public sealed class FileItem(TreeNode node, bool expanded, bool main, List<FileItem>? children)
{
    public string Name => node.Name;
    public string Path => node.Path;
    public bool IsDir => node.Type == "dir";
    public bool IsTex => node.Kind == "tex";
    public string? Kind => node.Kind;
    public bool IsExpanded { get; set; } = expanded;
    public bool IsMain => main;
    public List<FileItem>? Children => children;
    public string Glyph => node.Kind switch
    {
        null => "\uE8B7",
        "tex" => "\uE8A5",
        "bib" => "\uE8F1",
        "image" => "\uE91B",
        "pdf" => "\uEA90",
        _ => "\uE7C3",
    };
}

public sealed partial class WorkspacePage : Page
{
    readonly RenameFlyout rename = new();
    string id = "";
    ulong session;
    string root = "";
    string mainFile = "";
    HashSet<string> expanded = [];
    TreeNode[] tree = [];
    string treeJson = "";
    List<FileItem> items = [];
    bool sidebarWanted = true;

    static Core Core => App.Core!;

    public WorkspacePage()
    {
        InitializeComponent();
        NavigationCacheMode = NavigationCacheMode.Required;
        foreach (var item in TreeMenu.Items)
            foreach (var key in item.KeyboardAccelerators) key.ScopeOwner = Tree;
        Split.OpenPaneLength = MainWindow.Pref("sidebarWidth", 280.0);
        PaneSizer.Delta += d =>
        {
            Split.OpenPaneLength = Math.Clamp(Split.OpenPaneLength + d, 200, 480);
            MainWindow.Prefs["sidebarWidth"] = Split.OpenPaneLength;
        };
        Split.RegisterPropertyChangedCallback(SplitView.DisplayModeProperty, (_, _) => ShowPane(Split.DisplayMode == SplitViewDisplayMode.Inline && sidebarWanted));
        SetUpDocument();
        Loaded += (_, _) =>
        {
            // An InfoBar open while the page sat cached under Settings keeps the old theme's state colours.
            foreach (var bar in (InfoBar[])[BuildFailed, Notice])
            {
                var severity = bar.Severity;
                bar.Severity = severity == InfoBarSeverity.Informational ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
                bar.Severity = severity;
            }
        };
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        id = (string)e.Parameter;
        App.Window.TitleBar.Subtitle = id;
        if (session != 0) return;
        Core.Event += OnEvent;
        try { await OpenSession(); }
        catch (CoreException ex)
        {
            await App.Alert("Can't open this project", ex.Message);
            App.Window.GoHome();
        }
    }

    /// Settings keeps the project open underneath: the page is cached until it goes elsewhere.
    protected override void OnNavigatingFrom(NavigatingCancelEventArgs e)
    {
        if (e.SourcePageType != typeof(SettingsPage)) NavigationCacheMode = NavigationCacheMode.Disabled;
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        if (e.SourcePageType == typeof(SettingsPage)) return;
        Core.Event -= OnEvent;
        if (session != 0) _ = Core.CallAsync("session_close", new { session });
    }

    void OnEvent(CoreEvent e)
    {
        if (e.Session != session) return;
        if (e.Type == "tree") Show(e.Json.GetProperty("tree").Deserialize<TreeNode[]>(Core.Json)!);
        else OnDocumentEvent(e);
    }

    void Show(TreeNode[] nodes, bool force = false)
    {
        var json = JsonSerializer.Serialize(nodes, Core.Json);
        if (!force && json == treeJson) return;
        (tree, treeJson) = (nodes, json);
        var selected = (Tree.SelectedItem as FileItem)?.Path;
        items = Build(nodes);
        Tree.ItemsSource = items;
        if (selected is not null) Select(selected);
    }

    List<FileItem> Build(TreeNode[] nodes) =>
        [.. nodes.Select(n => new FileItem(n, expanded.Contains(n.Path), n.Path == mainFile, n.Children is { } c ? Build(c) : null))];

    async Task Refresh() => Show(await Core.CallAsync<TreeNode[]>("file_tree", new { id }));

    FileItem? Find(string path) => Find(path, items);

    static FileItem? Find(string path, List<FileItem> within)
    {
        foreach (var item in within)
        {
            if (item.Path == path) return item;
            if (item.Children is { } c && Find(path, c) is { } found) return found;
        }
        return null;
    }

    FrameworkElement? Select(string path)
    {
        if (Find(path) is not { } item) return null;
        Tree.SelectedItem = item;
        Tree.UpdateLayout();
        return Tree.ContainerFromItem(item) as FrameworkElement;
    }

    FileItem? Target => Tree.SelectedItem as FileItem;

    string TargetDir(FileItem? item) => item is null ? "" : item.IsDir ? item.Path : ParentOf(item.Path);

    static string ParentOf(string path) => path.LastIndexOf('/') is var i and > 0 ? path[..i] : "";

    string Full(string path) => System.IO.Path.Combine(root, path.Replace('/', '\\'));

    static string Join(string dir, string name) => dir.Length == 0 ? name : $"{dir}/{name}";

    void Persist() => _ = Core.CallAsync("set_ui_state", new { id, patch = new { expandedFolders = expanded.Order() } });

    void OnExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Item is not FileItem item) return;
        item.IsExpanded = true;
        if (expanded.Add(item.Path)) Persist();
    }

    void OnCollapsed(TreeView sender, TreeViewCollapsedEventArgs args)
    {
        if (args.Item is not FileItem item) return;
        item.IsExpanded = false;
        if (expanded.Remove(item.Path)) Persist();
    }

    void OnTreeContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        Tree.SelectedItem = (args.OriginalSource as FrameworkElement)?.DataContext as FileItem;
    }

    void OnTreeMenuOpening(object sender, object e)
    {
        var item = Target;
        RenameItem.IsEnabled = RevealItem.IsEnabled = DeleteItem.IsEnabled = item is not null;
        MainItem.IsEnabled = item is { IsTex: true, IsMain: false };
    }

    async Task Create(string name, bool dir)
    {
        var parent = TargetDir(Target);
        try
        {
            var made = (await Core.CallAsync("create_entry", new { id, path = Join(parent, name), dir, free = true })).GetProperty("path").GetString()!;
            if (parent.Length > 0 && expanded.Add(parent)) Persist();
            await Refresh();
            DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                if (Select(made) is { } row) Rename(Find(made)!, row);
            });
        }
        catch (CoreException ex) { await App.Alert("Can't create this", ex.Message); }
    }

    async void OnNewFile(object sender, RoutedEventArgs e) => await Create("untitled.tex", false);

    async void OnNewFolder(object sender, RoutedEventArgs e) => await Create("untitled folder", true);

    async void OnSetMain(object sender, RoutedEventArgs e)
    {
        if (Target is not { IsTex: true } item) return;
        var settings = await Core.CallAsync("session_set_settings", new { session, patch = new { mainFile = item.Path } });
        mainFile = settings.GetProperty("mainFile").GetString() ?? item.Path;
        Show(tree, true);
    }

    void OnRename(object sender, RoutedEventArgs e)
    {
        if (Target is { } item && Tree.ContainerFromItem(item) is FrameworkElement row) Rename(item, row);
    }

    void Rename(FileItem item, FrameworkElement row) => rename.Show(row, item.Name, async name =>
    {
        var to = Join(ParentOf(item.Path), name);
        await Core.CallAsync("session_rename", new { session, from = item.Path, to });
        if (mainFile == item.Path) mainFile = to;
        await Refresh();
        Select(to);
    });

    void OnReveal(object sender, RoutedEventArgs e)
    {
        if (Target is { } item) App.Reveal($"/select,\"{System.IO.Path.Combine(root, item.Path.Replace('/', '\\'))}\"");
    }

    async void OnDelete(object sender, RoutedEventArgs e)
    {
        if (Target is not { } item) return;
        try { await Core.CallAsync("session_prepare_delete", new { session, path = item.Path }); }
        catch (CoreException ex)
        {
            Notice.Title = ex.Status == 409 ? "The main file can't be deleted" : "Can't delete this";
            Notice.Message = ex.Status == 409 ? "Set another file as the main file first." : ex.Message;
            Notice.IsOpen = true;
            return;
        }
        var trashed = false;
        try
        {
            await App.Recycle(System.IO.Path.Combine(root, item.Path.Replace('/', '\\')));
            trashed = true;
        }
        catch (Exception ex) { await App.Alert("Can't delete this", ex.Message); }
        await Core.CallAsync("session_deleted", new { session, path = item.Path, trashed });
        await Refresh();
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems)) e.AcceptedOperation = DataPackageOperation.Copy;
    }

    async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var deferral = e.GetDeferral();
        var dropped = await e.DataView.GetStorageItemsAsync();
        deferral.Complete();
        var dir = TargetDir((e.OriginalSource as FrameworkElement)?.DataContext as FileItem);
        var paths = dropped.Select(i => i.Path).Where(p => p.Length > 0).ToArray();
        try
        {
            var result = await Core.CallAsync<Imported>("import_files", new { id, dir, paths });
            if (result.Existing.Length > 0)
            {
                ReplaceDialog.Content = new TextBlock
                {
                    Text = string.Join("\n", result.Existing.Select(c => c.Path)),
                    TextWrapping = TextWrapping.Wrap,
                    Style = (Style)Application.Current.Resources["BodyTextBlockStyle"],
                };
                var conflict = await ReplaceDialog.ShowAsync() switch
                {
                    ContentDialogResult.Primary => "replace",
                    ContentDialogResult.Secondary => "keepBoth",
                    _ => null,
                };
                if (conflict is null) return;
                await Core.CallAsync("import_files", new { id, dir, paths, conflict });
            }
            await Refresh();
        }
        catch (CoreException ex) { await App.Alert("Can't add these files", ex.Message); }
    }

    void OnOpenFolder(object sender, RoutedEventArgs e) => App.Window.OpenFolder();

    void OnOpenFile(object sender, RoutedEventArgs e) => App.Window.OpenFile();

    void OnClose(object sender, RoutedEventArgs e) => App.Window.GoHome();

    void OnSettings(object sender, RoutedEventArgs e) => App.Window.OpenSettings();

    /// F6 and Shift+F6: sidebar, editor, PDF, issues, in turn.
    void OnNextRegion(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        UIElement[] regions = [Tree, Editor, Pdf, IssueList];
        var at = -1;
        for (var e = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject; e is not null && at < 0; e = VisualTreeHelper.GetParent(e))
            at = Array.IndexOf(regions, e);
        var step = args.KeyboardAccelerator.Modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Shift) ? regions.Length - 1 : 1;
        for (var i = 1; i <= regions.Length; i++)
        {
            var next = regions[(Math.Max(at, 0) + i * step) % regions.Length];
            if (next == Tree && !Split.IsPaneOpen) ShowPane(sidebarWanted = true);
            if (next.Visibility != Visibility.Visible || next == IssueList && !panelOpen) continue;
            if (next == Editor) Editor.Focus(FocusState.Keyboard);
            else if (next == Pdf) Pdf.Focus(FocusState.Keyboard);
            else next.Focus(FocusState.Keyboard);
            return;
        }
    }

    public void TogglePane()
    {
        sidebarWanted = !Split.IsPaneOpen;
        ShowPane(sidebarWanted);
    }

    void ShowPane(bool open)
    {
        Split.IsPaneOpen = open;
        SidebarItem.IsChecked = open;
    }

    void OnSidebar(object sender, RoutedEventArgs e)
    {
        sidebarWanted = SidebarItem.IsChecked;
        ShowPane(sidebarWanted);
    }

    void OnPaneClosed(SplitView sender, object args) => SidebarItem.IsChecked = false;
}
