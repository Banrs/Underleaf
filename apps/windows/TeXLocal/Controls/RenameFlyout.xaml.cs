using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;
using Windows.Foundation;
using Windows.System;

namespace TeXLocal.Controls;

/// Rename in place: a name box and Rename; the core's refusal shows as the box's description.
public sealed partial class RenameFlyout : Flyout
{
    Func<string, Task>? rename;
    string original = "";

    public RenameFlyout() => InitializeComponent();

    /// At a rectangle of the target's, a name in the text, selected whole as VS Code's Rename Symbol has it; otherwise a
    /// file's or a project's, its stem selected as File Explorer's.
    public void Show(FrameworkElement target, string name, Func<string, Task> rename, Rect? at = null)
    {
        this.rename = rename;
        original = name;
        Box.Text = name;
        Box.Description = null;
        var stem = name.LastIndexOf('.');
        Box.Select(0, at is null && stem > 0 ? stem : name.Length);
        Commit.IsEnabled = false;
        if (at is { } r) ShowAt(target, new FlyoutShowOptions { Position = new(r.X, r.Bottom), ExclusionRect = r });
        else ShowAt(target);
    }

    void OnTextChanged(object sender, TextChangedEventArgs e)
    {
        Box.Description = null;
        Commit.IsEnabled = Box.Text.Trim() is { Length: > 0 } t && t != original;
    }

    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || !Commit.IsEnabled) return;
        e.Handled = true;
        OnCommit(sender, e);
    }

    async void OnCommit(object sender, RoutedEventArgs e)
    {
        Commit.IsEnabled = false;
        try
        {
            await rename!(Box.Text.Trim());
            Hide();
        }
        catch (CoreException ex) { Box.Description = ex.Message; }
    }
}
