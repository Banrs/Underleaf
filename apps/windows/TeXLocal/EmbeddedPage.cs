using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// One of the web pages the app embeds (web/embed/*.html) in a WebView2:
/// the host calls methods on the page's <c>window.texlocal</c>, and the page
/// posts <c>{ type, ... }</c> messages back. Calls wait until the page has
/// said it is ready, and survive a crash of the page's renderer.
/// </summary>
internal sealed class EmbeddedPage
{
    /// <summary>The bundled web\ folder next to the exe, served on its own origin.</summary>
    public const string AppHost = "app.texlocal";

    private readonly WebView2 view;
    private readonly Action<string, JsonElement> onMessage;
    private TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool started;
    private bool loadedOnce;

    // The latest call of each kind that sets the page's state rather than
    // doing something once (host keys, appearance…): a reloaded page has lost
    // it, so it is replayed before anything else runs.
    private readonly Dictionary<string, string> sticky = [];

    /// <summary>Raised when the page's renderer failed; whatever the page held is gone.</summary>
    public event Action? Crashed;

    /// <summary>Raised when the page came back after its renderer failed.</summary>
    public event Action? Reloaded;

    /// <summary>How many times the renderer has failed, to tell a lost answer from an empty one.</summary>
    public int Crashes { get; private set; }

    public EmbeddedPage(WebView2 view, string page, Action<string, JsonElement> onMessage)
    {
        this.view = view;
        this.onMessage = onMessage;
        // The page is drawn on the window's own surface (the layer over Mica),
        // not on a panel of its own: no seam, and it follows the theme.
        view.DefaultBackgroundColor = Microsoft.UI.Colors.Transparent;
        // WebView2 needs its window, so it starts once the control is in the tree.
        view.Loaded += async (_, _) =>
        {
            if (!started)
            {
                started = true;
                await StartAsync(page);
            }
        };
    }

    /// <summary>The page's WebView2, once the page is ready.</summary>
    public async Task<CoreWebView2> WebAsync()
    {
        await ready.Task;
        return view.CoreWebView2;
    }

    private async Task StartAsync(string page)
    {
        await view.EnsureCoreWebView2Async();
        var web = view.CoreWebView2;
        web.SetVirtualHostNameToFolderMapping(
            AppHost, Path.Combine(AppContext.BaseDirectory, "web"), CoreWebView2HostResourceAccessKind.DenyCors);

        var settings = web.Settings;
        // Shortcuts belong to the app's menus, and Ctrl+wheel to the PDF
        // viewer's own zoom — not to the browser (reload, print, page zoom).
        settings.AreBrowserAcceleratorKeysEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.IsStatusBarEnabled = false;
#if !DEBUG
        settings.AreDevToolsEnabled = false;
#endif

        // The page itself never navigates: links open in the browser, and a
        // file dropped on it must not replace it.
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
        // A crashed renderer leaves a blank view; load the page again. Calls
        // made meanwhile wait for it, and Reloaded tells the owner to restore
        // what only it knows (the open document).
        web.ProcessFailed += (_, e) =>
        {
            if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessExited)
            {
                if (ready.Task.IsCompleted)
                {
                    ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
                }
                Crashes++;
                Crashed?.Invoke();
                web.Reload();
            }
        };
        web.Navigate($"https://{AppHost}/embed/{page}");
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
            return await view.CoreWebView2.ExecuteScriptAsync(script);
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            // The page went away mid-call (its renderer crashed, or the view
            // is closing): no result, as if the page had returned nothing.
            return "null";
        }
    }

    /// <summary>
    /// Run a script once the page is ready. Returns its result as JSON; a
    /// promise comes back as {}, so results that need awaiting are posted as
    /// messages instead.
    /// </summary>
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

    /// <summary>A value as a JavaScript literal (JSON is one).</summary>
    public static string Literal(object? value) => JsonSerializer.Serialize(value, Core.Json);
}
