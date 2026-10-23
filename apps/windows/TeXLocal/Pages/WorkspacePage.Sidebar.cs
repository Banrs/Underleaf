using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;
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
    /// A file's hit count, a hit's line or a heading's words.
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
/// as VS Code's search view. Outline, words and hits are the core's (session_analyze, session_outline_current, session_search
/// and session_usages, which find the open document's unsaved edits).
public sealed partial class WorkspacePage
{
    readonly RenameFlyout rename = new();
    HashSet<string> expanded = [], folded = [];
    TreeNode[] tree = [];
    string treeJson = "", searched = "";
    /// The search's error, or what the replace before it did.
    string? searchNote;
    int searches;
    bool fileUnshown;
    Analysis? analysis;
    NavItem? currentHeading;
    /// The line whose heading the outline selects: the caret's, or the top line once a scroll passes a heading.
    int headingLine = 1;
    int? topHeading;
    bool caretScrolled;
    Task foldsSaved = Task.CompletedTask;

    TreeView[] SideTrees => [FilesTree, OutlineTree, ResultsTree];
    TreeNode? Picked => (FilesTree.SelectedItem as NavItem)?.Target as TreeNode;

    static string Glyph(string? kind) => kind switch { null => "\uE8B7", "tex" => "\uE8A5", "bib" => "\uE8F1", "image" => "\uE91B", "pdf" => "\uEA90", _ => "\uE7C3" };

    List<NavItem> Files(TreeNode[] nodes) => [.. nodes.Select(n => new NavItem
    {
        Lead = n.Name, Glyph = Glyph(n.Kind), Tip = n.Path, Key = n.Path, IsMain = n.Main,
        IsExpanded = expanded.Contains(n.Path), Target = n, Children = n.Children is { } c ? Files(c) : null,
    })];

    List<NavItem> Headings(OutlineNode[] nodes) => [.. nodes.Select(n => new NavItem
    {
        Lead = Title(n), Tip = Title(n), Trailing = $"{n.Words:N0}", Spoken = $"{Title(n)}, {WordCount(n.Words)}", Key = n.FoldKey,
        IsExpanded = !folded.Contains(n.FoldKey), Target = n, Children = n.Children is { } c ? Headings(c) : null,
    })];

    static string WordCount(int words) => words == 1 ? "1 word" : $"{words:N0} words";

    /// An empty heading by its level, in sentence case: "Untitled subsection".
    static string Title(OutlineNode n) => n.Untitled ? Sentence(n.Title) : n.Title;

