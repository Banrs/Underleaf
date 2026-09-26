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
    private static async Task<bool> ShowAsync(ContentDialog dialog, XamlRoot root)
    {
        if (IsOpen)
        {
            return false;
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
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
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
