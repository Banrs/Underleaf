using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace TeXLocal.Controls;

/// Accelerators as one attribute, "Ctrl+Shift+N" or "Ctrl+Enter; F5", including the OEM keys (= - , . /) that
/// KeyboardAccelerator can't name in XAML. Scope sets their ScopeOwner.
public static class Shortcut
{
    public static readonly DependencyProperty KeysProperty =
        DependencyProperty.RegisterAttached("Keys", typeof(string), typeof(Shortcut), new PropertyMetadata(null, Apply));
    public static readonly DependencyProperty ScopeProperty =
        DependencyProperty.RegisterAttached("Scope", typeof(UIElement), typeof(Shortcut), new PropertyMetadata(null, Apply));

    public static string GetKeys(UIElement e) => (string)e.GetValue(KeysProperty);
    public static void SetKeys(UIElement e, string value) => e.SetValue(KeysProperty, value);
    public static UIElement GetScope(UIElement e) => (UIElement)e.GetValue(ScopeProperty);
    public static void SetScope(UIElement e, UIElement value) => e.SetValue(ScopeProperty, value);

    static void Apply(DependencyObject d, DependencyPropertyChangedEventArgs _)
    {
        if (d is not UIElement e || GetKeys(e) is not { } keys) return;
        var combos = keys.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        e.KeyboardAccelerators.Clear();
        foreach (var parts in combos.Select(c => c.Split('+')))
            e.KeyboardAccelerators.Add(new KeyboardAccelerator
            {
                Key = Key(parts[^1]),
                Modifiers = parts[..^1].Aggregate(VirtualKeyModifiers.None, (all, m) => all | m switch
                {
                    "Ctrl" => VirtualKeyModifiers.Control,
                    "Shift" => VirtualKeyModifiers.Shift,
                    "Alt" => VirtualKeyModifiers.Menu,
                    "Win" => VirtualKeyModifiers.Windows,
                    _ => throw new ArgumentException($"No modifier {m} in {keys}"),
                }),
                ScopeOwner = GetScope(e),
            });
        // A menu item shows its keys already, so it has no accelerator tooltip, as in Notepad's menus.
        if (e is MenuFlyoutItem item) (item.KeyboardAcceleratorTextOverride, item.KeyboardAcceleratorPlacementMode) = (combos[0], KeyboardAcceleratorPlacementMode.Hidden);
    }

    static VirtualKey Key(string name) => name switch
    {
        "Esc" => VirtualKey.Escape,
        "=" => (VirtualKey)187,
        "," => (VirtualKey)188,
        "-" => (VirtualKey)189,
        "." => (VirtualKey)190,
        "/" => (VirtualKey)191,
        [>= '0' and <= '9'] => VirtualKey.Number0 + (name[0] - '0'),
        _ => Enum.Parse<VirtualKey>(name),
    };
}
