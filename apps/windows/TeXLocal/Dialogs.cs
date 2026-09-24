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
    public static async Task<string?> PromptAsync(XamlRoot root, string title, string label, string action, string initial = "")
    {
        var box = new TextBox { Header = label, Text = initial };
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

    private static readonly (string Id, string Label)[] Templates =
    [
        ("article", "Article"), ("report", "Report"), ("beamer", "Beamer Slides"), ("blank", "Blank"),
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
            Title = "New Project",
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

    /// <summary>The app's settings, applied as they change.</summary>
    public static async Task SettingsAsync(XamlRoot root, Preferences preferences, Action changed)
    {
        ComboBox Choice(string header, (string Value, string Label)[] options, string current, Action<string> set)
        {
            var box = new ComboBox { Header = header, MinWidth = 240 };
            foreach (var (_, label) in options)
            {
                box.Items.Add(label);
            }
            box.SelectedIndex = Math.Max(0, Array.FindIndex(options, o => o.Value == current));
            box.SelectionChanged += (_, _) =>
            {
                set(options[Math.Max(0, box.SelectedIndex)].Value);
                changed();
            };
            return box;
        }

        var size = new NumberBox
        {
            Header = "Font size",
            Minimum = 10,
            Maximum = 28,
            Value = preferences.EditorFontSize,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            MinWidth = 240,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        size.ValueChanged += (_, e) =>
        {
            if (!double.IsNaN(e.NewValue))
            {
                preferences.EditorFontSize = (int)Math.Clamp(e.NewValue, 10, 28);
                changed();
            }
        };

        var dialog = new ContentDialog
        {
            Title = "Settings",
            CloseButtonText = "Done",
            Content = new StackPanel
            {
                Spacing = 16,
                Children =
                {
                    Choice("Theme", [("system", "Use system setting"), ("light", "Light"), ("dark", "Dark")],
                        preferences.Theme, v => preferences.Theme = v),
                    Choice("Syntax colors", [("onedark", "One Dark"), ("xcode", "Xcode")],
                        preferences.EditorPalette, v => preferences.EditorPalette = v),
                    Choice("Editor font", [("system", "System monospace"), ("jetbrains", "JetBrains Mono")],
                        preferences.EditorFont, v => preferences.EditorFont = v),
                    size,
                },
            },
        };
        await ShowAsync(dialog, root);
    }
}