    static List<NavItem> Results(SearchFile[] files) => [.. files.Select(f => new NavItem
    {
        Lead = f.File, Glyph = "\uE8A5", Trailing = $"{f.Hits.Length}", Tip = f.File, IsExpanded = true,
        Spoken = $"{f.File}, {f.Hits.Length} {(f.Hits.Length == 1 ? "result" : "results")}",
        Children = [.. f.Hits.Select(h => new NavItem
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

    /// The project's files. The watcher's tree after a RefreshTree is often the one it read, which shown again would take
    /// away a new file's row as its name is typed (core gap 24).
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
        FilesTree.Visibility = Vis(tab == FilesTab);
        OutlineTree.Visibility = Vis(tab == OutlineTab && outlined);
        ResultsTree.Visibility = Vis(tab == ResultsTab && hits);
        ResultsHeading.Visibility = Vis(tab == ResultsTab && ResultsHeading.Text.Length > 0);
        SelectCurrentHeading();
        SideNote.Text = tab == OutlineTab && !outlined ? Editor.Path is null ? "Open a file to see its outline." : "No sections in this document."
            : tab != ResultsTab || hits ? ""
            : searchNote ?? (searched.Length == 0 ? "Search the project with the box above (Ctrl+Shift+F)." : $"No results for “{searched}”.");
        SideNote.Visibility = Vis(SideNote.Text.Length > 0);
    }

    void OnSideTab(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        ShowSide();
        if (fileUnshown) SelectShownFile();
    }

    /// The open file selected in Files, as Explorer's tree follows the open document: once it's opened from the
    /// outline or a search, and only while Files shows, as for the outline.
    void SelectShownFile()
    {
        fileUnshown = FilesTree.Visibility != Visibility.Visible;
        if (fileUnshown || Editor.Path is not { } path || (FilesTree.SelectedItem as NavItem)?.Key == path) return;
        FilesTree.UpdateLayout();
        Select(FilesTree, i => i.Key == path);
    }

    void OnShowOutline(object sender, RoutedEventArgs e)
    {
        Split.IsPaneOpen = true;
        SideTabs.SelectedItem = OutlineTab;
        (OutlineTree.Visibility == Visibility.Visible ? (Control)OutlineTree : SideTabs).Focus(FocusState.Keyboard);
    }

    void OnExpanding(TreeView sender, TreeViewExpandingEventArgs args) => Fold(sender, (NavItem)args.Item, true);
    void OnCollapsed(TreeView sender, TreeViewCollapsedEventArgs args) => Fold(sender, (NavItem)args.Item, false);

    /// Folders open and headings folded, kept together in the project's UI state.
    void Fold(TreeView view, NavItem row, bool open)
    {
        row.IsExpanded = open;
        var changed = view == FilesTree ? (open ? expanded.Add(row.Key) : expanded.Remove(row.Key))
            : view == OutlineTree && (open ? folded.Remove(row.Key) : folded.Add(row.Key));
        if (changed) SaveFolds();
    }

    void SaveFolds() => foldsSaved = Core.CallAsync("set_ui_state", new { id, patch = new { expandedFolders = expanded.Order(), foldedHeadings = folded.Order() } });

    /// The project's UI state: as it opens, and after a rename, which moves the entry's paths.
    void ReadFolds(UiState ui)
    {
        expanded = [.. ui.ExpandedFolders];
        folded = [.. ui.FoldedHeadings];
    }

    void OnInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        switch ((args.InvokedItem as NavItem)?.Target)
        {
            case TreeNode { Type: not "dir" } node: Jump(node.Path, null); break;
            case OutlineNode { File: { } file } heading: Jump(file, heading.Line); break;
            case SearchHit hit: Jump(hit.File, hit.Line, hit.Column, hit.Length); break;
        }
    }

    // MARK: the outline

    /// The outline and words of the document the shown file is in, again after each save.
    void Analyze() => App.Run(null, async () =>
    {
        if (Editor.Path is not { } path) return;
        var found = await Core.CallAsync<Analysis>("session_analyze", new { session, path });
        if (Editor.Path != path) return;
        analysis = found;
        (OutlineTree.ItemsSource, currentHeading) = (Headings(found.Tree), null);
        ShowSide();
        ShowHeadings(found.HeadingStyles);
        CaretSettled();
    });

    /// The caret's heading, checked in Insert › Heading, and headingLine's, selected in the outline; the words, as Word's
    /// status bar counts them: the selection's of the document's while text is selected.
    void CaretSettled() => App.Run(null, async () =>
    {
        if (analysis is not { } shown || Editor.Path is not { } path) return;
        var words = WordCount(shown.Words);
        Words.Text = Editor.SelectedWords is { } selected ? $"{selected:N0} of {words}" : words;
        var line = Editor.Caret.Line;
        ShowInsertChecks(shown.Outline.FirstOrDefault(h => h.File == path && h.Line == line));
        var index = await Core.CallAsync<int?>("session_outline_current", new { session, path, line = headingLine });
        if (analysis != shown) return;
        currentHeading = Find(OutlineTree.ItemsSource as List<NavItem>, i => i.Target is OutlineNode n && n.Index == index);
        SelectCurrentHeading();
    });

    /// As on the Mac, the outline follows a scroll of the reader's only as the top line passes a heading, so a caret
    /// placed since keeps its heading until then.
    void ScrollSettled() => App.Run(null, async () =>
    {
        var reader = !caretScrolled;
        caretScrolled = false;
        if (analysis is not { } shown || Editor.Path is not { } path) return;
        var line = Editor.TopLine;
        var index = await Core.CallAsync<int?>("session_outline_current", new { session, path, line });
        if (analysis != shown || index == topHeading) return;
        topHeading = index;
        if (!reader) return;
        headingLine = line;
        CaretSettled();
    });

    /// Only while the outline shows: a hidden TreeView selects a row it hasn't drawn in name only, and selecting in
    /// one whose items were just replaced can crash it.
    void SelectCurrentHeading()
    {
        if (OutlineTree.Visibility != Visibility.Visible || OutlineTree.SelectedItem == currentHeading) return;
        OutlineTree.UpdateLayout();
        OutlineTree.SelectedItem = currentHeading;
    }

    // MARK: project search

    void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    {
        if (e.Reason == AutoSuggestionBoxTextChangeReason.UserInput) Restart(searchTimer);
    }

    void OnSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs e) => App.Run(null, async () =>
    {
        searchTimer.Stop();
        await RunSearch();
        if (ResultsTree.Visibility == Visibility.Visible) ResultsTree.Focus(FocusState.Keyboard);
    });

    void OnSearchKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Escape || Search.Text.Length == 0) return;
        Search.Text = "";
        _ = RunSearch();
        e.Handled = true;
    }

