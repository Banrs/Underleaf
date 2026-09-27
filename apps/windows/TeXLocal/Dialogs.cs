using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeXLocal;

/// <summary>
/// The app's modal questions, as ContentDialogs. WinUI shows one at a time,
/// so commands are ignored while one is open.
/// </summary>
internal static class Dialogs
{
    public static bool IsOpen { get; private set; }

    private static ContentDialog Dialog(string title, object content, string action, string cancel = "Cancel",
        ContentDialogButton defaultButton = ContentDialogButton.Primary) => new()
    {
        Title = title,
        Content = content,
        PrimaryButtonText = action,
        CloseButtonText = cancel,
        DefaultButton = defaultButton,
    };

    /// <summary>Whether the primary action was chosen.</summary>
    private static async Task<bool> ShowAsync(ContentDialog dialog, XamlRoot root) =>
        await ChooseAsync(dialog, root) == ContentDialogResult.Primary;

    /// <summary>The button chosen; None when another dialog is already open.</summary>
    private static async Task<ContentDialogResult> ChooseAsync(ContentDialog dialog, XamlRoot root)
    {
        if (IsOpen)
        {
            return ContentDialogResult.None;
        }
        dialog.XamlRoot = root;
        dialog.Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"];
        // A dialog sits outside the window's content, so it takes the app's
        // theme from there rather than inheriting it.
        if (root.Content is FrameworkElement content)
        {
            dialog.RequestedTheme = content.RequestedTheme;
        }
        IsOpen = true;
        try
        {
            return await dialog.ShowAsync();
        }
        finally
        {
            IsOpen = false;
        }
    }

    /// <summary>One line of text, trimmed; null when cancelled or left empty.</summary>
    public static async Task<string?> PromptAsync(
        XamlRoot root, string title, string label, string action, string initial = "", string placeholder = "")
    {
        var box = new TextBox { Header = label, Text = initial, PlaceholderText = placeholder, MinWidth = 320 };
        box.Loaded += (_, _) =>
        {
            box.Focus(FocusState.Programmatic);
            box.SelectAll();
        };
        return await ShowAsync(Dialog(title, box, action), root) && box.Text.Trim() is { Length: > 0 } text ? text : null;
    }

    /// <summary>A destructive action, which Cancel guards by default.</summary>
    public static Task<bool> ConfirmAsync(XamlRoot root, string title, string body, string action, string cancel = "Cancel") =>
        ShowAsync(Dialog(title, new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap }, action, cancel, ContentDialogButton.Close), root);

    /// <summary>
    /// Names an import would take, asked about once for them all, in the
    /// Mac's words: "replace", "keepBoth", or null to stop.
    /// </summary>
    public static async Task<string?> ImportClashAsync(XamlRoot root, IReadOnlyList<ImportClash> clashes)
    {
        var names = clashes.Select(c => c.Path).ToList();
        var one = names.Count == 1;
        var replace = one
            ? "Do you want to replace it with the one you’re copying? The one here will be moved to the Recycle Bin."
            : "Do you want to replace them with the ones you’re copying? The ones here will be moved to the Recycle Bin.";
        // A few by name, so a folder's worth doesn't fill the dialog.
        var shown = names.Take(3).Select(n => $"“{n}”").ToList();
        if (names.Count > shown.Count)
        {
            shown.Add($"{names.Count - shown.Count} more");
        }
        var list = shown.Count switch
        {
            1 => shown[0],
            2 => $"{shown[0]} and {shown[1]}",
            _ => $"{string.Join(", ", shown[..^1])}, and {shown[^1]}",
        };
        var dialog = new ContentDialog
        {
            Title = one
                ? $"An item named “{names[0][(names[0].LastIndexOf('/') + 1)..]}” already exists here"
                : $"{names.Count} items with these names already exist here",
            Content = new TextBlock { Text = one ? replace : $"{list}. {replace}", TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = "Replace",
            SecondaryButtonText = "Keep both",
            CloseButtonText = "Stop",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await ChooseAsync(dialog, root) switch
        {
            ContentDialogResult.Primary => "replace",
            ContentDialogResult.Secondary => "keepBoth",
            _ => null,
        };
    }

    public static async Task<(string Name, string Template)?> NewProjectAsync(XamlRoot root, string template)
    {
        var name = new TextBox { Header = "Name", PlaceholderText = "My Paper" };
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        var templates = new RadioButtons { Header = "Template" };
        foreach (var t in ProjectTemplates.All)
        {
            templates.Items.Add(t.Title);
        }
        templates.SelectedIndex = Math.Max(0, ProjectTemplates.All.ToList().FindIndex(t => t.Id == template));
        var dialog = Dialog("New project", new StackPanel { Spacing = 16, MinWidth = 320, Children = { name, templates } }, "Create");
        dialog.IsPrimaryButtonEnabled = false;
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        return await ShowAsync(dialog, root) ? (name.Text.Trim(), ProjectTemplates.All[Math.Max(0, templates.SelectedIndex)].Id) : null;
    }
}
