using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// An open project, laid out as apps/macos lays it out after Xcode and
/// Overleaf: files and the outline in the sidebar; the source — a writer's
/// tools and its location over it — beside the PDF; a panel for the build
/// below them, a status bar along the foot, and an inspector at the trailing
/// edge. It renders a ProjectModel and sends every action through the
/// window's commands.
/// </summary>
public sealed partial class WorkspaceView : UserControl
{
    private static MainWindow Main => MainWindow.Instance;

    private ProjectModel? project;
    private readonly Splitter sidebarSplitter;
    private readonly Splitter previewSplitter;
    private readonly Splitter panelSplitter;
    private readonly Splitter inspectorSplitter;

    // The limits the panes keep, after macOS's (parity C19, E19, F12, H1).
    private const double SidebarMinimum = 200;
    private const double SidebarMaximum = 360;
    private const double PaneMinimum = 240;
    private const double PanelMinimum = 80;
    private const double EditorsMinimum = 120;
    private const double InspectorMinimum = 220;
    private const double InspectorMaximum = 320;

    // The layout as the reader last dragged it, remembered in Preferences.
    private double sidebarWidth;
    private double pdfSplit;
    private double panelHeight;
    private double inspectorWidth;

    private readonly Dictionary<MenuCommand, MenuFlyoutItem> menuItems = [];
    private readonly List<MenuFlyoutItemBase> latexMenuItems = [];
    private readonly List<RadioMenuFlyoutItem> engineMenuItems = [];
    private MenuFlyoutSubItem? engineMenu;

    /// <summary>
    /// The menu bar, after web/src/commands.js MENU, with the Format menu
    /// macOS keeps and the items every Windows menu bar has: Exit, the
    /// clipboard, full screen.
    /// </summary>
    private static readonly (string Title, MenuCommand?[] Items)[] MenuLayout =
    [
        ("File", [
            MenuCommand.ProjectNew, MenuCommand.FileNew, MenuCommand.FileNewFolder, null,
            MenuCommand.FileUpload, MenuCommand.FileUploadFolder, null,
            MenuCommand.FileSave, null,
            MenuCommand.PdfSave, MenuCommand.PdfShare, MenuCommand.ProjectExport, null,
            MenuCommand.AppSettings, null,
            MenuCommand.ProjectClose, MenuCommand.AppExit,
        ]),
        ("Edit", [
            MenuCommand.EditUndo, MenuCommand.EditRedo, null,
            MenuCommand.EditCut, MenuCommand.EditCopy, MenuCommand.EditPaste, MenuCommand.EditSelectAll, null,
            MenuCommand.EditFind, MenuCommand.EditFindNext, MenuCommand.EditFindPrevious, MenuCommand.ProjectSearch, MenuCommand.PdfFind, MenuCommand.EditGotoLine,
        ]),
        // Where Windows text apps keep styling, and what the source bar's
        // Heading, Reference and Insert menus hold.
        ("Format", [
            MenuCommand.EditBold, MenuCommand.EditItalic, MenuCommand.EditMath, null,
            null,
            MenuCommand.EditComment,
        ]),
        ("View", [
            MenuCommand.ViewToggleSidebar, MenuCommand.ViewTogglePdf, MenuCommand.ViewToggleLogs, MenuCommand.ViewToggleInspector, null,
            MenuCommand.ViewZoomIn, MenuCommand.ViewZoomOut, MenuCommand.ViewFitWidth, MenuCommand.ViewFitHeight, null,
            MenuCommand.ViewUiScaleUp, MenuCommand.ViewUiScaleDown, null,
            MenuCommand.ViewFullScreen,
        ]),
        ("Compile", [
            MenuCommand.CompileRun, MenuCommand.CompileStop, MenuCommand.CompileToggleAuto, null,
            MenuCommand.SyncForward, MenuCommand.SyncInverse,
        ]),
    ];

