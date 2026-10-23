using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using TeXLocal.Bridge;
using TeXLocal.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TeXLocal.Pages;

/// A template of the core's catalogue (create_project's `template`), as the gallery shows it: a slide's page is landscape.
public sealed record ProjectTemplate(string Id, string Title)
{
    public string Spoken => $"New {Title.ToLowerInvariant()} project";
    public string Tip => Id == "article" ? $"{Spoken} (Ctrl+Shift+N)" : Spoken;
    public double Width => Id == "beamer" ? 160 : 120;
    public double Height => Id == "beamer" ? 90 : 156;
}

public sealed partial class HomePage : Page
{
    readonly RenameFlyout rename = new();
    ProjectTemplate[] templates = [];
    ProjectInfo[] projects = [];
    ProjectInfo? target;
    string? focus;
    int loads;
    bool newProject;

    public HomePage() => InitializeComponent();

    /// A missing folder is dated 0, so its date says it isn't there.
    public static string Modified(long mtime, bool missing) => missing ? "Not found" : $"{DateTimeOffset.FromUnixTimeMilliseconds(mtime).LocalDateTime:g}";

    /// A style, not a brush: a ThemeResource in a setter follows the row's theme, which a brush looked up here wouldn't.
    public static Style NameStyle(bool missing) => (Style)Application.Current.Resources[missing ? "MissingNameStyle" : "BodyTextBlockStyle"];

    public static string MoreName(string name) => $"More options for {name}";

    static Core Core => App.Core!;

    /// The project of a row, or of an element in one (the More button).
    ProjectInfo? ProjectOf(object? element) =>
        element is ListViewItem row ? List.ItemFromContainer(row) as ProjectInfo : (element as FrameworkElement)?.DataContext as ProjectInfo;

    ProjectInfo? Focused => XamlRoot is { } root ? ProjectOf(FocusManager.GetFocusedElement(root)) : null;

    protected override void OnNavigatedTo(NavigationEventArgs e) => Refresh();

    /// The projects and TeX's status again: on arrival, and whenever the window comes back to the front.
    public void Refresh()
    {
        Reload();
        _ = CheckTex();
    }

    /// Lists the projects again, keeping keyboard focus on its row (or moving it to project `id`); a later call's answer
    /// wins over an earlier one's. The templates come with the first list, once the library has opened.
    async void Reload(string? id = null)
    {
        focus = id ?? focus;
        var generation = ++loads;
        var error = App.OpenCore();
        ProjectInfo[] listed = [];
        if (error is null)
            try
            {
                listed = await Core.CallAsync<ProjectInfo[]>("list_projects");
                if (templates.Length == 0)
                    Templates.ItemsSource = templates = [.. (await App.Catalogue()).Templates.Select(t => new ProjectTemplate(t.Id, t.Title))];
            }
            catch (CoreException ex) { error = ex.Message; }
        if (generation != loads) return;
        LibraryError.Message = error ?? "";
        LibraryError.IsOpen = error is not null;
        if (error is not null) return;
        projects = listed;
        Show();
        if (!newProject) return;
        newProject = false;
        Templates.UpdateLayout();
        (FocusManager.FindFirstFocusableElement(Templates) as Control)?.Focus(FocusState.Keyboard);
    }

    /// The gallery's first template focused, once listed: File › New project in a project.
    public void ShowTemplates() => newProject = true;

    /// The projects whose names hold the search's text, as on the Mac.
    void Show()
    {
        var query = Search.Text.Trim();
        ProjectInfo[] shown = [.. projects.Where(p => p.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase))];
        var id = focus ?? Focused?.Id;
        focus = null;
        if (List.ItemsSource is not ProjectInfo[] listed || !listed.SequenceEqual(shown))
        {
            List.ItemsSource = shown;
            if (shown.FirstOrDefault(p => p.Id == id) is { } p)
            {
                List.UpdateLayout();
                (List.ContainerFromItem(p) as Control)?.Focus(FocusState.Programmatic);
            }
        }
        var empty = shown.Length == 0;
        Empty.Text = projects.Length == 0 ? "No projects yet. Choose a template above, or open or drop a folder, .tex file or .zip." : $"No results for “{query}”.";
        Empty.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        List.Visibility = Columns.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    async Task CheckTex()
    {
        if (App.Core is { } core) TexMissing.IsOpen = !(await core.CallAsync<TexStatus>("status")).Available;
    }

    void OnRetry(object sender, RoutedEventArgs e) => Reload();

    void OnSearch(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e) => Show();

