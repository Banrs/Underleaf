using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;
using Windows.System;

namespace TeXLocal.Controls;

/// Rename in place: a name box and Rename; the core's refusal shows as the box's description.
public sealed partial class RenameFlyout : Flyout
{
    Func<string, Task>? rename;
    string original = "";

    public RenameFlyout() => InitializeComponent();

    public void Show(FrameworkElement target, string name, Func<string, Task> rename)
    {
        this.rename = rename;
        original = name;
        Box.Text = name;
        Box.Description = null;
        var stem = name.LastIndexOf('.');
        Box.Select(0, stem > 0 ? stem : name.Length);
        Commit.IsEnabled = false;
        ShowAt(target);
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
