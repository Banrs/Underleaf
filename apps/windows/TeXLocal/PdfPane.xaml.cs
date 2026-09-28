using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// The compiled PDF in pdf.js (contract in web/src/embed/pdf.js) under native
/// controls: Windows has no PDF view of its own with selectable text and find.
/// </summary>
public sealed partial class PdfPane : UserControl
{
    /// <summary>Where the page fetches the PDF, the only other origin pdf.html's CSP lets it fetch from.</summary>
    private const string ProjectHost = "project.texlocal";

    private readonly EmbeddedPage page;
    private string? pdfPath;

    // Typing pauses before searching: each keystroke's search would be superseded by the next.
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer findDelay;

    internal ProjectModel? Project { get; set; }

    /// <summary>A menu chord pressed while the PDF has focus, handed back by the page.</summary>
    internal Action<MenuCommand>? Command { get; set; }

    public PdfPane()
    {
        InitializeComponent();
        ZoomMenu.Items.Add(ContextMenus.Item("Fit width", FitWidth, "Ctrl+0"));
        ZoomMenu.Items.Add(ContextMenus.Item("Fit height", FitHeight, "Ctrl+Alt+0"));
        ZoomMenu.Items.Add(new MenuFlyoutSeparator());
        foreach (var percent in new[] { 50, 75, 100, 125, 150, 200 })
        {
            ZoomMenu.Items.Add(ContextMenus.Item($"{percent}%", () => SetScale(percent / 100.0)));
        }
        findDelay = DispatcherQueue.CreateTimer();
        findDelay.Interval = TimeSpan.FromMilliseconds(200);
        findDelay.IsRepeating = false;
        findDelay.Tick += (_, _) => Search();
        // Served from here, not a folder mapping, which would tie the page to one project.
        page = new EmbeddedPage(View, "pdf.html", OnMessage, web =>
        {
            web.AddWebResourceRequestedFilter($"https://{ProjectHost}/*", CoreWebView2WebResourceContext.All);
            web.WebResourceRequested += (_, e) => e.Response = PdfResponse(web.Environment);
        });
        _ = page.SetHostKeysAsync(MenuCommands.ClaimedChords);
    }

    private static string L(object? value) => EmbeddedPage.Literal(value);

    private void OnMessage(string type, JsonElement body)
    {
        switch (type)
        {
            case "page":
                PageLabel.Text = $"Page {body.GetProperty("page").GetInt32()} of {body.GetProperty("total").GetInt32()}";
                break;
            case "zoom":
                ZoomText.Text = body.GetProperty("fit").GetString() switch
                {
                    "width" => "Fit width",
                    "height" => "Fit height",
                    _ => $"{body.GetProperty("percent").GetInt32()}%",
                };
                break;
            case "inverse":
                if (Project is { } project)
                {
                    _ = project.InverseSyncAsync(
                        body.GetProperty("page").GetInt32(), body.GetProperty("x").GetDouble(), body.GetProperty("y").GetDouble());
                }
                break;
            // An answer that arrives after the bar closed has nothing to report to.
            case "found" when FindBar.Visibility == Visibility.Visible:
                var total = body.GetProperty("total").GetInt32();
                ShowFindStatus(total == 0
                    ? (FindBox.Text.Trim().Length == 0 ? "" : "Not found")
                    : $"{body.GetProperty("index").GetInt32()} of {total}{(body.GetProperty("limited").GetBoolean() ? "+" : "")}");
                PreviousMatch.IsEnabled = NextMatch.IsEnabled = total > 0;
                break;
            case "command" when body.TryGetProperty("id", out var id) && MenuCommands.FromId(id.GetString() ?? "") is { } command:
                Command?.Invoke(command);
                break;
        }
    }

    // ---------- the document ----------

