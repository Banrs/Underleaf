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

    private static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot root)
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
        var dialog = new ContentDialog
        {
            Title = title,
            Content = box,
            PrimaryButtonText = action,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(dialog, root) != ContentDialogResult.Primary)
        {
            return null;
        }
        var text = box.Text.Trim();
        return text.Length == 0 ? null : text;
    }

    /// <summary>A destructive action, which Cancel guards by default.</summary>
    public static async Task<bool> ConfirmAsync(XamlRoot root, string title, string body, string action)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        return await ShowAsync(dialog, root) == ContentDialogResult.Primary;
    }

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
        return await ShowAsync(dialog, root) switch
        {
            ContentDialogResult.Primary => "replace",
            ContentDialogResult.Secondary => "keepBoth",
            _ => null,
        };
    }

    private static readonly (string Id, string Label)[] Templates =
    [
        ("article", "Article"), ("report", "Report"), ("beamer", "Beamer slides"), ("blank", "Blank"),
    ];

    public static async Task<(string Name, string Template)?> NewProjectAsync(XamlRoot root)
    {
        var name = new TextBox { Header = "Name", PlaceholderText = "My Paper" };
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        var templates = new RadioButtons { Header = "Template" };
        foreach (var (_, label) in Templates)
        {
            templates.Items.Add(label);
        }
        templates.SelectedIndex = 0;
        var dialog = new ContentDialog
        {
            Title = "New project",
            Content = new StackPanel { Spacing = 16, MinWidth = 320, Children = { name, templates } },
            PrimaryButtonText = "Create",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        if (await ShowAsync(dialog, root) != ContentDialogResult.Primary)
        {
            return null;
        }
        return (name.Text.Trim(), Templates[Math.Max(0, templates.SelectedIndex)].Id);
    }
}
