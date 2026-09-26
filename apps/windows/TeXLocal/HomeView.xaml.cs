using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace TeXLocal;

/// <summary>The start page: templates to begin from, every project to search and sort, and TeX's status.</summary>
public sealed partial class HomeView : UserControl
{
    private static MainWindow Main => MainWindow.Instance;

    private string query = "";
    private string sortBy = "modified";
    private bool descending = true;

    public HomeView()
    {
        InitializeComponent();
        foreach (var template in ProjectTemplates.All)
        {
            Templates.Items.Add(TemplateCard(template));
        }
        RenderColumns();
    }

    internal void Render()
    {
        IEnumerable<ProjectInfo> shown = Main.Projects
            .Where(p => query.Length == 0 || p.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase));
        shown = sortBy switch
        {
            "name" => descending ? shown.OrderByDescending(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
                : shown.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase),
            "main" => descending ? shown.OrderByDescending(p => p.MainFile, StringComparer.CurrentCultureIgnoreCase)
                : shown.OrderBy(p => p.MainFile, StringComparer.CurrentCultureIgnoreCase),
            _ => descending ? shown.OrderByDescending(p => p.Mtime) : shown.OrderBy(p => p.Mtime),
        };
        var rows = shown.Select(p => new ProjectRow(p)).ToList();
        Projects.ItemsSource = rows;