    /// <summary>Show a freshly built PDF; pdf.js keeps the reader's place across the reload.</summary>
    public async Task LoadAsync(string pdfPath, int version)
    {
        ShowDocument(true);
        // pdf.js drops the last PDF's matches on load; the bar closes with them.
        if (FindBar.Visibility == Visibility.Visible)
        {
            EndFind();
        }
        this.pdfPath = pdfPath;
        // The version defeats the cache: the file keeps its name across builds.
        var url = $"https://{ProjectHost}/{Uri.EscapeDataString(Path.GetFileName(pdfPath))}?v={version}";
        await page.RunStickyAsync("load", $"texlocal.load({L(url)})");
    }

    /// <summary>The PDF read whole, so a compile can't tear pdf.js's copy; CORS as the page is on another origin.</summary>
    private CoreWebView2WebResourceResponse PdfResponse(CoreWebView2Environment environment)
    {
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(pdfPath!);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return environment.CreateWebResourceResponse(null, 404, "Not Found", "");
        }
        return environment.CreateWebResourceResponse(new MemoryStream(bytes).AsRandomAccessStream(), 200, "OK",
            $"Content-Type: application/pdf\nAccess-Control-Allow-Origin: https://{EmbeddedPage.AppHost}");
    }

    /// <summary>No PDF yet: say why instead of showing the last project's.</summary>
    public void ShowEmpty(bool texAvailable)
    {
        EmptyTitle.Text = texAvailable ? "No PDF yet" : "TeX isn’t installed";
        EmptyDetail.Text = texAvailable
            ? "Compile to preview your document."
            : "Install MiKTeX (miktex.org) or TeX Live (tug.org/texlive) to compile. TeXLocal notices once it is installed.";
        EndFind();
        PageLabel.Text = "";
        ShowDocument(false);
    }

    private void ShowDocument(bool shown)
    {
        page.View.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        Empty.Visibility = shown ? Visibility.Collapsed : Visibility.Visible;
        ZoomOutButton.IsEnabled = ZoomInButton.IsEnabled = ZoomLevel.IsEnabled = ShareButton.IsEnabled = shown;
        SetToolTip(ShareButton, shown ? "Share the PDF" : "Compile to share the PDF");
    }

    // ---------- the bar ----------

    /// <summary>Compile, or a spinner and Stop while a build runs; and whether the PDF is current.</summary>
    internal void Render(ProjectModel p, bool canCompile)
    {
        CompileButton.Visibility = p.Compiling ? Visibility.Collapsed : Visibility.Visible;
        CompileProgress.IsActive = p.Compiling;
        CompileProgress.Visibility = StopButton.Visibility = p.Compiling ? Visibility.Visible : Visibility.Collapsed;
        CompileButton.IsEnabled = canCompile;
        SetToolTip(CompileButton, p.TexAvailable ? "Compile (Ctrl+Enter)" : "Install TeX to compile");
        Freshness.Visibility = p.Freshness is null ? Visibility.Collapsed : Visibility.Visible;
        EditedIcon.Visibility = p.Freshness == PdfFreshness.Edited ? Visibility.Visible : Visibility.Collapsed;
        FailedIcon.Visibility = p.Freshness == PdfFreshness.LastSuccessful ? Visibility.Visible : Visibility.Collapsed;
        FreshnessText.Text = p.Freshness switch
        {
            PdfFreshness.Edited => "Preview out of date",
            PdfFreshness.LastSuccessful => "Last successful build",
            _ => "",
        };
        SetToolTip(Freshness, p.Freshness == PdfFreshness.LastSuccessful
            ? "The latest build failed; this is the last one that succeeded"
            : "The preview doesn’t reflect the current source");
    }

    /// <summary>Set only on change: Render runs on every edit, and setting one closes an open tooltip.</summary>
    internal static void SetToolTip(DependencyObject element, string text)
    {
        if (ToolTipService.GetToolTip(element) as string != text)
        {
            ToolTipService.SetToolTip(element, text);
        }
    }

    /// <summary>Compile, Stop and Share, each naming its <see cref="MenuCommand"/> in its Tag.</summary>
    private void OnCommand(object sender, RoutedEventArgs e) =>
        Command?.Invoke(Enum.Parse<MenuCommand>((string)((FrameworkElement)sender).Tag));

    /// <summary>The app's theme, the Windows accent, and dark paper, which inverts the pages.</summary>
    public void SetAppearance(bool dark, string accent, bool darkPaper)
    {
        _ = page.RunStickyAsync("theme", $"texlocal.setTheme({L(dark ? "dark" : "light")})");
        _ = page.RunStickyAsync("accent", $"document.documentElement.style.setProperty('--accent', {L(accent)})");
        _ = page.RunStickyAsync("paper", $"document.documentElement.classList.toggle('pdf-dark', {L(darkPaper)})");
    }

    public void Highlight(ForwardLoc loc) => _ = page.RunAsync($"texlocal.highlight({L(loc)})");

    /// <summary>Go to the source of what the reader is looking at; the answer comes as a double-click's.</summary>
    public void InverseFromView() => _ = page.RunAsync(
        "Promise.resolve(texlocal.currentLocation()).then(l => l && chrome.webview.postMessage({ type: 'inverse', ...l }))");

    // ---------- zoom ----------

    public void ZoomBy(double factor) => _ = page.RunAsync($"texlocal.zoomBy({factor.ToString(CultureInfo.InvariantCulture)})");

    public void FitWidth() => _ = page.RunAsync("texlocal.fitWidth()");

    public void FitHeight() => _ = page.RunAsync("texlocal.fitHeight()");

    private void SetScale(double scale) =>
        _ = page.RunAsync($"texlocal.setScale({scale.ToString(CultureInfo.InvariantCulture)})");

    private void OnZoom(object sender, RoutedEventArgs e) => ZoomBy(ReferenceEquals(sender, ZoomInButton) ? 1.15 : 1 / 1.15);

    // ---------- find ----------

    /// <summary>Finding takes the whole bar, as Preview's find does on the Mac.</summary>
    public void BeginFind()
    {
        CompileControls.Visibility = ViewTools.Visibility = Visibility.Collapsed;
        FindBar.Visibility = Visibility.Visible;
        FindBox.Focus(FocusState.Programmatic);
        FindBox.SelectAll();
    }

    private void EndFind()
    {
        findDelay.Stop();
        FindBar.Visibility = Visibility.Collapsed;
        CompileControls.Visibility = ViewTools.Visibility = Visibility.Visible;
        FindBox.Text = "";
        FindStatus.Text = "";
        PreviousMatch.IsEnabled = NextMatch.IsEnabled = false;
        _ = page.RunAsync("texlocal.clearFind()");
    }

    /// <summary>The count, read out as it changes: it is the search's only answer.</summary>
    private void ShowFindStatus(string text)
    {
        if (FindStatus.Text != text)
        {
            FindStatus.Text = text;
            FrameworkElementAutomationPeer.CreatePeerForElement(FindStatus)
                .RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
    }

    // find() resolves once every page is searched; a message carries its status, as a promise can't.
    private void Report(string call) =>
        _ = page.RunAsync($"Promise.resolve({call}).then(s => chrome.webview.postMessage({{ type: 'found', ...s }}))");

    private void Search()
    {
        findDelay.Stop();
        Report($"texlocal.find({L(FindBox.Text)})");
    }

    private void OnFindChanged(object sender, TextChangedEventArgs e)
    {
        findDelay.Stop();
        // Closing the bar empties the box, which is not a search.
        if (FindBar.Visibility == Visibility.Visible)
        {
            findDelay.Start();
        }
    }

    /// <summary>A step waits for a search still pending: Enter then finds the first match of what was typed.</summary>
    private void Step(int delta)
    {
        if (findDelay.IsRunning)
        {
            Search();
        }
        else
        {
            Report($"texlocal.findStep({delta})");
        }
    }

    private void OnStepMatch(object sender, RoutedEventArgs e) => Step(ReferenceEquals(sender, NextMatch) ? 1 : -1);

    private void OnFindDone(object sender, RoutedEventArgs e) => EndFind();

    private void OnFindKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            Step(shift ? -1 : 1);
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Escape)
        {
            EndFind();
            e.Handled = true;
        }
    }
}
