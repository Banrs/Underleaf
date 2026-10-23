using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using VirtualKey = Windows.System.VirtualKey;

namespace TeXLocal.Pages;

/// An issues panel row: a build's error or warning or a check, by its index among the session's issues, or a bad box,
/// which is none.
/// <param name="Fixing">The id of the fix that runs, if one does: its rows' rings turn and every fix waits. A list rebuilt
/// meanwhile, by a build or new checks, has new items with the same fix.</param>
public sealed record IssueItem(int? Index, LogItem Item, string? Fixing = null)
{
    public bool HasFix => Item.Fix is not null;
    public bool Running => Item.Fix is { } fix && fix.Id == Fixing;
    public bool Idle => Fixing is null;
    public string FixName => $"{Item.Fix?.Title}: {Item.Fix?.Help}";
    public bool HasExplain => Item.Explain is not null;
    public bool IsError => Item.Type == "error";
    public bool IsWarning => !IsError;
    public bool HasPlace => Item.File is not null;
    public string Place => Item.Line is { } line ? $"{Item.File}:{line}" : Item.File ?? "";
    public override string ToString() => $"{(IsError ? "Error" : "Warning")}: {Item.Message}{(HasPlace ? $", {Place}" : "")}{(HasExplain ? $". {Item.Explain}" : "")}";
}

/// A project: the sidebar, the editor and the PDF, builds and their issues, all through the project's session.
public sealed partial class WorkspacePage : Page
{
    sealed record Chosen(int Index, LogItem Issue);

    static ulong sessions;
    readonly DispatcherQueueTimer searchTimer, caretTimer, scrollTimer;
    readonly HashSet<string> unsaved = [];
    readonly Dictionary<string, IssueLine[]> issueLines = [];
    string id = "", root = "", issueFilter = "", logFilter = "";
    string? name, fixing;
    ulong session;
    bool texAvailable, compiling, outdated, zooming, sidebarWanted = true;
    int quickQueries;
    double ratio = Prefs.SplitRatio;
    /// Where the quick info shown says its name is defined.
    Spot? helpPlace;
    CompileResult? result;
    LogItem[] checks = [];
    UIElement? beforeMenu;

    static Core Core => App.Core!;
    bool Inline => Split.DisplayMode == SplitViewDisplayMode.Inline;
    /// The session's, numbered as session_choose_issue numbers them.
    LogItem[] Issues => [.. result?.Errors ?? [], .. result?.Warnings ?? [], .. checks];

