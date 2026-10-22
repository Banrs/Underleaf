using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Controls;
using Windows.ApplicationModel.DataTransfer;
using VirtualKey = Windows.System.VirtualKey;

namespace TeXLocal.Pages;

/// An issues panel row: a build's error or warning, by its index among the build's issues, or a bad box, which is none.
/// <param name="Installing">Its missing file's package is being installed.</param>
public sealed record IssueItem(int? Index, LogItem Item, bool Installing = false)
{
    public bool Installable => Item.Missing is not null;
    public bool Idle => !Installing;
    public string InstallName => $"Install the package with {Item.Missing}";
    public bool IsError => Item.Type == "error";
    public bool IsWarning => !IsError;
    public bool HasPlace => Item.File is not null;
    public string Place => Item.Line is { } line ? $"{Item.File}:{line}" : Item.File ?? "";
    public override string ToString() => $"{(IsError ? "Error" : "Warning")}: {Item.Message}{(HasPlace ? $", {Place}" : "")}";
}

/// A project: the sidebar, the editor and the PDF, builds and their issues, all through the project's session.
public sealed partial class WorkspacePage : Page
{
    sealed record Chosen(int Index, LogItem Issue);

    static ulong sessions;
    readonly DispatcherQueueTimer searchTimer, caretTimer, scrollTimer;
    readonly HashSet<string> unsaved = [], installing = [];
    readonly Dictionary<string, IssueLine[]> issueLines = [];
    string id = "", root = "", issueFilter = "", logFilter = "";
    string? name;
    ulong session;
    bool texAvailable, compiling, outdated, zooming, sidebarWanted = true;
    double ratio = Prefs.SplitRatio;
    CompileResult? result;
    UIElement? beforeMenu;

