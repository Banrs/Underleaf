using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeXLocal;

/// <summary>The CodeMirror editor (contract in web/src/embed/editor.js), one for the app's lifetime.</summary>
internal sealed class EditorBridge
{
    private readonly EmbeddedPage page;

    public WebView2 View => page.View;

    public Action? Changed { get; set; }
    public Action<int>? CursorMoved { get; set; }

    /// <summary>The first line showing at the top of the editor, as it scrolls.</summary>
    public Action<int>? Scrolled { get; set; }
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
        page = new EmbeddedPage(new WebView2(), "editor.html", OnMessage);
        // Handed back, or Ctrl+Enter would insert a line; they arrive as Command.
        _ = page.SetHostKeysAsync(MenuCommands.HostKeys);
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
            case "scroll" when body.TryGetProperty("line", out var top) && top.ValueKind == JsonValueKind.Number:
                Scrolled?.Invoke(top.GetInt32());
                break;
            case "command" when body.TryGetProperty("id", out var id) && id.GetString() is { } command:
                Command?.Invoke(command);
                break;
        }
    }

    private static string L(object? value) => EmbeddedPage.Literal(value);

    /// <summary>Show a file; <paramref name="focus"/> false leaves keyboard focus where it is.</summary>
    public Task OpenAsync(string path, string text, bool focus = true) =>
        page.RunAsync($"texlocal.open({L(path)}, {L(text)}, 0, {L(focus)})");

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

    /// <summary>Go to a line: centred, or at the top as the outline shows a heading.</summary>
    public Task RevealAsync(int line, bool atTop = false, bool focus = true) =>
        page.RunAsync($"texlocal.reveal({line}, {L(atTop)}, {L(focus)})");

    public Task CommandAsync(string name, string? arg = null) =>
        page.RunAsync($"texlocal.command({L(name)}, {L(arg)})");

    public Task ForgetAsync(string path) => page.RunAsync($"texlocal.forget({L(path)})");

    /// <summary>Move a file's undo history to its new path; pages without rename() forget it.</summary>
    public Task RenameAsync(string from, string to) =>
        page.RunAsync($"texlocal.rename ? texlocal.rename({L(from)}, {L(to)}) : texlocal.forget({L(from)})");

    /// <summary>Undo or redo; in the editor's own inputs (the find panel) the browser's.</summary>
    public Task UndoAsync(bool redo) => page.RunAsync(
        $"texlocal.command({L(redo ? "redo" : "undo")}) || document.execCommand({L(redo ? "redo" : "undo")})");

    /// <summary>The interface size times Windows' text size, which a web page does not follow by itself.</summary>
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