    public WorkspacePage()
    {
        InitializeComponent();
        NavigationCacheMode = NavigationCacheMode.Required;
        searchTimer = Timer(250, () => _ = RunSearch());
        caretTimer = Timer(150, CaretSettled);
        scrollTimer = Timer(150, ScrollSettled);
        SetSplit(ratio);
        ShowEdge();
        ShowPage();
        // A layer's content scrolls under its rounded corners, inside its 1 px border.
        var radius = (float)((CornerRadius)Application.Current.Resources["OverlayCornerRadius"]).TopLeft - 1;
        foreach (var layer in (FrameworkElement[])[EditorClip, PdfClip, IssuesClip])
        {
            var visual = ElementCompositionPreview.GetElementVisual(layer);
            var shape = visual.Compositor.CreateRoundedRectangleGeometry();
            shape.CornerRadius = new(radius, radius);
            visual.Clip = visual.Compositor.CreateGeometricClip(shape);
            layer.SizeChanged += (_, e) => shape.Size = new((float)e.NewSize.Width, (float)e.NewSize.Height);
        }
        // Wide, the pane is as the reader last left it there; narrow, it opens over the content only when asked.
        SizeChanged += (_, e) => WideTrigger.IsActive = e.NewSize.Width >= 1008;
        Split.RegisterPropertyChangedCallback(SplitView.DisplayModeProperty, (_, _) =>
        {
            Split.IsPaneOpen = Inline && sidebarWanted;
            ShowEdge();
        });
        Split.RegisterPropertyChangedCallback(SplitView.IsPaneOpenProperty, (_, _) =>
        {
            if (Inline || Split.IsPaneOpen) sidebarWanted = Split.IsPaneOpen;
            ShowEdge();
        });
        Split.PaneOpened += (_, _) => Remeasure(SideTabs);
        // One of the source and the PDF always shows: hiding the one shows the other. LaTeX's tools follow the source.
        void Toggled(ToggleMenuFlyoutItem item, ToggleMenuFlyoutItem other)
        {
            if (!item.IsChecked) other.IsChecked = true;
            ShowPanes();
            CaretSettled();
        }
        SourceItem.RegisterPropertyChangedCallback(ToggleMenuFlyoutItem.IsCheckedProperty, (_, _) => Toggled(SourceItem, PdfItem));
        PdfItem.RegisterPropertyChangedCallback(ToggleMenuFlyoutItem.IsCheckedProperty, (_, _) => Toggled(PdfItem, SourceItem));
        // An overlaid pane open as the window widens is light-dismissed after it has become inline; it stays.
        Split.PaneClosing += (_, e) => e.Cancel = Inline;
        PaneSizer.Delta += d => Split.OpenPaneLength = Math.Clamp(Split.OpenPaneLength + d, 200, 480);
        PaneSizer.Released += () => Prefs.SidebarWidth = Split.OpenPaneLength;
        SplitSizer.Delta += d =>
        {
            var width = Panes.ActualWidth - SplitSizer.ActualWidth;
            if (width > 0) SetSplit(Math.Clamp(ratio * width + d, EditorColumn.MinWidth, width - PdfColumn.MinWidth) / width);
        };
        SplitSizer.Released += () => Prefs.SplitRatio = ratio;
        IssuesSizer.Delta += d => IssuesRow.Height = new(Math.Clamp(IssuesRow.Height.Value - d, 120, Math.Max(ActualHeight / 2, 120)));
        IssuesSizer.Released += () => Prefs.IssuesHeight = IssuesRow.Height.Value;
        PaneSizer.Spoken = () => $"{Split.OpenPaneLength:0} pixels";
        SplitSizer.Spoken = () => $"{ratio:P0}";
        IssuesSizer.Spoken = () => $"{IssuesRow.Height.Value:0} pixels";

        // A scroll within the caret's wait of a move, either side, is the caret's.
        Editor.CaretMoved += () =>
        {
            HelpFlyout.Hide();
            ShowCaret();
            headingLine = Editor.Caret.Line;
            caretScrolled |= scrollTimer.IsRunning;
            Restart(caretTimer);
        };
        Editor.Scrolled += () =>
        {
            HelpFlyout.Hide();
            caretScrolled |= caretTimer.IsRunning;
            Restart(scrollTimer);
        };
        Editor.Composing += composing =>
        {
            if (Editor.Path is { } path) _ = Core.CallAsync("session_composing", new { session, path, composing });
        };
        // Compile's Ctrl+Enter reaches RichEdit as a line break too, unless it is taken before the editor has it.
        Editor.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter || !SourceView.Down(VirtualKey.Control) || SourceView.Down(VirtualKey.Shift) || SourceView.Down(VirtualKey.Menu)) return;
            e.Handled = true;
            if (CompileItem.IsEnabled) OnCompile(this, e);
        };
        Editor.IssueInvoked += line =>
        {
            if (line.Index is { } index) GoToIssue("session_choose_issue", new { session, index });
        };
        Editor.FilesDropped += OnFilesDropped;
        // The Mac's double-click to the PDF; where the PDF is hidden, selecting a word doesn't open it.
        Editor.DoubleClicked += () =>
        {
            if (PdfItem.IsChecked && Pdf.PageCount > 0) Run(null, SyncToCaret);
        };
        Editor.DefinitionFound += place => _ = Jump(place.File, place.Line, place.Column, place.Length);
        Editor.HelpAsked += ShowHelp;
        Editor.ReferencesAsked += ShowUsages;
        // The core's refusal shows in the flyout.
        Editor.RenameAsked += (symbol, at) => rename.Show(Editor, symbol.Name, async to => Editor.Apply((await Core.CallAsync<Replaced>("session_rename_symbol",
            new { session, kind = symbol.Kind, from = symbol.Name, to })).Edits), at);
        Pdf.ViewMoved += ShowPage;
        Pdf.Inverse += (page, x, y) => Run(null, async () =>
        {
            var at = await Core.CallAsync<InverseSync>("synctex_inverse", new { id, page, x, y });
            await Jump(at.File, at.Line, at.Column ?? 0);
        });
        foreach (var item in (UIElement[])[BoldItem, ItalicItem, UnderlineItem, InlineItem, SymbolItem, DefinitionItem, ReferencesItem, RenameSymbolItem, QuickInfoItem]) Shortcut.SetScope(item, Editor);
        foreach (var item in (UIElement[])[RenameItem, DeleteItem]) Shortcut.SetScope(item, FilesTree);
        DeleteItem.KeyboardAcceleratorTextOverride = "Del";
        SetUpInsert();
        SetUpMenuFocus();
        ShowLook();
        Prefs.EditorChanged += ShowLook;
        Loaded += (_, _) =>
        {
            // In case the wide state applied before the callbacks above were registered.
            Split.IsPaneOpen |= Inline && sidebarWanted;
            // An InfoBar open while the page sat cached under Settings keeps the old theme's colours until its state changes.
            BuildFailed.Severity = InfoBarSeverity.Warning;
            BuildFailed.Severity = InfoBarSeverity.Error;
        };
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        (id, var file) = ((string, string?))e.Parameter;
        MenuSlot.Child = null;
        App.Window.SetMenu(MainMenu);
        App.Window.SetTitle(name, Editor.Path);
        CheckTex();
        if (session != 0)
        {
            // Settings › Compiling may have changed it while the page waited underneath.
            if (AutoCompileItem.IsChecked != Prefs.AutoCompile) SetAutoCompile();
            return;
        }
        Core.Event += OnEvent;
        try { await OpenSession(file); }
        catch (CoreException ex)
        {
            session = 0;
            await App.Alert("Can't open this project", ex.Message);
            App.Window.GoHome();
        }
    }

    /// Settings keeps the project open underneath: the page stays cached until it goes elsewhere.
    protected override void OnNavigatingFrom(NavigatingCancelEventArgs e)
    {
        if (e.SourcePageType != typeof(SettingsPage)) NavigationCacheMode = NavigationCacheMode.Disabled;
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        if (e.SourcePageType == typeof(SettingsPage)) return;
        Prefs.EditorChanged -= ShowLook;
        Core.Event -= OnEvent;
        // WinUI 2.3.9 keeps a menu's accelerators after its bar has left the window: kept, this page's would take Home's
        // Ctrl+F and the next project's keys.
        ClearKeys(MainMenu.Items.SelectMany(m => m.Items));
        if (session != 0) _ = Core.CallAsync("session_close", new { session });
    }

    static void ClearKeys(IEnumerable<MenuFlyoutItemBase> items)
    {
        foreach (var item in items)
        {
            item.KeyboardAccelerators.Clear();
            if (item is MenuFlyoutSubItem sub) ClearKeys(sub.Items);
        }
    }

    /// Before the project goes: saved, and the place it's left at kept in its ui state for the next open. False,
    /// staying, when the save is asked about or fails.
    public async Task<bool> Leave()
    {
        if (session == 0) return true;
        if (!await Save()) return false;
        var (page, zoom) = Pdf.Place;
        // A place that can't be written is only lost.
        try
        {
            await Core.CallAsync("set_ui_state", new
            {
                id, patch = new { file = Editor.Path, line = Editor.Path is null ? (int?)null : Editor.Caret.Line, page, zoom, panel = IssuesItem.IsChecked },
            });
        }
        catch (CoreException) { }
        return true;
    }

    /// As on the Mac, before the project goes, since session_close saves quietly and would lose edits a conflict's Cancel
    /// held or a write refused, and before its ZIP, which has what is on disk. False when this save is asked about or fails.
    async Task<bool> Save()
    {
        try { return (await Core.CallAsync("session_save", new { session })).GetProperty("saved").GetBoolean(); }
        catch (CoreException ex)
        {
            await App.Alert("Can't save", ex.Message);
            return false;
        }
    }

    /// The session is numbered before it opens, so the events that come before its answer are this page's too; a tree
    /// or a build among them is newer than the answer's.
    async Task OpenSession(string? file)
    {
        session = ++sessions;
        var opened = await Core.CallAsync<SessionOpened>("session_open", new { id, session, autoCompile = Prefs.AutoCompile });
        // A smoke run ends here, not after the editor's first layout below, which a headless runner may never do.
        if (App.Smoke)
        {
            if (IsLoaded) App.ExitSmoke(null);
            else Loaded += (_, _) => App.ExitSmoke(null);
        }
        (name, root) = (opened.Name, opened.Root);
        App.Window.SetTitle(name);
        Search.PlaceholderText = $"Search {name}";
        await ShowEngines();
        ShowSettings(opened.Settings);
        var ui = opened.Ui;
        ReadFolds(ui);
        ShowTree(treeJson.Length > 0 ? tree : opened.Tree, true);
        if (opened.Pdf is { } pdf && result is null)
        {
            await Pdf.Load(pdf);
            Pdf.GoTo(ui.Page, ui.Zoom);
        }
        ShowBuild();
        ShowPanel(ui.Panel);
        // The file it was left at, unless another was asked for; one gone since, the main file.
        var shown = file ?? (ui.File is { } left && KindOf(left) is not null ? left : opened.Settings.GetProperty("mainFile").GetString());
        Select(FilesTree, i => i.Key == shown);
        if (Picked is { Type: not "dir" } node && await OpenDocument(node.Path, node.Kind) && node.Path == ui.File && ui.Line is { } line && line <= Editor.LineCount)
            Editor.GoTo(line);
    }

    /// Build › Engine, the catalogue's.
    async Task ShowEngines()
    {
        foreach (var choice in (await App.Catalogue()).Engines)
        {
            var item = new RadioMenuFlyoutItem { Text = choice.Title, GroupName = "engine", Tag = choice.Id };
            item.Click += (_, _) => Run("Can't change the engine", () => Core.CallAsync("session_set_settings", new { session, patch = new { engine = choice.Id } }));
            EngineMenu.Items.Add(item);
        }
    }

    /// The Build menu's, as session_open and session_set_settings give them.
    void ShowSettings(JsonElement settings)
    {
        ShellEscapeItem.IsChecked = settings.GetProperty("shellEscape").GetBoolean();
        StopOnErrorItem.IsChecked = settings.GetProperty("stopOnFirstError").GetBoolean();
        var engine = settings.GetProperty("engine").GetString();
        foreach (var item in EngineMenu.Items.OfType<RadioMenuFlyoutItem>()) item.IsChecked = (string)item.Tag == engine;
    }

    void OnEvent(CoreEvent e)
    {
        if (e.Session != session) return;
        var ev = e.Json.Deserialize<DocEvent>(Core.Json)!;
        switch (e.Type)
        {
            case "tree": ShowTree(ev.Tree!); break;
            case "saved": _ = Analyze(); break;
            case "document_reload": Reload(ev.Path!, ev.Text ?? ""); break;
            case "document_closed" when ev.Path == Editor.Path: CloseEditor(); break;
            case "document_renamed" when ev.From == Editor.Path:
                Editor.Path = ev.To;
                App.Window.SetTitle(name, ev.To);
                break;
            case "conflict": Conflict(ev.Path!, ev.Kind!); break;
            case "build_cleaned": Pdf.Clear(); break;
            // As on the Mac: the outline and words are read from the disk, where another app has changed a file.
            case "files_changed" when ev.Paths!.Any(p => KindOf(p) is "tex" or "bib"): _ = Analyze(); break;
            case "document":
                var failed = ev.Error is not null;
                if (failed && !unsaved.Contains(ev.Path!)) Announce(BuildState, "Wasn't saved", "save");
                if (failed || ev.Held) unsaved.Add(ev.Path!);
                else unsaved.Remove(ev.Path!);
                ShowSaved();
                break;
            case "issues":
                issueLines[ev.Path!] = ev.Lines!;
                if (ev.Path == Editor.Path) Editor.SetIssues(ev.Lines!);
                break;
            case "build":
                if (ev.Compiling && !compiling)
                {
                    BuildFailed.IsOpen = false;
                    if (!ev.Auto) Announce(BuildState, "Compiling", "build");
                }
                (compiling, outdated) = (ev.Compiling, ev.Outdated);
                ShowBuild();
                break;
            case "build_finished": Finished(ev); break;
            case "checks":
                checks = ev.Items!;
                ShowIssues();
                break;
        }
    }

    // MARK: the document

    /// Shows a file in the editor, or opens one it doesn't edit in its own app; false if the editor doesn't show it.
    async Task<bool> OpenDocument(string path, string? kind = "tex")
    {
        if (kind is not ("tex" or "bib" or "text"))
        {
            Launch(Full(path));
            return false;
        }
        // As a PDF command shows the PDF.
        SourceItem.IsChecked = true;
        if (Editor.Path == path) return true;
        try
        {
            // Opened first and the shown one closed after, so a file that won't open leaves the editor as it was.
            await Core.CallAsync("session_open_document", new { session, path });
            if (Editor.Path is { } shown && !(await Core.CallAsync("session_close_document", new { session, path = shown })).GetProperty("closed").GetBoolean())
            {
                // The session keeps no document the editor doesn't show; a later open of it opens it again.
                Run(null, () => Core.CallAsync("session_close_document", new { session, path }));
                return false;
            }
            if (Core.SessionSource(session, path) is not { } source) return false;
            (Editor.Visibility, NoFile.Visibility) = (Visibility.Visible, Visibility.Collapsed);
            await Editor.Show(path, source);
            App.Window.SetTitle(name, path);
            Editor.SetIssues(issueLines.GetValueOrDefault(path, []));
            ShowSaved();
            ShowCaret();
            SelectShownFile();
            _ = Analyze();
            return true;
        }
        catch (CoreException ex)
        {
            await App.Alert("Can't open this file", ex.Message);
            return false;
        }
    }

    /// A place in a file: a line from 1, or none for the file alone, a column from 0 and what to select from there. The
    /// file opens as Files would open it, so a graphic a definition names opens in its own app. False if the editor doesn't
    /// show it.
    async Task<bool> Reveal(string path, int? line, int column = 0, int length = 0)
    {
        if (!await OpenDocument(path, KindOf(path) ?? "tex")) return false;
        if (line is { } at) Editor.GoTo(at, column, length);
        return true;
    }

    /// A jump from the caret's place, which Back then returns to (session_navigate), unless the caret is there still.
    async Task Jump(string path, int? line, int column = 0, int length = 0)
    {
        if (Editor.Path is { } shown)
        {
            var from = new Spot(shown, Editor.Caret.Line);
            Run(null, async () => ShowTrail(await Core.CallAsync<Trail>("session_navigate", new { session, from })));
        }
        await Reveal(path, line, column, length);
    }

    void ShowTrail(Trail trail) => (BackItem.IsEnabled, ForwardItem.IsEnabled) = (trail.Back, trail.Forward);

    /// VS Code's Go back and Go forward, through the session's places, the caret's going on the other way's; also the
    /// window's Alt+Left and the mouse's buttons, false where there's no place to go to.
    public bool Go(bool back)
    {
        if (!(back ? BackItem : ForwardItem).IsEnabled) return false;
        Run(null, async () =>
        {
            if (Editor.Path is not { } path) return;
            var trail = await Core.CallAsync<Trail>(back ? "session_back" : "session_forward", new { session, at = new Spot(path, Editor.Caret.Line) });
            ShowTrail(trail);
            if (trail.To is { } to) await Reveal(to.Path, to.Line);
        });
        return true;
    }

    void OnBack(object sender, RoutedEventArgs e) => Go(true);
    void OnForward(object sender, RoutedEventArgs e) => Go(false);

    /// Visual Studio's Go to all, at the workspace's top centre: the files first, then what the query matches.
    void OnGoToAll(object sender, RoutedEventArgs e)
    {
        GoToBox.Text = "";
        GoToFlyout.ShowAt(Split, new FlyoutShowOptions { Position = new(Split.ActualWidth / 2, 8), Placement = FlyoutPlacementMode.Bottom });
        ListQuick("");
    }

    void OnGoToOpened(object sender, object e) => GoToBox.Focus(FocusState.Programmatic);

    void OnGoToChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    {
        if (e.Reason == AutoSuggestionBoxTextChangeReason.UserInput) ListQuick(sender.Text);
    }

    /// A later query's answer wins over an earlier one's.
    void ListQuick(string query) => Run(null, async () =>
    {
        var generation = ++quickQueries;
        var items = await Core.CallAsync<QuickItem[]>("session_quick_open", new { session, query });
        if (generation != quickQueries) return;
        GoToBox.ItemsSource = items;
        GoToBox.IsSuggestionListOpen = items.Length > 0;
    });

    /// Enter without a result chosen takes the best.
    void OnGoToSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs e)
    {
        if ((e.ChosenSuggestion ?? (sender.ItemsSource as QuickItem[])?.FirstOrDefault()) is not QuickItem item) return;
        GoToFlyout.Hide();
        _ = Jump(item.Path, item.Line);
    }

    /// One Escape closes it, list and all, as Visual Studio's does.
    void OnGoToKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape) return;
        e.Handled = true;
        GoToFlyout.Hide();
    }

    public static string KindGlyph(string kind) => kind switch { "heading" => "\uE8FD", "label" => "\uE8EC", _ => "\uE8A5" };

    /// VS Code's hover and Visual Studio's Quick info: what the core says the name is, by its character. Hovered, the
    /// keyboard stays in the text and the flyout goes as the pointer leaves it.
    void ShowHelp(int offset, Rect at, bool hovered) => Run(null, async () =>
    {
        if (Editor.Path is not { } path || await Core.CallAsync<QuickHelp?>("session_quick_help", new { session, path, offset }) is not { } help
            || Editor.Path != path) return;
        (HelpTitle.Text, HelpDetail.Text, helpPlace) = (help.Title, help.Detail, help.Place);
        HelpDetail.Visibility = Vis(help.Detail.Length > 0);
        HelpPlace.Visibility = Vis(help.Place is not null);
        HelpFlyout.ShowAt(Editor, new FlyoutShowOptions
        {
            Position = new(at.X, at.Bottom), ExclusionRect = at,
            ShowMode = hovered ? FlyoutShowMode.TransientWithDismissOnPointerMoveAway : FlyoutShowMode.Standard,
        });
    });

    void OnHelpPlace(object sender, RoutedEventArgs e)
    {
        HelpFlyout.Hide();
        if (helpPlace is { } place) _ = Jump(place.Path, place.Line);
    }

    /// Another app's text, or the disk's after Revert, shown without an edit. The session holds the document's saves until
    /// its source has it, so one open but not shown takes it too.
    void Reload(string path, string text)
    {
        if (path == Editor.Path)
        {
            Editor.Reload(text);
            return;
        }
        using var source = Core.SessionSource(session, path);
        source?.Reload(text);
    }

    void CloseEditor()
    {
        (analysis, currentHeading) = (null, null);
        OutlineTree.ItemsSource = null;
        Words.Text = "";
        Editor.Clear();
        App.Window.SetTitle(name);
        (Editor.Visibility, NoFile.Visibility) = (Visibility.Collapsed, Visibility.Visible);
        ShowSide();
        ShowSaved();
    }

    /// Settings › Editor, which can change while the page waits under Settings.
    void ShowLook()
    {
        Editor.SetLook(Prefs.EditorFont, Prefs.EditorFontSize, Prefs.EditorTheme);
        HelpTitle.FontFamily = SourceView.Font(Prefs.EditorFont);
        (Editor.AutoPair, Editor.AutoComplete, Editor.LineNumbers) = (Prefs.AutoPair, Prefs.AutoComplete, Prefs.LineNumbers);
    }

    /// Another app changed or removed a file with edits here. Changed, the safe choice (Cancel) is the default.
    async void Conflict(string path, string kind)
    {
        var name = System.IO.Path.GetFileName(path);
        var changed = kind == "changed";
        var answer = await App.Show(new ContentDialog
        {
            Title = changed ? $"“{name}” changed on disk" : $"“{name}” was deleted",
            Content = changed ? "It has edits here that aren't saved." : "It was deleted or moved, and it has edits here that aren't saved.",
            PrimaryButtonText = changed ? "Save anyway" : "Save again",
            SecondaryButtonText = changed ? "Revert" : "Close",
            CloseButtonText = "Cancel",
            DefaultButton = changed ? ContentDialogButton.Close : ContentDialogButton.Primary,
        }) switch
        {
            ContentDialogResult.Primary => "save",
            ContentDialogResult.Secondary => changed ? "revert" : "close",
            _ => "cancel",
        };
        Run("Can't save this file", () => Core.CallAsync("session_resolve", new { session, path, answer }));
        if (Editor.Path is not null) Editor.Focus(FocusState.Programmatic);
    }

    // MARK: builds and issues

    void Finished(DocEvent ev)
    {
        var done = result = ev.Result!;
        ShowLog();
        ShowIssues();
        var failed = !done.Ok && !done.Stopped;
        if (failed && !ev.Auto)
        {
            BuildFailed.Message = done.Errors.FirstOrDefault()?.Short ?? "";
            BuildFailed.IsOpen = true;
            ShowPanel(true);
            IssueTabs.SelectedItem = IssuesTab;
            IssueList.SelectedIndex = IssueList.Items.Count > 0 ? 0 : -1;
        }
        if (ev.Announce) Announce(BuildState, failed ? $"Build failed, {done.Errors.Length} {(done.Errors.Length == 1 ? "error" : "errors")}" : "Build succeeded", "build");
        var shown = done.Pdf is { } pdf && (done.PdfChanged || Pdf.PageCount == 0) ? Pdf.Load(pdf) : Task.CompletedTask;
        // Settings › PDF, as on the Mac: only to a PDF that shows and has the caret's text.
        if (done.Ok && !ev.Outdated && Prefs.SyncAfterCompile && PdfItem.IsChecked && Editor.Path is not null) Run(null, async () =>
        {
            await shown;
            await SyncToCaret();
        });
        outdated = ev.Outdated;
        ShowBuild();
    }

    void ShowBuild()
    {
        CompileIcon.Glyph = compiling ? "\uE71A" : "\uE768";
        CompileLabel.Text = compiling ? "Stop" : "Compile";
        AutomationProperties.SetName(CompileButton, CompileLabel.Text);
        ToolTipService.SetToolTip(CompileButton, compiling ? "Stop (Shift+F5)" : "Compile (Ctrl+Enter)");
        StopItem.IsEnabled = Pdf.Compiling = compiling;
        var state = compiling ? "Compiling…"
            : result is null ? (Pdf.PageCount > 0 ? "" : "No build yet")
            : result.Stopped ? "Build stopped"
            : result.Ok ? $"Built in {result.DurationMs / 1000.0:0.0} s"
            : "Build failed";
        // As on the Mac, only when no automatic build is coming to bring it up to date.
        BuildState.Text = outdated && !compiling && result is not null && !Prefs.AutoCompile ? $"{state} · PDF out of date" : state;
    }

    /// The bad boxes last; the Warnings toggle hides them too.
    void ShowIssues()
    {
        var issues = Issues;
        var warnings = issues.Count(i => i.Type != "error");
        (ErrorCount.Text, WarningCount.Text) = ($"{issues.Length - warnings}", $"{warnings}");
        WarningsToggle.IsEnabled = warnings + (result?.BadBoxes.Length ?? 0) > 0;
        WarningsLabel.Text = warnings == 1 ? "1 warning" : $"{warnings} warnings";
        IssueList.ItemsSource = issues.Select((item, i) => new IssueItem(i, item, fixing)).Concat((result?.BadBoxes ?? []).Select(box => new IssueItem(null, box)))
            .Where(i => (WarningsToggle.IsChecked == true || i.IsError) && (Has(i.Item.Message, issueFilter) || Has(i.Item.File, issueFilter))).ToArray();
        ShowIssueTab();
    }

    void ShowLog()
    {
        var log = (result?.Log ?? "").ReplaceLineEndings("\r");
        Log.Text = logFilter.Length == 0 ? log : string.Join('\r', log.Split('\r').Where(line => Has(line, logFilter)));
    }

    static bool Has(string? text, string part) => text?.Contains(part, StringComparison.CurrentCultureIgnoreCase) == true;

    void ShowIssueTab()
    {
        if (Log is null) return;
        var log = IssueTabs.SelectedItem == LogTab;
        var filter = Filter.Text = log ? logFilter : issueFilter;
        var none = log ? filter.Length > 0 && Log.Text.Length == 0 : IssueList.ItemsSource is not IssueItem[] { Length: > 0 };
        Log.Visibility = Vis(log && !none);
        CopyLog.Visibility = Vis(log);
        WarningsToggle.Visibility = Vis(!log);
        IssueList.Visibility = Vis(!log && !none);
        NoIssues.Visibility = Vis(none);
        NoIssues.Text = filter.Length > 0 ? $"No results for “{filter}”." : result is null ? "Compile to check for issues." : "No issues in the last build.";
    }

    void OnFilter(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    {
        if (e.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        if (IssueTabs.SelectedItem == LogTab)
        {
            logFilter = sender.Text;
            ShowLog();
            ShowIssueTab();
        }
        else
        {
            issueFilter = sender.Text;
            ShowIssues();
        }
    }

    void ShowPanel(bool open)
    {
        IssuesItem.IsChecked = open;
        IssuesRow.Height = new(open ? Prefs.IssuesHeight : 0);
        IssuesSizer.Visibility = IssuesPanel.Visibility = Vis(open);
        if (open && Editor.Path is not null) Editor.ScrollToCaret();
    }

    /// The core's pick of an issue (a click, F8, a line end's mark): selected in the panel, and its place shown.
    void GoToIssue(string command, object args) => Run("Can't show this issue", async () =>
    {
        if (await Core.CallAsync<Chosen?>(command, args) is not { } chosen) return;
        ShowPanel(true);
        IssueTabs.SelectedItem = IssuesTab;
        IssueList.SelectedItem = (IssueList.ItemsSource as IssueItem[])?.FirstOrDefault(i => i.Index == chosen.Index);
        if (IssueList.SelectedItem is { } row) IssueList.ScrollIntoView(row);
        if (chosen.Issue.File is { } file) await Jump(file, chosen.Issue.Line ?? 1);
    });

    /// A bad box isn't one of the session's issues, so its place is opened here.
    void Choose(IssueItem row)
    {
        if (row.Index is { } index) GoToIssue("session_choose_issue", new { session, index });
        else if (row.Item.File is { } file) _ = Jump(file, row.Item.Line ?? 1);
    }

    void OnIssueClick(object sender, ItemClickEventArgs e) => Choose((IssueItem)e.ClickedItem);
    void OnNextIssue(object sender, RoutedEventArgs e) => GoToIssue("session_issue", new { session, next = true });
    void OnPreviousIssue(object sender, RoutedEventArgs e) => GoToIssue("session_issue", new { session, next = false });
    void OnIssueTab(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => ShowIssueTab();
    void OnIssuesPane(object sender, RoutedEventArgs e) => ShowPanel(IssuesItem.IsChecked);
    void OnIssueCounts(object sender, RoutedEventArgs e) => ShowPanel(!IssuesItem.IsChecked);
    void OnCloseIssues(object sender, RoutedEventArgs e) => ShowPanel(false);

    /// The core's fix, run without knowing which it is (docs/core-api.md, Explanations and fixes); one at a time, as an
    /// install takes minutes. The build's refusal is ignored, since the project may have closed meanwhile.
    async void OnFix(object sender, RoutedEventArgs e)
    {
        var fix = ((IssueItem)((FrameworkElement)sender).DataContext).Item.Fix!;
        if (fix.Confirm is { } confirm && await App.Show(new ContentDialog
            {
                Title = fix.Title, Content = confirm, PrimaryButtonText = fix.Title, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
            }) != ContentDialogResult.Primary) return;
        fixing = fix.Id;
        ShowIssues();
        JsonElement answer = default;
        CoreException? failure = null;
        try { answer = await Core.CallAsync("session_fix", new { session, id = fix.Id }); }
        catch (CoreException ex) { failure = ex; }
        fixing = null;
        ShowIssues();
        if (failure is not null)
        {
            await App.Alert($"Can't {char.ToLower(fix.Title[0])}{fix.Title[1..]}", failure.Message);
            return;
        }
        // Null: the UAC prompt was cancelled.
        if (answer.ValueKind == JsonValueKind.Null) return;
        Editor.Apply(answer.GetProperty("edits").Deserialize<DocumentEdits?>(Core.Json));
        // The menus send the settings they show, so they show the fix's.
        ShowSettings(answer.GetProperty("settings"));
        Run(null, () => Core.CallAsync("session_compile", new { session }));
    }

    /// Checked and Unchecked rather than Click, which a toggle through UI Automation doesn't raise; the first comes during
    /// InitializeComponent.
    void OnWarnings(object sender, RoutedEventArgs e)
    {
        if (Log is not null) ShowIssues();
    }

    void OnShowIssues(object sender, RoutedEventArgs e)
    {
        BuildFailed.IsOpen = false;
        ShowPanel(true);
        IssueTabs.SelectedItem = IssuesTab;
        IssueList.Focus(FocusState.Programmatic);
    }

    void OnCopyLog(object sender, RoutedEventArgs e) => Copy(result?.Log ?? "");

    /// The Mac's issue menu, on the row right-clicked or, from the keyboard, the one focused.
    void OnIssueContext(UIElement sender, ContextRequestedEventArgs args)
    {
        var row = (args.OriginalSource as FrameworkElement)?.DataContext as IssueItem;
        IssueList.SelectedItem = row;
        IssuePlaceItem.Text = row?.Item.Line is null ? "Open file" : "Go to line";
        IssuePlaceItem.Visibility = Vis(row?.HasPlace == true);
        CopyIssueItem.IsEnabled = row is not null;
    }

    void OnIssuePlace(object sender, RoutedEventArgs e)
    {
        if (IssueList.SelectedItem is IssueItem row) Choose(row);
    }

    void OnCopyIssue(object sender, RoutedEventArgs e)
    {
        if (IssueList.SelectedItem is IssueItem row) Copy(row.Item.Message);
    }

    static void Copy(string text)
    {
        var data = new DataPackage();
        data.SetText(text);
        Clipboard.SetContent(data);
    }

    void OnCompileButton(object sender, RoutedEventArgs e) => (compiling ? (RoutedEventHandler)OnStop : OnCompile)(sender, e);

    /// TeX installed while the app runs is found as the window comes to the front or the page back from Settings, as on
    /// the Mac.
    public async void CheckTex()
    {
        if (texAvailable) return;
        texAvailable = (await Core.CallAsync<TexStatus>("status")).Available;
        CompileButton.IsEnabled = CompileItem.IsEnabled = texAvailable;
        Pdf.TexMissing = !texAvailable;
    }

    void OnCompile(object sender, RoutedEventArgs e) => Run("Can't compile", () => Core.CallAsync("session_compile", new { session }));
    void OnStop(object sender, RoutedEventArgs e) => Run("Can't stop the build", () => Core.CallAsync("session_stop_compile", new { session }));
    void OnClean(object sender, RoutedEventArgs e) => Run("Can't clean the build folder", () => Core.CallAsync("session_clean", new { session }));

    void OnAutoCompile(object sender, RoutedEventArgs e)
    {
        Prefs.AutoCompile = AutoCompileItem.IsChecked;
        SetAutoCompile();
    }

    /// The menu and the session follow Prefs, which the menu or Settings set.
    void SetAutoCompile()
    {
        AutoCompileItem.IsChecked = Prefs.AutoCompile;
        ShowBuild();
        Run("Can't change this setting", () => Core.CallAsync("session_set_options", new { session, autoCompile = Prefs.AutoCompile }));
    }

    void OnBuildSetting(object sender, RoutedEventArgs e) => Run("Can't change this setting", () => Core.CallAsync("session_set_settings",
        new { session, patch = new { shellEscape = ShellEscapeItem.IsChecked, stopOnFirstError = StopOnErrorItem.IsChecked } }));

    // MARK: the status bar, the panes and F6

    void ShowSaved() => NotSaved.Visibility = Vis(Editor.Path is { } path && unsaved.Contains(path));

    void ShowCaret() => CaretText.Text = $"Ln {Editor.Caret.Line}, Col {Editor.Caret.Column + 1}";

    void ShowPage()
    {
        var shown = Pdf.PageCount > 0;
        PageText.Text = shown ? $"Page {Pdf.CurrentPage} of {Pdf.PageCount}" : "No PDF";
        ZoomText.Text = $"{Pdf.Zoom * 100:0}%";
        foreach (var control in ZoomBar.Children.OfType<Control>()) control.IsEnabled = shown;
        ExportItem.IsEnabled = OpenPdfItem.IsEnabled = ShareItem.IsEnabled = PrintItem.IsEnabled = shown;
        zooming = true;
        ZoomSlider.Value = Math.Log2(Pdf.Zoom);
        zooming = false;
    }

    /// Word's slider: 100% at its middle, each step either side doubling or halving.
    void OnZoomSlider(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (!zooming && Pdf.PageCount > 0) Pdf.ZoomTo(Math.Pow(2, e.NewValue));
    }

    /// The layers keep 8 from the window's edge; beside an open inline pane, its splitter is that gap.
    void ShowEdge() => Body.Margin = new(Inline && Split.IsPaneOpen ? 0 : 8, 0, 8, 0);

    /// Laid out off-screen as the pane slides in, the tabs' repeater realizes only the first until measured again.
    static void Remeasure(DependencyObject element)
    {
        if (element is ItemsRepeater repeater) repeater.InvalidateMeasure();
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(element); i++) Remeasure(VisualTreeHelper.GetChild(element, i));
    }

    void SetSplit(double to)
    {
        ratio = Math.Clamp(to, 0.1, 0.9);
        ShowPanes();
    }

    void OnSplitReset(object sender, DoubleTappedRoutedEventArgs e)
    {
        SetSplit(0.5);
        Prefs.SplitRatio = ratio;
    }

    void ShowPanes()
    {
        var (source, pdf) = (SourceItem.IsChecked, PdfItem.IsChecked);
        (EditorLayer.Visibility, PdfLayer.Visibility, SplitSizer.Visibility) = (Vis(source), Vis(pdf), Vis(source && pdf));
        (EditorColumn.MinWidth, PdfColumn.MinWidth) = (source ? 280 : 0, pdf ? 240 : 0);
        EditorColumn.Width = new(source ? ratio : 0, GridUnitType.Star);
        PdfColumn.Width = new(pdf ? 1 - ratio : 0, GridUnitType.Star);
    }

    /// F6 and Shift+F6: the sidebar, the editor, the PDF and the issues panel in turn, each that is shown.
    void OnNextRegion(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Control side = SideTrees.FirstOrDefault(t => t.Visibility == Visibility.Visible) as Control ?? SideTabs;
        (UIElement Area, bool Shown, Func<bool> Focus)[] regions =
        [
            (SidePane, true, () => (Split.IsPaneOpen = true) && side.Focus(FocusState.Keyboard)),
            (Editor, SourceItem.IsChecked && Editor.Visibility == Visibility.Visible, () => { Editor.Focus(FocusState.Keyboard); return true; }),
            (Pdf, PdfItem.IsChecked, () => Pdf.Focus(FocusState.Keyboard)),
            (IssuesPanel, IssuesItem.IsChecked, () => (Log.Visibility == Visibility.Visible ? (Control)Log : IssueList).Focus(FocusState.Keyboard)),
        ];
        var back = args.KeyboardAccelerator.Modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Shift);
        var focused = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
        var at = Array.FindIndex(regions, r => focused is not null && Within(focused, r.Area));
        if (at < 0) at = back ? 0 : regions.Length - 1;
        for (var i = 1; i <= regions.Length; i++)
            if (regions[(at + i * (back ? regions.Length - 1 : 1)) % regions.Length] is (_, true, var focus) && focus()) return;
    }

    // MARK: dialogs and commands

    /// A Win32 menu gives focus back to the window's control when it closes; MenuBar leaves it on its own item,
    /// where typing goes nowhere. So focus that comes back to the bar from a menu, flyout or dialog goes on to
    /// wherever it was before the bar took it.
    void SetUpMenuFocus() => MainMenu.GettingFocus += (_, e) =>
    {
        if (e.OldFocusedElement is not { } old || Within(old, MainMenu)) return;
        if (XamlRoot?.Content is { } content && Within(old, content)) beforeMenu = old as UIElement;
        else DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (XamlRoot is null || FocusManager.GetFocusedElement(XamlRoot) is not MenuBarItem) return;
            if (beforeMenu is { } back && XamlRoot.Content is { } root && Within(back, root) && back.Focus(FocusState.Programmatic)) return;
            if (Editor.Path is not null) Editor.Focus(FocusState.Programmatic);
        });
    };

    static bool Within(DependencyObject element, DependencyObject ancestor)
    {
        for (var at = element; at is not null; at = VisualTreeHelper.GetParent(at))
            if (at == ancestor) return true;
        return false;
    }

    /// Notepad's Go to line, its number box focused.
    static async Task<int?> AskNumber(string title, string header, int value, int maximum)
    {
        var box = new NumberBox { Header = header, Minimum = 1, Maximum = maximum, Value = value, SmallChange = 1, ValidationMode = NumberBoxValidationMode.InvalidInputOverwritten };
        var dialog = new ContentDialog { Title = title, Content = box, PrimaryButtonText = "Go to", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        return await App.Show(dialog) == ContentDialogResult.Primary && !double.IsNaN(box.Value) ? (int)box.Value : null;
    }

    async void OnGoToLine(object sender, RoutedEventArgs e)
    {
        if (Editor.Path is null || await AskNumber("Go to line", $"Line (1–{Editor.LineCount})", Editor.Caret.Line, Editor.LineCount) is not { } line)
            return;
        SourceItem.IsChecked = true;
        Editor.GoTo(line);
    }

    async void OnGoToPage(object sender, RoutedEventArgs e)
    {
        if (Pdf.PageCount > 0 && await AskNumber("Go to page", $"Page (1–{Pdf.PageCount})", Pdf.CurrentPage, Pdf.PageCount) is { } page)
            Pdf.GoToPage(page);
    }

    /// Turns the PDF on if it's hidden, since that's where this goes.
    void OnForwardSync(object sender, RoutedEventArgs e)
    {
        if (Editor.Path is null || Pdf.PageCount == 0) return;
        PdfItem.IsChecked = true;
        Run(null, SyncToCaret);
    }

    async Task SyncToCaret()
    {
        var (line, _) = Editor.Caret;
        Pdf.Reveal(await Core.CallAsync<ForwardSync>("synctex_forward", new { id, file = Editor.Path, line }));
    }

    void OnSave(object sender, RoutedEventArgs e) => Run("Can't save", () => Core.CallAsync("session_save", new { session }));

    /// Word's Save a version: a name the core keeps with the project's files as they are.
    async void OnSaveVersion(object sender, RoutedEventArgs e)
    {
        var box = new TextBox { Header = "Name" };
        var dialog = new ContentDialog { Title = "Save version", Content = box, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false };
        box.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = box.Text.Trim().Length > 0;
        dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        if (await App.Show(dialog) != ContentDialogResult.Primary) return;
        Run("Can't save this version", async () =>
        {
            var saved = await Core.CallAsync<Snapshot>("session_history_save", new { session, name = box.Text.Trim() });
            Announce(BuildState, $"Saved version “{saved.Name}”", "history");
        });
    }

    /// A restore's edits of the open document, as Replace all's, at the version the core read.
    void OnHistory(object sender, RoutedEventArgs e) => Run("Can't restore", async () =>
    {
        if (await new HistoryDialog(session).Restore() is { } restored) Editor.Apply(restored.Edits);
    });

    void OnFind(object sender, RoutedEventArgs e) => Editor.ShowFind(false);
    void OnReplace(object sender, RoutedEventArgs e) => Editor.ShowFind(true);
    void OnFindNext(object sender, RoutedEventArgs e) => Editor.FindNext(true);
    void OnFindPrevious(object sender, RoutedEventArgs e) => Editor.FindNext(false);
    void OnShiftRight(object sender, RoutedEventArgs e) => Editor.ShiftLines(1);
    void OnShiftLeft(object sender, RoutedEventArgs e) => Editor.ShiftLines(-1);
    void OnMoveLineUp(object sender, RoutedEventArgs e) => Editor.MoveLines(true);
    void OnMoveLineDown(object sender, RoutedEventArgs e) => Editor.MoveLines(false);
    void OnDuplicateLine(object sender, RoutedEventArgs e) => Editor.ChangeLines("duplicate_lines");
    void OnDeleteLine(object sender, RoutedEventArgs e) => Editor.ChangeLines("delete_lines");
    void OnActualSize(object sender, RoutedEventArgs e) => Pdf.ZoomTo(1);

    async void OnExportPdf(object sender, RoutedEventArgs e)
    {
        if (Pdf.FilePath is not { } path) return;
        var picker = new FileSavePicker(App.Window.AppWindow.Id) { SuggestedFileName = name! };
        picker.FileTypeChoices.Add("PDF document", [".pdf"]);
        if (await picker.PickSaveFileAsync() is not { } picked) return;
        try { File.Copy(path, picked.Path, true); }
        catch (Exception ex) { await App.Alert("Can't export", ex.Message); }
    }

    void OnOpenPdf(object sender, RoutedEventArgs e) => Launch(Pdf.FilePath!);

    async void OnExportZip(object sender, RoutedEventArgs e)
    {
        if (await Save()) await App.ExportZip(id, name!, ReferenceEquals(sender, ArxivItem));
    }

    /// Windows' share sheet, which a desktop app opens through its window.
    async void OnSharePdf(object sender, RoutedEventArgs e)
    {
        if (Pdf.FilePath is not { } path) return;
        var window = Microsoft.UI.Win32Interop.GetWindowFromWindowId(App.Window.AppWindow.Id);
        // The interop throws when Windows refuses the sheet, which unhandled would end the app.
        DataTransferManager? sharing = null;
        try
        {
            sharing = DataTransferManagerInterop.GetForWindow(window);
            sharing.DataRequested += Requested;
            DataTransferManagerInterop.ShowShareUIForWindow(window);
        }
        catch (Exception ex)
        {
            if (sharing is not null) sharing.DataRequested -= Requested;
            await App.Alert("Can't share", ex.Message);
        }

        // For this Share only: the manager is the window's, and outlives the page.
        async void Requested(DataTransferManager manager, DataRequestedEventArgs args)
        {
            manager.DataRequested -= Requested;
            var deferral = args.Request.GetDeferral();
            try
            {
                args.Request.Data.Properties.Title = System.IO.Path.GetFileName(path);
                args.Request.Data.SetStorageItems([await Windows.Storage.StorageFile.GetFileFromPathAsync(path)]);
            }
            catch (Exception ex) { args.Request.FailWithDisplayText(ex.Message); }
            finally { deferral.Complete(); }
        }
    }

    // MARK: helpers

    /// A core command, its refusal shown in an alert titled `failure`; with no title, ignored.
    static async void Run(string? failure, Func<Task> call)
    {
        try { await call(); }
        catch (CoreException ex) when (failure is not null) { await App.Alert(failure, ex.Message); }
        catch (CoreException) { }
    }

    static void Announce(UIElement on, string text, string activity)
    {
        var peer = FrameworkElementAutomationPeer.FromElement(on) ?? FrameworkElementAutomationPeer.CreatePeerForElement(on);
        peer.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, text, activity);
    }

    DispatcherQueueTimer Timer(int milliseconds, Action tick)
    {
        var timer = DispatcherQueue.CreateTimer();
        (timer.Interval, timer.IsRepeating) = (TimeSpan.FromMilliseconds(milliseconds), false);
        timer.Tick += (_, _) => tick();
        return timer;
    }

    static void Restart(DispatcherQueueTimer timer)
    {
        timer.Stop();
        timer.Start();
    }

    static Visibility Vis(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

    /// In the app Windows opens the file with.
    static void Launch(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    string Full(string path) => System.IO.Path.Combine(root, path.Replace('/', '\\'));
}
