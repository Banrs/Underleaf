using Microsoft.UI.Xaml;

namespace TeXLocal;

// What the lists show for the core's data, shaped for x:Bind.

/// <summary>A file or folder in the sidebar's tree.</summary>
public sealed class FileItem
{
    public FileItem(TreeNode node, string? mainFile, IReadOnlySet<string> expanded)
    {
        Node = node;
        Children = node.Children?.Select(c => new FileItem(c, mainFile, expanded)).ToList() ?? [];
        IsExpanded = expanded.Contains(node.Path);
        MainVisibility = node.Path == mainFile ? Visibility.Visible : Visibility.Collapsed;
    }

    public TreeNode Node { get; }
    public string Name => Node.Name;
    public List<FileItem> Children { get; }

    /// <summary>Written back by the tree, so a reload can keep folders open.</summary>
    public bool IsExpanded { get; set; }

    public Visibility MainVisibility { get; }

    /// <summary>What a screen reader says: the name, and what kind of entry it is.</summary>
    public string AccessibleName => Node.IsDirectory ? $"{Node.Name}, folder"
        : MainVisibility == Visibility.Visible ? $"{Node.Name}, main file" : Node.Name;

    /// <summary>Segoe Fluent Icons glyphs by kind of file.</summary>
    public string Glyph => Node.IsDirectory ? "\uE8B7" : Path.GetExtension(Node.Name).ToLowerInvariant() switch
    {
        ".tex" => "\uE8A5",
        ".bib" => "\uE8F1",
        ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".bmp" or ".svg" => "\uE91B",
        ".pdf" => "\uEA90",
        _ => "\uE7C3",
    };

    public IEnumerable<FileItem> SelfAndDescendants() => Children.SelectMany(c => c.SelfAndDescendants()).Prepend(this);
}

/// <summary>A heading in the sidebar's outline, and the headings it encloses.</summary>
public sealed class OutlineEntry
{
    public OutlineEntry(OutlineNode node, IReadOnlySet<string> collapsed)
    {
        Item = node.Item;
        Children = node.Children.Select(c => new OutlineEntry(c, collapsed)).ToList();
        IsExpanded = !collapsed.Contains(Key);
    }

    public OutlineItem Item { get; }
    public List<OutlineEntry> Children { get; }

    /// <summary>Headings start expanded; a fold is written back by the tree.</summary>
    public bool IsExpanded { get; set; }

    /// <summary>Level and title, so a fold survives edits that renumber the headings.</summary>
    public string Key => $"{Item.Level}:{Item.Title}";

    public string Title => Outline.DisplayTitle(Item);

    /// <summary>A heading with no title reads "Untitled section", dimmed.</summary>
    public Visibility TitledVisibility => Item.Title == "(untitled)" ? Visibility.Collapsed : Visibility.Visible;
    public Visibility UntitledVisibility => Item.Title == "(untitled)" ? Visibility.Visible : Visibility.Collapsed;

    public IEnumerable<OutlineEntry> SelfAndDescendants() => Children.SelectMany(c => c.SelfAndDescendants()).Prepend(this);
}

/// <summary>
/// One file's matches in the project search, as macOS groups them: a
/// "file — n" heading over the file's lines.
/// </summary>
public sealed class SearchGroup(string file, IEnumerable<SearchHit> hits) : List<SearchHit>(hits)
{
    public string Header => $"{file} — {Count:N0}";
}

/// <summary>One step of the source's location: the project, a folder, the file or the section.</summary>
public sealed record Crumb(string Label, string Glyph, CrumbKind Kind, string Folder)
{
    public override string ToString() => Label;
}

public enum CrumbKind
{
    /// <summary>The project or a folder in it; its menu lists the text files there.</summary>
    Folder,

    /// <summary>The open file; its menu lists the files beside it.</summary>
    File,

    /// <summary>The section around the cursor; its menu lists the file's sections.</summary>
    Section,
}

public sealed class LogRow(LogItem item)
{
    public LogItem Item => item;
    public string Message => item.Message;
    public string Location => item.File is null ? "" : item.Line is { } line ? $"{item.File}:{line}" : item.File;
    public Visibility LocationVisibility => item.File is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ErrorVisibility => item.IsError ? Visibility.Visible : Visibility.Collapsed;
    public Visibility WarningVisibility => item.IsError ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>What a screen reader says for the row.</summary>
    public string AccessibleName => $"{(item.IsError ? "Error" : "Warning")}: {item.Message} {Location}";
}

public sealed class ProjectRow(ProjectInfo info)
{
    public ProjectInfo Info => info;
    public string Name => info.Name;
    public string MainFile => info.MainFile;

    /// <summary>When it was last changed, as File Explorer words a recent date.</summary>
    public string Modified
    {
        get
        {
            var age = DateTimeOffset.Now - info.Modified;
            return age.TotalMinutes < 1 ? "Just now"
                : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago"
                : age.TotalDays < 1 ? $"{(int)age.TotalHours} h ago"
                : age.TotalDays < 7 ? $"{(int)age.TotalDays} d ago"
                : $"{info.Modified.LocalDateTime:d}";
        }
    }

    public string AccessibleName => $"{info.Name}, main file {info.MainFile}, modified {Modified}";
}