    public WorkspaceView()
    {
        InitializeComponent();
        EditorHost.Children.Insert(0, Main.Editor.View);

        var preferences = Main.Preferences;
        sidebarWidth = Math.Clamp(preferences.SidebarWidth ?? 280, SidebarMinimum, SidebarMaximum);
        pdfSplit = Math.Clamp(preferences.PdfSplit ?? 0.5, 0.1, 0.9);
        panelHeight = Math.Max(preferences.PanelHeight ?? 220, PanelMinimum);
        inspectorWidth = Math.Clamp(preferences.InspectorWidth ?? 260, InspectorMinimum, InspectorMaximum);

        // Added last, so each grip lies over the panes it overhangs. The
        // content layer's own edge is the line beside the sidebar.
        sidebarSplitter = new Splitter(SidebarColumn, targetIsBefore: true, SidebarMinimum, () => SidebarMaximum, "Resize the sidebar", line: false);
        sidebarSplitter.Resized += width => sidebarWidth = width;
        sidebarSplitter.Committed += () => Remember(p => p.SidebarWidth = sidebarWidth);
        Grid.SetColumn(sidebarSplitter, 1);
        Panes.Children.Add(sidebarSplitter);
        // The PDF keeps its share of the width as the window resizes.
        previewSplitter = new Splitter(PreviewColumn, targetIsBefore: false, PaneMinimum, () => Document.ActualWidth - PaneMinimum, "Resize the PDF");
        previewSplitter.Resized += width =>
        {
            if (Document.ActualWidth > 0)
            {
                pdfSplit = width / Document.ActualWidth;
                Layout();
            }
        };
        previewSplitter.Committed += () => Remember(p => p.PdfSplit = pdfSplit);
        Grid.SetColumn(previewSplitter, 1);
        Document.Children.Add(previewSplitter);
        panelSplitter = new Splitter(PanelRow, targetIsBefore: false, PanelMinimum, () => Editors.ActualHeight - EditorsMinimum, "Resize the panel");
        panelSplitter.Resized += height => panelHeight = height;
        panelSplitter.Committed += () => Remember(p => p.PanelHeight = panelHeight);
        Grid.SetRow(panelSplitter, 1);
        Editors.Children.Add(panelSplitter);
        inspectorSplitter = new Splitter(InspectorColumn, targetIsBefore: false, InspectorMinimum, () => InspectorMaximum, "Resize the details pane");
        inspectorSplitter.Resized += width => inspectorWidth = width;
        inspectorSplitter.Committed += () => Remember(p => p.InspectorWidth = inspectorWidth);
        Grid.SetColumn(inspectorSplitter, 1);
        Layer.Children.Add(inspectorSplitter);

        BuildMenu();
        AddTemplates(HeadingMenu.Items, LatexTemplates.Headings);
        AddInserts(InsertMenu.Items);
        MathIcon.Data = MathGeometry();
        Pdf.Command = command => Main.Perform(command);
        Main.WatchTextFocus();
    }

    /// <summary>Keep a dragged length for the next launch.</summary>
    private static void Remember(Action<Preferences> set)
    {
        set(Main.Preferences);
        Main.SavePreferences();
    }

    // ---------- the project ----------

    internal void Attach(ProjectModel model)
    {
        project = model;
        Pdf.Project = Logs.Project = model;
        model.PropertyChanged += OnModelChanged;
        Main.SearchBox.Text = "";
        Files.ItemsSource = null;
        collapsedSections.Clear();
        shownSections = null;
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
            case nameof(ProjectModel.CursorLine):
                // On every cursor move: only the location follows it.
                RenderLocation();
                return;
            case nameof(ProjectModel.Tree):
            case nameof(ProjectModel.Settings):
                RenderTree();
                break;
            case nameof(ProjectModel.OpenPath):
                SelectOpenFile();
                break;
            case nameof(ProjectModel.Stats):
                RenderOutline();
                break;
            case nameof(ProjectModel.SearchHits):
                RenderResults();
                break;
            case nameof(ProjectModel.Result):
            case nameof(ProjectModel.PanelTab):
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

    internal void SetAppearance(bool dark, string accent, bool darkPaper) => Pdf.SetAppearance(dark, accent, darkPaper);

    // ---------- rendering ----------

    /// <summary>Everything cheap to recompute: states, counts, layout, the menus.</summary>
    internal void Render()
    {
        RenderMenus();
        if (project is not { } p)
        {
            return;
        }
        // The title bar names the open file.
        Main.UpdateTitle();

        SetToggle(Main.PdfToggle, MenuCommand.ViewTogglePdf, "PDF");
        SetToggle(Main.InspectorToggle, MenuCommand.ViewToggleInspector, "details pane");
        SetToggle(PanelToggle, MenuCommand.ViewToggleLogs, "panel");

        UndoButton.IsEnabled = RedoButton.IsEnabled = p.OpenPath is not null;
        // A writer's tools are LaTeX's; another text file keeps only its
        // history. Render runs on every edit, so the bar folds again only
        // when that changes (or its width does).
        if (IsTex(p.OpenPath) != latexTools)
        {
            latexTools = !latexTools;
            FoldSourceBar();
        }
        EditorPlaceholder.Visibility = p.OpenPath is null ? Visibility.Visible : Visibility.Collapsed;

        Pdf.Render(p, Main.IsEnabled(MenuCommand.CompileRun));
        if (Main.Preferences.InspectorVisible)
        {
            Inspector.Render(p);
        }
        RenderStatusBar(p);
        RenderLocation();
        Layout();
    }

    private static bool IsTex(string? path) => path?.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) == true;