    void OnFindKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Search.Focus(FocusState.Keyboard);
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems)) e.AcceptedOperation = DataPackageOperation.Copy;
    }

    /// Folders, .tex and .zip files from File Explorer, opened as from the Open menu.
    async void OnDrop(object sender, DragEventArgs e) => await App.Window.Open(await App.Dropped(e));

    void OnItemClick(object sender, ItemClickEventArgs e) => App.Window.OpenProject(((ProjectInfo)e.ClickedItem).Id);

    void OnTemplate(object sender, RoutedEventArgs e) => New((ProjectTemplate)((FrameworkElement)sender).DataContext);

    void OnNewArticle(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (templates.FirstOrDefault(t => t.Id == "article") is { } article) New(article);
    }

    /// New project, as File Explorer's New folder: a free name, selected for typing over; a refusal under the box.
    async void New(ProjectTemplate template)
    {
        if (App.Core is null) return;
        var box = new TextBox { Header = "Name", Width = 360 };
        try { box.Text = (await Core.CallAsync("free_project_name")).GetProperty("name").GetString() ?? ""; }
        catch (CoreException) { }
        var dialog = new ContentDialog
        {
            Title = $"New {template.Title.ToLowerInvariant()} project",
            Content = box,
            PrimaryButtonText = "Create",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        string? id = null;
        dialog.Opened += (_, _) => box.SelectAll();
        box.TextChanged += (_, _) => box.Description = null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try { id = (await Core.CallAsync<ProjectInfo>("create_project", new { name = box.Text.Trim(), template = template.Id, engine = Prefs.Engine is "" ? null : Prefs.Engine })).Id; }
            catch (CoreException ex)
            {
                args.Cancel = true;
                box.Description = ex.Message;
            }
            finally { deferral.Complete(); }
        };
        if (await App.Show(dialog) == ContentDialogResult.Primary && id is not null) App.Window.OpenProject(id);
    }

    /// An opened folder is the author's: it is never renamed or recycled from here.
    void OnMenuOpening(object sender, object e)
    {
        var p = target = ProjectOf(((MenuFlyout)sender).Target)!;
        RenameItem.Visibility = DuplicateItem.Visibility = DeleteItem.Visibility = p.Opened ? Visibility.Collapsed : Visibility.Visible;
        ForgetItem.Visibility = p.Opened ? Visibility.Visible : Visibility.Collapsed;
        RevealItem.IsEnabled = ExportItem.IsEnabled = !p.Missing;
    }

    void OnKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (Focused is not { } p) return;
        args.Handled = true;
        if (sender.Key == VirtualKey.F2) Rename(p);
        else Delete(p);
    }

    void OnOpenItem(object sender, RoutedEventArgs e) => App.Window.OpenProject(target!.Id);

    void OnRenameItem(object sender, RoutedEventArgs e) => Rename(target!);

    /// A copy beside it, named as File Explorer names one, its row focused.
    async void OnDuplicateItem(object sender, RoutedEventArgs e)
    {
        try { Reload((await Core.CallAsync<ProjectInfo>("duplicate_project", new { id = target!.Id, name = $"{target.Name} - Copy" })).Id); }
        catch (CoreException ex) { await App.Alert("Can't duplicate this project", ex.Message); }
    }

    void OnRevealItem(object sender, RoutedEventArgs e) => App.Reveal(target!.Path);

    void OnDeleteItem(object sender, RoutedEventArgs e) => Delete(target!);

    async void OnExportItem(object sender, RoutedEventArgs e) => await App.ExportZip(target!.Id, target.Name);

    /// Renames in place, at the row's name, as File Explorer does.
    void Rename(ProjectInfo p)
    {
        if (!p.Opened && (List.ContainerFromItem(p) as ListViewItem)?.ContentTemplateRoot is FrameworkElement row && row.FindName("NameText") is FrameworkElement name)
            rename.Show(name, p.Name, async to => Reload((await Core.CallAsync<ProjectInfo>("rename_project", new { id = p.Id, name = to })).Id));
    }

    /// An opened folder is the author's, so it only leaves the list, without asking, as from Word's Recent.
    async void Delete(ProjectInfo p)
    {
        if (!p.Opened && await App.Show(new ContentDialog
        {
            Title = $"Delete “{p.Name}”?",
            Content = "The project folder moves to the Recycle Bin.",
            PrimaryButtonText = "Move to Recycle Bin",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        }) != ContentDialogResult.Primary) return;
        try { await (p.Opened ? Core.CallAsync("forget_folder", new { id = p.Id }) : App.Recycle(p.Path)); }
        catch (Exception ex) { await App.Alert(p.Opened ? "Can't remove this folder from the list" : "Can't delete this project", ex.Message); }
        Reload();
    }
}