        var none = rows.Count == 0;
        NoProjects.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        Columns.Visibility = Main.Projects.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        NoProjectsTitle.Text = Main.Projects.Count == 0 ? "No projects yet" : "No matching projects";
        NoProjectsDetail.Text = Main.Projects.Count == 0
            ? "Choose a template above to start writing. Your files never leave this PC."
            : $"No project’s name contains “{query}”.";
    }

    internal void RenderTex() => TexMissing.IsOpen = Main.Tex is { Available: false };

    // ---------- templates ----------

    /// <summary>A template's card: a drawing of its first page, then its name and what it holds.</summary>
    private StackPanel TemplateCard(ProjectTemplate template)
    {
        // Padded inside, so the item's hover plate doesn't hug the paper.
        var card = new StackPanel { Spacing = 8, Padding = new Thickness(8), Tag = template.Id };
        card.Children.Add(new Border
        {
            Width = 120,
            Height = 156,
            // Paper, which is white in either theme.
            Background = new SolidColorBrush(Colors.White),
            BorderBrush = new SolidColorBrush(Colors.Gray) { Opacity = 0.3 },
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Child = PagePreview(template.Page),
        });
        var text = new StackPanel { Width = 120, Spacing = 2 };
        text.Children.Add(new TextBlock { Text = template.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        text.Children.Add(new TextBlock { Text = template.Detail, Style = (Style)Resources["TemplateDetailStyle"] });
        card.Children.Add(text);
        ToolTipService.SetToolTip(card, $"New {template.Title.ToLowerInvariant()} project");
        AutomationProperties.SetName(card, $"New {template.Title.ToLowerInvariant()} project: {template.Detail}");
        return card;
    }

    /// <summary>Grey bars where the text would be, laid out like the template's first page (or first slide).</summary>
    private static UIElement PagePreview(TemplatePage page)
    {
        var column = new StackPanel { Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center };
        void Bar(double width, double height, double before = 0) =>
            column.Children.Add(new Rectangle
            {
                Width = width,
                Height = height,
                RadiusX = height / 2,
                RadiusY = height / 2,
                Fill = new SolidColorBrush(Colors.Gray) { Opacity = 0.45 },
                Margin = new Thickness(0, before, 0, 0),
            });
        switch (page)
        {
            case TemplatePage.Blank:
                return new FontIcon
                {
                    Glyph = "\uE710",
                    FontSize = 28,
                    Foreground = new SolidColorBrush(Colors.Gray) { Opacity = 0.6 },
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            case TemplatePage.Article:
                Bar(64, 5, before: 16);
                Bar(40, 3);
                Bar(52, 3);
                Bar(78, 2, before: 6);
                Bar(78, 2);
                Bar(60, 2);
                column.Children.Add(new Rectangle
                {
                    Width = 40, Height = 3, RadiusX = 1.5, RadiusY = 1.5,
                    Fill = new SolidColorBrush(Colors.Gray) { Opacity = 0.45 },
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Margin = new Thickness(0, 4, 0, 0),
                });
                for (var i = 0; i < 4; i++)
                {
                    Bar(88, 2);
                }
                Bar(50, 2);
                return column;
            case TemplatePage.Report:
                column.VerticalAlignment = VerticalAlignment.Center;
                column.Spacing = 6;
                Bar(70, 6);
                Bar(46, 3);
                Bar(36, 3);
                return new Grid
                {
                    Children =
                    {
                        column,
                        new Rectangle
                        {
                            Width = 30, Height = 2, RadiusX = 1, RadiusY = 1,
                            Fill = new SolidColorBrush(Colors.Gray) { Opacity = 0.45 },
                            VerticalAlignment = VerticalAlignment.Bottom,
                            Margin = new Thickness(0, 0, 0, 18),
                        },
                    },
                };
            default:
                // A slide: a title band over a heading and a line.
                var slide = new StackPanel
                {
                    Width = 104,
                    Height = 58,
                    Spacing = 6,
                    BorderBrush = new SolidColorBrush(Colors.Gray) { Opacity = 0.3 },
                    BorderThickness = new Thickness(1),
                    VerticalAlignment = VerticalAlignment.Center,
                };
                slide.Children.Add(new Rectangle { Height = 14, Fill = new SolidColorBrush(Colors.RoyalBlue) { Opacity = 0.55 } });
                column = slide;
                Bar(60, 4);
                Bar(40, 3);
                return slide;
        }
    }

    private void OnTemplateClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is FrameworkElement { Tag: string template })
        {
            _ = Main.NewProjectAsync(template);
        }
    }

    private void OnNewProject(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.ProjectNew);

    private void OnSettings(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.AppSettings);

    // ---------- recent ----------

    /// <summary>The title bar's search box, while the library is on screen.</summary>
    internal void Search(string text)
    {
        query = text.Trim();
        Render();
    }

    internal void OpenFirstMatch()
    {
        if ((Projects.ItemsSource as List<ProjectRow>)?.FirstOrDefault() is { } row)
        {
            _ = Main.OpenAsync(row.Info.Id);
        }
    }

    /// <summary>A column's header sorts by it; again reverses the order.</summary>
    private void OnSort(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string column })
        {
            return;
        }
        // Newest first and A to Z first, as File Explorer starts each column.
        descending = column == sortBy ? !descending : column == "modified";
        sortBy = column;
        RenderColumns();
        Render();
    }

    private void RenderColumns()
    {
        foreach (var (button, column, title) in new[] { (SortName, "name", "Name"), (SortMain, "main", "Main file"), (SortModified, "modified", "Modified") })
        {
            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            header.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
            if (column == sortBy)
            {
                header.Children.Add(new FontIcon { Glyph = descending ? "\uE70D" : "\uE70E", FontSize = 10 });
            }
            button.Content = header;
            AutomationProperties.SetName(button, column == sortBy
                ? $"{title}, sorted {(descending ? "descending" : "ascending")}"
                : $"Sort by {title.ToLowerInvariant()}");
        }
    }

    private void OnProjectClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ProjectRow row)
        {
            _ = Main.OpenAsync(row.Info.Id);
        }
    }

    private void OnProjectContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if (ContextMenus.Row<ListViewItem>(e.OriginalSource) is not { Content: ProjectRow row } item)
        {
            return;
        }
        ContextMenus.Show(ProjectMenu(row.Info), item, e);
    }

    private MenuFlyout ProjectMenu(ProjectInfo project)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(ContextMenus.Item("Open", "\uE8E5", () => _ = Main.OpenAsync(project.Id)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(ContextMenus.Item("Rename…", "\uE8AC", () => _ = RenameAsync(project), "F2"));
        menu.Items.Add(ContextMenus.Item("Open folder location", "\uE838", () => _ = RevealAsync(project)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(ContextMenus.Item("Delete…", "\uE74D", () => _ = DeleteAsync(project), "Delete"));
        return menu;
    }

    /// <summary>F2 renames and Delete deletes the focused project, as in File Explorer.</summary>
    private void OnProjectsKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (FocusManager.GetFocusedElement(XamlRoot) is not ListViewItem { Content: ProjectRow row })
        {
            return;
        }
        if (e.Key == Windows.System.VirtualKey.F2)
        {
            e.Handled = true;
            _ = RenameAsync(row.Info);
        }
        else if (e.Key == Windows.System.VirtualKey.Delete)
        {
            e.Handled = true;
            _ = DeleteAsync(row.Info);
        }
    }

    /// <summary>
    /// Select the project's folder in File Explorer, as Explorer's own "Open
    /// file location" does. The core hands out paths only inside a project,
    /// so the folder is its main file's path less the main file's segments.
    /// </summary>
    private static async Task RevealAsync(ProjectInfo project)
    {
        try
        {
            var path = await Main.Core.CallAsync<string>("raw_path", new { id = project.Id, path = project.MainFile });
            foreach (var _ in project.MainFile.Split('/', StringSplitOptions.RemoveEmptyEntries))
            {
                path = System.IO.Path.GetDirectoryName(path)!;
            }
            Shell.Reveal(path);
        }
        catch (CoreException e)
        {
            Main.Report("Couldn’t open the folder location", e.Message);
        }
    }

    private async Task RenameAsync(ProjectInfo project)
    {
        if (await Dialogs.PromptAsync(XamlRoot, "Rename project", "Name", "Rename", project.Name) is { } name)
        {
            await Main.RenameProjectAsync(project, name);
        }
    }

    private async Task DeleteAsync(ProjectInfo project)
    {
        if (await Dialogs.ConfirmAsync(XamlRoot, $"Delete {project.Name}?",
                "The project will be moved to the Recycle Bin, where you can restore it.", "Delete"))
        {
            await Main.DeleteProjectAsync(project);
        }
    }
}

internal enum TemplatePage
{
    Blank,
    Article,
    Report,
    Slides,
}

/// <summary>A template the core can make a project from (crates/texlocal-core templates.rs), with how its first page looks.</summary>
internal sealed record ProjectTemplate(string Id, string Title, string Detail, TemplatePage Page);

internal static class ProjectTemplates
{
    public static readonly IReadOnlyList<ProjectTemplate> All =
    [
        new("blank", "Blank", "An empty document", TemplatePage.Blank),
        new("article", "Article", "Paper with abstract and sections", TemplatePage.Article),
        new("report", "Report", "Chapters and a title page", TemplatePage.Report),
        new("beamer", "Presentation", "Beamer slides", TemplatePage.Slides),
    ];
}
