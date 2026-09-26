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
    public static async Task<bool> ConfirmAsync(XamlRoot root, string title, string body, string action, string cancel = "Cancel")
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action,
            CloseButtonText = cancel,
            DefaultButton = ContentDialogButton.Close,
        };
        return await ShowAsync(dialog, root) == ContentDialogResult.Primary;
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
        return (name.Text.Trim(), ProjectTemplates.All[Math.Max(0, templates.SelectedIndex)].Id);
    }
}
