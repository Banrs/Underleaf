using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using TeXLocal.Bridge;
using TeXLocal.Pages;
using Windows.Foundation.Collections;
using Windows.Graphics;
using Windows.System;

namespace TeXLocal;

public sealed partial class MainWindow : Window
{
    public static IPropertySet Prefs { get; } =
        Microsoft.Windows.Storage.ApplicationData.GetForUnpackaged("TeXLocal", "TeXLocal").LocalSettings.Values;

    public static T Pref<T>(string key, T fallback) => Prefs.TryGetValue(key, out var v) && v is T t ? t : fallback;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(Bar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.ico"));
        ApplyTheme((ElementTheme)Pref("theme", 0));
        PlaceWindow();

        var settings = new KeyboardAccelerator { Key = (VirtualKey)188, Modifiers = VirtualKeyModifiers.Control };
        settings.Invoked += (_, e) => { e.Handled = true; OpenSettings(); };
        Root.KeyboardAccelerators.Add(settings);

        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated && Pages.Content is HomePage home) home.Reload();
        };
        Closed += (_, _) =>
        {
            Prefs["maximized"] = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
            App.Core?.Dispose();
        };
        Pages.Navigate(typeof(HomePage));
    }

    public TitleBar TitleBar => Bar;

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
        if (e.Content is not WorkspacePage) Bar.Subtitle = "";
    }

    void PlaceWindow()
    {
        var scale = GetDpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0;
        var presenter = (OverlappedPresenter)AppWindow.Presenter;
        presenter.PreferredMinimumWidth = (int)(800 * scale);
        presenter.PreferredMinimumHeight = (int)(500 * scale);

        var area = DisplayArea.Primary.WorkArea;
        var size = new SizeInt32((int)(1280 * scale), (int)(800 * scale));
        var rect = new RectInt32(area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 2, size.Width, size.Height);
        if (Pref("bounds", "") is { Length: > 0 } s && s.Split(',').Select(int.Parse).ToArray() is [var x, var y, var w, var h])
        {
            var saved = new RectInt32(x, y, w, h);
            var shown = DisplayArea.GetFromRect(saved, DisplayAreaFallback.None);
            if (shown is not null) rect = saved;
        }
        AppWindow.MoveAndResize(rect);
        if (Pref("maximized", false)) presenter.Maximize();

        AppWindow.Changed += (win, e) =>
        {
            if ((e.DidPositionChange || e.DidSizeChange) && win.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
                Prefs["bounds"] = $"{win.Position.X},{win.Position.Y},{win.Size.Width},{win.Size.Height}";
        };
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);
}