    void OnFindInProject(object sender, RoutedEventArgs e)
    {
        Split.IsPaneOpen = true;
        Search.Focus(FocusState.Keyboard);
    }

    /// The hits by file; a later search's answer wins over an earlier one's. After a replace, what it did is said in place
    /// of the count, and shown in place of no results.
    async Task RunSearch(string? replaced = null)
    {
        var query = Search.Text.Trim();
        var generation = ++searches;
        SearchFile[] files = [];
        string? error = null;
        if (query.Length > 0)
            try { files = await Core.CallAsync<SearchFile[]>("session_search", new { session, query }); }
            catch (CoreException ex) { error = ex.Message; }
        if (generation != searches) return;
        ShowResults(query, files, error ?? replaced);
    }

    /// Visual Studio's Find all references: each line that defines or uses the name at the caret, in Results under a
    /// heading naming it. Where no name is, nothing changes, as for Go to definition.
    void ShowUsages(int offset) => App.Run("Can't find references", async () =>
    {
        if (Editor.Path is not { } path) return;
        var generation = ++searches;
        var usages = await Core.CallAsync<Usages?>("session_usages", new { session, path, offset });
        if (usages is not null && generation == searches) ShowResults(usages.Name, usages.Groups, null, $"Usages of {usages.Name}");
    });

    /// Hits by file, said as their count or the note. A heading names what found them other than the box's search, whose
    /// matches Replace all would replace.
    void ShowResults(string query, SearchFile[] files, string? note, string heading = "")
    {
        (searched, searchNote) = (query, note);
        ResultsTree.ItemsSource = Results(files);
        ResultsHeading.Text = heading;
        ReplaceAll.IsEnabled = heading.Length == 0 && files.Length > 0;
        if (query.Length > 0)
        {
            Split.IsPaneOpen = true;
            SideTabs.SelectedItem = ResultsTab;
            Announce(Search, note ?? files.Sum(f => f.Hits.Length) switch { 0 => "No results", 1 => "1 result", var n => $"{n} results" }, "search");
        }
        ShowSide();
    }

    void OnReplaceToggle(object sender, RoutedEventArgs e)
    {
        var show = ReplaceRow.Visibility != Visibility.Visible;
        ReplaceRow.Visibility = Vis(show);
        ReplaceChevron.Glyph = show ? "\uE70D" : "\uE76C";
        if (show) ReplaceBox.Focus(FocusState.Keyboard);
    }

    /// VS Code's Replace All, of the matches the results show; the core writes the files not open, and the search runs again.
    void OnReplaceAll(object sender, RoutedEventArgs e) => App.Run("Can't replace", async () =>
    {
        var replacement = ReplaceBox.Text;
        var replaced = await Core.CallAsync<Replaced>("session_replace", new { session, query = searched, replacement });
        Editor.Apply(replaced.Edits);
        var count = replaced.Written.Sum(w => w.Count) + (replaced.Edits?.Edits.Length ?? 0);
        var files = replaced.Written.Length + (replaced.Edits is null ? 0 : 1);
        await RunSearch($"Replaced {count} {(count == 1 ? "occurrence" : "occurrences")} across {files} {(files == 1 ? "file" : "files")} with “{replacement}”.");
    });

    // MARK: files

    string TargetDir(NavItem? item) => item?.Target is TreeNode n ? n.Type == "dir" ? n.Path : ParentOf(n.Path) : "";

    static string ParentOf(string path) => path.LastIndexOf('/') is var i and > 0 ? path[..i] : "";

    static string Join(string dir, string name) => dir.Length == 0 ? name : $"{dir}/{name}";

    void OnFilesContext(UIElement sender, ContextRequestedEventArgs args) =>
        FilesTree.SelectedItem = (args.OriginalSource as FrameworkElement)?.DataContext as NavItem;

    /// The main file can't be deleted: setting another as the main file comes first. Set as the selection changes, not as
    /// the menu opens, since a disabled item's F2 or Delete doesn't fire.
    void ShowFileCommands()
    {
        var node = Picked;
        RenameItem.IsEnabled = RevealItem.IsEnabled = node is not null;
        DeleteItem.IsEnabled = node is { Main: false };
        MainItem.IsEnabled = node is { Kind: "tex", Main: false };
    }

