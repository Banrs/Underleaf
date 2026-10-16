using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TeXLocal.Bridge;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TeXLocal.Pages;

public sealed class IssueItem(int index, LogItem item)
{
    public int Index => index;
    public LogItem Item => item;
    public string Message => item.Message;
    public bool IsError => item.Type == "error";
    public bool IsWarning => item.Type == "warning";
    public bool IsInfo => !IsError && !IsWarning;
    public bool HasPlace => item.File is not null;
    public string Place => item.Line is { } line ? $"{item.File}:{line}" : item.File ?? "";
}

/// The editor, builds, issues, the PDF and SyncTeX: all through the project's session.
public sealed partial class WorkspacePage
{
    bool texAvailable, compiling, outdated, panelOpen;
    CompileResult? result;
    IssueItem[] issues = [];
    readonly HashSet<string> unsaved = [];
    readonly Dictionary<string, IssueLine[]> issueLines = [];

    void SetUpDocument()
    {
        AutoCompileItem.IsChecked = MainWindow.Pref("autoCompile", true);
        // Wherever the focus is, since the editor has no zoom of its own; the keypad's + and - too.
        var zoomKeys = new[] { (ZoomInItem, (VirtualKey)187), (ZoomInItem, VirtualKey.Add), (ZoomOutItem, (VirtualKey)189),
            (ZoomOutItem, VirtualKey.Subtract), (ActualSizeItem, VirtualKey.Number0) };
        foreach (var (item, key) in zoomKeys) item.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control });
        var ratio = MainWindow.Pref("splitRatio", 0.5);
        SetSplit(ratio);
        SplitSizer.Delta += d =>
        {
            var width = Panes.ActualWidth - SplitSizer.ActualWidth;
            if (width <= 0) return;
            var editor = Math.Clamp(EditorColumn.ActualWidth + d, EditorColumn.MinWidth, width - PdfColumn.MinWidth);
            SetSplit(editor / width);
        };
        IssuesRow.Height = new GridLength(0);
        IssuesSizer.Delta += d =>
        {
            var height = Math.Clamp(IssuesRow.ActualHeight - d, 120, Math.Max(ActualHeight / 2, 120));
            IssuesRow.Height = new GridLength(height);
            Prefs.IssuesHeight = height;
        };

        SetUpNavigation();
        SetUpInsert();
        Editor.CaretMoved += ShowCaret;
        Editor.Composing += composing =>
        {
            if (Editor.Path is { } path) _ = Core.CallAsync("session_composing", new { session, path, composing });
        };
        Editor.IssueInvoked += async line =>
        {
            var index = Array.FindIndex<LogItem>(result is null ? [] : [.. result.Errors, .. result.Warnings], i => i.File == Editor.Path && i.Line == line.Line);
            if (index >= 0) await ChooseIssue(index);
        };
        Pdf.ViewMoved += ShowPage;
        Pdf.Inverse += async (page, x, y) =>
        {
            try
            {
                var at = await Core.CallAsync<InverseSync>("synctex_inverse", new { id, page, x, y });
                await Reveal(at.File, at.Line, at.Column ?? 0);
            }
            catch (CoreException) { }
        };
    }

    void SetSplit(double ratio)
    {
        ratio = Math.Clamp(ratio, 0.1, 0.9);
        EditorColumn.Width = new GridLength(ratio, GridUnitType.Star);
        PdfColumn.Width = new GridLength(1 - ratio, GridUnitType.Star);
        Prefs.SplitRatio = ratio;
    }

    void OnSplitReset(object sender, DoubleTappedRoutedEventArgs e) => SetSplit(0.5);

    async Task OpenSession()
    {
        texAvailable = (await Core.CallAsync<TexStatus>("status")).Available;
        CompileButton.IsEnabled = CompileItem.IsEnabled = texAvailable;
        if (!texAvailable) ToolTipService.SetToolTip(CompileButton, "TeX isn't installed");
        var opened = await Core.CallAsync<SessionOpened>("session_open", new { id, autoCompile = AutoCompileItem.IsChecked && texAvailable });
        (session, root) = (opened.Session, opened.Root);
        var settings = await Core.CallAsync("get_settings", new { id });
        mainFile = settings.GetProperty("mainFile").GetString() ?? "";
        ShellEscapeItem.IsChecked = settings.GetProperty("shellEscape").GetBoolean();
        StopOnErrorItem.IsChecked = settings.GetProperty("stopOnFirstError").GetBoolean();
        var ui = await Core.CallAsync("get_ui_state", new { id });
        expanded = [.. ui.GetProperty("expandedFolders").EnumerateArray().Select(f => f.GetString()!)];
        folded = [.. ui.GetProperty("foldedHeadings").EnumerateArray().Select(f => f.GetString()!)];
        Show(opened.Tree);
        if (opened.Pdf is { } pdf) await Pdf.Load(Full(pdf));
        ShowBuild();
        if (Find(mainFile) is { IsDir: false } main)
        {
            Select(main.Path);
            await OpenDocument(main.Path, main.Kind);
        }
    }

    void OnDocumentEvent(CoreEvent e)
    {
        var json = e.Json;
        string? Str(string name) => json.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        bool Flag(string name) => json.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
        switch (e.Type)
        {
            case "document":
                var failed = Str("error") is not null;
                if (failed && !unsaved.Contains(Str("path")!)) Announce("Wasn't saved");
                if (failed || Flag("held")) unsaved.Add(Str("path")!);
                else unsaved.Remove(Str("path")!);
                ShowSaved();
                break;
            case "saved":
                _ = Analyze();
                break;
            case "document_reload" when Str("path") == Editor.Path:
                Editor.Reload(Str("text") ?? "");
                break;
            case "document_closed" when Str("path") == Editor.Path:
                CloseEditor();
                break;
            case "document_renamed" when Str("from") == Editor.Path:
                Editor.Rename(Str("to")!);
                break;
            case "conflict":
                _ = Conflict(Str("path")!, Str("kind")!);
                break;
            case "issues":
                var lines = json.GetProperty("lines").Deserialize<IssueLine[]>(Core.Json)!;
                issueLines[Str("path")!] = lines;
                if (Str("path") == Editor.Path) Editor.SetIssues(lines);
                break;
            case "build":
                var manual = !Flag("auto");
                if (Flag("compiling") && !compiling)
                {
                    BuildFailed.IsOpen = false;
                    if (manual) Announce("Compiling");
                }
                (compiling, outdated) = (Flag("compiling"), Flag("outdated"));
                ShowBuild();
                break;
            case "build_finished":
                Finished(json.GetProperty("result").Deserialize<CompileResult>(Core.Json)!, Flag("auto"), Flag("announce"));
                outdated = Flag("outdated");
                ShowBuild();
                break;
            case "build_cleaned":
                Pdf.Clear();
                break;
        }
    }

    async void Finished(CompileResult done, bool auto, bool announce)
    {
        result = done;
        issues = [.. done.Errors.Concat(done.Warnings).Select((item, i) => new IssueItem(i, item))];
        ErrorCount.Text = done.Errors.Length.ToString();
        WarningCount.Text = done.Warnings.Length.ToString();
        WarningsToggle.IsEnabled = done.Warnings.Length > 0;
        ShowIssues();
        Log.Text = done.Log.ReplaceLineEndings("\r");
        var failed = !done.Ok && !done.Stopped;
        if (failed && !auto)
        {
            BuildFailed.Message = done.Errors.FirstOrDefault()?.Short ?? "";
            BuildFailed.IsOpen = true;
            ShowPanel(true);
            IssueList.SelectedIndex = IssueList.Items.Count > 0 ? 0 : -1;
        }
        if (announce) Announce(failed ? $"Build failed, {done.Errors.Length} {(done.Errors.Length == 1 ? "error" : "errors")}" : "Build succeeded");
        if (done.Pdf is { } pdf && (done.PdfChanged || Pdf.PageCount == 0)) await Pdf.Load(Full(pdf));
    }

    void Announce(string text)
    {
        var peer = FrameworkElementAutomationPeer.FromElement(BuildState) ?? FrameworkElementAutomationPeer.CreatePeerForElement(BuildState);
        peer.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, text, "build");
    }

    void ShowBuild()
    {
        CompileIcon.Glyph = compiling ? "\uE71A" : "\uE768";
        CompileLabel.Text = compiling ? "Stop" : "Compile";
        AutomationProperties.SetName(CompileButton, CompileLabel.Text);
        if (texAvailable) ToolTipService.SetToolTip(CompileButton, compiling ? "Stop (Shift+F5)" : "Compile (Ctrl+Enter)");
        Pdf.Compiling = compiling;
        var state = compiling ? "Compiling…"
            : result is null ? (Pdf.PageCount > 0 ? "" : "No build yet")
            : result.Stopped ? "Build stopped"
            : result.Ok ? $"Built in {result.DurationMs / 1000.0:0.0} s"
            : "Build failed";
        BuildState.Text = outdated && !compiling && result is not null ? $"{state} · Preview out of date" : state;
    }

    void ShowSaved()
    {
        var show = Editor.Path is { } path && unsaved.Contains(path);
        NotSavedSegment.Opacity = show ? 1 : 0;
        NotSaved.IsEnabled = show;
    }

    void ShowCaret()
    {
        var (line, column) = Editor.Caret;
        CaretText.Text = $"Ln {line}, Col {column + 1}";
    }

    void ShowPage()
    {
        PageText.Text = Pdf.PageCount == 0 ? "No PDF" : $"Page {Pdf.CurrentPage} of {Pdf.PageCount}";
        ZoomText.Text = $"{Pdf.Zoom * 100:0}%";
    }

    void ShowIssues()
    {
        if (IssueList is null) return;
        IssueList.ItemsSource = WarningsToggle.IsChecked == true ? issues : issues.Where(i => !i.IsWarning).ToArray();
    }

    void ShowPanel(bool open)
    {
        panelOpen = IssuesItem.IsChecked = open;
        IssuesRow.Height = new GridLength(open ? Prefs.IssuesHeight : 0);
        IssuesSizer.Visibility = IssuesPanel.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (open && Editor.Path is not null) Editor.ScrollToCaret();
    }

    void OnIssuesPane(object sender, RoutedEventArgs e) => ShowPanel(IssuesItem.IsChecked);

    void OnIssueCounts(object sender, RoutedEventArgs e) => ShowPanel(!panelOpen);

    void OnShowIssues(object sender, RoutedEventArgs e)
    {
        BuildFailed.IsOpen = false;
        ShowPanel(true);
        IssueTabs.SelectedItem = IssuesTab;
        IssueList.Focus(FocusState.Programmatic);
    }

    void OnPdfPane(object sender, RoutedEventArgs e)
    {
        var show = PdfItem.IsChecked;
        Pdf.Visibility = SplitSizer.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        PdfColumn.MinWidth = show ? 240 : 0;
        PdfColumn.Width = show ? new GridLength(1 - Prefs.SplitRatio, GridUnitType.Star) : new GridLength(0);
    }

    void OnIssueTab(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (Log is null) return;
        var log = sender.SelectedItem == LogTab;
        Log.Visibility = log ? Visibility.Visible : Visibility.Collapsed;
        IssueList.Visibility = log ? Visibility.Collapsed : Visibility.Visible;
    }

    void OnWarnings(object sender, RoutedEventArgs e) => ShowIssues();

    void OnCopyLog(object sender, RoutedEventArgs e)
    {
        var data = new DataPackage();
        data.SetText(result?.Log ?? "");
        Clipboard.SetContent(data);
    }

    async void OnIssueDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (IssueList.SelectedItem is IssueItem item) await ChooseIssue(item.Index);
    }

    async void OnIssueKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || IssueList.SelectedItem is not IssueItem item) return;
        e.Handled = true;
        await ChooseIssue(item.Index);
    }

    async Task ChooseIssue(int index) => await GoToIssue(await Core.CallAsync("session_choose_issue", new { session, index }));

    async Task GoToIssue(JsonElement chosen)
    {
        if (chosen.ValueKind != JsonValueKind.Object) return;
        var index = chosen.GetProperty("index").GetInt32();
        var item = chosen.GetProperty("issue").Deserialize<LogItem>(Core.Json)!;
        if (!panelOpen) ShowPanel(true);
        IssueTabs.SelectedItem = IssuesTab;
        IssueList.SelectedItem = (IssueList.ItemsSource as IEnumerable<IssueItem>)?.FirstOrDefault(i => i.Index == index);
        if (IssueList.SelectedItem is { } row) IssueList.ScrollIntoView(row);
        if (item.File is { } file) await Reveal(file, item.Line ?? 1, 0);
    }

    async void OnNextIssue(object sender, RoutedEventArgs e) => await GoToIssue(await Core.CallAsync("session_issue", new { session, next = true }));

    async void OnPreviousIssue(object sender, RoutedEventArgs e) => await GoToIssue(await Core.CallAsync("session_issue", new { session, next = false }));

    /// Shows a file at a line and column from 0, focusing the editor.
    async Task Reveal(string path, int line, int column)
    {
        if (Editor.Path != path && !await OpenDocument(path)) return;
        Editor.GoTo(line, column);
    }

    async void OnItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is FileItem { IsDir: false } item) await OpenDocument(item.Path, item.Kind);
    }

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
            if (Editor.Path is { } shown && !(await Core.CallAsync("session_close_document", new { session, path = shown })).GetProperty("closed").GetBoolean())
                return false;
            var text = (await Core.CallAsync("session_open_document", new { session, path })).GetProperty("text").GetString() ?? "";
            if (Core.SessionSource(session, path) is not { } source) return false;
            Editor.Visibility = Visibility.Visible;
            NoFile.Visibility = Visibility.Collapsed;
            await Editor.Show(path, text, source);
            Editor.SetIssues(issueLines.GetValueOrDefault(path, []));
            ShowSaved();
            ShowCaret();
            _ = Analyze();
            return true;
        }
        catch (CoreException ex)
        {
            await App.Alert("Can't open this file", ex.Message);
            return false;
        }
    }

    void CloseEditor()
    {
        (analysis, outline) = (null, []);
        OutlineTree.ItemsSource = null;
        WordsText.Text = "";
        ShowSide();
        Editor.Clear();
        Editor.Visibility = Visibility.Collapsed;
        NoFile.Visibility = Visibility.Visible;
        ShowSaved();
    }

    async Task Conflict(string path, string kind)
    {
        var name = System.IO.Path.GetFileName(path);
        var changed = kind == "changed";
        var root = (FrameworkElement)App.Window.Content;
        var dialog = new ContentDialog
        {
            Title = changed ? $"“{name}” changed on disk" : $"“{name}” was deleted",
            Content = changed ? "It has edits here that aren't saved." : "It was deleted or moved, and it has edits here that aren't saved.",
            PrimaryButtonText = changed ? "Save anyway" : "Save again",
            SecondaryButtonText = changed ? "Revert" : "Close",
            CloseButtonText = "Cancel",
            DefaultButton = changed ? ContentDialogButton.None : ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
            RequestedTheme = root.ActualTheme,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
        };
        var first = changed;
        dialog.GettingFocus += (_, e) =>
        {
            if (!first || e.NewFocusedElement is not Button || Cancel(dialog) is not { } cancel) return;
            first = false;
            e.Handled = e.TrySetNewFocusedElement(cancel);
        };
        var answer = await dialog.ShowAsync() switch
        {
            ContentDialogResult.Primary => "save",
            ContentDialogResult.Secondary => changed ? "revert" : "close",
            _ => "cancel",
        };
        try { await Core.CallAsync("session_resolve", new { session, path, answer }); }
        catch (CoreException ex) { await App.Alert("Can't save this file", ex.Message); }
        if (Editor.Path is not null) Editor.Focus(FocusState.Programmatic);
    }

    /// With no default button, Enter must not save over the disk: focus starts on Cancel.
    static Button? Cancel(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is Button { Name: "CloseButton" } button) return button;
            if (Cancel(child) is { } found) return found;
        }
        return null;
    }

    async Task<int?> AskNumber(string title, string header, int value, int maximum)
    {
        var box = new NumberBox { Header = header, Minimum = 1, Maximum = maximum, Value = value, SmallChange = 1, ValidationMode = NumberBoxValidationMode.InvalidInputOverwritten };
        var root = (FrameworkElement)App.Window.Content;
        var dialog = new ContentDialog
        {
            Title = title,
            Content = box,
            PrimaryButtonText = "Go to",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
            RequestedTheme = root.ActualTheme,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
        };
        dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        return await dialog.ShowAsync() == ContentDialogResult.Primary && !double.IsNaN(box.Value) ? (int)box.Value : null;
    }

    async void OnGoToLine(object sender, RoutedEventArgs e)
    {
        if (Editor.Path is null) return;
        if (await AskNumber("Go to line", $"Line (1–{Editor.LineCount})", Editor.Caret.Line, Editor.LineCount) is { } line) Editor.GoTo(line);
    }

    async void OnGoToPage(object sender, RoutedEventArgs e)
    {
        if (Pdf.PageCount == 0) return;
        if (await AskNumber("Go to page", $"Page (1–{Pdf.PageCount})", Pdf.CurrentPage, Pdf.PageCount) is { } page) Pdf.GoToPage(page);
    }

    async void OnForwardSync(object sender, RoutedEventArgs e)
    {
        if (Editor.Path is not { } file || Pdf.PageCount == 0) return;
        var (line, column) = Editor.Caret;
        try
        {
            var at = await Core.CallAsync<ForwardSync>("synctex_forward", new { id, file, line, column });
            Pdf.Reveal(at);
        }
        catch (CoreException) { }
    }

    async void OnSave(object sender, RoutedEventArgs e)
    {
        try { await Core.CallAsync("session_save", new { session }); }
        catch (CoreException ex) { await App.Alert("Can't save", ex.Message); }
    }

    void OnUndo(object sender, RoutedEventArgs e) => Editor.Undo();
    void OnRedo(object sender, RoutedEventArgs e) => Editor.Redo();
    void OnCut(object sender, RoutedEventArgs e) => Editor.Cut();
    void OnCopy(object sender, RoutedEventArgs e) => Editor.Copy();
    void OnPaste(object sender, RoutedEventArgs e) => Editor.Paste();

    void OnZoomIn(object sender, RoutedEventArgs e) => Pdf.ZoomBy(1.25);
    void OnZoomOut(object sender, RoutedEventArgs e) => Pdf.ZoomBy(0.8);
    void OnActualSize(object sender, RoutedEventArgs e) => Pdf.ZoomTo(1);
    void OnFitWidth(object sender, RoutedEventArgs e) => Pdf.FitWidth();
    void OnFitPage(object sender, RoutedEventArgs e) => Pdf.FitPage();

    void OnCompileButton(object sender, RoutedEventArgs e)
    {
        if (compiling) OnStop(sender, e);
        else OnCompile(sender, e);
    }

    async void OnCompile(object sender, RoutedEventArgs e)
    {
        if (!texAvailable) return;
        try { await Core.CallAsync("session_compile", new { session }); }
        catch (CoreException ex) { await App.Alert("Can't compile", ex.Message); }
    }

    void OnStop(object sender, RoutedEventArgs e) => _ = Core.CallAsync("session_stop_compile", new { session });

    async void OnClean(object sender, RoutedEventArgs e)
    {
        try { await Core.CallAsync("session_clean", new { session }); }
        catch (CoreException ex) { await App.Alert("Can't clean the build folder", ex.Message); }
    }

    void OnAutoCompile(object sender, RoutedEventArgs e)
    {
        Prefs.AutoCompile = AutoCompileItem.IsChecked;
        _ = Core.CallAsync("session_set_options", new { session, autoCompile = AutoCompileItem.IsChecked && texAvailable });
    }

    async void OnShellEscape(object sender, RoutedEventArgs e) =>
        await Core.CallAsync("session_set_settings", new { session, patch = new { shellEscape = ShellEscapeItem.IsChecked } });

    async void OnStopOnError(object sender, RoutedEventArgs e) =>
        await Core.CallAsync("session_set_settings", new { session, patch = new { stopOnFirstError = StopOnErrorItem.IsChecked } });
}
