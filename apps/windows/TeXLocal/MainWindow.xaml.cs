using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Pages;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;

namespace TeXLocal;

public sealed partial class MainWindow : Window
{
    RectInt32 restored;
    double scale;
    WorkspacePage? project;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(Bar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.ico"));
        ApplyTheme((ElementTheme)Prefs.Theme);
        Place();

        // Ctrl+, as a handled-too key handler: the editor's RichEditBox swallows it before accelerators.
        Root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, e) =>
        {
            if (e.Key == (VirtualKey)188 && InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down)) OpenSettings();
        }), true);
        // The mouse's back button, as in File Explorer and Settings.
        Root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, e) =>
        {
            if (e.GetCurrentPoint(Root).Properties.IsXButton1Pressed) GoBack();
        }), true);
        Root.Loaded += (_, _) => Root.XamlRoot.Changed += (_, _) => Fit();
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) return;
            (Pages.Content as HomePage)?.Refresh();
            (Pages.Content as WorkspacePage)?.CheckTex();
        };
        // Held until the project's save answers, as the Mac's quit; one that fails keeps the window, and closing again
        // saves again.
        AppWindow.Closing += async (_, e) =>
        {
            if (project is null) return;
            e.Cancel = true;
            if (!await Leave()) return;
            project = null;
            Close();
        };
        Closed += (_, _) =>
        {
            Prefs.Bounds = $"{restored.X},{restored.Y},{restored.Width},{restored.Height}";
            Prefs.Maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
            App.Core?.Dispose();
        };
        Pages.Navigate(typeof(HomePage));
    }

    /// A later launch brings the window forward and opens what it names; its process has let this one take the foreground.
    public void Arrive(string[] args)
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        Activate();
        _ = Import(args);
    }

    /// The project's menus in the title bar; null takes them away.
    public void SetMenu(MenuBar? menu) => Bar.Content = menu;

    /// The title bar names the project, as Visual Studio's names the solution; the caption (taskbar, Alt+Tab) adds
    /// the file, "main.tex - Thesis - TeXLocal", as Word and Notepad name theirs.
    public void SetTitle(string? project, string? file = null)
    {
        Bar.Title = project ?? "TeXLocal";
        Title = project is null ? "TeXLocal" : file is null ? $"{project} - TeXLocal" : $"{System.IO.Path.GetFileName(file)} - {project} - TeXLocal";
    }

    public void ApplyTheme(ElementTheme theme)
    {
        Root.RequestedTheme = theme;
        AppWindow.TitleBar.PreferredTheme = theme switch
        {
            ElementTheme.Light => TitleBarTheme.Light,
            ElementTheme.Dark => TitleBarTheme.Dark,
            _ => TitleBarTheme.UseDefaultAppMode,
        };
    }

    /// With `file`, the project shows that file instead of its main file.
    public async void OpenProject(string id, string? file = null)
    {
        if (!await Leave()) return;
        ShowHome();
        Pages.Navigate(typeof(WorkspacePage), (id, file), new DrillInNavigationTransitionInfo());
    }

    public async void OpenFolder()
    {
        if (await new FolderPicker(AppWindow.Id).PickSingleFolderAsync() is { } picked) await Import(picked.Path);
    }

    public async void OpenFile()
    {
        var picker = new FileOpenPicker(AppWindow.Id) { FileTypeFilter = { ".zip", ".tex" } };
        if (await picker.PickSingleFileAsync() is { } picked) await Import(picked.Path);
    }

    /// The folders, .tex and .zip files of a command line or a drop on Home; as on the Mac, one alone opens.
    public async Task Import(IEnumerable<string> paths)
    {
        string[] openable = [.. paths.Where(p => Directory.Exists(p) || Path.GetExtension(p).ToLowerInvariant() is ".tex" or ".zip").Select(Path.GetFullPath)];
        foreach (var path in openable) await Import(path, openable.Length == 1);
        if (openable.Length > 1) (Pages.Content as HomePage)?.Refresh();
    }

    /// What's already in the library is its project, opening at the file, as on the Mac; anything else is imported.
    async Task Import(string src, bool open = true)
    {
        if (App.Core is null) return;
        try
        {
            var at = await App.Core.CallAsync<Located?>("locate", new { path = src });
            var id = at?.Id ?? (await App.Core.CallAsync<ProjectInfo>("import_project", new { src })).Id;
            if (open) OpenProject(id, at is not null && File.Exists(src) ? at.Path : null);
        }
        catch (CoreException ex) { await App.Alert("Can't open this", ex.Message); }
    }

    public void OpenSettings()
    {
        if (Pages.Content is not SettingsPage)
            Pages.Navigate(typeof(SettingsPage), null, new SlideNavigationTransitionInfo { Effect = SlideNavigationTransitionEffect.FromRight });
    }

    public async void GoHome()
    {
        if (await Leave()) ShowHome();
    }

    void ShowHome()
    {
        while (Pages.CanGoBack && Pages.Content is not HomePage) Pages.GoBack();
    }

    /// Back from Settings returns to the project; back from the project leaves it.
    async void GoBack()
    {
        if (Pages.CanGoBack && (Pages.Content is not WorkspacePage || await Leave())) Pages.GoBack();
    }

    /// False, staying, when the open project's save fails or is asked about: the editor holds the only copy.
    async Task<bool> Leave() => project is null || await project.Save();

    /// Back shows only where there is somewhere to go back to, as in Windows Settings.
    void OnNavigated(object sender, NavigationEventArgs e)
    {
        Bar.IsBackButtonVisible = Pages.CanGoBack;
        SettingsButton.Visibility = e.Content is SettingsPage ? Visibility.Collapsed : Visibility.Visible;
        if (e.Content is WorkspacePage page)
        {
            project = page;
            return;
        }
        if (e.Content is HomePage) project = null;
        SetMenu(null);
        SetTitle(null);
    }

    /// The saved bounds while they're on a display, else 1280 × 800 centred; they're saved on Closed.
    void Place()
    {
        Fit();
        var area = DisplayArea.Primary.WorkArea;
        var (width, height) = ((int)(1280 * scale), (int)(800 * scale));
        restored = new(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height);
        if (Prefs.Bounds.Split(',').Select(s => int.TryParse(s, out var n) ? n : (int?)null).ToArray() is [int x, int y, int w and > 0, int h and > 0]
            && DisplayArea.GetFromRect(new(x, y, w, h), DisplayAreaFallback.None) is not null)
            restored = new(x, y, w, h);
        AppWindow.MoveAndResize(restored);
        if (Prefs.Maximized) ((OverlappedPresenter)AppWindow.Presenter).Maximize();
        AppWindow.Changed += (win, e) =>
        {
            if ((e.DidPositionChange || e.DidSizeChange) && win.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
                restored = new(win.Position.X, win.Position.Y, win.Size.Width, win.Size.Height);
        };
    }

    /// The 800 × 500 minimum in the pixels of the window's display, again when it moves to another scale.
    void Fit()
    {
        var now = GetDpiForWindow(Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0;
        if (now != scale)
        {
            scale = now;
            var presenter = (OverlappedPresenter)AppWindow.Presenter;
            presenter.PreferredMinimumWidth = (int)(800 * scale);
            presenter.PreferredMinimumHeight = (int)(500 * scale);
        }
        // TitleBar 2.3.9 takes the caption inset's pixels as DIPs (docs/windows.md): the bar reaches past the edge by the difference.
        var inset = AppWindow.TitleBar.RightInset;
        Bar.Margin = new Thickness(0, 0, inset / scale - inset, 0);
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);
}
