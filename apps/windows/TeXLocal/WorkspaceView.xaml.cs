using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;

namespace TeXLocal;

/// <summary>
/// An open project: menus and toolbar, the sidebar, the editor, and the PDF
/// or the compile log beside it. It renders a ProjectModel and sends every
/// action through the window's commands.
/// </summary>
public sealed partial class WorkspaceView : UserControl
{
    private static MainWindow Main => MainWindow.Instance;

    private ProjectModel? project;
    private readonly Splitter sidebarSplitter;
    private readonly Splitter previewSplitter;
    private GridLength sidebarWidth = new(260);
    private GridLength previewWidth = new(1, GridUnitType.Star);
    private readonly Dictionary<MenuCommand, MenuFlyoutItem> menuItems = [];

    /// <summary>The menu bar, after web/src/commands.js MENU.</summary>
    private static readonly (string Title, MenuCommand?[] Items)[] MenuLayout =
    [
        ("File", [
            MenuCommand.ProjectNew, null,
            MenuCommand.FileNew, MenuCommand.FileNewFolder, MenuCommand.FileUpload, null,
            MenuCommand.FileSave, null,
            MenuCommand.ProjectClose, null,
            MenuCommand.PdfSave, MenuCommand.ProjectExport, null,
            MenuCommand.AppSettings,
        ]),
        ("Edit", [
            MenuCommand.EditUndo, MenuCommand.EditRedo, null,
            MenuCommand.EditFind, MenuCommand.ProjectSearch, MenuCommand.PdfFind, MenuCommand.EditGotoLine, null,
            MenuCommand.EditBold, MenuCommand.EditItalic, MenuCommand.EditMath, MenuCommand.EditComment,
        ]),
        ("View", [
            MenuCommand.ViewToggleSidebar, MenuCommand.ViewTogglePdf, MenuCommand.ViewToggleLogs, null,
            MenuCommand.ViewZoomIn, MenuCommand.ViewZoomOut, MenuCommand.ViewFitWidth, MenuCommand.ViewFitHeight,
        ]),
        ("Compile", [
            MenuCommand.CompileRun, MenuCommand.CompileToggleAuto, null,
            MenuCommand.SyncForward, MenuCommand.SyncInverse,
        ]),
    ];

    /// <summary>web/src/workspace.js INSERT_TEMPLATES; "$0" marks where the cursor lands.</summary>
    private static readonly (string Label, string Template)[] InsertTemplates =
    [
        ("Figure", "\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n"),
        ("Table", "\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n"),
        ("Equation", "\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n"),
        ("Align (multi-line math)", "\\begin{align}\n  $0 \\\\\n\\end{align}\n"),
        ("Bulleted List", "\\begin{itemize}\n  \\item $0\n\\end{itemize}\n"),
        ("Numbered List", "\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n"),
        ("Code Block", "\\begin{verbatim}\n$0\n\\end{verbatim}\n"),
    ];

    public WorkspaceView()
    {
        InitializeComponent();
        EditorHost.Children.Insert(0, Main.Editor.View);

        sidebarSplitter = new Splitter(SidebarColumn, targetIsBefore: true, minimum: 160);
        sidebarSplitter.Resized += width => sidebarWidth = new GridLength(width);
        Grid.SetColumn(sidebarSplitter, 1);
        previewSplitter = new Splitter(PreviewColumn, targetIsBefore: false, minimum: 240);
        previewSplitter.Resized += width => previewWidth = new GridLength(width);
        Grid.SetColumn(previewSplitter, 3);
        Panes.Children.Add(sidebarSplitter);
        Panes.Children.Add(previewSplitter);

        BuildMenu();
        foreach (var (label, template) in InsertTemplates)
        {
            InsertMenu.Items.Add(ContextMenus.Item(label, () => Format("insert", template)));
        }
        Pdf.Command = command => Main.Perform(command);
    }

    // ---------- the project ----------

    internal void Attach(ProjectModel model)
    {
        project = model;
        Pdf.Project = Logs.Project = model;
        model.PropertyChanged += OnModelChanged;
        SearchBox.Text = "";
        Files.ItemsSource = null;
        RenderTree();
        RenderOutline();
        Logs.Render();
        Pdf.ShowEmpty(model.TexAvailable);
        Render();
    }

