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
        Root.Loaded += (_, _) =>
        {
            Fit();
            Root.XamlRoot.Changed += (_, _) => Fit();
        };
        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated) (Pages.Content as HomePage)?.Refresh();
        };
        Closed += (_, _) =>
        {
            Prefs.Bounds = $"{restored.X},{restored.Y},{restored.Width},{restored.Height}";
            Prefs.Maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
            App.Core?.Dispose();
        };
        Pages.Navigate(typeof(HomePage));
    }

    /// The project in the caption (taskbar, Alt+Tab) and the search box, as Notepad and VS Code name theirs.
    public void SetProject(string? name)
    {
        Title = name is null ? "TeXLocal" : $"{name} - TeXLocal";
        Search.Visibility = name is null ? Visibility.Collapsed : Visibility.Visible;
        if (name is not null) Search.PlaceholderText = $"Search {name}";
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

    public void OpenProject(string id)
    {
        GoHome();
        Pages.Navigate(typeof(WorkspacePage), id, new DrillInNavigationTransitionInfo());
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

    async Task Import(string src)
    {
        if (App.Core is null) return;
        try { OpenProject((await App.Core.CallAsync<ProjectInfo>("import_project", new { src })).Id); }
        catch (CoreException ex) { await App.Alert("Can't open this", ex.Message); }
    }

    public void OpenSettings()
    {
        if (Pages.Content is not SettingsPage)
            Pages.Navigate(typeof(SettingsPage), null, new SlideNavigationTransitionInfo { Effect = SlideNavigationTransitionEffect.FromRight });
    }

    public void GoHome()
    {
        while (Pages.CanGoBack && Pages.Content is not HomePage) Pages.GoBack();
    }

    void OnBackRequested(TitleBar sender, object args)
    {
        if (Pages.CanGoBack) Pages.GoBack();
    }

    void OnPaneToggleRequested(TitleBar sender, object args) => (Pages.Content as WorkspacePage)?.TogglePane();

    void OnNavigated(object sender, NavigationEventArgs e)
    {
        Bar.IsBackButtonVisible = Pages.CanGoBack;
        Bar.IsPaneToggleButtonVisible = e.Content is WorkspacePage;
        SettingsButton.Visibility = e.Content is SettingsPage ? Visibility.Collapsed : Visibility.Visible;
        if (e.Content is not WorkspacePage) SetProject(null);
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
        // WinUI's TitleBar reserves the caption buttons' inset in pixels as if they were DIPs, which above 100% leaves
        // the gear a caption-width short of them: the bar reaches past the window's edge by the difference.
        var inset = AppWindow.TitleBar.RightInset;
        Bar.Margin = new Thickness(0, 0, inset / scale - inset, 0);
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);
}
