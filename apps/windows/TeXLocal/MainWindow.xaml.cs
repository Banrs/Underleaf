using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
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
    private bool closing;
    private bool active = true;

    public MainWindow()
    {
        Instance = this;
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        // Tall, as the guidance asks of a title bar with a back button; the
        // TitleBar control is given the same 48 px so its icon, title and
        // back button centre on the caption buttons.
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.ico"));
        TitleIcon.ImageSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.png")));
        // Most of the screen, centred: an editor and a PDF side by side want room.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.MoveAndResize(new RectInt32(
            area.X + area.Width / 10, area.Y + area.Height / 10, area.Width * 8 / 10, area.Height * 8 / 10));

        AddAccelerators();
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
                Report("TeX was found. You can compile now.", InfoBarSeverity.Success);
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
            Report(e.Message);
        }
        Home.Render();
    }

    /// <summary>
    /// Show a message above the content: errors by default. An InfoBar, not
    /// a dialog, so it never interrupts typing.
    /// </summary>
    internal void Report(string message, InfoBarSeverity severity = InfoBarSeverity.Error)
    {
        MessageBar.Severity = severity;
        MessageBar.Message = message;
        MessageBar.IsOpen = true;
    }

    internal void UpdateTitle()
    {
        var settings = SettingsPage.Visibility == Visibility.Visible;
        AppTitleBar.Subtitle = settings ? "Settings" : Project?.Id ?? "";
        AppTitleBar.IsBackButtonVisible = settings || Project is not null;
        AppTitleBar.IsPaneToggleButtonVisible = !settings && Project is not null;
        Title = Project is { } p ? $"{p.Id} - TeXLocal" : "TeXLocal";
    }

    // ---------- screens ----------

    /// <summary>The library, the open project, or settings over either.</summary>
    private void ShowScreen(bool settings)
    {
        SettingsPage.Visibility = settings ? Visibility.Visible : Visibility.Collapsed;
        Workspace.Visibility = !settings && Project is not null ? Visibility.Visible : Visibility.Collapsed;
        Home.Visibility = !settings && Project is null ? Visibility.Visible : Visibility.Collapsed;
        if (settings)
        {
            SettingsPage.Render();
        }
        UpdateTitle();
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
            Report(e.Message);
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
            Report(e.Message);
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
            Report(e.Message);
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
        Workspace.SetAppearance(dark, accent, darkPaper);
        Workspace.Render();
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
    private async void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (closing || Project is not { } project)
        {
            return;
        }
        args.Cancel = true;
        if (Dialogs.IsOpen)
        {
            return;
        }
        if (!await project.FlushAsync()
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
