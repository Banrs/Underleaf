using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;
using VirtualKey = Windows.System.VirtualKey;

namespace TeXLocal.Controls;

/// RichEdit finds; replacements are the session's edits like any other.
public sealed partial class SourceView
{
    const int Forward = 0x3FFFFFFF, MostCounted = 999;

    FindOptions Options => (MatchCase.IsChecked ? FindOptions.Case : FindOptions.None) | (WholeWord.IsChecked ? FindOptions.Word : FindOptions.None);

    bool FindShown => FindBar.Visibility == Visibility.Visible;

    public void ShowFind(bool replace)
    {
        if (source is null) return;
        CloseCompletions();
        var s = Selected;
        if (s.Length is > 0 and < 200 && Text.IndexOf('\n', s.Start, s.Length) < 0) FindBox.Text = Text.Substring(s.Start, s.Length);
        FindBar.Visibility = Visibility.Visible;
        ShowReplace(replace || ReplaceBox.Visibility == Visibility.Visible);
        // Replace takes the keys only once there is something to find (VS Code, Notepad).
        (replace && FindBox.Text.Length > 0 ? ReplaceBox : FindBox).Focus(FocusState.Keyboard);
        FindBox.SelectAll();
        Count();
    }

    void ShowReplace(bool show)
    {
        ReplaceBox.Visibility = ReplaceButtons.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        ReplaceChevron.Glyph = show ? "\uE70D" : "\uE76C";
        Band();
    }

    /// VS Code's space above the text while the bar is open, as tall as the bar, so no match is ever under it.
    void Band()
    {
        Editor.Padding = new Thickness(8, 8 + (!FindShown ? 0 : ReplaceBox.Visibility == Visibility.Visible ? 84 : 48), 16, 8);
        Invalidate(false);
    }

    void HideFind()
    {
        if (!FindShown) return;
        FindBar.Visibility = Visibility.Collapsed;
        Band();
        Editor.Focus(FocusState.Programmatic);
    }

    public void FindNext(bool forward)
    {
        if (source is null) return;
        var s = Selected;
        if (FindBox.Text.Length == 0) ShowFind(false);
        else if ((Search(forward ? s.End : s.Start, forward) ?? Search(forward ? 0 : Text.Length, forward)) is { } found) Place(found);
        Count();
    }

    SourceRange? Search(int from, bool forward)
    {
        var range = forward ? Document.GetRange(from, Text.Length) : Document.GetRange(0, from);
        return range.FindText(FindBox.Text, forward ? Forward : -Forward, Options) > 0
            ? new SourceRange(range.StartPosition, range.EndPosition - range.StartPosition) : null;
    }

    List<SourceRange> Matches(int most = int.MaxValue)
    {
        var found = new List<SourceRange>();
        for (var at = 0; found.Count < most && Search(at, true) is { } match; at = match.End) found.Add(match);
        return found;
    }

    void Count()
    {
        List<SourceRange> matches = FindBox.Text.Length == 0 || source is null ? [] : Matches(MostCounted + 1);
        var at = matches.IndexOf(Selected);
        var total = matches.Count > MostCounted ? $"{MostCounted}+" : $"{matches.Count}";
        FindCount.Text = FindBox.Text.Length == 0 ? "" : matches.Count == 0 ? "No results" : at < 0 ? $"{total} found" : $"{at + 1} of {total}";
        ReplaceOne.IsEnabled = ReplaceEvery.IsEnabled = matches.Count > 0;
        FrameworkElementAutomationPeer.FromElement(FindCount)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    void OnFindChanged(object sender, object e)
    {
        if (source is not null && FindBox.Text.Length > 0 && (Search(Selected.Start, true) ?? Search(0, true)) is { } found) Place(found);
        Count();
    }

    void OnFindNext(object sender, RoutedEventArgs e) => FindNext(true);
    void OnFindPrevious(object sender, RoutedEventArgs e) => FindNext(false);
    void OnFindClose(object sender, RoutedEventArgs e) => HideFind();
    void OnReplaceToggle(object sender, RoutedEventArgs e) => ShowReplace(ReplaceBox.Visibility != Visibility.Visible);

    void OnFindKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape) HideFind();
        else if (e.Key == VirtualKey.Enter && ReferenceEquals(sender, ReplaceBox)) OnReplace(sender, e);
        else if (e.Key == VirtualKey.Enter) FindNext(!Down(VirtualKey.Shift));
        else return;
        e.Handled = true;
    }

    void OnReplace(object sender, RoutedEventArgs e)
    {
        if (source is null || FindBox.Text.Length == 0) return;
        var s = Selected;
        if (Search(s.Start, true) == s) Apply(new TextEdit(s.Start, s.Length, ReplaceBox.Text));
        FindNext(true);
    }

    void OnReplaceAll(object sender, RoutedEventArgs e)
    {
        if (source is null || FindBox.Text.Length == 0) return;
        Apply([.. Matches().Select(m => new TextEdit(m.Start, m.Length, ReplaceBox.Text))]);
        Count();
    }
}
