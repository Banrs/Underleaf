using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// A web/embed/*.html page in a WebView2: the host calls <c>window.texlocal</c>,
/// the page posts <c>{ type, ... }</c> back. Calls wait for the page's "ready"
/// and survive a renderer or browser-process crash.
/// </summary>
internal sealed class EmbeddedPage
{
    /// <summary>The bundled web\ folder next to the exe, served on its own origin.</summary>
    public const string AppHost = "app.texlocal";

    private readonly string page;
    private readonly Action<string, JsonElement> onMessage;
    private readonly Action<CoreWebView2>? configure;
    private TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool started;
    private bool loadedOnce;

    // The latest state-setting call of each kind, replayed first after a reload.
    private readonly Dictionary<string, string> sticky = [];

    /// <summary>Raised when the page's renderer failed; whatever the page held is gone.</summary>
    public event Action? Crashed;

    /// <summary>Raised when the page came back after its renderer failed.</summary>
    public event Action? Reloaded;

    /// <summary>How many times the renderer has failed, to tell a lost answer from an empty one.</summary>
    public int Crashes { get; private set; }

    /// <param name="configure">Sets up each new CoreWebView2 before the page loads in it.</param>
    public EmbeddedPage(WebView2 view, string page, Action<string, JsonElement> onMessage, Action<CoreWebView2>? configure = null)
    {
        View = view;
        this.page = page;
        this.onMessage = onMessage;
        this.configure = configure;
        Attach(view);
    }

    /// <summary>The page's WebView2; a new one after the browser process died.</summary>
    public WebView2 View { get; private set; }

    private void Attach(WebView2 view)
    {
        // Drawn on the window's own surface over Mica: no seam, and it follows the theme.
        view.DefaultBackgroundColor = Microsoft.UI.Colors.Transparent;
        // WebView2 needs its window, so it starts once the control is in the tree.
        view.Loaded += async (_, _) =>
        {
            if (!started)
            {
                started = true;
                await StartAsync();
            }
        };
    }

