using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Text;
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
        IsMain = node.Path == mainFile;
    }

    public TreeNode Node { get; }
    public string Name => Node.Name;
    public List<FileItem> Children { get; }

    /// <summary>Written back by the tree, so a reload can keep folders open.</summary>
    public bool IsExpanded { get; set; }

    private bool IsMain { get; }

    public Windows.UI.Text.FontWeight Weight => IsMain ? FontWeights.SemiBold : FontWeights.Normal;

    public string? ToolTip => IsMain ? "Main file" : null;

    /// <summary>What a screen reader says: the name, and what kind of entry it is.</summary>
    public string AccessibleName => Node.IsDirectory ? $"{Node.Name}, folder"
        : IsMain ? $"{Node.Name}, main file" : Node.Name;

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

/// <summary>A heading in the sidebar's outline; the current one is drawn in the accent colour, not selected.</summary>
public sealed partial class OutlineEntry : INotifyPropertyChanged
{
    public OutlineEntry(OutlineNode node, IReadOnlyDictionary<OutlineItem, string> keys, IReadOnlySet<string> folded)
    {
        Item = node.Item;
        Key = keys[node.Item];
        Children = node.Children.Select(c => new OutlineEntry(c, keys, folded)).ToList();
        IsExpanded = !folded.Contains(Key);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Raise([CallerMemberName] string name = "") => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public OutlineItem Item { get; }
    public List<OutlineEntry> Children { get; }

    /// <summary>What its fold is remembered by: its project and file, and <see cref="Outline.FoldKeys"/>.</summary>
    public string Key { get; }

    /// <summary>Headings start expanded unless folded before; the tree writes a fold back.</summary>
    public bool IsExpanded
    {
        get;
        set
        {
            if (field != value)
            {
                field = value;
                Raise();
            }
        }
    }

    /// <summary>The section at the top of the source.</summary>
    public bool IsCurrent
    {
        get;
        set
        {
            if (field != value)
            {
                field = value;
                Raise(nameof(TitledVisibility));
                Raise(nameof(UntitledVisibility));
                Raise(nameof(CurrentVisibility));
                Raise(nameof(Status));
            }
        }
    }

    public string Title => Outline.DisplayTitle(Item);

    private bool Untitled => Item.Title == "(untitled)";

    /// <summary>A heading with no title reads "Untitled section", dimmed; the current one in the accent colour.</summary>
    public Visibility TitledVisibility => !IsCurrent && !Untitled ? Visibility.Visible : Visibility.Collapsed;
    public Visibility UntitledVisibility => !IsCurrent && Untitled ? Visibility.Visible : Visibility.Collapsed;
    public Visibility CurrentVisibility => IsCurrent ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>What a screen reader adds to the current heading's name.</summary>
    public string Status => IsCurrent ? "Current section" : "";

    public IEnumerable<OutlineEntry> SelfAndDescendants() => Children.SelectMany(c => c.SelfAndDescendants()).Prepend(this);
}

/// <summary>One file's matches in the project search: a "file — n" heading over its lines.</summary>
public sealed class SearchGroup(string file, IEnumerable<SearchHit> hits) : List<SearchHit>(hits)
{
    public string Header => $"{file} — {Count:N0}";
}

/// <summary>A kind of symbol in the source bar's palette.</summary>
public sealed class PaletteGroup(string title, IEnumerable<PaletteSymbol> symbols) : List<PaletteSymbol>(symbols)
{
    public string Title => title;
}

/// <summary>A symbol in the palette; a screen reader names it by its command.</summary>
public sealed record PaletteSymbol(string Glyph, string Command)
{
    public override string ToString() => Command;
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
