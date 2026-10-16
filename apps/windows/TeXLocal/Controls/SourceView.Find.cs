using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TeXLocal.Bridge;
using VirtualKey = Windows.System.VirtualKey;

namespace TeXLocal.Controls;

/// Find and replace in the file, as Notepad's bar over the text: RichEdit finds (FindText), and replacements are the
/// session's edits like any other.
public sealed partial class SourceView
{
    const int Forward = 0x3FFFFFFF, MostCounted = 9999;

    FindOptions Options => (MatchCase.IsChecked ? FindOptions.Case : FindOptions.None) | (WholeWord.IsChecked ? FindOptions.Word : FindOptions.None);

    public bool FindShown => FindBar.Visibility == Visibility.Visible;

    public void ShowFind(bool replace)
    {
        if (source is null) return;
        CloseCompletions();
        var s = Selected;
        if (s.Length is > 0 and < 200 && text.IndexOf('\n', s.Start, s.Length) < 0) FindBox.Text = text.Substring(s.Start, s.Length);
        FindBar.Visibility = Visibility.Visible;
        ShowReplace(replace || ReplaceBox.Visibility == Visibility.Visible);
        (replace ? ReplaceBox : FindBox).Focus(FocusState.Keyboard);
        FindBox.SelectAll();
        Count();
    }

    void ShowReplace(bool show)
    {
        ReplaceBox.Visibility = ReplaceButtons.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        ReplaceChevron.Glyph = show ? "\uE70E" : "\uE76C";
        var name = show ? "Hide replace" : "Show replace";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ReplaceToggle, name);
        ToolTipService.SetToolTip(ReplaceToggle, show ? "Hide replace" : "Show replace (Ctrl+H)");
    }

    public void HideFind()
    {
        if (!FindShown) return;
        FindBar.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    /// The next match after the selection, or the one before it, round the ends.
    public void FindNext(bool forward)
    {
        if (source is null) return;
        if (FindBox.Text.Length == 0)
        {
            ShowFind(false);
            return;
        }
        var s = Selected;
        if ((Search(forward ? s.End : s.Start, forward) ?? Search(forward ? 0 : text.Length, forward)) is { } found) Place(found);
        Count();
    }

    SourceRange? Search(int from, bool forward)
    {
        var range = forward ? Document.GetRange(from, text.Length) : Document.GetRange(0, from);
        return range.FindText(FindBox.Text, forward ? Forward : -Forward, Options) > 0
            ? new SourceRange(range.StartPosition, range.EndPosition - range.StartPosition) : null;
    }

    List<SourceRange> Matches()
    {
        var found = new List<SourceRange>();
        for (var at = 0; found.Count <= MostCounted && Search(at, true) is { } match; at = match.End)
        {
            found.Add(match);
            if (match.Length == 0) break;
        }
        return found;
    }

    void Count()
    {
        if (FindBox.Text.Length == 0 || source is null)
        {
            FindCount.Text = "";
            return;
        }
        var matches = Matches();
        var s = Selected;
        var at = matches.FindIndex(m => m.Start == s.Start && m.Length == s.Length);
        var total = matches.Count > MostCounted ? $"{MostCounted}+" : $"{matches.Count}";
        FindCount.Text = matches.Count == 0 ? "No results" : at < 0 ? $"{total} found" : $"{at + 1} of {total}";
    }

    void OnFindChanged(object sender, object e) => Count();

    void OnFindNext(object sender, RoutedEventArgs e) => FindNext(true);

    void OnFindPrevious(object sender, RoutedEventArgs e) => FindNext(false);

    void OnFindClose(object sender, RoutedEventArgs e) => HideFind();

    void OnReplaceToggle(object sender, RoutedEventArgs e) => ShowReplace(ReplaceBox.Visibility != Visibility.Visible);

    void OnFindKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (e.Key == VirtualKey.Escape) HideFind();
        else if (e.Key == VirtualKey.Enter && ReferenceEquals(sender, ReplaceBox)) OnReplace(sender, e);
        else if (e.Key == VirtualKey.Enter) FindNext(!shift);
        else return;
        e.Handled = true;
    }

    /// The selected match is replaced, and the next one selected.
    void OnReplace(object sender, RoutedEventArgs e)
    {
        if (source is null || FindBox.Text.Length == 0) return;
        var s = Selected;
        if (Search(s.Start, true) is { } match && match == s)
        {
            NextUndoGroup();
            Put(s.Start, s.Length, ReplaceBox.Text);
            Place(s.Start + ReplaceBox.Text.Length);
            NextUndoGroup();
        }
        FindNext(true);
    }

    /// Every match, as one undo step.
    void OnReplaceAll(object sender, RoutedEventArgs e)
    {
        if (source is null || FindBox.Text.Length == 0) return;
        Apply([.. Matches().Select(m => new TextEdit(m.Start, m.Length, ReplaceBox.Text))]);
        Refresh();
        Count();
    }
}
