using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
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
    RectInt32[] passthrough = [];
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
        // The mouse's back button, as in File Explorer and Settings.
        Root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, e) =>
        {
            if (e.GetCurrentPoint(Root).Properties.IsXButton1Pressed && Pages.CanGoBack) Pages.GoBack();
        }), true);
        Root.Loaded += (_, _) =>
        {
            Fit();
            Root.XamlRoot.Changed += (_, _) => Fit();
        };
        Bar.LayoutUpdated += OnBarLayout;
        Activated += (_, e) =>
        {
            // The title dims while another window is active, as every Windows title does: tertiary text is about half
            // the primary's opacity in both themes.
            var active = e.WindowActivationState != WindowActivationState.Deactivated;
            TitleText.Opacity = active ? 1 : 0.5;
            if (active) (Pages.Content as HomePage)?.Refresh();
        };
        Closed += (_, _) =>
        {
            Bar.LayoutUpdated -= OnBarLayout;
            Prefs.Bounds = $"{restored.X},{restored.Y},{restored.Width},{restored.Height}";
            Prefs.Maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
            App.Core?.Dispose();
        };
        Pages.Navigate(typeof(HomePage));
    }

    /// The project's menus in the title bar, beside the icon, as Paint and Visual Studio carry theirs; null takes them away.
    public void SetMenu(MenuBar? menu) => MenuHost.Child = menu;

    /// The caption (taskbar, Alt+Tab) and the title bar's middle: "main.tex - Thesis", as Word and Notepad name theirs.
    public void SetTitle(string? project, string? file = null)
    {
        var shown = project is null ? "TeXLocal" : file is null ? project : $"{System.IO.Path.GetFileName(file)} - {project}";
        Title = project is null ? "TeXLocal" : $"{shown} - TeXLocal";
        TitleText.Text = shown;
        TitleText.HorizontalAlignment = MenuHost.Child is null ? HorizontalAlignment.Left : HorizontalAlignment.Center;
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

    void OnBack(object sender, RoutedEventArgs e) => Pages.GoBack();

    void OnNavigated(object sender, NavigationEventArgs e)
    {
        BackButton.Visibility = Pages.CanGoBack ? Visibility.Visible : Visibility.Collapsed;
        SettingsButton.Visibility = e.Content is SettingsPage ? Visibility.Collapsed : Visibility.Visible;
        if (e.Content is WorkspacePage) return;
        SetMenu(null);
        SetTitle(null);
    }

    /// The title bar's controls take the pointer; the rest of the row drags the window. Set again whenever they move.
    void OnBarLayout(object? sender, object e)
    {
        var s = Root.XamlRoot.RasterizationScale;
        RectInt32[] rects = [.. new FrameworkElement[] { BackButton, MenuHost, SettingsButton }
            .Where(e => e.Visibility == Visibility.Visible && e.ActualWidth > 0)
            .Select(e => e.TransformToVisual(null).TransformBounds(new(0, 0, e.ActualWidth, e.ActualHeight)))
            .Select(r => new RectInt32((int)(r.X * s), (int)(r.Y * s), (int)Math.Ceiling(r.Width * s), (int)Math.Ceiling(r.Height * s)))];
        if (rects.SequenceEqual(passthrough)) return;
        passthrough = rects;
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, rects);
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

    /// The 800 × 500 minimum in the pixels of the window's display, again when it moves to another scale; the caption
    /// buttons' room in the title bar.
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
        CaptionColumn.Width = new(AppWindow.TitleBar.RightInset / scale);
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);
}
