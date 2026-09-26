using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace TeXLocal;

/// <summary>
/// Right-click (or Shift+F10) menus for list rows, built when asked for: the
/// row under the pointer decides what the menu offers.
/// </summary>
internal static class ContextMenus
{
    /// <summary>The list row a context request came from, if any.</summary>
    public static T? Row<T>(object source) where T : DependencyObject
    {
        for (var node = source as DependencyObject; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is T row)
            {
                return row;
            }
        }
        return null;
    }

    public static MenuFlyoutItem Item(string text, Action action, string? shortcut = null)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        if (shortcut is not null)
        {
            item.KeyboardAcceleratorTextOverride = shortcut;
        }
        return item;
    }

    /// <summary>A context-menu item with its Segoe Fluent Icons glyph, and the key that does the same.</summary>
    public static MenuFlyoutItem Item(string text, string glyph, Action action, string? shortcut = null)
    {
        var item = Item(text, action, shortcut);
        item.Icon = new FontIcon { Glyph = glyph };
        return item;
    }

    /// <summary>At the pointer, or beside the row when the keyboard asked.</summary>
    public static void Show(MenuFlyout menu, FrameworkElement row, ContextRequestedEventArgs e)
    {
        e.Handled = true;
        if (e.TryGetPosition(row, out var point))
        {
            menu.ShowAt(row, new FlyoutShowOptions { Position = point });
        }
        else
        {
            menu.ShowAt(row);
        }
    }
}