    static Core Core => App.Core!;
    bool Inline => Split.DisplayMode == SplitViewDisplayMode.Inline;
    LogItem[] BuildIssues => result is null ? [] : [.. result.Errors, .. result.Warnings];

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
        PdfItem.RegisterPropertyChangedCallback(ToggleMenuFlyoutItem.IsCheckedProperty, (_, _) => ShowPdf());
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
            ShowCaret();
            headingLine = Editor.Caret.Line;
            caretScrolled |= scrollTimer.IsRunning;
            Restart(caretTimer);
        };
        Editor.Scrolled += () =>
        {
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
            var index = Array.FindIndex(BuildIssues, i => i.File == Editor.Path && i.Line == line.Line);
            if (index >= 0) GoToIssue("session_choose_issue", new { session, index });
        };
        Editor.FilesDropped += OnFilesDropped;
        Editor.DefinitionFound += place => _ = Reveal(place.File, place.Line, place.Column, place.Length);
        // The core's refusal shows in the flyout.
        Editor.RenameAsked += (symbol, at) => rename.Show(Editor, symbol.Name, async to => Editor.Apply((await Core.CallAsync<Replaced>("session_rename_symbol",
            new { session, kind = symbol.Kind, from = symbol.Name, to })).Edits), at);
        Pdf.ViewMoved += ShowPage;
        Pdf.Inverse += (page, x, y) => Run(null, async () =>
        {
            var at = await Core.CallAsync<InverseSync>("synctex_inverse", new { id, page, x, y });
            await Reveal(at.File, at.Line, at.Column ?? 0);
        });
        foreach (var item in (UIElement[])[BoldItem, ItalicItem, UnderlineItem, InlineItem, SymbolItem, DefinitionItem, RenameSymbolItem]) Shortcut.SetScope(item, Editor);
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
        if (session != 0) return;
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

    /// Before the project goes, as on the Mac: session_close saves quietly, so edits a conflict's Cancel held or a write
    /// refused would be lost. False, staying, when this save is asked about or fails.
    public async Task<bool> Save()
    {
        if (session == 0) return true;
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
        ShellEscapeItem.IsChecked = opened.Settings.GetProperty("shellEscape").GetBoolean();
        StopOnErrorItem.IsChecked = opened.Settings.GetProperty("stopOnFirstError").GetBoolean();
        ReadFolds(opened.Ui);
        ShowTree(treeJson.Length > 0 ? tree : opened.Tree, true);
        if (opened.Pdf is { } pdf && result is null) await Pdf.Load(pdf);
        ShowBuild();
        Select(FilesTree, i => i.Key == (file ?? opened.Settings.GetProperty("mainFile").GetString()));
        if (Picked is { Type: not "dir" } main) await OpenDocument(main.Path, main.Kind);
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
        }
    }

    // MARK: the document

    /// Shows a file in the editor, or opens one it doesn't edit in its own app; false if the editor doesn't show it.
    async Task<bool> OpenDocument(string path, string? kind = "tex")
    {
        if (kind is not ("tex" or "bib" or "text"))
        {
            Process.Start(new ProcessStartInfo(Full(path)) { UseShellExecute = true });
            return false;
        }
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

    /// A place in a file: a line from 1, a column from 0 and what to select from there. The file opens as Files would open
    /// it, so a graphic a definition names opens in its own app.
    async Task Reveal(string path, int line, int column = 0, int length = 0)
    {
        if (await OpenDocument(path, KindOf(path) ?? "tex")) Editor.GoTo(line, column, length);
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
        (ErrorCount.Text, WarningCount.Text) = ($"{done.Errors.Length}", $"{done.Warnings.Length}");
        WarningsToggle.IsEnabled = done.Warnings.Length + done.BadBoxes.Length > 0;
        WarningsLabel.Text = done.Warnings.Length == 1 ? "1 warning" : $"{done.Warnings.Length} warnings";
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

    /// The bad boxes after the warnings, as on the Mac; the Warnings toggle hides them too.
    void ShowIssues()
    {
        IssueList.ItemsSource = BuildIssues.Select((item, i) => new IssueItem(i, item, item.Missing is { } file && installing.Contains(file))).Concat((result?.BadBoxes ?? []).Select(box => new IssueItem(null, box)))
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
        if (chosen.Issue.File is { } file) await Reveal(file, chosen.Issue.Line ?? 1);
    });

    /// A bad box isn't one of the session's issues, so its place is opened here.
    void Choose(IssueItem row)
    {
        if (row.Index is { } index) GoToIssue("session_choose_issue", new { session, index });
        else if (row.Item.File is { } file) _ = Reveal(file, row.Item.Line ?? 1);
    }

    void OnIssueClick(object sender, ItemClickEventArgs e) => Choose((IssueItem)e.ClickedItem);
    void OnNextIssue(object sender, RoutedEventArgs e) => GoToIssue("session_issue", new { session, next = true });
    void OnPreviousIssue(object sender, RoutedEventArgs e) => GoToIssue("session_issue", new { session, next = false });
    void OnIssueTab(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => ShowIssueTab();
    void OnIssuesPane(object sender, RoutedEventArgs e) => ShowPanel(IssuesItem.IsChecked);
    void OnIssueCounts(object sender, RoutedEventArgs e) => ShowPanel(!IssuesItem.IsChecked);
    void OnCloseIssues(object sender, RoutedEventArgs e) => ShowPanel(false);

    /// tlmgr takes minutes, behind UAC for a TeX Live installed for all users, whose Cancel (403) needs no alert. The
    /// build runs again with its refusal ignored, since the project may have closed meanwhile.
    async void OnInstall(object sender, RoutedEventArgs e)
    {
        var file = ((IssueItem)((FrameworkElement)sender).DataContext).Item.Missing!;
        installing.Add(file);
        ShowIssues();
        CoreException? failure = null;
        try { await Core.CallAsync("install_package", new { file }); }
        catch (CoreException ex) { failure = ex; }
        installing.Remove(file);
        ShowIssues();
        if (failure is null) Run(null, () => Core.CallAsync("session_compile", new { session }));
        else if (failure.Status != 403) await App.Alert($"Can't install {file}", failure.Message);
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
        ExportItem.IsEnabled = ShareItem.IsEnabled = shown;
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
        EditorColumn.Width = new(ratio, GridUnitType.Star);
        if (PdfItem.IsChecked) PdfColumn.Width = new(1 - ratio, GridUnitType.Star);
    }

    void OnSplitReset(object sender, DoubleTappedRoutedEventArgs e)
    {
        SetSplit(0.5);
        Prefs.SplitRatio = ratio;
    }

    void ShowPdf()
    {
        var show = PdfItem.IsChecked;
        PdfLayer.Visibility = SplitSizer.Visibility = Vis(show);
        PdfColumn.MinWidth = show ? 240 : 0;
        PdfColumn.Width = new(show ? 1 - ratio : 0, GridUnitType.Star);
    }

    /// F6 and Shift+F6: the sidebar, the editor, the PDF and the issues panel in turn, each that is shown.
    void OnNextRegion(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Control side = SideTrees.FirstOrDefault(t => t.Visibility == Visibility.Visible) as Control ?? SideTabs;
        (UIElement Area, bool Shown, Func<bool> Focus)[] regions =
        [
            (SidePane, true, () => (Split.IsPaneOpen = true) && side.Focus(FocusState.Keyboard)),
            (Editor, Editor.Visibility == Visibility.Visible, () => { Editor.Focus(FocusState.Keyboard); return true; }),
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
        if (Editor.Path is not null && await AskNumber("Go to line", $"Line (1–{Editor.LineCount})", Editor.Caret.Line, Editor.LineCount) is { } line)
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
        var (line, column) = Editor.Caret;
        Pdf.Reveal(await Core.CallAsync<ForwardSync>("synctex_forward", new { id, file = Editor.Path, line, column }));
    }

    void OnSave(object sender, RoutedEventArgs e) => Run("Can't save", () => Core.CallAsync("session_save", new { session }));
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

    string Full(string path) => System.IO.Path.Combine(root, path.Replace('/', '\\'));
}