    private async Task StartAsync()
    {
        await View.EnsureCoreWebView2Async();
        var web = View.CoreWebView2;
        web.SetVirtualHostNameToFolderMapping(
            AppHost, Path.Combine(AppContext.BaseDirectory, "web"), CoreWebView2HostResourceAccessKind.DenyCors);

        var settings = web.Settings;
        // Shortcuts belong to the app's menus and Ctrl+wheel to the PDF's zoom, not the browser.
        settings.AreBrowserAcceleratorKeysEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.IsStatusBarEnabled = false;
#if !DEBUG
        settings.AreDevToolsEnabled = false;
#endif
        // No browser menu (Back, Reload, Inspect…); the editor keeps a text field's items.
        if (page == "pdf.html")
        {
            settings.AreDefaultContextMenusEnabled = false;
        }
        else
        {
            web.ContextMenuRequested += (_, e) => KeepEditItems(e);
        }

        // The page never navigates: links open in the browser, a dropped file must not replace it.
        web.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith($"https://{AppHost}/", StringComparison.OrdinalIgnoreCase))
            {
                e.Cancel = true;
                OpenExternally(e.Uri);
            }
        };
        web.NewWindowRequested += (_, e) =>
        {
            e.Handled = true;
            OpenExternally(e.Uri);
        };
        web.WebMessageReceived += (_, e) => Receive(e.WebMessageAsJson);
        await web.AddScriptToExecuteOnDocumentCreatedAsync(
            "addEventListener('DOMContentLoaded', () => document.head.insertAdjacentHTML('beforeend', " +
            "'<style>html, body, .cm-editor { background: transparent !important; }</style>'))");
        // A crashed renderer is reloaded. A dead browser process takes the view
        // with it, and a WebView2 can't start twice, so a new one replaces it.
        // Calls wait meanwhile; Reloaded lets the owner restore the document.
        web.ProcessFailed += (_, e) =>
        {
            var browser = e.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited;
            if (!browser && e.ProcessFailedKind != CoreWebView2ProcessFailedKind.RenderProcessExited)
            {
                return;
            }
            if (ready.Task.IsCompleted)
            {
                ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
            }
            Crashes++;
            Crashed?.Invoke();
            if (browser)
            {
                Replace();
            }
            else
            {
                web.Reload();
            }
        };
        configure?.Invoke(web);
        web.Navigate($"https://{AppHost}/embed/{page}");
    }

    private void Replace()
    {
        var old = View;
        var children = ((Panel)old.Parent).Children;
        View = new WebView2 { Visibility = old.Visibility };
        started = false;
        Attach(View);
        children[children.IndexOf(old)] = View;
        old.Close();
    }

    /// <summary>The unlocalised <see cref="CoreWebView2ContextMenuItem.Name"/>s of a text field's menu items.</summary>
    private static readonly HashSet<string> EditItems = ["cut", "copy", "paste", "selectAll", "spellCheck"];

    /// <summary>Trim the page's menu to its edit items, with no separator left leading, trailing or doubled.</summary>
    private static void KeepEditItems(CoreWebView2ContextMenuRequestedEventArgs e)
    {
        var items = e.MenuItems;
        for (var i = items.Count - 1; i >= 0; i--)
        {
            var separator = items[i].Kind == CoreWebView2ContextMenuItemKind.Separator;
            if (separator ? i == 0 || i == items.Count - 1 || items[i + 1].Kind == CoreWebView2ContextMenuItemKind.Separator
                : !EditItems.Contains(items[i].Name))
            {
                items.RemoveAt(i);
            }
        }
        if (items.Count > 0 && items[0].Kind == CoreWebView2ContextMenuItemKind.Separator)
        {
            items.RemoveAt(0);
        }
        // Nothing left (a right-click away from any text): no menu at all.
        e.Handled = items.Count == 0;
    }

    private static void OpenExternally(string uri)
    {
        if (Uri.TryCreate(uri, UriKind.Absolute, out var url) && url.Scheme is "http" or "https" or "mailto")
        {
            _ = Launcher.LaunchUriAsync(url);
        }
    }

    private async void Receive(string json)
    {
        using var message = JsonDocument.Parse(json);
        var body = message.RootElement;
        var type = body.TryGetProperty("type", out var t) ? t.GetString() : null;
        if (type != "ready")
        {
            onMessage(type ?? "", body.Clone());
            return;
        }
        if (loadedOnce)
        {
            foreach (var script in sticky.Values)
            {
                await ExecuteAsync(script);
            }
        }
        var reloaded = loadedOnce;
        loadedOnce = true;
        ready.TrySetResult();
        if (reloaded)
        {
            Reloaded?.Invoke();
        }
    }

    private async Task<string> ExecuteAsync(string script)
    {
        try
        {
            return await View.CoreWebView2.ExecuteScriptAsync(script);
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            // The page went away mid-call (a crash, or closing): as if it returned nothing.
            return "null";
        }
    }

    /// <summary>Run a script once the page is ready; a promise comes back as {}, so those post messages instead.</summary>
    public async Task<JsonElement> RunAsync(string script)
    {
        await ready.Task;
        using var result = JsonDocument.Parse(await ExecuteAsync(script));
        return result.RootElement.Clone();
    }

    /// <summary>Set part of the page's state, remembered for a reload.</summary>
    public Task RunStickyAsync(string key, string script)
    {
        sticky[key] = script;
        return RunAsync(script);
    }

    /// <summary>The chords the page gives back instead of handling; they arrive as "command" messages.</summary>
    public Task SetHostKeysAsync(IEnumerable<(string Id, string Accel)> keys) =>
        RunStickyAsync("hostKeys", $"texlocal.setHostKeys({Literal(keys.Select(k => new { id = k.Id, accel = k.Accel }))})");

    /// <summary>A value as a JavaScript literal (JSON is one).</summary>
    public static string Literal(object? value) => JsonSerializer.Serialize(value, Core.Json);
}
