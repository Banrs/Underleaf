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
    private readonly Splitter outlineSplitter;

    // The limits the panes keep, after macOS's (parity C19, E19, F12, H1).
    private const double SidebarMinimum = 200;
    private const double SidebarMaximum = 360;
    private const double PaneMinimum = 240;
    private const double PanelMinimum = 80;
    private const double EditorsMinimum = 120;
    private const double InspectorMinimum = 220;
    private const double InspectorMaximum = 320;
    private const double OutlineMinimum = 80;
    private const double FilesMinimum = 100;

    // The layout as the reader last dragged it, remembered in Preferences.
    private double sidebarWidth;
    private double pdfSplit;
    private double panelHeight;
    private double inspectorWidth;
    private double outlineHeight;

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
        outlineHeight = Math.Max(preferences.OutlineHeight ?? 240, OutlineMinimum);
        foldedSections = [.. preferences.OutlineFolded];

        // Added last, so each grip lies over the panes it overhangs. The
        // content layer's own edge is the line beside the sidebar.
        sidebarSplitter = new Splitter(() => Panes.OpenPaneLength, w => Panes.OpenPaneLength = w, targetIsBefore: true,
            SidebarMinimum, () => SidebarMaximum, "Resize the sidebar", line: false)
        {
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        sidebarSplitter.Resized += width => sidebarWidth = width;
        sidebarSplitter.Committed += () => Remember(p => p.SidebarWidth = sidebarWidth);
        SidebarContent.Children.Add(sidebarSplitter);
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
        inspectorSplitter = new Splitter(() => Details.OpenPaneLength, w => Details.OpenPaneLength = w, targetIsBefore: false,
            InspectorMinimum, () => InspectorMaximum, "Resize the details pane")
        {
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        inspectorSplitter.Resized += width => inspectorWidth = width;
        inspectorSplitter.Committed += () => Remember(p => p.InspectorWidth = inspectorWidth);
        DetailsContent.Children.Add(inspectorSplitter);
        // The outline's heading draws the line between it and the files.
        outlineSplitter = new Splitter(OutlineRow, targetIsBefore: false, OutlineMinimum, () => OutlineRoom, "Resize the file outline", line: false);
        outlineSplitter.Resized += height => outlineHeight = height;
        outlineSplitter.Committed += () => Remember(p => p.OutlineHeight = outlineHeight);
        Grid.SetRow(outlineSplitter, 2);
        Browse.Children.Add(outlineSplitter);

        BuildMenu();
        PiIcon.Data = Icon(PiIconData);
        NumberedListIcon.Data = Icon(NumberedListIconData);
        SymbolGrid.ItemsSource = new CollectionViewSource
        {
            IsSourceGrouped = true,
            Source = LatexTemplates.SymbolGroups
                .Select(g => new PaletteGroup(g.Title, g.Symbols.Select(s => new PaletteSymbol(s.Glyph, s.Command))))
                .ToList(),
        }.View;
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
            case nameof(ProjectModel.TopLine):
                // On every scroll: only the outline follows it.
                FollowTopLine();
                return;
            case nameof(ProjectModel.Tree):
            case nameof(ProjectModel.Settings):
                RenderTree();
                break;
            case nameof(ProjectModel.OpenPath):
                SelectOpenFile();
                RenderOutline();
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
        engineMenu?.IsEnabled = Main.IsEnabled(MenuCommand.CompileToggleAuto);
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

        // While a build runs the build status says so; the save state would repeat it.
        Show(StatusText, p.OpenPath is null || p.Compiling ? "" : p.Saving ? "Saving…" : p.Dirty ? "Unsaved changes" : "Saved");
        Show(CountsText, Main.Preferences.ShowWordCount && p.Stats is { } stats
            ? $"{Count(stats.Words, "word")} · {Count(stats.Lines, "line")}"
            : "");
        EngineText.Text = p.TexAvailable ? LatexTemplates.EngineName(p.Settings?.Engine ?? "pdflatex") : "No TeX";
        EngineWarning.Visibility = p.TexAvailable ? Visibility.Collapsed : Visibility.Visible;
        PdfPane.SetToolTip(EngineStatus, p.TexAvailable ? "Choose the engine" : "TeX wasn’t found: open Settings");
        AutomationProperties.SetName(EngineStatus, $"Engine: {EngineText.Text}");
        FoldStatusBar();
    }

    private void OnStatusBarSizeChanged(object sender, SizeChangedEventArgs e) => FoldStatusBar();

    /// <summary>
    /// A narrow status bar drops whole items, never cutting one short, as
    /// the macOS app's does: the engine first (the details pane and the
    /// Compile menu show it too), then the counts, then the save state.
    /// </summary>
    private void FoldStatusBar()
    {
        var available = StatusBar.ActualWidth - StatusBar.Padding.Left - StatusBar.Padding.Right;
        if (available <= 0)
        {
            return;
        }
        var infinite = new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity);
        for (var dropped = 0; dropped <= 3; dropped++)
        {
            EngineStatus.Visibility = dropped < 1 ? Visibility.Visible : Visibility.Collapsed;
            CountsText.Visibility = dropped < 2 && CountsText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            StatusText.Visibility = dropped < 3 && StatusText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            StatusStart.Measure(infinite);
            StatusEnd.Measure(infinite);
            if (StatusStart.DesiredSize.Width + StatusEnd.DesiredSize.Width + 12 <= available)
            {
                return;
            }
        }
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
        Panes.OpenPaneLength = sidebarWidth;
        Panes.IsPaneOpen = sidebar;
        sidebarSplitter.Visibility = sidebar ? Visibility.Visible : Visibility.Collapsed;
        // Without the sidebar the layer meets the window's edge: no corner.
        Layer.CornerRadius = sidebar ? new CornerRadius(8, 0, 0, 0) : new CornerRadius(0);
        Layer.BorderThickness = sidebar ? new Thickness(1, 1, 0, 0) : new Thickness(0, 1, 0, 0);

        var pdf = Main.Preferences.PdfVisible;
        // The panes a SplitView doesn't hold come in from the edge they're docked to.
        Motion.Show(Pdf, pdf, Motion.Pane(40, 0));
        previewSplitter.Visibility = Pdf.Visibility;
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
        Details.OpenPaneLength = inspectorWidth;
        Details.IsPaneOpen = inspector;
        inspectorSplitter.Visibility = inspector ? Visibility.Visible : Visibility.Collapsed;
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
                if (command == MenuCommand.EditMath)
                {
                    // The rest of the source bar's math group.
                    foreach (var extra in new MenuFlyoutItemBase[] { ContextMenus.Item("Display math", DisplayMath), SymbolMenu() })
                    {
                        menu.Items.Add(extra);
                        latexMenuItems.Add(extra);
                    }
                }
                if (command == MenuCommand.CompileToggleAuto)
                {
                    // The engine, in the Compile menu as in the status bar.
                    engineMenu = new MenuFlyoutSubItem { Text = "Engine" };
                    AddEngines(engineMenu.Items, engineMenuItems);
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
            LevelSubmenu(current: null),
            Submenu("Reference", LatexTemplates.References, "inline"),
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

    /// <summary>A menu of templates: blocks inserted, or, for "inline", put around the selection.</summary>
    private MenuFlyoutSubItem Submenu(string title, IReadOnlyList<(string Label, string Template)> templates, string how = "insert")
    {
        var submenu = new MenuFlyoutSubItem { Text = title };
        AddTemplates(submenu.Items, templates, how);
        return submenu;
    }

    private void AddTemplates(IList<MenuFlyoutItemBase> items, IEnumerable<(string Label, string Template)> templates, string how = "insert")
    {
        foreach (var (label, template) in templates)
        {
            items.Add(ContextMenus.Item(label, () => Format(how, template)));
        }
    }

    /// <summary>The section levels; the source bar's checks the caret line's.</summary>
    private void AddLevels(IList<MenuFlyoutItemBase> items, string? current)
    {
        foreach (var (label, command) in LatexTemplates.HeadingLevels)
        {
            MenuFlyoutItem item = current is null ? new MenuFlyoutItem() : new RadioMenuFlyoutItem { IsChecked = label == current };
            item.Text = label;
            item.Click += (_, _) => Format("heading", command);
            items.Add(item);
            if (command.Length == 0)
            {
                items.Add(new MenuFlyoutSeparator());
            }
        }
    }

    private MenuFlyoutSubItem LevelSubmenu(string? current)
    {
        var submenu = new MenuFlyoutSubItem { Text = "Section level" };
        AddLevels(submenu.Items, current);
        return submenu;
    }

    /// <summary>The palette as a menu, for the Format menu and "See more".</summary>
    private MenuFlyoutSubItem SymbolMenu()
    {
        var menu = new MenuFlyoutSubItem { Text = "Symbols" };
        foreach (var (title, symbols) in LatexTemplates.SymbolGroups)
        {
            var group = new MenuFlyoutSubItem { Text = title };
            foreach (var (glyph, command) in symbols)
            {
                group.Items.Add(ContextMenus.Item($"{glyph}   {command}", () => Format("symbol", command)));
            }
            menu.Items.Add(group);
        }
        return menu;
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
        var level = LatexTemplates.LevelAt(p.Sections, p.CursorLine);
        LevelLabel.Text = level;
        AutomationProperties.SetName(LevelButton, $"Section level: {level}");
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
    private string? shownOutlineFile;
    private OutlineEntry? currentSection;

    /// <summary>The headings the reader folded, by OutlineEntry.Key, remembered in Preferences.</summary>
    private readonly HashSet<string> foldedSections;

    private List<OutlineEntry> OutlineEntries => OutlineTree.ItemsSource as List<OutlineEntry> ?? [];

    private void RenderOutline()
    {
        ShowOutline();
        // Every save analyses the file again; an unchanged outline keeps its
        // rows rather than flashing new ones in.
        var sections = project?.Sections ?? [];
        var file = $"{project?.Id}/{project?.OpenPath}\t";
        if (shownSections is not null && sections.SequenceEqual(shownSections) && file == shownOutlineFile)
        {
            return;
        }
        shownSections = sections;
        shownOutlineFile = file;
        var keys = sections.Zip(Outline.FoldKeys(sections)).ToDictionary(k => k.First, k => file + k.Second);
        OutlineTree.ItemsSource = Outline.Tree(sections).Select(n => new OutlineEntry(n, keys, foldedSections)).ToList();
        NoSections.Visibility = sections.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        currentSection = null;
        FollowTopLine();
    }

    /// <summary>
    /// The section at the top of the source is the current one, as Overleaf's
    /// outline follows where you are reading: its headings open, and the
    /// least scroll that brings it into view.
    /// </summary>
    private void FollowTopLine()
    {
        if (project is not { } p)
        {
            return;
        }
        var chain = Outline.Chain(p.Sections, p.TopLine);
        var entries = OutlineEntries.SelectMany(e => e.SelfAndDescendants()).ToList();
        var current = chain.Count == 0 ? null : entries.FirstOrDefault(e => e.Item == chain[^1]);
        if (current == currentSection)
        {
            return;
        }
        currentSection?.IsCurrent = false;
        currentSection = current;
        if (current is null)
        {
            return;
        }
        current.IsCurrent = true;
        foreach (var entry in entries.Where(e => e != current && chain.Contains(e.Item)))
        {
            entry.IsExpanded = true;
        }
        // Once the opened headings have their rows.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (currentSection == current && OutlineTree.ContainerFromItem(current) is UIElement row)
            {
                row.StartBringIntoView();
            }
        });
    }

    /// <summary>
    /// The outline for a .tex file: open at the height it was dragged to, or
    /// folded to its heading at the sidebar's foot, the files taking the room.
    /// </summary>
    private void ShowOutline()
    {
        var shown = project?.Stats is not null;
        var open = shown && Main.Preferences.OutlineOpen;
        OutlineHeader.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        Motion.Show(OutlinePane, open, Motion.Pane(0, 40));
        outlineSplitter.Visibility = OutlinePane.Visibility;
        OutlineRow.Height = new GridLength(open ? Math.Clamp(outlineHeight, OutlineMinimum, Math.Max(OutlineMinimum, OutlineRoom)) : 0);
        // Its state, not a direction: down while open, right while folded.
        OutlineChevron.Glyph = Main.Preferences.OutlineOpen ? "\uE70D" : "\uE76C";
        var tip = Main.Preferences.OutlineOpen ? "Hide file outline" : "Show file outline";
        PdfPane.SetToolTip(OutlineToggle, tip);
        AutomationProperties.SetItemStatus(OutlineToggle, Main.Preferences.OutlineOpen ? "Expanded" : "Collapsed");
    }

    /// <summary>The most the outline can take and leave the files their minimum.</summary>
    private double OutlineRoom => Browse.ActualHeight - 2 * 32 - FilesMinimum;

    private void OnBrowseSizeChanged(object sender, SizeChangedEventArgs e) => ShowOutline();

    private void OnToggleOutline(object sender, RoutedEventArgs e)
    {
        Main.Preferences.OutlineOpen = !Main.Preferences.OutlineOpen;
        Main.SavePreferences();
        ShowOutline();
    }

    private void OnOutlineExpanding(TreeView sender, TreeViewExpandingEventArgs args) => Fold(args.Item, folded: false);

    private void OnOutlineCollapsed(TreeView sender, TreeViewCollapsedEventArgs args) => Fold(args.Item, folded: true);

    /// <summary>A heading's fold, remembered for the next time the file is open.</summary>
    private void Fold(object item, bool folded)
    {
        if (item is OutlineEntry entry && (folded ? foldedSections.Add(entry.Key) : foldedSections.Remove(entry.Key)))
        {
            Remember(p => p.OutlineFolded = [.. foldedSections.Order()]);
        }
    }

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
        // Choosing a heading scrolls it to the top of the source, leaving
        // focus in the outline; its expander folds it.
        args.Handled = true;
        if (args.InvokedItem is OutlineEntry entry && project is not null)
        {
            project.Reveal(entry.Item.Line, atTop: true, focus: false);
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

    /// <summary>How many of Groups show; the rest are in "See more".</summary>
    private int shownGroups;
    private bool levelFolded;
    private bool redoFolded;

    /// <summary>The groups that fold, in the bar's order; they fold from the end.</summary>
    private FrameworkElement[] Groups => [FormatTools, MathTools, ReferenceTools, FigureTools, ListTools];

    /// <summary>
    /// Icons Segoe Fluent Icons has none of, on its 16 px grid: π for the
    /// symbols, and a list numbered 1, 2, 3.
    /// </summary>
    private const string PiIconData = "M1,3 H15 V5 H11.5 V12 C11.5,12.8 11.9,13.2 12.6,13.2 H14 V15 H12.2 C10.6,15 9.5,14 9.5,12.4 V5 H6.5 V15 H4.5 V5 H1 Z";
    private const string NumberedListIconData =
        "M2.4,0.4 H3.4 V4.6 H2.4 Z M1.4,1.2 L2.4,0.4 V1.5 L1.9,1.9 Z"
        + " M0.8,5.9 H3.8 V8.45 H1.7 V9.2 H3.8 V10.1 H0.8 V7.55 H2.9 V6.8 H0.8 Z"
        + " M0.8,11.4 H3.8 V15.6 H0.8 V14.7 H2.9 V13.95 H1.4 V13.05 H2.9 V12.3 H0.8 Z"
        + " M6,1.9 H15.5 V3.1 H6 Z M6,7.4 H15.5 V8.6 H6 Z M6,12.9 H15.5 V14.1 H6 Z";

    /// <summary>A geometry draws in only one icon, so each gets its own.</summary>
    private static Geometry Icon(string data) => (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), data);

    private void OnSourceBarSizeChanged(object sender, SizeChangedEventArgs e) => FoldSourceBar();

    /// <summary>
    /// The widest form of the bar that fits, as the macOS bar's ViewThatFits
    /// chooses one: every group; then groups into "See more" from the end;
    /// then the section level, then redo, so undo is never clipped. Each
    /// form is measured as it would lay out, so text scaling needs no table
    /// of widths.
    /// </summary>
    private void FoldSourceBar()
    {
        var available = SourceBar.ActualWidth - SourceBar.Padding.Left - SourceBar.Padding.Right;
        if (available <= 0)
        {
            // Not laid out yet: SizeChanged folds it when it is.
            return;
        }
        var groups = Groups.Length;
        for (var form = 0; form <= groups + 2; form++)
        {
            ShowSourceTools(shown: Math.Max(0, groups - form), level: form <= groups, redo: form <= groups + 1);
            SourceTools.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            if (SourceTools.DesiredSize.Width <= available)
            {
                return;
            }
        }
    }

    private void ShowSourceTools(int shown, bool level, bool redo)
    {
        shownGroups = shown;
        levelFolded = !level;
        redoFolded = latexTools && !redo;
        LatexTools.Visibility = latexTools ? Visibility.Visible : Visibility.Collapsed;
        var groups = Groups;
        for (var i = 0; i < groups.Length; i++)
        {
            groups[i].Visibility = i < shown ? Visibility.Visible : Visibility.Collapsed;
        }
        LevelTools.Visibility = level ? Visibility.Visible : Visibility.Collapsed;
        RedoButton.Visibility = redoFolded ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>"See more": what has folded, in the bar's order, then the templates with no button.</summary>
    private void OnSourceMoreOpening(object? sender, object e)
    {
        var items = SourceMoreMenu.Items;
        items.Clear();
        void Add(params MenuFlyoutItemBase[] entries)
        {
            foreach (var entry in entries)
            {
                items.Add(entry);
            }
            items.Add(new MenuFlyoutSeparator());
        }

        if (redoFolded)
        {
            var redo = ContextMenus.Item("Redo", "\uE7A6", () => Main.Perform(MenuCommand.EditRedo), "Ctrl+Shift+Z");
            redo.IsEnabled = Main.IsEnabled(MenuCommand.EditRedo);
            Add(redo);
        }
        if (levelFolded)
        {
            Add(LevelSubmenu(LevelLabel.Text));
        }
        var groups = Groups;
        for (var i = shownGroups; i < groups.Length; i++)
        {
            var group = groups[i];
            if (group == FormatTools)
            {
                Add(ContextMenus.Item("Bold", "\uE8DD", () => Main.Perform(MenuCommand.EditBold), "Ctrl+B"),
                    ContextMenus.Item("Italic", "\uE8DB", () => Main.Perform(MenuCommand.EditItalic), "Ctrl+I"));
            }
            else if (group == MathTools)
            {
                Add(ContextMenus.Item("Inline math", "\uE94B", () => Main.Perform(MenuCommand.EditMath), "Ctrl+Shift+M"),
                    ContextMenus.Item("Display math", DisplayMath),
                    SymbolMenu());
            }
            else if (group == ReferenceTools)
            {
                Add(ContextMenus.Item("Link", "\uE71B", () => Inline("Link")),
                    ContextMenus.Item("Reference", () => Inline("Reference")),
                    ContextMenus.Item("Citation", "\uE9B1", () => Inline("Citation")));
            }
            else if (group == FigureTools)
            {
                Add(ContextMenus.Item("Figure", "\uE8B9", () => Insert("Figure")),
                    ContextMenus.Item("Table", "\uE80A", () => Insert("Table")));
            }
            else
            {
                Add(ContextMenus.Item("Bulleted list", "\uE8FD", () => Insert("Bulleted list")),
                    ContextMenus.Item("Numbered list", () => Insert("Numbered list")));
            }
        }
        string[] buttoned = ["Figure", "Table", "Bulleted list", "Numbered list", "Link", "Reference", "Citation"];
        AddTemplates(items, LatexTemplates.Environments.Concat(LatexTemplates.Lists).Where(t => !buttoned.Contains(t.Label)));
        items.Add(new MenuFlyoutSeparator());
        AddTemplates(items, LatexTemplates.References.Where(t => !buttoned.Contains(t.Label)), "inline");
    }

    private void OnLevelMenuOpening(object? sender, object e)
    {
        LevelMenu.Items.Clear();
        AddLevels(LevelMenu.Items, LevelLabel.Text);
    }

    private void OnSymbolClick(object sender, ItemClickEventArgs e)
    {
        SymbolsFlyout.Hide();
        if (e.ClickedItem is PaletteSymbol symbol)
        {
            Format("symbol", symbol.Command);
        }
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

    private void OnDisplayMath(object sender, RoutedEventArgs e) => DisplayMath();

    private void DisplayMath() => Format("displayMath");

    /// <summary>A reference or block button: its Tag is the template's label.</summary>
    private void OnInline(object sender, RoutedEventArgs e) => Inline((string)((FrameworkElement)sender).Tag);

    private void OnInsert(object sender, RoutedEventArgs e) => Insert((string)((FrameworkElement)sender).Tag);

    /// <summary>A reference template around the selection, by its label.</summary>
    private void Inline(string label) =>
        Format("inline", LatexTemplates.References.First(r => r.Label == label).Template);

    /// <summary>A block from the environments or the lists, by its label.</summary>
    private void Insert(string label) =>
        Format("insert", LatexTemplates.Environments.Concat(LatexTemplates.Lists).First(t => t.Label == label).Template);

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
        project?.SearchQuery = text;
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
            Main.Report($"Can’t delete “{node.Name}”", "Choose a different main file before you delete this.", InfoBarSeverity.Warning);
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