    /// <summary>
    /// The menu bar for the screen showing: what can run now, what is on, and
    /// the LaTeX items only for a .tex file. The window calls this as the
    /// screen changes, with or without a project open.
    /// </summary>
    internal void RenderMenus()
    {
        foreach (var (command, item) in menuItems)
        {
            item.IsEnabled = Main.IsEnabled(command);
            if (item is ToggleMenuFlyoutItem toggle)
            {
                toggle.IsChecked = Main.IsChecked(command);
            }
        }
        // Bold is enabled exactly while a document is open on screen.
        var latex = Main.IsEnabled(MenuCommand.EditBold) && IsTex(project?.OpenPath);
        foreach (var item in latexMenuItems)
        {
            item.IsEnabled = latex;
        }
        if (engineMenu is not null)
        {
            engineMenu.IsEnabled = Main.IsEnabled(MenuCommand.CompileToggleAuto);
        }
        var engine = project?.Settings?.Engine ?? "pdflatex";
        foreach (var item in engineMenuItems)
        {
            item.IsChecked = (string)item.Tag == engine;
        }
    }

    /// <summary>A pane's toggle: on while it shows, and a tooltip saying what a click does.</summary>
    private static void SetToggle(ToggleButton toggle, MenuCommand command, string pane)
    {
        var shown = Main.IsChecked(command);
        toggle.IsChecked = shown;
        var tip = $"{(shown ? "Hide" : "Show")} {pane} ({Accelerators.Label(command.Accel()!)})";
        PdfPane.SetToolTip(toggle, tip);
        AutomationProperties.SetHelpText(toggle, tip);
    }

    private void RenderStatusBar(ProjectModel p)
    {
        BuildProgress.IsActive = p.Compiling;
        BuildProgress.Visibility = p.Compiling ? Visibility.Visible : Visibility.Collapsed;
        BuildSucceeded.Visibility = !p.Compiling && p.Result is { Ok: true } ? Visibility.Visible : Visibility.Collapsed;
        BuildFailed.Visibility = !p.Compiling && p.Result is { Ok: false } ? Visibility.Visible : Visibility.Collapsed;
        BuildText.Text = p.Compiling ? "Compiling…"
            : p.Result is { Ok: true } ok ? $"Compiled in {ok.DurationMs / 1000.0:0.0} s"
            : p.Result is not null ? "Build failed"
            // A PDF from an earlier session is on screen, but no build from this one.
            : p.PdfVersion > 0 ? "Ready" : "Not compiled";
        ErrorCount.Visibility = p.ErrorCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        ErrorCountText.Text = $"{p.ErrorCount:N0}";
        WarningCount.Visibility = p.WarningCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        WarningCountText.Text = $"{p.WarningCount:N0}";
        AutomationProperties.SetName(BuildStatus, $"{BuildText.Text}, {Count(p.ErrorCount, "error")}, {Count(p.WarningCount, "warning")}");

        Show(StatusText, p.OpenPath is null ? "" : p.Saving ? "Saving…" : p.Dirty ? "Unsaved changes" : "Saved");
        Show(CountsText, Main.Preferences.ShowWordCount && p.Stats is { } stats
            ? $"{Count(stats.Words, "word")} · {Count(stats.Lines, "line")}"
            : "");
        EngineText.Text = p.TexAvailable ? LatexTemplates.EngineName(p.Settings?.Engine ?? "pdflatex") : "No TeX";
        EngineWarning.Visibility = p.TexAvailable ? Visibility.Collapsed : Visibility.Visible;
        PdfPane.SetToolTip(EngineStatus, p.TexAvailable ? "Choose the engine" : "TeX wasn’t found: open Settings");
        AutomationProperties.SetName(EngineStatus, $"Engine: {EngineText.Text}");
    }

    private static string Count(int n, string noun) => n == 1 ? $"1 {noun}" : $"{n:N0} {noun}s";

