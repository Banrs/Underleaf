using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;
using VirtualKey = Windows.System.VirtualKey;

namespace TeXLocal.Controls;

/// The core finds (`find`), folding case as project search does, so Ctrl+F and Ctrl+Shift+F find the same; replacements
/// are the session's edits like any other.
public sealed partial class SourceView
{
    bool FindShown => FindBar.Visibility == Visibility.Visible;

    public void ShowFind() => OpenFind(false);
    public void ShowReplace() => OpenFind(true);
    public void FindNext() => Step(true);
    public void FindPrevious() => Step(false);

    void OpenFind(bool replace)
    {
        if (source is null) return;
        CloseCompletions();
        var s = Selected;
        if (s.Length is > 0 and < 200 && Text.IndexOf('\n', s.Start, s.Length) < 0) FindBox.Text = Text.Substring(s.Start, s.Length);
        FindBar.Visibility = Visibility.Visible;
        ShowReplaceRow(replace || ReplaceBox.Visibility == Visibility.Visible);
        // Replace takes the keys only once there is something to find (VS Code, Notepad).
        (replace && FindBox.Text.Length > 0 ? ReplaceBox : FindBox).Focus(FocusState.Keyboard);
        FindBox.SelectAll();
        Count();
    }

    void ShowReplaceRow(bool show)
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

    void Step(bool forward)
    {
        if (source is null) return;
        var s = Selected;
        if (FindBox.Text.Length == 0) ShowFind();
        else if (Next(forward ? s.End : s.Start, forward) is { } found) Place(found);
        Count();
    }

    SourceRange[] Matches() => FindBox.Text.Length == 0 || source is null ? []
        : source.Call<SourceRange[]>("find", new { query = FindBox.Text, matchCase = MatchCase.IsChecked, wholeWord = WholeWord.IsChecked }) ?? [];

    /// The first match from `from` on, or the last before it, round the document's ends.
    SourceRange? Next(int from, bool forward)
    {
        var matches = Matches();
        return forward ? matches.FirstOrDefault(m => m.Start >= from) ?? matches.FirstOrDefault()
            : matches.LastOrDefault(m => m.End <= from) ?? matches.LastOrDefault();
    }

    void Count()
    {
        var matches = Matches();
        var at = Array.IndexOf(matches, Selected);
        FindCount.Text = FindBox.Text.Length == 0 ? "" : matches.Length == 0 ? "No results" : at < 0 ? $"{matches.Length} found" : $"{at + 1} of {matches.Length}";
        ReplaceOne.IsEnabled = ReplaceEvery.IsEnabled = matches.Length > 0;
        FrameworkElementAutomationPeer.FromElement(FindCount)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    void OnFindChanged(object sender, object e)
    {
        if (Next(Selected.Start, true) is { } found) Place(found);
        Count();
    }

    void OnFindClose(object sender, RoutedEventArgs e) => HideFind();
    void OnReplaceToggle(object sender, RoutedEventArgs e) => ShowReplaceRow(ReplaceBox.Visibility != Visibility.Visible);

    void OnFindKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape) HideFind();
        else if (e.Key == VirtualKey.Enter && ReferenceEquals(sender, ReplaceBox)) OnReplace(sender, e);
        else if (e.Key == VirtualKey.Enter) Step(!Down(VirtualKey.Shift));
        else return;
        e.Handled = true;
    }

    void OnReplace(object sender, RoutedEventArgs e)
    {
        if (source is null || FindBox.Text.Length == 0) return;
        var s = Selected;
        if (Matches().Contains(s)) Apply(new TextEdit(s.Start, s.Length, ReplaceBox.Text));
        FindNext();
    }

    void OnReplaceAll(object sender, RoutedEventArgs e)
    {
        if (source is null || FindBox.Text.Length == 0) return;
        Apply([.. Matches().Select(m => new TextEdit(m.Start, m.Length, ReplaceBox.Text))]);
        Count();
    }
}
