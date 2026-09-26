using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.UI.ViewManagement;

namespace TeXLocal;

/// <summary>
/// The one window, and the state around the open project: the library of
/// projects, TeX's availability and the preferences. Its commands are in
/// Commands.cs.
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>The app has one window; its views reach it here.</summary>
    internal static MainWindow Instance { get; private set; } = null!;

    private static readonly string PreferencesPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TeXLocal", "settings.json");

    internal Core Core { get; } = new();
    internal Preferences Preferences { get; } = Preferences.Load(PreferencesPath);
    internal EditorBridge Editor { get; } = new();
    internal IReadOnlyList<ProjectInfo> Projects { get; private set; } = [];
    internal TexStatus? Tex { get; private set; }
    internal ProjectModel? Project { get; private set; }

    // Kept alive for their change events: Windows' text size and accent.
    private readonly UISettings uiSettings = new();
    // The window's presenter while it isn't full screen: kept, so leaving
    // full screen restores its minimum size and state.
    private readonly OverlappedPresenter overlapped;
    private double minimumSizeScale;
    private bool closing;
    private bool active = true;

    public MainWindow()
    {
        Instance = this;
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        // Tall, as the guidance asks of a title bar holding controls: the
        // TitleBar control grows to 48 once it has content, and the caption
        // buttons are then as tall as it is.
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        overlapped = (OverlappedPresenter)AppWindow.Presenter;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.ico"));
        TitleIcon.ImageSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.png")));
        // Most of the screen, centred: an editor and a PDF side by side want room.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.MoveAndResize(new RectInt32(
            area.X + area.Width / 10, area.Y + area.Height / 10, area.Width * 8 / 10, area.Height * 8 / 10));

        AddAccelerators();
        Root.Loaded += (_, _) =>
        {
            ApplyMinimumSize();
            FitCaptionInset();
            Root.XamlRoot.Changed += (_, _) =>
            {
                ApplyMinimumSize();
                FitCaptionInset();
            };
        };
        Root.ActualThemeChanged += (_, _) => AppearanceChanged();
        uiSettings.TextScaleFactorChanged += (_, _) => DispatcherQueue.TryEnqueue(AppearanceChanged);
        uiSettings.ColorValuesChanged += (_, _) => DispatcherQueue.TryEnqueue(AppearanceChanged);
        ApplyTheme();
        UpdateTitle();

        AppWindow.Closing += OnClosing;
        Closed += (_, _) =>
        {
            // Compiles run in their own process trees, which nothing else stops.
            Core.KillAll();
            Notifications.Unregister();
        };
        Activated += (_, e) => active = e.WindowActivationState != WindowActivationState.Deactivated;

        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        await RefreshProjectsAsync();
        await RefreshTexAsync();
        // While TeX is missing, look again now and then, so installing it
        // takes effect without a restart.
        while (Tex is { Available: false })
        {
            await Task.Delay(TimeSpan.FromSeconds(10));
            await RefreshTexAsync();
            if (Tex is { Available: true })
            {
                Report("TeX was found", "You can compile now.", InfoBarSeverity.Success);
            }
        }
    }

    private async Task RefreshTexAsync()
    {
        try
        {
            Tex = await Core.CallAsync<TexStatus>("status");
        }
        catch (CoreException)
        {
            // Reported as missing; the next look may succeed.
            Tex = new TexStatus(false, null);
        }
        TexChanged();
    }

    /// <summary>
    /// Use TeX from this folder, or find it by itself again (null). The core
    /// refuses a folder without latexmk, and says so in words.
    /// </summary>
    internal async Task SetTexDirAsync(string? dir)
    {
        try
        {
            Tex = await Core.CallAsync<TexStatus>("set_tex_dir", new { dir });
        }
        catch (CoreException e)
        {
            Report("Couldn’t use this folder", e.Message);
            return;
        }
        TexChanged();
    }

    private void TexChanged()
    {
        Home.RenderTex();
        Workspace.TexChanged();
        SettingsPage.Render();
    }

    private async Task RefreshProjectsAsync()
    {
        try
        {
            Projects = (await Core.CallAsync<List<ProjectInfo>>("list_projects")).OrderByDescending(p => p.Mtime).ToList();
        }
        catch (CoreException e)
        {
            Report("Couldn’t list the projects", e.Message);
        }
        Home.Render();
    }

    /// <summary>
    /// Show a message above the content: errors by default. A short title —
    /// what happened, "Couldn’t rename “x”" — then the detail. An InfoBar,
    /// not a dialog, so it never interrupts typing.
    /// </summary>
    internal void Report(string title, string? message = null, InfoBarSeverity severity = InfoBarSeverity.Error)
    {
        MessageBar.Severity = severity;
        MessageBar.Title = title;
        MessageBar.Message = message ?? "";
        MessageBar.IsOpen = true;
        if (severity == InfoBarSeverity.Success)
        {
            _ = DismissLaterAsync(title);
        }
    }

    /// <summary>Good news goes away by itself; errors stay until read.</summary>
    private async Task DismissLaterAsync(string title)
    {
        await Task.Delay(TimeSpan.FromSeconds(6));
        if (MessageBar.Title == title)
        {
            MessageBar.IsOpen = false;
        }
    }

    /// <summary>
    /// The title bar and the taskbar's title for what is on screen: the open
    /// file and its project in the workspace, as a document app names its
    /// document; the screen's name elsewhere. Worked out from the current
    /// state alone, so anything that changes it just calls this again.
    /// </summary>
    internal void UpdateTitle()
    {
        var settings = SettingsPage.Visibility == Visibility.Visible;
        var project = settings ? null : Project;
        // Project-relative paths use forward slashes on every platform.
        var file = project?.OpenPath is { } path ? path[(path.LastIndexOf('/') + 1)..] : null;
        // The project names the window; the open file is in the jump bar below.
        AppTitleBar.Title = settings ? "Settings" : project?.Id ?? "TeXLocal";
        AppTitleBar.IsBackButtonVisible = settings || project is not null;
        AppTitleBar.IsPaneToggleButtonVisible = project is not null;
        PaneToggles.Visibility = project is not null ? Visibility.Visible : Visibility.Collapsed;
        SearchBox.Visibility = settings ? Visibility.Collapsed : Visibility.Visible;
        var search = project is null ? "Search projects" : "Search project";
        SearchBox.PlaceholderText = search;
        AutomationProperties.SetName(SearchBox, search);
        ToolTipService.SetToolTip(SearchBox, $"{search} (Ctrl+Shift+F)");
        Title = project is null ? "TeXLocal"
            : file is null ? $"{project.Id} – TeXLocal"
            : $"{file} – {project.Id} – TeXLocal";
    }

    // ---------- screens ----------

    /// <summary>The library, the open project, or settings over either.</summary>
    private void ShowScreen(bool settings)
    {
        // Library, project, Settings: deeper drills in, back drills out.
        UIElement[] screens = [Home, Workspace, SettingsPage];
        var from = Array.FindIndex(screens, s => s.Visibility == Visibility.Visible);
        var to = settings ? 2 : Project is null ? 0 : 1;
        for (var i = 0; i < screens.Length; i++)
        {
            Motion.Show(screens[i], i == to, to > from ? Motion.DrillIn : Motion.DrillOut);
        }
        if (settings)
        {
            SettingsPage.Render();
        }
        // A new screen starts with nothing searched.
        SearchBox.Text = "";
        UpdateTitle();
        Workspace.RenderMenus();
    }

    // ---------- search ----------

    /// <summary>The title bar's search box searches what's on screen.</summary>
    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (Workspace.Visibility == Visibility.Visible)
        {
            Workspace.Search(sender.Text);
        }
        else if (Home.Visibility == Visibility.Visible)
        {
            Home.Search(sender.Text);
        }
    }

    /// <summary>Enter on the library opens the first match.</summary>
    private void OnSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        if (Home.Visibility == Visibility.Visible)
        {
            Home.OpenFirstMatch();
        }
    }

    /// <summary>
    /// Room for the caption buttons and no more. TitleBar reserves the
    /// window's caption inset, which is in physical pixels, as if it were in
    /// effective ones — twice the buttons' width at 200% — and only once, when
    /// its template applies. Correct it, and again when the scale changes.
    /// </summary>
    private void FitCaptionInset()
    {
        if (VisualTreeHelper.GetChildrenCount(AppTitleBar) == 0
            || VisualTreeHelper.GetChild(AppTitleBar, 0) is not FrameworkElement template)
        {
            return;
        }
        var scale = Root.XamlRoot.RasterizationScale;
        if (template.FindName("LeftPaddingColumn") is ColumnDefinition left)
        {
            left.Width = new GridLength(AppWindow.TitleBar.LeftInset / scale);
        }
        if (template.FindName("RightPaddingColumn") is ColumnDefinition right)
        {
            right.Width = new GridLength(AppWindow.TitleBar.RightInset / scale);
        }
    }

    private void OnSearchAreaSizeChanged(object sender, SizeChangedEventArgs e) => PlaceSearch();

    /// <summary>
    /// Up to 400 wide and centred on the window, as Windows 11 apps centre a
    /// title bar's search box, but never over the menus or the toggles.
    /// </summary>
    private void PlaceSearch()
    {
        if (Root.XamlRoot is null)
        {
            return;
        }
        var slotLeft = Menu.ActualWidth + SearchArea.ColumnSpacing;
        var slotWidth = SearchArea.ActualWidth - slotLeft;
        var width = Math.Clamp(slotWidth, 0, 400);
        var areaLeft = SearchArea.TransformToVisual(Root).TransformPoint(default).X;
        var centred = (Root.ActualWidth - width) / 2 - areaLeft - slotLeft;
        SearchBox.Width = width;
        SearchBox.Margin = new Thickness(Math.Clamp(centred, 0, slotWidth - width), 0, 0, 0);
    }

    private void OnSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape && SearchBox.Text.Length > 0)
        {
            SearchBox.Text = "";
            e.Handled = true;
        }
    }

    internal void OpenSettings() => ShowScreen(settings: true);

    internal void CloseSettings() => ShowScreen(settings: false);

    private void OnBackRequested(TitleBar sender, object args)
    {
        if (SettingsPage.Visibility == Visibility.Visible)
        {
            CloseSettings();
        }
        else
        {
            Perform(MenuCommand.ProjectClose);
        }
    }

    private void OnPaneToggleRequested(TitleBar sender, object args) => Perform(MenuCommand.ViewToggleSidebar);

    private void OnTogglePdf(object sender, RoutedEventArgs e) => Perform(MenuCommand.ViewTogglePdf);

    private void OnToggleInspector(object sender, RoutedEventArgs e) => Perform(MenuCommand.ViewToggleInspector);

    // ---------- projects ----------

    internal async Task OpenAsync(string id)
    {
        if (!await CloseAsync())
        {
            return;
        }
        var project = new ProjectModel(id, Core, Editor, this);
        Project = project;
        ShowScreen(settings: false);
        Workspace.Attach(project);
        await project.LoadAsync();
    }

    /// <summary>
    /// Save, then leave the project. False — and it stays — when the save
    /// fails, rather than dropping the only copy of the edits.
    /// </summary>
    internal async Task<bool> CloseAsync()
    {
        if (Project is not { } project)
        {
            return true;
        }
        if (!await project.FlushAsync())
        {
            return false;
        }
        project.Detach();
        Workspace.Detach();
        Project = null;
        ShowScreen(settings: false);
        await RefreshProjectsAsync();
        return true;
    }

    internal async Task CreateProjectAsync(string name, string template)
    {
        ProjectInfo info;
        try
        {
            info = await Core.CallAsync<ProjectInfo>("create_project", new { name, template });
        }
        catch (CoreException e)
        {
            Report($"Couldn’t create “{name}”", e.Message);
            return;
        }
        await OpenAsync(info.Id);
    }

    internal async Task RenameProjectAsync(ProjectInfo project, string name)
    {
        try
        {
            await Core.CallAsync<ProjectInfo>("rename_project", new { id = project.Id, name });
        }
        catch (CoreException e)
        {
            Report($"Couldn’t rename “{project.Name}”", e.Message);
        }
        await RefreshProjectsAsync();
    }

    internal async Task DeleteProjectAsync(ProjectInfo project)
    {
        try
        {
            await Core.PerformAsync("delete_project", new { id = project.Id });
        }
        catch (CoreException e)
        {
            Report($"Couldn’t delete “{project.Name}”", e.Message);
        }
        await RefreshProjectsAsync();
    }

    // ---------- appearance ----------

    internal void SavePreferences() => Preferences.Save(PreferencesPath);

    /// <summary>"system" follows Windows; the others pin the app's theme.</summary>
    internal void ApplyTheme()
    {
        Root.RequestedTheme = Preferences.Theme switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        AppearanceChanged();
    }

    /// <summary>Carry the theme, accent, text size and settings to what XAML does not reach.</summary>
    internal void AppearanceChanged()
    {
        var dark = Root.ActualTheme == ElementTheme.Dark;
        // The caption buttons are the system's, drawn for the Windows theme,
        // so a pinned app theme recolours them — except in a contrast theme,
        // whose colours are the user's and stay the system's.
        var titleBar = AppWindow.TitleBar;
        var contrast = new AccessibilitySettings().HighContrast;
        titleBar.ButtonForegroundColor = contrast ? null : dark ? Colors.White : Colors.Black;
        titleBar.ButtonBackgroundColor = contrast ? null : Colors.Transparent;
        titleBar.ButtonInactiveBackgroundColor = contrast ? null : Colors.Transparent;

        // The web pages have no access to the Windows accent colour (Chromium
        // dropped CSS AccentColor), so it reaches them from here.
        var color = uiSettings.GetColorValue(UIColorType.Accent);
        var accent = $"#{color.R:x2}{color.G:x2}{color.B:x2}";
        _ = Editor.SetAppearanceAsync(dark, Preferences, accent);
        _ = Editor.SetZoomAsync(Preferences.UiScale / 100.0 * uiSettings.TextScaleFactor);
        var darkPaper = Preferences.PdfPaper == "dark" || (Preferences.PdfPaper == "auto" && dark);
        Workspace.Pdf.SetAppearance(dark, accent, darkPaper);
        Workspace.Render();
    }

    // ---------- window size ----------

    /// <summary>
    /// 960 × 600 at least, as on macOS, so every pane fits at its minimum.
    /// The presenter takes physical pixels (microsoft-ui-xaml#10452), so the
    /// minimum is scaled again whenever the display's scale changes.
    /// </summary>
    private void ApplyMinimumSize()
    {
        var scale = Root.XamlRoot.RasterizationScale;
        if (scale == minimumSizeScale)
        {
            return;
        }
        minimumSizeScale = scale;
        overlapped.PreferredMinimumWidth = (int)Math.Ceiling(960 * scale);
        overlapped.PreferredMinimumHeight = (int)Math.Ceiling(600 * scale);
    }

    /// <summary>F11: the whole screen for the window, and back.</summary>
    internal void ToggleFullScreen()
    {
        if (AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen)
        {
            AppWindow.SetPresenter(overlapped);
        }
        else
        {
            AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
        }
    }

    // ---------- keyboard ----------

    /// <summary>
    /// The menus' chords, on the root so they work on every screen. With focus
    /// in a web page, the page hands the chord back itself (setHostKeys), and
    /// handling it here as well would run the command twice.
    /// </summary>
    private void AddAccelerators()
    {
        foreach (var command in Enum.GetValues<MenuCommand>())
        {
            if (!command.ClaimsChord())
            {
                continue;
            }
            foreach (var chord in Accelerators.Chords(command.Accel()!))
            {
                var accelerator = new KeyboardAccelerator { Key = chord.Key, Modifiers = chord.Modifiers };
                accelerator.Invoked += (_, args) =>
                {
                    if (FocusManager.GetFocusedElement(Root.XamlRoot) is WebView2)
                    {
                        return;
                    }
                    args.Handled = true;
                    Perform(command);
                };
                Root.KeyboardAccelerators.Add(accelerator);
            }
        }
    }

    // ---------- quitting ----------

    /// <summary>
    /// Closing waits for the open document to reach disk. When it cannot be
    /// saved, the window stays unless the user chooses to lose the edits —
    /// never silently, and never a dead end.
    /// </summary>
    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (closing || Project is null)
        {
            return;
        }
        args.Cancel = true;
        _ = CloseAfterSavingAsync();
    }

    /// <summary>Close once the open document reaches disk, or once the user agrees to lose it.</summary>
    private async Task CloseAfterSavingAsync()
    {
        if (closing || Dialogs.IsOpen)
        {
            return;
        }
        if (Project is { } project
            && !await project.FlushAsync()
            && !await Dialogs.ConfirmAsync(Root.XamlRoot, "Close without saving?",
                "TeXLocal couldn’t save your latest changes. If you close now, they’ll be lost.", "Close without saving"))
        {
            return;
        }
        closing = true;
        Close();
    }

    /// <summary>A compile that ends while the window is in the background says so.</summary>
    internal void NotifyCompiled(CompileResult result)
    {
        if (active)
        {
            return;
        }
        Notifications.Show(result.Ok
            ? $"Compiled in {result.DurationMs / 1000.0:0.0}s"
            : result.Errors.Count switch
            {
                0 => "Compile failed",
                1 => "Compile failed with 1 error",
                var n => $"Compile failed with {n} errors",
            });
    }
}
