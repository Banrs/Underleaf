using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeXLocal;

/// <summary>
/// The CodeMirror editor (web/embed/editor.html, contract in
/// web/src/embed/editor.js) in a WebView2: content in native chrome. One
/// editor serves the app's whole lifetime, handed from project to project.
/// </summary>
internal sealed class EditorBridge
{
    public WebView2 View { get; } = new();
    private readonly EmbeddedPage page;

    public Action? Changed { get; set; }
    public Action<int>? CursorMoved { get; set; }
    public Action<string>? Command { get; set; }

    /// <summary>The page's renderer failed, taking the document with it.</summary>
    public event Action? Crashed
    {
        add => page.Crashed += value;
        remove => page.Crashed -= value;
    }

    public int Crashes => page.Crashes;

    /// <summary>The page reloaded after a crash and shows no document.</summary>
    public event Action? Reloaded
    {
        add => page.Reloaded += value;
        remove => page.Reloaded -= value;
    }

    public EditorBridge()
    {
        page = new EmbeddedPage(View, "editor.html", OnMessage);
        // The chords the page gives back instead of handling (Ctrl+Enter
        // would otherwise insert a line); they arrive as Command.
        _ = page.RunStickyAsync("hostKeys",
            $"texlocal.setHostKeys({L(MenuCommands.HostKeys.Select(k => new { id = k.Id, accel = k.Accel }))})");
    }

    private void OnMessage(string type, JsonElement body)
    {
        switch (type)
        {
            case "changed":
                Changed?.Invoke();
                break;
            case "cursor" when body.TryGetProperty("line", out var line) && line.ValueKind == JsonValueKind.Number:
                CursorMoved?.Invoke(line.GetInt32());
                break;
            case "command" when body.TryGetProperty("id", out var id) && id.GetString() is { } command:
                Command?.Invoke(command);
                break;
        }
    }

    private static string L(object? value) => EmbeddedPage.Literal(value);

    public Task OpenAsync(string path, string text) => page.RunAsync($"texlocal.open({L(path)}, {L(text)})");

    /// <summary>The document's text, or null when the page has none to give.</summary>
    public async Task<string?> GetTextAsync()
    {
        var text = await page.RunAsync("texlocal.getText()");
        return text.ValueKind == JsonValueKind.String ? text.GetString() : null;
    }

    public async Task<int> CurrentLineAsync()
    {
        var line = await page.RunAsync("texlocal.currentLine()");
        return line.ValueKind == JsonValueKind.Number ? line.GetInt32() : 1;
    }

    public Task RevealAsync(int line) => page.RunAsync($"texlocal.reveal({line})");

    public Task CommandAsync(string name, string? arg = null) =>
        page.RunAsync($"texlocal.command({L(name)}, {L(arg)})");

    public Task ForgetAsync(string path) => page.RunAsync($"texlocal.forget({L(path)})");

    /// <summary>
    /// Move a file's remembered state (undo history) to its new path. Pages
    /// without rename() just forget it.
    /// </summary>
    public Task RenameAsync(string from, string to) =>
        page.RunAsync($"texlocal.rename ? texlocal.rename({L(from)}, {L(to)}) : texlocal.forget({L(from)})");

    /// <summary>
    /// Undo or redo in the page. The editor declines when focus is in one of
    /// its own inputs (the find panel), which then takes the browser's own.
    /// </summary>
    public Task UndoAsync(bool redo) => page.RunAsync(
        $"texlocal.command({L(redo ? "redo" : "undo")}) || document.execCommand({L(redo ? "redo" : "undo")})");

    /// <summary>
    /// The editor's size: the interface-size setting times Windows' text
    /// size (Settings › Accessibility), which a web page does not follow by
    /// itself. The page scales as the browser version's window does.
    /// </summary>
    public Task SetZoomAsync(double zoom) =>
        page.RunStickyAsync("zoom", $"document.body.style.zoom = {L(zoom)}");

    public Task SetSymbolsAsync(Symbols symbols) =>
        page.RunStickyAsync("symbols", $"texlocal.setSymbols({L(symbols.Labels)}, {L(symbols.Citations)})");

    public Task SetAppearanceAsync(bool dark, Preferences preferences, string accent) =>
        page.RunStickyAsync("appearance", $"texlocal.setAppearance({L(new
        {
            theme = dark ? "dark" : "light",
            palette = preferences.EditorPalette,
            font = preferences.EditorFont,
            fontSize = preferences.EditorFontSize,
            accent,
        })})");

    public void Focus() => View.Focus(FocusState.Programmatic);
}
