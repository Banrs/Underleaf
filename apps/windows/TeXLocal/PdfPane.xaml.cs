using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// The compiled PDF in pdf.js (web/embed/pdf.html, contract in
/// web/src/embed/pdf.js), driven by native controls. Windows has no PDF view
/// of its own with selectable text and find.
/// </summary>
public sealed partial class PdfPane : UserControl
{
    /// <summary>The project's build folder, the only other origin pdf.html's CSP lets it fetch from.</summary>
    private const string ProjectHost = "project.texlocal";

    private readonly EmbeddedPage page;
    private string? mappedFolder;

    internal ProjectModel? Project { get; set; }

    /// <summary>A menu chord pressed while the PDF has focus, handed back by the page.</summary>
    internal Action<MenuCommand>? Command { get; set; }

    public PdfPane()
    {
        InitializeComponent();
        page = new EmbeddedPage(View, "pdf.html", OnMessage);
        _ = page.RunStickyAsync("hostKeys", $"texlocal.setHostKeys({L(MenuCommands.ClaimedChords.Select(k => new { id = k.Id, accel = k.Accel }))})");
    }

    private static string L(object? value) => EmbeddedPage.Literal(value);

    private void OnMessage(string type, JsonElement body)
    {
        switch (type)
        {
            case "page":
                PageLabel.Text = $"Page {body.GetProperty("page").GetInt32()} of {body.GetProperty("total").GetInt32()}";
                break;
            case "inverse":
                if (Project is { } project)
                {
                    _ = project.InverseSyncAsync(
                        body.GetProperty("page").GetInt32(), body.GetProperty("x").GetDouble(), body.GetProperty("y").GetDouble());
                }
                break;
            case "found":
                var total = body.GetProperty("total").GetInt32();
                FindStatus.Text = total == 0
                    ? (FindBox.Text.Length == 0 ? "" : "No matches")
                    : $"{body.GetProperty("index").GetInt32()} of {total}{(body.GetProperty("limited").GetBoolean() ? "+" : "")}";
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
        var web = await page.WebAsync();
        var folder = Path.GetDirectoryName(pdfPath)!;
        if (folder != mappedFolder)
        {
            if (mappedFolder is not null)
            {
                web.ClearVirtualHostNameToFolderMapping(ProjectHost);
            }
            // Allow: the page, on its own origin, fetches the PDF cross-origin.
            web.SetVirtualHostNameToFolderMapping(ProjectHost, folder, CoreWebView2HostResourceAccessKind.Allow);
            mappedFolder = folder;
        }
        // The version defeats the cache: the file keeps its name across builds.
        var url = $"https://{ProjectHost}/{Uri.EscapeDataString(Path.GetFileName(pdfPath))}?v={version}";
        await page.RunStickyAsync("load", $"texlocal.load({L(url)})");
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
        View.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        Empty.Visibility = shown ? Visibility.Collapsed : Visibility.Visible;
        ZoomOutButton.IsEnabled = ZoomInButton.IsEnabled = FitWidthButton.IsEnabled = shown;
    }

    public void SetTheme(bool dark) => _ = page.RunStickyAsync("theme", $"texlocal.setTheme({L(dark ? "dark" : "light")})");

    public void Highlight(ForwardLoc loc) => _ = page.RunAsync($"texlocal.highlight({L(loc)})");

    /// <summary>
    /// Go to the source of what the reader is looking at. The page answers
    /// through the same message a double-click sends.
    /// </summary>
    public void InverseFromView() => _ = page.RunAsync(
        "Promise.resolve(texlocal.currentLocation()).then(l => l && chrome.webview.postMessage({ type: 'inverse', ...l }))");

    // ---------- zoom ----------

    public void ZoomBy(double factor) => _ = page.RunAsync($"texlocal.zoomBy({factor.ToString(System.Globalization.CultureInfo.InvariantCulture)})");

    public void FitWidth() => _ = page.RunAsync("texlocal.fitWidth()");

    public void FitHeight() => _ = page.RunAsync("texlocal.fitHeight()");

    private void OnZoomOut(object sender, RoutedEventArgs e) => ZoomBy(1 / 1.15);

    private void OnZoomIn(object sender, RoutedEventArgs e) => ZoomBy(1.15);

    private void OnFitWidth(object sender, RoutedEventArgs e) => FitWidth();

    // ---------- find ----------

    public void BeginFind()
    {
        PageLabel.Visibility = Visibility.Collapsed;
        FindBar.Visibility = Visibility.Visible;
        FindBox.Focus(FocusState.Programmatic);
        FindBox.SelectAll();
    }

    private void EndFind()
    {
        FindBar.Visibility = Visibility.Collapsed;
        PageLabel.Visibility = Visibility.Visible;
        FindBox.Text = "";
        FindStatus.Text = "";
        _ = page.RunAsync("texlocal.clearFind()");
    }

    // find() resolves once every page is searched; its status comes back as
    // a message because a script's promise does not.
    private void Report(string call) =>
        _ = page.RunAsync($"Promise.resolve({call}).then(s => chrome.webview.postMessage({{ type: 'found', ...s }}))");

    private void OnFindChanged(object sender, TextChangedEventArgs e) => Report($"texlocal.find({L(FindBox.Text)})");

    private void OnPreviousMatch(object sender, RoutedEventArgs e) => Report("texlocal.findStep(-1)");

    private void OnNextMatch(object sender, RoutedEventArgs e) => Report("texlocal.findStep(1)");

    private void OnFindDone(object sender, RoutedEventArgs e) => EndFind();

    private void OnFindKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            Report($"texlocal.findStep({(shift ? -1 : 1)})");
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Escape)
        {
            EndFind();
            e.Handled = true;
        }
    }
}
