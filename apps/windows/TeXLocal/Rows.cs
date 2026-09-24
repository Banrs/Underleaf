using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

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

    /// <summary>Segoe Fluent Icons glyphs by kind of file.</summary>
    public string Glyph => Node.IsDirectory ? "" : Path.GetExtension(Node.Name).ToLowerInvariant() switch
    {
        ".tex" => "",
        ".bib" => "",
        ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".bmp" or ".svg" => "",
        ".pdf" => "",
        _ => "",
    };

    public IEnumerable<FileItem> SelfAndDescendants() => Children.SelectMany(c => c.SelfAndDescendants()).Prepend(this);
}

public sealed class OutlineRow(OutlineItem item)
{
    public string Title => item.Title;
    public int Line => item.Line;
    public Thickness Indent => new(Math.Max(0, item.Level - 2) * 12, 0, 0, 0);
}

public sealed class LogRow(LogItem item)
{
    public LogItem Item => item;
    public string Message => item.Message;
    public string Location => item.File is null ? "" : item.Line is { } line ? $"{item.File}:{line}" : item.File;
    public Visibility LocationVisibility => item.File is null ? Visibility.Collapsed : Visibility.Visible;
    public string Glyph => item.IsError ? "" : "";
    public Brush Tint => (Brush)Application.Current.Resources[item.IsError ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush"];
}

public sealed class ProjectRow(ProjectInfo info)
{
    public ProjectInfo Info => info;
    public string Name => info.Name;

    public string Modified
    {
        get
        {
            var age = DateTimeOffset.Now - info.Modified;
            return age.TotalMinutes < 1 ? "Edited just now"
                : age.TotalHours < 1 ? $"Edited {(int)age.TotalMinutes} min ago"
                : age.TotalDays < 1 ? $"Edited {(int)age.TotalHours} h ago"
                : age.TotalDays < 7 ? $"Edited {(int)age.TotalDays} d ago"
                : $"Edited {info.Modified.LocalDateTime:d}";
        }
    }
}