    internal void Detach()
    {
        if (project is null)
        {
            return;
        }
        project.PropertyChanged -= OnModelChanged;
        project = null;
        Pdf.Project = Logs.Project = null;
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ProjectModel.Tree):
            case nameof(ProjectModel.Settings):
                RenderTree();
                break;
            case nameof(ProjectModel.OpenPath):
                SelectOpenFile();
                break;
            case nameof(ProjectModel.Sections):
                RenderOutline();
                break;
            case nameof(ProjectModel.SearchHits):
                RenderResults();
                break;
            case nameof(ProjectModel.Result):
                Logs.Render();
                break;
            case nameof(ProjectModel.PdfVersion):
                if (project is { PdfPath: { } path, PdfVersion: > 0 } p)
                {
                    _ = Pdf.LoadAsync(path, p.PdfVersion);
                }
                break;
            case nameof(ProjectModel.Highlight):
                if (project?.Highlight is { } loc)
                {
                    Pdf.Highlight(loc);
                }
                break;
        }
        Render();
    }

    /// <summary>TeX was found or lost: the PDF pane says what to do about it.</summary>
    internal void TexChanged()
    {
        if (project is { PdfVersion: 0 } p)
        {
            Pdf.ShowEmpty(p.TexAvailable);
        }
        Render();
    }

    internal void SetTheme(bool dark) => Pdf.SetTheme(dark);

    internal void FocusSearch() => SearchBox.Focus(FocusState.Programmatic);

    // ---------- rendering ----------

    /// <summary>Everything cheap to recompute: states, badges, layout, the menus.</summary>
    internal void Render()
    {
        if (project is not { } p)
        {
            return;
        }
        Main.UpdateTitle();

        CompileButton.IsEnabled = p.TexAvailable && !p.Compiling;
        CompileProgress.IsActive = p.Compiling;
        CompileIcon.Visibility = p.Compiling ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(CompileButton, p.TexAvailable ? "Compile (Ctrl+Enter)" : "Install TeX to compile");
        var engine = p.Settings?.Engine ?? "pdflatex";
        EnginePdf.IsChecked = engine == "pdflatex";
        EngineXe.IsChecked = engine == "xelatex";
        EngineLua.IsChecked = engine == "lualatex";
        EngineLabel.Text = EngineName(engine);
        AutoCompileItem.IsChecked = Main.Preferences.AutoCompile;

        ErrorBadge.Value = p.ErrorCount;
        ErrorBadge.Visibility = p.ErrorCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        LogButton.IsChecked = p.ShowLogs;
        ToolTipService.SetToolTip(LogButton, p.Result is null
            ? "Compile Log (Ctrl+Shift+L)"
            : $"Compile Log — {Count(p.ErrorCount, "error")}, {Count(p.WarningCount, "warning")}");
        PdfToggle.IsChecked = Main.Preferences.PdfVisible;
        SavePdfItem.IsEnabled = Main.IsEnabled(MenuCommand.PdfSave);
        EditorPlaceholder.Visibility = p.OpenPath is null ? Visibility.Visible : Visibility.Collapsed;

        Layout();
        foreach (var (command, item) in menuItems)
        {
            item.IsEnabled = Main.IsEnabled(command);
            if (item is ToggleMenuFlyoutItem toggle)
            {
                toggle.IsChecked = Main.IsChecked(command);
            }
        }
    }

    private static string Count(int n, string noun) => n == 1 ? $"1 {noun}" : $"{n} {noun}s";

    private static string EngineName(string engine) => engine switch
    {
        "xelatex" => "XeLaTeX",
        "lualatex" => "LuaLaTeX",
        _ => "pdfLaTeX",
    };

    /// <summary>Which panes show: the sidebar, and the PDF or the log beside the editor.</summary>
    private void Layout()
    {
        var sidebar = Main.Preferences.SidebarVisible;
        Sidebar.Visibility = sidebarSplitter.Visibility = sidebar ? Visibility.Visible : Visibility.Collapsed;
        SidebarColumn.Width = sidebar ? sidebarWidth : new GridLength(0);

        var logs = project?.ShowLogs == true;
        var preview = logs || Main.Preferences.PdfVisible;
        Preview.Visibility = previewSplitter.Visibility = preview ? Visibility.Visible : Visibility.Collapsed;
        PreviewColumn.Width = preview ? previewWidth : new GridLength(0);
        Logs.Visibility = logs ? Visibility.Visible : Visibility.Collapsed;
        Pdf.Visibility = logs ? Visibility.Collapsed : Visibility.Visible;
    }

    private void BuildMenu()
    {
        foreach (var (title, items) in MenuLayout)
        {
            var menu = new MenuBarItem { Title = title };
            foreach (var entry in items)
            {
                if (entry is not { } command)
                {
                    menu.Items.Add(new MenuFlyoutSeparator());
                    continue;
                }
                MenuFlyoutItem item = MainWindow.IsToggle(command) ? new ToggleMenuFlyoutItem() : new MenuFlyoutItem();
                item.Text = command.Title();
                if (command.Accel() is { } accel && (command.ClaimsChord() || command.IsTextEditing()))
                {
                    // The chord itself is the window's; the menu only shows it.
                    item.KeyboardAcceleratorTextOverride = Accelerators.Label(accel);
                }
                item.Click += (_, _) => Main.Perform(command);
                menu.Items.Add(item);
                menuItems[command] = item;
            }
            Menu.Items.Add(menu);
        }
    }

    private List<FileItem> FileItems => Files.ItemsSource as List<FileItem> ?? [];

    private void RenderTree()
    {
        if (project is null)
        {
            return;
        }
        // Folders the reader opened stay open across a reload of the tree.
        var expanded = FileItems.SelectMany(i => i.SelfAndDescendants())
            .Where(i => i.IsExpanded).Select(i => i.Node.Path).ToHashSet();
        var mainFile = project.Settings?.MainFile;
        Files.ItemsSource = project.Tree.Select(n => new FileItem(n, mainFile, expanded)).ToList();
        SelectOpenFile();
    }

    private void SelectOpenFile()
    {
        var open = project?.OpenPath;
        if (FileItems.SelectMany(i => i.SelfAndDescendants()).FirstOrDefault(i => i.Node.Path == open) is { } item)
        {
            Files.SelectedItem = item;
        }
    }

    private void RenderOutline()
    {
        var rows = project?.Sections.Select(s => new OutlineRow(s)).ToList() ?? [];
        OutlineList.ItemsSource = rows;
        OutlineHeader.Visibility = OutlineList.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RenderResults()
    {
        var hits = project?.SearchHits ?? [];
        Results.ItemsSource = hits;
        ResultsHeader.Text = Count(hits.Count, "result");
    }

    // ---------- toolbar ----------

    private void Format(string name, string? arg = null)
    {
        project?.Format(name, arg);
        Main.Editor.Focus();
    }

    private void OnBack(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.ProjectClose);

    private void OnBold(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditBold);

    private void OnItalic(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditItalic);

    private void OnMath(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditMath);

    private void OnCompile(SplitButton sender, SplitButtonClickEventArgs args) => Main.Perform(MenuCommand.CompileRun);

    private void OnEngine(object sender, RoutedEventArgs e)
    {
        if (project is not null && sender is FrameworkElement { Tag: string engine } && engine != project.Settings?.Engine)
        {
            _ = project.SetEngineAsync(engine);
        }
    }

    private void OnAutoCompile(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.CompileToggleAuto);

    private void OnToggleLogs(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.ViewToggleLogs);

    private void OnTogglePdf(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.ViewTogglePdf);

    private void OnSavePdf(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.PdfSave);

    private void OnExportZip(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.ProjectExport);

    // ---------- sidebar ----------

    private void OnNewFile(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.FileNew);

    private void OnNewFolder(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.FileNewFolder);

    private void OnAddFiles(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.FileUpload);

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (project is not null)
        {
            project.SearchQuery = sender.Text;
        }
        var searching = !string.IsNullOrWhiteSpace(sender.Text);
        Browse.Visibility = searching ? Visibility.Collapsed : Visibility.Visible;
        Results.Visibility = searching ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape)
        {
            SearchBox.Text = "";
            e.Handled = true;
        }
    }

    private void OnResultClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is SearchHit hit && project is not null)
        {
            _ = project.OpenAsync(hit.File, hit.Line);
        }
    }

    private void OnOutlineClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is OutlineRow row && project is not null)
        {
            project.Reveal(row.Line);
            Main.Editor.Focus();
        }
    }

    private void OnFileInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        // Folders expand and collapse on their own.
        if (args.InvokedItem is FileItem { Node.IsDirectory: false } item && project is not null)
        {
            _ = project.OpenAsync(item.Node.Path);
        }
    }

    private void OnFileContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if (project is not { } p
            || ContextMenus.Row<TreeViewItem>(e.OriginalSource) is not { } row
            || Files.ItemFromContainer(row) is not FileItem { Node: var node })
        {
            return;
        }
        var menu = new MenuFlyout();
        if (!node.IsDirectory && node.Path.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) && node.Path != p.Settings?.MainFile)
        {
            menu.Items.Add(ContextMenus.Item("Set as Main File", () => _ = p.SetMainFileAsync(node.Path)));
            menu.Items.Add(new MenuFlyoutSeparator());
        }
        menu.Items.Add(ContextMenus.Item("Rename…", () => _ = RenameAsync(p, node)));
        menu.Items.Add(ContextMenus.Item("Show in File Explorer", () => _ = p.RevealAsync(node.Path)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(ContextMenus.Item("Delete…", () => _ = DeleteAsync(p, node)));
        ContextMenus.Show(menu, row, e);
    }

    private async Task RenameAsync(ProjectModel p, TreeNode node)
    {
        if (await Dialogs.PromptAsync(XamlRoot, $"Rename “{node.Name}”", "Path", "Rename", node.Path) is { } to)
        {
            await p.RenameEntryAsync(node.Path, to);
        }
    }

    private async Task DeleteAsync(ProjectModel p, TreeNode node)
    {
        // Refuse before asking, not after the user has already confirmed.
        if (ProjectPaths.Contains(node.Path, p.Settings?.MainFile))
        {
            Main.Report("Choose a different main file before deleting this entry.");
            return;
        }
        var what = node.IsDirectory ? "This folder and everything inside it" : "This file";
        if (await Dialogs.ConfirmAsync(XamlRoot, $"Delete “{node.Name}”?", $"{what} will be moved to the Recycle Bin.", "Delete"))
        {
            await p.DeleteEntryAsync(node.Path);
        }
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (project is not null && e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Add to project";
        }
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (project is not { } p || !e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }
        var deferral = e.GetDeferral();
        List<string> paths;
        try
        {
            paths = (await e.DataView.GetStorageItemsAsync()).Select(i => i.Path).Where(path => path.Length > 0).ToList();
        }
        finally
        {
            deferral.Complete();
        }
        await p.ImportFilesAsync(paths);
    }
}