    /// <summary>A status-bar text, collapsed while empty so it leaves no gap.</summary>
    private static void Show(TextBlock block, string text)
    {
        block.Text = text;
        block.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Which panes show, at the sizes the reader last dragged them to.</summary>
    private void Layout()
    {
        var sidebar = Main.Preferences.SidebarVisible;
        // Each pane comes in from the edge it's docked to.
        Motion.Show(Sidebar, sidebar, Motion.Pane(-40, 0));
        sidebarSplitter.Visibility = Sidebar.Visibility;
        SidebarColumn.Width = new GridLength(sidebar ? sidebarWidth : 0);
        // Without the sidebar the layer meets the window's edge: no corner.
        Layer.CornerRadius = sidebar ? new CornerRadius(8, 0, 0, 0) : new CornerRadius(0);
        Layer.BorderThickness = sidebar ? new Thickness(1, 1, 0, 0) : new Thickness(0, 1, 0, 0);

        var pdf = Main.Preferences.PdfVisible;
        Pdf.Visibility = previewSplitter.Visibility = pdf ? Visibility.Visible : Visibility.Collapsed;
        // Shares of the width rather than lengths, so the split holds as
        // the window resizes.
        PreviewColumn.MinWidth = pdf ? PaneMinimum : 0;
        PreviewColumn.Width = new GridLength(pdf ? pdfSplit : 0, GridUnitType.Star);
        SourceColumn.Width = new GridLength(pdf ? 1 - pdfSplit : 1, GridUnitType.Star);

        var panel = project?.ShowLogs == true;
        Motion.Show(Logs, panel, Motion.Pane(0, 40));
        panelSplitter.Visibility = Logs.Visibility;
        // A height remembered from a taller window leaves the editors theirs.
        var height = Editors.ActualHeight > 0
            ? Math.Min(panelHeight, Math.Max(PanelMinimum, Editors.ActualHeight - EditorsMinimum))
            : panelHeight;
        PanelRow.Height = new GridLength(panel ? height : 0);

        var inspector = Main.Preferences.InspectorVisible;
        Motion.Show(Inspector, inspector, Motion.Pane(40, 0));
        inspectorSplitter.Visibility = Inspector.Visibility;
        InspectorColumn.Width = new GridLength(inspector ? inspectorWidth : 0);
    }

    // ---------- menus ----------

    private void BuildMenu()
    {
        var menuKeys = AccessKeys.Assign(MenuLayout.Select(m => m.Title).ToList());
        for (var m = 0; m < MenuLayout.Length; m++)
        {
            var (title, items) = MenuLayout[m];
            var menu = new MenuBarItem { Title = title, AccessKey = menuKeys[m] };
            var commands = items.OfType<MenuCommand>().ToList();
            var keys = AccessKeys.Assign(commands.Select(c => c.Title()).ToList());
            var separators = 0;
            foreach (var entry in items)
            {
                if (entry is not { } command)
                {
                    // Format's second break holds what the source bar inserts.
                    if (title == "Format" && ++separators == 2)
                    {
                        AddFormatTemplates(menu.Items);
                    }
                    menu.Items.Add(new MenuFlyoutSeparator());
                    continue;
                }
                MenuFlyoutItem item = MainWindow.IsToggle(command) ? new ToggleMenuFlyoutItem() : new MenuFlyoutItem();
                item.Text = command.Title();
                item.AccessKey = keys[commands.IndexOf(command)];
                if (command.Accel() is { } accel && (command.ClaimsChord() || command.IsTextEditing()))
                {
                    // The chord itself is the window's; the menu only shows it.
                    item.KeyboardAcceleratorTextOverride = Accelerators.Label(accel);
                }
                item.Click += (_, _) => Main.Perform(command);
                menu.Items.Add(item);
                menuItems[command] = item;
                if (command == MenuCommand.CompileToggleAuto)
                {
                    engineMenu = EngineMenu();
                    menu.Items.Add(engineMenu);
                }
            }
            Main.Menu.Items.Add(menu);
        }
    }

    private void AddFormatTemplates(IList<MenuFlyoutItemBase> items)
    {
        foreach (var submenu in new[]
        {
            Submenu("Heading", LatexTemplates.Headings),
            Submenu("Reference", LatexTemplates.References),
            Submenu("List", LatexTemplates.Lists),
        })
        {
            items.Add(submenu);
            latexMenuItems.Add(submenu);
        }
        items.Add(new MenuFlyoutSeparator());
        foreach (var (label, template) in LatexTemplates.Environments)
        {
            var item = ContextMenus.Item(label, () => Format("insert", template));
            items.Add(item);
            latexMenuItems.Add(item);
        }
    }

    /// <summary>The engine a project compiles with, in the Compile menu as in the status bar.</summary>
    private MenuFlyoutSubItem EngineMenu()
    {
        var submenu = new MenuFlyoutSubItem { Text = "Engine" };
        AddEngines(submenu.Items, engineMenuItems);
        return submenu;
    }

    private void AddEngines(IList<MenuFlyoutItemBase> items, List<RadioMenuFlyoutItem>? keep)
    {
        foreach (var (id, name) in LatexTemplates.Engines)
        {
            var item = new RadioMenuFlyoutItem { Text = name, Tag = id, GroupName = keep is null ? "StatusEngine" : "MenuEngine" };
            item.IsChecked = id == (project?.Settings?.Engine ?? "pdflatex");
            item.Click += (_, _) => _ = project?.SetEngineAsync(id);
            items.Add(item);
            keep?.Add(item);
        }
    }

    /// <summary>The references other than Reference and Citation, which have buttons of their own.</summary>
    private static List<(string Label, string Template)> OtherReferences =>
        LatexTemplates.References.Where(r => r.Label is not ("Reference" or "Citation")).ToList();

    /// <summary>Insert's menu: the environments, the lists, then the references the bar has no button for.</summary>
    private void AddInserts(IList<MenuFlyoutItemBase> items)
    {
        AddTemplates(items, LatexTemplates.Environments);
        items.Add(Submenu("List", LatexTemplates.Lists));
        items.Add(new MenuFlyoutSeparator());
        AddTemplates(items, OtherReferences);
    }

    private MenuFlyoutSubItem Submenu(string title, IReadOnlyList<(string Label, string Template)> templates)
    {
        var submenu = new MenuFlyoutSubItem { Text = title };
        AddTemplates(submenu.Items, templates);
        return submenu;
    }

    private void AddTemplates(IList<MenuFlyoutItemBase> items, IReadOnlyList<(string Label, string Template)> templates)
    {
        foreach (var (label, template) in templates)
        {
            items.Add(ContextMenus.Item(label, () => Format("insert", template)));
        }
    }

    // ---------- the source's location ----------

    private List<Crumb> crumbs = [];

    /// <summary>
    /// Project › folders › file › section, as the web's breadcrumb
    /// (workspace.js renderCrumbs) with the project and folders first, as
    /// Xcode's jump bar has them.
    /// </summary>
    private void RenderLocation()
    {
        if (project is not { } p)
        {
            return;
        }
        Show(LineText, p.OpenPath is null ? "" : $"Line {p.CursorLine:N0}");
        List<Crumb> next = [];
        if (p.OpenPath is { } path)
        {
            var parts = path.Split('/');
            next.Add(new Crumb(p.Id, "", CrumbKind.Folder, ""));
            for (var i = 0; i < parts.Length - 1; i++)
            {
                next.Add(new Crumb(parts[i], "", CrumbKind.Folder, string.Join('/', parts[..(i + 1)])));
            }
            var folder = string.Join('/', parts[..^1]);
            next.Add(new Crumb(parts[^1], "", CrumbKind.File, folder));
            if (p.Sections.Count > 0)
            {
                var section = Outline.Chain(p.Sections, p.CursorLine).LastOrDefault();
                next.Add(new Crumb(section is null ? "Top of file" : Outline.DisplayTitle(section), "", CrumbKind.Section, folder));
            }
        }
        if (!next.SequenceEqual(crumbs))
        {
            crumbs = next;
            Crumbs.ItemsSource = crumbs;
        }
        SelectCurrentSection();
    }

    /// <summary>A crumb opens a menu of its neighbours: the files in a folder, or the file's sections.</summary>
    private void OnCrumbClicked(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        if (project is not { } p || args.Item is not Crumb crumb)
        {
            return;
        }
        var menu = new MenuFlyout();
        if (crumb.Kind == CrumbKind.Section && p.OpenPath is { } path)
        {
            var depths = Outline.Depths(p.Sections);
            for (var i = 0; i < p.Sections.Count; i++)
            {
                var section = p.Sections[i];
                var item = ContextMenus.Item(Outline.DisplayTitle(section), () => _ = p.OpenAsync(path, section.Line));
                item.Padding = new Thickness(11 + 16 * depths[i], item.Padding.Top, item.Padding.Right, item.Padding.Bottom);
                menu.Items.Add(item);
            }
        }
        else
        {
            foreach (var file in TextFilesIn(p.Tree).Where(f => Folder(f) == crumb.Folder))
            {
                menu.Items.Add(ContextMenus.Item(file[(file.LastIndexOf('/') + 1)..], () => _ = p.OpenAsync(file)));
            }
        }
        if (menu.Items.Count == 0)
        {
            return;
        }
        // Beneath the crumb that was chosen, found by the data it shows.
        var anchor = Descendants(sender).OfType<BreadcrumbBarItem>()
            .FirstOrDefault(i => Descendants(i).OfType<FrameworkElement>().Any(e => ReferenceEquals(e.DataContext, crumb)));
        menu.ShowAt(anchor ?? (FrameworkElement)sender, new FlyoutShowOptions
        {
            Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft,
        });
    }

    private static string Folder(string path) => path.Contains('/') ? path[..path.LastIndexOf('/')] : "";

    private static IEnumerable<string> TextFilesIn(IEnumerable<TreeNode> nodes) => nodes.SelectMany(n =>
        n.IsDirectory ? TextFilesIn(n.Children ?? []) : TextFiles.IsText(n.Path) ? [n.Path] : []);

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var descendant in Descendants(child))
            {
                yield return descendant;
            }
        }
    }

    // ---------- the sidebar ----------

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

    private IReadOnlyList<OutlineItem>? shownSections;

    /// <summary>Sections the reader folded, by level and title (OutlineEntry.Key).</summary>
    private readonly HashSet<string> collapsedSections = [];

    private List<OutlineEntry> OutlineEntries => OutlineTree.ItemsSource as List<OutlineEntry> ?? [];

    private void RenderOutline()
    {
        // Every save analyses the file again; an unchanged outline keeps its
        // rows rather than flashing new ones in.
        var sections = project?.Sections ?? [];
        if (shownSections is not null && sections.SequenceEqual(shownSections))
        {
            return;
        }
        shownSections = sections;
        foreach (var entry in OutlineEntries.SelectMany(e => e.SelfAndDescendants()))
        {
            if (entry.IsExpanded)
            {
                collapsedSections.Remove(entry.Key);
            }
            else
            {
                collapsedSections.Add(entry.Key);
            }
        }
        OutlineTree.ItemsSource = Outline.Tree(sections).Select(n => new OutlineEntry(n, collapsedSections)).ToList();
        OutlineToggle.Visibility = sections.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowOutline();
        SelectCurrentSection();
    }

    /// <summary>The section the cursor is in shows selected, as the open file does above it.</summary>
    private void SelectCurrentSection()
    {
        if (project is not { } p || OutlineTree.Visibility != Visibility.Visible)
        {
            return;
        }
        var current = Outline.Chain(p.Sections, p.CursorLine).LastOrDefault();
        var entry = OutlineEntries.SelectMany(e => e.SelfAndDescendants()).FirstOrDefault(e => e.Item == current);
        if (OutlineTree.SelectedItem != entry)
        {
            OutlineTree.SelectedItem = entry;
        }
    }

    /// <summary>The outline's disclosure: open or closed, remembered as the browser version does.</summary>
    private void ShowOutline()
    {
        var open = Main.Preferences.OutlineOpen;
        OutlineTree.Visibility = open && shownSections is { Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        OutlineChevron.Glyph = open ? "" : "";
        AutomationProperties.SetItemStatus(OutlineToggle, open ? "Expanded" : "Collapsed");
    }

    private void OnToggleOutline(object sender, RoutedEventArgs e)
    {
        Main.Preferences.OutlineOpen = !Main.Preferences.OutlineOpen;
        Main.SavePreferences();
        ShowOutline();
        SelectCurrentSection();
    }

    /// <summary>The outline takes at most a little under half the sidebar, leaving the files the rest.</summary>
    private void OnSidebarSizeChanged(object sender, SizeChangedEventArgs e) =>
        OutlineTree.MaxHeight = Math.Max(96, e.NewSize.Height * 0.45);

    /// <summary>
    /// The tree's expander column, 24 wide rather than 40, so a row's content
    /// starts 12 in from its section's heading. The template fixes the
    /// column's padding and no resource reaches it.
    /// </summary>
    private void OnTreeItemLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is TreeViewItem item && VisualTreeHelper.GetChildrenCount(item) > 0
            && VisualTreeHelper.GetChild(item, 0) is FrameworkElement root
            && root.FindName("ExpandCollapseChevron") is Grid chevron)
        {
            chevron.Padding = new Thickness(6, 0, 6, 0);
        }
    }

    private void OnOutlineInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        // Choosing a heading goes to it; its expander folds it.
        args.Handled = true;
        if (args.InvokedItem is OutlineEntry entry && project is not null)
        {
            project.Reveal(entry.Item.Line);
            Main.Editor.Focus();
        }
    }

    /// <summary>The matches under their files, or "No results" when a finished search found none.</summary>
    private void RenderResults()
    {
        var hits = project?.SearchHits ?? [];
        Results.ItemsSource = new CollectionViewSource
        {
            IsSourceGrouped = true,
            Source = hits.GroupBy(h => h.File).Select(g => new SearchGroup(g.Key, g)).ToList(),
        }.View;
        NoResults.Visibility = hits.Count == 0 && Searching ? Visibility.Visible : Visibility.Collapsed;
        NoResultsText.Text = $"Nothing in this project matches “{Main.SearchBox.Text.Trim()}”.";
    }

    private bool Searching => !string.IsNullOrWhiteSpace(Main.SearchBox.Text);

    // ---------- the source bar ----------

    /// <summary>Whether the bar shows the LaTeX tools, or only history for another text file.</summary>
    private bool latexTools = true;

    /// <summary>How many of FoldOrder's groups are in "See more".</summary>
    private int sourceFolded;

    /// <summary>The groups "See more" takes as the bar narrows, first to go first. History never folds.</summary>
    private FrameworkElement[] FoldOrder => [ReferenceTools, InsertButton, HeadingButton, FormatTools];

    /// <summary>The inline-math icon, for its button and for "See more": Segoe Fluent Icons has none.</summary>
    private const string MathIconData = "M1,3 H15 V5 H11.5 V12 C11.5,12.8 11.9,13.2 12.6,13.2 H14 V15 H12.2 C10.6,15 9.5,14 9.5,12.4 V5 H6.5 V15 H4.5 V5 H1 Z";

    /// <summary>A geometry can draw in only one icon, so each gets its own.</summary>
    private static Geometry MathGeometry() => (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), MathIconData);

    private void OnSourceBarSizeChanged(object sender, SizeChangedEventArgs e) => FoldSourceBar();

    /// <summary>
    /// The widest form of the bar that fits, as the macOS bar's ViewThatFits
    /// chooses one: everything labelled; then icons only, the tooltips
    /// keeping the names; then whole groups into "See more", in FoldOrder.
    /// Each form is measured as it would lay out, so text scaling needs no
    /// table of widths; there are at most six, and the width changes only
    /// as the pane is resized.
    /// </summary>
    private void FoldSourceBar()
    {
        var available = SourceBar.ActualWidth - SourceBar.Padding.Left - SourceBar.Padding.Right;
        if (available <= 0)
        {
            // Not laid out yet: SizeChanged folds it when it is.
            return;
        }
        var folds = latexTools ? FoldOrder.Length : 0;
        for (var form = 0; form <= folds + 1; form++)
        {
            ShowSourceTools(labelled: form == 0, folded: Math.Max(0, form - 1));
            SourceTools.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            if (SourceTools.DesiredSize.Width <= available)
            {
                return;
            }
        }
    }

    private void ShowSourceTools(bool labelled, int folded)
    {
        foreach (var label in new[] { HeadingLabel, ReferenceLabel, CitationLabel, InsertLabel })
        {
            label.Visibility = labelled ? Visibility.Visible : Visibility.Collapsed;
        }
        sourceFolded = folded;
        var groups = FoldOrder;
        for (var i = 0; i < groups.Length; i++)
        {
            groups[i].Visibility = latexTools && i >= folded ? Visibility.Visible : Visibility.Collapsed;
        }
        HistorySeparator.Visibility = latexTools ? Visibility.Visible : Visibility.Collapsed;
        // Between the formatting tools and the inserting ones, while both show.
        var formatting = HeadingButton.Visibility == Visibility.Visible || FormatTools.Visibility == Visibility.Visible;
        var inserting = ReferenceTools.Visibility == Visibility.Visible || InsertButton.Visibility == Visibility.Visible;
        FormatSeparator.Visibility = formatting && inserting ? Visibility.Visible : Visibility.Collapsed;
        SourceMore.Visibility = latexTools && folded > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>"See more": the folded groups in the bar's order, with the shortcuts their tooltips name.</summary>
    private void OnSourceMoreOpening(object? sender, object e)
    {
        var items = SourceMoreMenu.Items;
        items.Clear();
        var folded = FoldOrder[..sourceFolded];
        void Group(FrameworkElement group, params MenuFlyoutItemBase[] entries)
        {
            if (!folded.Contains(group))
            {
                return;
            }
            if (items.Count > 0)
            {
                items.Add(new MenuFlyoutSeparator());
            }
            foreach (var entry in entries)
            {
                items.Add(entry);
            }
        }

        var heading = Submenu("Heading", LatexTemplates.Headings);
        heading.Icon = new FontIcon { Glyph = "" };
        Group(HeadingButton, heading);
        var math = ContextMenus.Item("Inline math", () => Main.Perform(MenuCommand.EditMath), "Ctrl+Shift+M");
        math.Icon = new PathIcon { Data = MathGeometry() };
        Group(FormatTools,
            ContextMenus.Item("Bold", "", () => Main.Perform(MenuCommand.EditBold), "Ctrl+B"),
            ContextMenus.Item("Italic", "", () => Main.Perform(MenuCommand.EditItalic), "Ctrl+I"),
            math);
        Group(ReferenceTools,
            ContextMenus.Item("Reference", "", () => InsertReference("Reference")),
            ContextMenus.Item("Citation", "", () => InsertReference("Citation")));
        var insert = new MenuFlyoutSubItem { Text = "Insert", Icon = new FontIcon { Glyph = "" } };
        AddInserts(insert.Items);
        Group(InsertButton, insert);
    }

    // ---------- the bars ----------

    private void Format(string name, string? arg = null)
    {
        project?.Format(name, arg);
        Main.Editor.Focus();
    }

    private void OnUndo(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditUndo);

    private void OnRedo(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditRedo);

    private void OnBold(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditBold);

    private void OnItalic(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditItalic);

    private void OnMath(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.EditMath);

    private void OnReference(object sender, RoutedEventArgs e) => InsertReference("Reference");

    private void OnCitation(object sender, RoutedEventArgs e) => InsertReference("Citation");

    private void InsertReference(string label) =>
        Format("insert", LatexTemplates.References.First(r => r.Label == label).Template);

    private void OnTogglePanel(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.ViewToggleLogs);

    /// <summary>The build's status opens its issues.</summary>
    private void OnShowIssues(object sender, RoutedEventArgs e)
    {
        if (project is { } p)
        {
            p.PanelTab = PanelTab.Issues;
            p.ShowLogs = true;
        }
    }

    /// <summary>The engine: a menu of the others, or Settings when there is no TeX to run.</summary>
    private void OnEngineStatus(object sender, RoutedEventArgs e)
    {
        if (project is not { TexAvailable: true })
        {
            Main.Perform(MenuCommand.AppSettings);
            return;
        }
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.TopEdgeAlignedRight };
        AddEngines(menu.Items, keep: null);
        menu.ShowAt(EngineStatus);
    }

    // ---------- the sidebar's actions ----------

    private void OnNewFile(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.FileNew);

    private void OnNewFolder(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.FileNewFolder);

    private void OnAddFiles(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.FileUpload);

    private void OnAddFolder(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.FileUploadFolder);

    /// <summary>The title bar's search box, while the project is on screen: results replace the trees.</summary>
    internal void Search(string text)
    {
        if (project is not null)
        {
            project.SearchQuery = text;
        }
        // The results and the trees fade in in each other's place.
        Motion.Show(Browse, !Searching, Motion.FadeIn);
        Motion.Show(Results, Searching, Motion.FadeIn);
        // Until this query's results arrive (RenderResults).
        NoResults.Visibility = Visibility.Collapsed;
    }

    private void OnResultClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is SearchHit hit && project is not null)
        {
            _ = project.OpenAsync(hit.File, hit.Line);
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

    /// <summary>F2 renames and Delete deletes, as in File Explorer.</summary>
    private void OnFilesKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (project is not { } p || Files.SelectedItem is not FileItem { Node: var node })
        {
            return;
        }
        if (e.Key == VirtualKey.F2)
        {
            e.Handled = true;
            _ = RenameAsync(p, node);
        }
        else if (e.Key == VirtualKey.Delete)
        {
            e.Handled = true;
            _ = DeleteAsync(p, node);
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
        // The usual order: open, then the file's own commands, then its
        // location, and the destructive one last.
        var menu = new MenuFlyout();
        if (!node.IsDirectory)
        {
            menu.Items.Add(ContextMenus.Item("Open", "", () => _ = p.OpenAsync(node.Path)));
        }
        if (!node.IsDirectory && node.Path.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) && node.Path != p.Settings?.MainFile)
        {
            menu.Items.Add(ContextMenus.Item("Set as main file", "", () => _ = p.SetMainFileAsync(node.Path)));
        }
        menu.Items.Add(ContextMenus.Item("Rename…", "", () => _ = RenameAsync(p, node), "F2"));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(ContextMenus.Item("Open file location", "", () => _ = p.RevealAsync(node.Path)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(ContextMenus.Item("Delete…", "", () => _ = DeleteAsync(p, node), "Delete"));
        ContextMenus.Show(menu, row, e);
    }

    private async Task RenameAsync(ProjectModel p, TreeNode node)
    {
        if (await Dialogs.PromptAsync(XamlRoot, $"Rename {node.Name}", "New path", "Rename", node.Path) is { } to)
        {
            await p.RenameEntryAsync(node.Path, to);
        }
    }

    private async Task DeleteAsync(ProjectModel p, TreeNode node)
    {
        // Refuse before asking, not after the user has already confirmed.
        if (ProjectPaths.Contains(node.Path, p.Settings?.MainFile))
        {
            Main.Report("Choose a different main file before you delete this.", InfoBarSeverity.Warning);
            return;
        }
        var what = node.IsDirectory ? "This folder and everything in it" : "This file";
        if (await Dialogs.ConfirmAsync(XamlRoot, $"Delete {node.Name}?", $"{what} will be moved to the Recycle Bin.", "Delete"))
        {
            await p.DeleteEntryAsync(node.Path);
        }
    }

    // ---------- dropping files in ----------

    /// <summary>
    /// The folder a drop lands in: the folder under the pointer, the folder
    /// of the file under it, or the project's root.
    /// </summary>
    private string DropFolder(DragEventArgs e)
    {
        var point = e.GetPosition(null);
        foreach (var element in VisualTreeHelper.FindElementsInHostCoordinates(point, Files))
        {
            if (element is TreeViewItem row && Files.ItemFromContainer(row) is FileItem { Node: var node })
            {
                return node.IsDirectory ? node.Path : Folder(node.Path);
            }
        }
        return "";
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (project is not null && e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            var folder = DropFolder(e);
            e.DragUIOverride.Caption = folder.Length == 0 ? "Add to project" : $"Add to {folder}";
        }
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (project is not { } p || !e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }
        var folder = DropFolder(e);
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
        await p.ImportFilesAsync(paths, folder);
    }
}