    /// A new entry beside the selection, named in place as File Explorer's New folder is.
    void Create(string name, bool dir) => App.Run("Can't create this", async () =>
    {
        var parent = TargetDir(FilesTree.SelectedItem as NavItem);
        var made = (await Core.CallAsync("create_entry", new { id, path = Join(parent, name), dir })).GetProperty("path").GetString()!;
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
        App.Run("Can't set the main file", () => Core.CallAsync("session_set_settings", new { session, patch = new { mainFile = node.Path } }));
    }

    void OnRename(object sender, RoutedEventArgs e)
    {
        if (Picked is { } node && FilesTree.ContainerFromItem(FilesTree.SelectedItem) is FrameworkElement row) Rename(node, row);
    }

    /// The core's refusal shows in the flyout. A rename above the main file moves it, and the folders open move with
    /// it; the answer is null if the files couldn't be saved first.
    void Rename(TreeNode node, FrameworkElement row) => rename.Show(row, node.Name, async name =>
    {
        var to = Join(ParentOf(node.Path), name);
        // The core takes a session's service commands in no set order, and the rename moves the folds this wrote; a
        // write that failed doesn't stop it.
        await Task.WhenAny(foldsSaved);
        if (await Core.CallAsync("session_rename", new { session, from = node.Path, to }) is { ValueKind: JsonValueKind.Object } renamed)
            ReadFolds(renamed.GetProperty("ui").Deserialize<UiState>(Core.Json)!);
        await RefreshTree();
        Select(FilesTree, i => i.Key == to);
    });

    void OnReveal(object sender, RoutedEventArgs e)
    {
        if (Picked is { } node) App.Reveal(Full(node.Path), select: true);
    }

    void OnDelete(object sender, RoutedEventArgs e)
    {
        if (Picked is not { Main: false } node) return;
        App.Run("Can't delete this", async () =>
        {
            // Not ready: a save it needed is asked about, and nothing is deleted.
            var prepared = await Core.CallAsync("session_prepare_delete", new { session, path = node.Path });
            if (!prepared.GetProperty("ready").GetBoolean()) return;
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

    string? KindOf(string path) => (Find(FilesTree.ItemsSource as List<NavItem>, i => i.Key == path)?.Target as TreeNode)?.Kind;

    /// A file dragged to the editor, as on the Mac; a folder, which a drop there does nothing with, isn't dragged.
    void OnFilesDrag(TreeView sender, TreeViewDragItemsStartingEventArgs args)
    {
        if (args.Items.Count == 1 && args.Items[0] is NavItem { Target: TreeNode { Type: not "dir" } node })
        {
            args.Data.SetData(SourceView.FileFormat, Full(node.Path));
            args.Data.RequestedOperation = DataPackageOperation.Copy;
        }
        else args.Cancel = true;
    }

    /// The first file of this project decides, as on the Mac: a figure goes in where it was dropped; another file opens.
    void OnFilesDropped(string[] paths, int at) => App.Run(null, async () =>
    {
        foreach (var path in paths)
        {
            if (await Core.CallAsync<Located?>("locate", new { path }) is not { Path.Length: > 0 } found || found.Id != id || KindOf(found.Path) is not { } kind)
                continue;
            if (Source.SyntaxCall<JsonElement>("drop_text", new { path = found.Path, kind, into = KindOf(Editor.Path!) }) is { ValueKind: JsonValueKind.Object } drop
                && drop.TryGetProperty("insert", out var insert))
                Editor.InsertDropped(at, insert.GetString()!);
            else await OpenDocument(found.Path, kind);
            return;
        }
    });

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems)) e.AcceptedOperation = DataPackageOperation.Copy;
    }

    /// Files dropped from File Explorer, into the folder they're dropped on.
    void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var dir = TargetDir((e.OriginalSource as FrameworkElement)?.DataContext as NavItem);
        App.Run("Can't add these files", async () => await AddFiles(dir, await App.Dropped(e)));
    }

    /// Beside the selection, as New file.
    void OnAddFiles(object sender, RoutedEventArgs e) => App.Run("Can't add these files", async () =>
    {
        var picked = await new FileOpenPicker(App.Window.AppWindow.Id).PickMultipleFilesAsync();
        if (picked.Count > 0) await AddFiles(TargetDir(FilesTree.SelectedItem as NavItem), [.. picked.Select(f => f.Path)]);
    });

    /// Copies of other files into a folder of the project; a clash asks as File Explorer does.
    async Task AddFiles(string dir, string[] paths)
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
    }
}
