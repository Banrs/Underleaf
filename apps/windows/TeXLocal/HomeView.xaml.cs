using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;

namespace TeXLocal;

/// <summary>The library: every project, newest first, and TeX's status.</summary>
public sealed partial class HomeView : UserControl
{
    private static MainWindow Main => MainWindow.Instance;

    public HomeView()
    {
        InitializeComponent();
        Logo.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.png")));
    }

    internal void Render()
    {
        Projects.ItemsSource = Main.Projects.Select(p => new ProjectRow(p)).ToList();
        NoProjects.Visibility = Main.Projects.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    internal void RenderTex() => TexMissing.IsOpen = Main.Tex is { Available: false };

    private void OnNewProject(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.ProjectNew);

    private void OnSettings(object sender, RoutedEventArgs e) => Main.Perform(MenuCommand.AppSettings);

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
        var project = row.Info;
        var menu = new MenuFlyout();
        menu.Items.Add(ContextMenus.Item("Open", () => _ = Main.OpenAsync(project.Id)));
        menu.Items.Add(ContextMenus.Item("Rename…", () => _ = RenameAsync(project)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(ContextMenus.Item("Delete…", () => _ = DeleteAsync(project)));
        ContextMenus.Show(menu, item, e);
    }

    private async Task RenameAsync(ProjectInfo project)
    {
        if (await Dialogs.PromptAsync(XamlRoot, "Rename Project", "Name", "Rename", project.Name) is { } name)
        {
            await Main.RenameProjectAsync(project, name);
        }
    }

    private async Task DeleteAsync(ProjectInfo project)
    {
        if (await Dialogs.ConfirmAsync(XamlRoot, $"Delete “{project.Name}”?",
                "The project moves to the Recycle Bin, where you can restore it.", "Delete"))
        {
            await Main.DeleteProjectAsync(project);
        }
    }
}
