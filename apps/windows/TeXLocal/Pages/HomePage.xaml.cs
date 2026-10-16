using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Controls;

namespace TeXLocal.Pages;

public sealed partial class HomePage : Page
{
    readonly RenameFlyout rename = new();
    ProjectInfo? target;
    bool loading;

    public HomePage()
    {
        InitializeComponent();
        // The menu acts on the card it was opened for; F2 and Del on the focused card.
        foreach (var item in ProjectMenu.Items)
            foreach (var key in item.KeyboardAccelerators)
            {
                key.ScopeOwner = List;
                key.Invoked += (_, _) => target = ProjectMenu.IsOpen ? target : Focused;
            }
    }

    public static string Caption(string mainFile, long mtime) =>
        $"{mainFile} · {DateTimeOffset.FromUnixTimeMilliseconds(mtime).LocalDateTime:g}";

    public static string MoreName(string name) => $"More options for {name}";

    static Core? Core => App.Core;
    ProjectInfo? Focused => XamlRoot is { } root ? ProjectOf(FocusManager.GetFocusedElement(root)) : null;
    MainWindow Window => App.Window;

    /// The project of the card an element is in (a card's DataContext isn't its item).
    ProjectInfo? ProjectOf(object? element)
    {
        for (var e = element as DependencyObject; e is not null; e = VisualTreeHelper.GetParent(e))
            if (e is ListViewItem card) return List.ItemFromContainer(card) as ProjectInfo;
        return null;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        Reload();
        _ = CheckTex();
    }

    /// Lists the projects again, keeping keyboard focus on the card it was on (or on `focus`).
    public async void Reload(string? focus = null)
    {
        if (loading) return;
        loading = true;
        try
        {
            if (!App.OpenCore()) throw new CoreException(0, "");
            var projects = await Core!.CallAsync<ProjectInfo[]>("list_projects");
            if (List.ItemsSource is not ProjectInfo[] shown || !shown.SequenceEqual(projects))
            {
                focus ??= Focused?.Id;
                List.ItemsSource = projects;
                if (projects.FirstOrDefault(p => p.Id == focus) is { } p)
                {
                    List.UpdateLayout();
                    (List.ContainerFromItem(p) as Control)?.Focus(FocusState.Programmatic);
                }
            }
            LibraryError.IsOpen = false;
            ShowEmpty(projects.Length == 0);
            if (App.Smoke) App.ExitSmoke(0);
        }
        catch (CoreException ex)
        {
            LibraryError.IsOpen = true;
            ShowEmpty(false);
            if (App.Smoke) App.ExitSmoke(1, ex.Message);
        }
        finally { loading = false; }
    }

    async Task CheckTex()
    {
        if (Core is null) return;
        var status = await Core.CallAsync<TexStatus>("status");
        TexMissing.IsOpen = !status.Available;
    }

    void ShowEmpty(bool empty)
    {
        Empty.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        List.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        NewButton.Style = (Style)Application.Current.Resources[empty ? "DefaultButtonStyle" : "AccentButtonStyle"];
    }

    void OnRetry(object sender, RoutedEventArgs e) => Reload();

    void OnSettings(object sender, RoutedEventArgs e) => Window.OpenSettings();

    async void OnNew(object sender, RoutedEventArgs e)
    {
        if (Core is null) return;
        NameBox.Text = "";
        NameError.Text = "";
        if (await NewDialog.ShowAsync() == ContentDialogResult.Primary && NewDialog.Tag is string id)
            Window.OpenProject(id);
    }

    void OnNameChanged(object sender, TextChangedEventArgs e)
    {
        NameError.Text = "";
        NewDialog.IsPrimaryButtonEnabled = NameBox.Text.Trim().Length > 0;
    }

    async void OnCreate(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            sender.Tag = (await Core!.CallAsync<ProjectInfo>("create_project", new { name = NameBox.Text.Trim() })).Id;
        }
        catch (CoreException ex)
        {
            args.Cancel = true;
            NameError.Text = ex.Message;
        }
        finally { deferral.Complete(); }
    }

    void OnOpenFolder(object sender, RoutedEventArgs e) => Window.OpenFolder();

    void OnOpenFile(object sender, RoutedEventArgs e) => Window.OpenFile();

    void OnItemClick(object sender, ItemClickEventArgs e) => Window.OpenProject(((ProjectInfo)e.ClickedItem).Id);

    void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args) =>
        AutomationProperties.SetName(args.ItemContainer, ((ProjectInfo)args.Item).Name);

    void OnContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        args.Handled = true;
        if (ProjectOf(args.OriginalSource) is not { } p || List.ContainerFromItem(p) is not FrameworkElement card) return;
        target = p;
        ProjectMenu.ShowAt(card, args.TryGetPosition(card, out var at)
            ? new FlyoutShowOptions { Position = at }
            : new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    void OnMore(object sender, RoutedEventArgs e)
    {
        target = ProjectOf(sender);
        ProjectMenu.ShowAt((Button)sender, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
    }

    void OnOpenItem(object sender, RoutedEventArgs e)
    {
        if (target is { } p) Window.OpenProject(p.Id);
    }

    void OnRenameItem(object sender, RoutedEventArgs e)
    {
        if (target is not { } p || List.ContainerFromItem(p) is not FrameworkElement card) return;
        rename.Show(card, p.Name, async name =>
        {
            var renamed = await Core!.CallAsync<ProjectInfo>("rename_project", new { id = p.Id, name });
            Reload(renamed.Id);
        });
    }

    async void OnRevealItem(object sender, RoutedEventArgs e)
    {
        if (target is { } p) App.Reveal($"\"{(await Core!.CallAsync("project_root", new { id = p.Id })).GetString()}\"");
    }

    async void OnExportItem(object sender, RoutedEventArgs e)
    {
        if (target is not { } p) return;
        var picker = new FileSavePicker(Window.AppWindow.Id) { SuggestedFileName = p.Name };
        picker.FileTypeChoices.Add("ZIP archive", [".zip"]);
        var picked = await picker.PickSaveFileAsync();
        if (picked is null) return;
        try { await Core!.CallAsync("export_zip", new { id = p.Id, dest = picked.Path }); }
        catch (CoreException ex) { await App.Alert("Can't export", ex.Message); }
    }

    async void OnDeleteItem(object sender, RoutedEventArgs e)
    {
        if (target is not { } p) return;
        DeleteDialog.Title = $"Delete “{p.Name}”?";
        if (await DeleteDialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await Core!.CallAsync("stop_compile", new { id = p.Id });
            var root = (await Core.CallAsync("project_root", new { id = p.Id })).GetString()!;
            await App.Recycle(root);
        }
        catch (Exception ex)
        {
            await App.Alert("Can't delete this project", ex.Message);
        }
        Reload();
    }
}
