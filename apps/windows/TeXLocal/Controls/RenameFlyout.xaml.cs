using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;
using Windows.System;

namespace TeXLocal.Controls;

/// Rename in place: a name box and Rename; the core's refusal shows under the box.
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
        var stem = name.LastIndexOf('.');
        Box.Select(0, stem > 0 ? stem : name.Length);
        Commit.IsEnabled = false;
        Error.Visibility = Visibility.Collapsed;
        ShowAt(target);
    }

    void OnTextChanged(object sender, TextChangedEventArgs e)
    {
        Error.Visibility = Visibility.Collapsed;
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
        catch (CoreException ex)
        {
            Error.Text = ex.Message;
            Error.Visibility = Visibility.Visible;
        }
    }
}
