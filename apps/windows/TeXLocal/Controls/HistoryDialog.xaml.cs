using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TeXLocal.Bridge;
using TeXLocal.Pages;

namespace TeXLocal.Controls;

/// A version's row: its name in SemiBold, else why the core kept it, and its date beneath.
public sealed record VersionRow(Snapshot Snapshot)
{
    public string Title => Snapshot.Name ?? (Snapshot.Reason is { } reason ? WorkspacePage.Sentence(reason) : "Automatic");
    public Style TitleStyle => (Style)Application.Current.Resources[Snapshot.Name is null ? "BodyTextBlockStyle" : "BodyStrongTextBlockStyle"];
    public string When => $"{Snapshot.Time.LocalDateTime:f}";
    public override string ToString() => $"{Title}, {When}";
}

public sealed record ChangeRow(SnapshotChange Change)
{
    public string Path => Change.Path;
    public string State => Change.Change switch { "added" => "Added", "deleted" => "Deleted", _ => "Changed" };
    public string Glyph => Change.Change switch { "added" => "", "deleted" => "", _ => "" };
    public override string ToString() => $"{Path}, {State}";
}

/// A line of a comparison, marked as only in the version (−), only now (+) or in both, as a unified diff marks them.
public sealed record DiffLine(string Sign, string Text)
{
    public bool Removed => Sign == "−";
    public bool Added => Sign == "+";
    public override string ToString() => Removed ? $"Removed: {Text}" : Added ? $"Added: {Text}" : Text;
}

/// Word's Version History: the versions the core keeps, the files each changed, and the chosen file then and now. The
/// core restores; the comparison is drawn here.
public sealed partial class HistoryDialog : ContentDialog
{
    /// Beyond this many pairs of lines between the texts' common start and end, the middle shows as removed then added.
    const long MostPairs = 4_000_000;

    readonly ulong session;
    int comparisons;

    VersionRow? Chosen => Versions.SelectedItem as VersionRow;

    public HistoryDialog(ulong session)
    {
        this.session = session;
        InitializeComponent();
        Lines.ItemContainerStyle = new Style(typeof(ListViewItem))
        {
            BasedOn = (Style)Resources["DiffLineStyle"],
            Setters = { new Setter(FontFamilyProperty, SourceView.Font(Prefs.EditorFont)) },
        };
        Loading += (_, _) => (Body.Width, Body.Height) = (Math.Min(1040, XamlRoot.Size.Width - 96), Math.Min(600, XamlRoot.Size.Height - 220));
    }

    /// Shows the versions until one is restored, after Restore all is confirmed, or the dialog is closed (null).
    public async Task<Restored?> Restore()
    {
        try
        {
            Versions.ItemsSource = (await App.Core!.CallAsync<Snapshot[]>("session_history_list", new { session })).Select(s => new VersionRow(s)).ToArray();
            VersionsNote.Text = "No versions yet. One is kept as you save, every 10 minutes at most, and before Replace all and Restore.";
        }
        catch (CoreException ex) { VersionsNote.Text = ex.Message; }
        Versions.SelectedIndex = Versions.Items.Count > 0 ? 0 : -1;
        VersionsNote.Visibility = Versions.Items.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
        while (true)
        {
            var answer = await App.Show(this);
            if (answer == ContentDialogResult.None || Chosen is not { } version) return null;
            var id = version.Snapshot.Id;
            if (answer == ContentDialogResult.Primary)
                return await App.Core!.CallAsync<Restored>("session_history_restore", new { session, id, paths = new[] { ((ChangeRow)Files.SelectedItem).Path } });
            var confirmed = await App.Show(new ContentDialog
            {
                Title = $"Restore all files to {(version.Snapshot.Name is { } name ? $"“{name}”" : $"the version of {version.When}")}?",
                Content = "Files changed since go back to how they were, and deleted ones return; files added since stay. The project as it is now is kept as a version first.",
                PrimaryButtonText = "Restore all",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            });
            if (confirmed == ContentDialogResult.Primary) return await App.Core!.CallAsync<Restored>("session_history_restore", new { session, id });
        }
    }

    void OnVersion(object sender, SelectionChangedEventArgs e)
    {
        IsSecondaryButtonEnabled = Chosen is not null;
        Files.ItemsSource = Chosen?.Snapshot.Changed.Select(c => new ChangeRow(c)).ToArray();
        Files.SelectedIndex = Files.Items.Count > 0 ? 0 : -1;
        if (Files.Items.Count == 0) ShowLines([], Chosen is null ? "" : "No files changed in this version.");
    }

    /// A file deleted in the version has nothing to put back; a later comparison's answer wins over an earlier one's.
    async void OnFile(object sender, SelectionChangedEventArgs e)
    {
        var generation = ++comparisons;
        IsPrimaryButtonEnabled = Files.SelectedItem is ChangeRow { Change.Change: not "deleted" };
        if (Files.SelectedItem is not ChangeRow row || Chosen is not { } version) return;
        List<DiffLine> lines = [];
        string? note;
        try
        {
            var compared = await App.Core!.CallAsync<Compared>("session_history_compare", new { session, id = version.Snapshot.Id, path = row.Path });
            lines = Diff(compared.Old, compared.New);
            note = lines.Any(l => l.Sign.Length > 0) ? null : "This file is the same now as in this version.";
        }
        catch (CoreException ex) { note = ex.Message; }
        if (generation == comparisons) ShowLines(lines, note);
    }

    /// The comparison from its first change, or the note in its place.
    void ShowLines(List<DiffLine> lines, string? note)
    {
        Lines.ItemsSource = note is null ? lines : null;
        LinesNote.Text = note ?? "";
        if (lines.Find(l => l.Sign.Length > 0) is { } first) Lines.ScrollIntoView(first, ScrollIntoViewAlignment.Leading);
    }

    /// The version's lines against now's over their longest common subsequence, removed before added where a block was
    /// replaced. The common start and end, which most edits leave, are set aside first, so the table is the middle's.
    static List<DiffLine> Diff(string? then, string? now)
    {
        string[] a = Split(then), b = Split(now);
        var start = 0;
        while (start < a.Length && start < b.Length && a[start] == b[start]) start++;
        var end = 0;
        while (end < a.Length - start && end < b.Length - start && a[^(end + 1)] == b[^(end + 1)]) end++;
        int n = a.Length - start - end, m = b.Length - start - end;
        var common = (long)n * m <= MostPairs ? new int[n + 1, m + 1] : null;
        for (var i = n - 1; common is not null && i >= 0; i--)
            for (var j = m - 1; j >= 0; j--)
                common[i, j] = a[start + i] == b[start + j] ? common[i + 1, j + 1] + 1 : Math.Max(common[i + 1, j], common[i, j + 1]);
        List<DiffLine> lines = [.. a[..start].Select(l => new DiffLine("", l))];
        int x = 0, y = 0;
        while (x < n || y < m)
        {
            if (x < n && y < m && a[start + x] == b[start + y])
            {
                lines.Add(new("", a[start + x]));
                (x, y) = (x + 1, y + 1);
            }
            else if (y == m || x < n && (common?[x + 1, y] ?? 0) >= (common?[x, y + 1] ?? 0)) lines.Add(new("−", a[start + x++]));
            else lines.Add(new("+", b[start + y++]));
        }
        lines.AddRange(a[^end..].Select(l => new DiffLine("", l)));
        return lines;
    }

    static string[] Split(string? text) => text?.Split('\n') ?? [];
}
