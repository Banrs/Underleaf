using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Controls;
using Windows.System;

namespace TeXLocal.Pages;

/// A template the core makes projects from (create_project's `template`), as the gallery shows it.
public sealed record ProjectTemplate(string Id, string Title, double Width = 120, double Height = 156)
{
    public string Spoken => $"New {Title.ToLowerInvariant()} project";
    public string Tip => Id == "article" ? $"{Spoken} (Ctrl+Shift+N)" : Spoken;
}

public sealed partial class HomePage : Page
{
    static readonly ProjectTemplate[] templates = [new("blank", "Blank"), new("article", "Article"), new("report", "Report"), new("beamer", "Presentation", 160, 90)];
    readonly RenameFlyout rename = new();
    ProjectInfo? target;
    string? focus;
    int loads;

    public HomePage()
    {
        InitializeComponent();
        Templates.ItemsSource = templates;
        var shortcut = new KeyboardAccelerator { Key = VirtualKey.N, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift };
        shortcut.Invoked += (_, e) =>
        {
            e.Handled = true;
            New(templates[1]);
        };
        KeyboardAccelerators.Add(shortcut);
    }

    public static string Modified(long mtime) => $"{DateTimeOffset.FromUnixTimeMilliseconds(mtime).LocalDateTime:g}";

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
    /// wins over an earlier one's.
    async void Reload(string? id = null)
    {
        focus = id ?? focus;
        var generation = ++loads;
        var error = App.OpenCore() ? null : App.CoreError ?? "";
        ProjectInfo[] projects = [];
        if (error is null)
            try { projects = await Core.CallAsync<ProjectInfo[]>("list_projects"); }
            catch (CoreException ex) { error = ex.Message; }
        if (generation != loads) return;
        LibraryError.Message = error ?? "";
        LibraryError.IsOpen = error is not null;
        if (error is null) Show(projects);
    }

    void Show(ProjectInfo[] projects)
    {
        var id = focus ?? Focused?.Id;
        focus = null;
        if (List.ItemsSource is not ProjectInfo[] shown || !shown.SequenceEqual(projects))
        {
            List.ItemsSource = projects;
            if (projects.FirstOrDefault(p => p.Id == id) is { } p)
            {
                List.UpdateLayout();
                (List.ContainerFromItem(p) as Control)?.Focus(FocusState.Programmatic);
            }
        }
        var empty = projects.Length == 0;
        Empty.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        List.Visibility = Columns.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    async Task CheckTex()
    {
        if (App.Core is { } core) TexMissing.IsOpen = !(await core.CallAsync<TexStatus>("status")).Available;
    }

    void OnRetry(object sender, RoutedEventArgs e) => Reload();

    void OnItemClick(object sender, ItemClickEventArgs e) => App.Window.OpenProject(((ProjectInfo)e.ClickedItem).Id);

    void OnTemplate(object sender, RoutedEventArgs e) => New((ProjectTemplate)((FrameworkElement)sender).DataContext);

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
            try { id = (await Core.CallAsync<ProjectInfo>("create_project", new { name = box.Text.Trim(), template = template.Id })).Id; }
            catch (CoreException ex)
            {
                args.Cancel = true;
                box.Description = ex.Message;
            }
            finally { deferral.Complete(); }
        };
        if (await App.Show(dialog) == ContentDialogResult.Primary && id is not null) App.Window.OpenProject(id);
    }

    void OnMenuOpening(object sender, object e) => target = ProjectOf(((MenuFlyout)sender).Target);

    void OnKey(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (Focused is not { } p) return;
        args.Handled = true;
        if (sender.Key == VirtualKey.F2) Rename(p);
        else Delete(p);
    }

    void OnOpenItem(object sender, RoutedEventArgs e) => App.Window.OpenProject(target!.Id);

    void OnRenameItem(object sender, RoutedEventArgs e) => Rename(target!);

    async void OnRevealItem(object sender, RoutedEventArgs e) => App.Reveal(await Root(target!));

    void OnDeleteItem(object sender, RoutedEventArgs e) => Delete(target!);

    async void OnExportItem(object sender, RoutedEventArgs e)
    {
        var p = target!;
        var picker = new FileSavePicker(App.Window.AppWindow.Id) { SuggestedFileName = p.Name };
        picker.FileTypeChoices.Add("ZIP archive", [".zip"]);
        if (await picker.PickSaveFileAsync() is not { } picked) return;
        try { await Core.CallAsync("export_zip", new { id = p.Id, dest = picked.Path }); }
        catch (CoreException ex) { await App.Alert("Can't export", ex.Message); }
    }

    static async Task<string> Root(ProjectInfo p) => (await Core.CallAsync("project_root", new { id = p.Id })).GetString()!;

    /// Renames in place, at the row's name, as File Explorer does.
    void Rename(ProjectInfo p)
    {
        if ((List.ContainerFromItem(p) as ListViewItem)?.ContentTemplateRoot is FrameworkElement row && row.FindName("NameText") is FrameworkElement name)
            rename.Show(name, p.Name, async to => Reload((await Core.CallAsync<ProjectInfo>("rename_project", new { id = p.Id, name = to })).Id));
    }

    async void Delete(ProjectInfo p)
    {
        if (await App.Show(new ContentDialog
        {
            Title = $"Delete “{p.Name}”?",
            Content = "The project folder moves to the Recycle Bin.",
            PrimaryButtonText = "Move to Recycle Bin",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        }) != ContentDialogResult.Primary) return;
        try
        {
            await Core.CallAsync("stop_compile", new { id = p.Id });
            await App.Recycle(await Root(p));
        }
        catch (Exception ex) { await App.Alert("Can't delete this project", ex.Message); }
        Reload();
    }
}
