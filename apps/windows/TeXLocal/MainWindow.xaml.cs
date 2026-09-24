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

    private bool closing;

    public MainWindow()
    {
        Instance = this;
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.ico"));
        TitleIcon.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "TeXLocal.png")));
        // Most of the screen, centred: an editor and a PDF side by side want room.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.MoveAndResize(new RectInt32(
            area.X + area.Width / 10, area.Y + area.Height / 10, area.Width * 8 / 10, area.Height * 8 / 10));

        AddAccelerators();
        Root.ActualThemeChanged += (_, _) => AppearanceChanged();
        ApplyTheme();

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

    private bool active = true;

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
                Report("TeX distribution detected — compilation enabled.", InfoBarSeverity.Success);
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
    /// Show a message above the content: errors by default. Not a dialog, so
    /// it never interrupts typing.
    /// </summary>
    internal void Report(string message, InfoBarSeverity severity = InfoBarSeverity.Error)
    {
        MessageBar.Severity = severity;
        MessageBar.Message = message;
        MessageBar.IsOpen = true;
    }

    internal void UpdateTitle()
    {
        TitleText.Text = Project is { } p ? (p.OpenPath is { } file ? $"{p.Id} — {file}" : p.Id) : "TeXLocal";
        StatusText.Text = Project?.Status ?? "";
        Title = Project is { } q ? $"{q.Id} - TeXLocal" : "TeXLocal";
    }

    // ---------- projects ----------

    internal async Task OpenAsync(string id)
    {
        if (!await CloseAsync())
        {
            return;
        }
        var project = new ProjectModel(id, Core, Editor, this);
        Project = project;
        Home.Visibility = Visibility.Collapsed;
        Workspace.Visibility = Visibility.Visible;
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
        Workspace.Visibility = Visibility.Collapsed;
        Home.Visibility = Visibility.Visible;
        UpdateTitle();
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

    private void AppearanceChanged()
    {
        var dark = Root.ActualTheme == ElementTheme.Dark;
        // The caption buttons are the system's, drawn for the Windows theme,
        // so a pinned app theme has to recolour them.
        var titleBar = AppWindow.TitleBar;
        titleBar.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
        titleBar.ButtonBackgroundColor = Colors.Transparent;
        titleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        // The web pages have no access to the Windows accent colour (Chromium
        // dropped CSS AccentColor), so it reaches them from here.
        var accent = new UISettings().GetColorValue(UIColorType.Accent);
        _ = Editor.SetAppearanceAsync(dark, Preferences, $"#{accent.R:x2}{accent.G:x2}{accent.B:x2}");
        Workspace.SetTheme(dark);
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
            if (!command.ClaimsChord() || Accelerators.Parse(command.Accel()!) is not { } chord)
            {
                continue;
            }
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
                "TeXLocal couldn’t save your latest edits. If you close now, they are lost.", "Close Without Saving"))
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
                1 => "Compile failed — 1 error",
                var n => $"Compile failed — {n} errors",
            });
    }
}
