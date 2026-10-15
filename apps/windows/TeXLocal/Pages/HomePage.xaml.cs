using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Controls;

namespace TeXLocal.Pages;

public sealed partial class HomePage : Page
{
    readonly RenameFlyout rename = new();
    bool loading;

    public HomePage()
    {
        InitializeComponent();
        foreach (var item in ProjectMenu.Items)
            foreach (var key in item.KeyboardAccelerators) key.ScopeOwner = List;
    }

    public static string Caption(string mainFile, long mtime) =>
        $"{mainFile} · {DateTimeOffset.FromUnixTimeMilliseconds(mtime).LocalDateTime:g}";

    static Core? Core => App.Core;
    ProjectInfo? Selected => List.SelectedItem as ProjectInfo;
    MainWindow Window => App.Window;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        Reload();
        _ = CheckTex();
    }

    public async void Reload()
    {
        if (loading) return;
        loading = true;
        try
        {
            if (!App.OpenCore()) throw new CoreException(0, "");
            var projects = await Core!.CallAsync<ProjectInfo[]>("list_projects");
            var selected = Selected?.Id;
            List.ItemsSource = projects;
            List.SelectedItem = projects.FirstOrDefault(p => p.Id == selected);
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
        if ((args.OriginalSource as FrameworkElement)?.DataContext is ProjectInfo p) List.SelectedItem = p;
        else if (Selected is null) args.Handled = true;
    }

    void OnOpenItem(object sender, RoutedEventArgs e)
    {
        if (Selected is { } p) Window.OpenProject(p.Id);
    }

    void OnRenameItem(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } p || List.ContainerFromItem(p) is not FrameworkElement row) return;
        rename.Show(row, p.Name, async name =>
        {
            await Core!.CallAsync("rename_project", new { id = p.Id, name });
            Reload();
        });
    }

    async void OnRevealItem(object sender, RoutedEventArgs e)
    {
        if (Selected is { } p) App.Reveal($"\"{(await Core!.CallAsync("project_root", new { id = p.Id })).GetString()}\"");
    }

    async void OnExportItem(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } p) return;
        var picker = new FileSavePicker(Window.AppWindow.Id) { SuggestedFileName = p.Name };
        picker.FileTypeChoices.Add("ZIP archive", [".zip"]);
        var picked = await picker.PickSaveFileAsync();
        if (picked is null) return;
        try { await Core!.CallAsync("export_zip", new { id = p.Id, dest = picked.Path }); }
        catch (CoreException ex) { await App.Alert("Can't export", ex.Message); }
    }

    async void OnDeleteItem(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } p) return;
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
