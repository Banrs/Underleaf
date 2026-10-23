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
    public string Glyph => Change.Change switch { "added" => "\uE710", "deleted" => "\uE74D", _ => "\uE70F" };
    public override string ToString() => $"{Path}, {State}";
}

/// A line of a comparison, marked as only in the version (−), only now (+) or in both, as a unified diff marks them; or
/// the unchanged lines folded away between changes.
public sealed record DiffLine(DiffRow Row)
{
    public bool Removed => Row.Removed is not null;
    public bool Added => Row.Added is not null;
    public string Sign => Removed ? "−" : Added ? "+" : Row.Skipped is not null ? "⋯" : "";
    public string Text => Row.Removed ?? Row.Added ?? Row.Same ?? $"{Row.Skipped} unchanged line{(Row.Skipped == 1 ? "" : "s")}";
    public override string ToString() => Removed ? $"Removed: {Text}" : Added ? $"Added: {Text}" : Text;
}

/// Word's Version History: the versions the core keeps, the files each changed, and the chosen file then and now. The
/// core compares and restores.
public sealed partial class HistoryDialog : ContentDialog
{
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
            var confirmed = await App.Ask($"Restore all files to {(version.Snapshot.Name is { } name ? $"“{name}”" : $"the version of {version.When}")}?",
                "Files changed since go back to how they were, and deleted ones return; files added since stay. The project as it is now is kept as a version first.",
                "Restore all");
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
    void OnFile(object sender, SelectionChangedEventArgs e) => App.Run(null, async () =>
    {
        var generation = ++comparisons;
        IsPrimaryButtonEnabled = Files.SelectedItem is ChangeRow { Change.Change: not "deleted" };
        if (Files.SelectedItem is not ChangeRow row || Chosen is not { } version) return;
        List<DiffLine> lines = [];
        string? note;
        try
        {
            var rows = await App.Core!.CallAsync<DiffRow[]>("session_history_compare", new { session, id = version.Snapshot.Id, path = row.Path });
            lines = [.. rows.Select(r => new DiffLine(r))];
            note = lines.Count > 0 ? null : "This file is the same now as in this version.";
        }
        catch (CoreException ex) { note = ex.Message; }
        if (generation == comparisons) ShowLines(lines, note);
    });

    /// The comparison, or the note in its place.
    void ShowLines(List<DiffLine> lines, string? note)
    {
        Lines.ItemsSource = note is null ? lines : null;
        LinesNote.Text = note ?? "";
    }
}
