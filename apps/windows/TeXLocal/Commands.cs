using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace TeXLocal;

// Every command the menus, the toolbar, the keyboard and the embedded pages
// can run: when each is available, and what it does.
public sealed partial class MainWindow
{
    internal bool IsEnabled(MenuCommand command) => command switch
    {
        MenuCommand.ProjectNew or MenuCommand.AppSettings or MenuCommand.ViewUiScaleUp or MenuCommand.ViewUiScaleDown
            or MenuCommand.ViewFullScreen or MenuCommand.AppExit => true,
        // A focused text box (or page, for the clipboard) takes these;
        // otherwise the open document does.
        MenuCommand.EditUndo or MenuCommand.EditRedo => textTarget is TextBox || Editing,
        MenuCommand.EditCut or MenuCommand.EditCopy or MenuCommand.EditPaste or MenuCommand.EditSelectAll =>
            textTarget is not null || Editing,
        // Search finds projects on the library, as it finds text in a project.
        MenuCommand.ProjectSearch when Home.Visibility == Visibility.Visible => true,
        // The rest act on the open project, so only while it is on screen:
        // on the library, or in Settings, they are there but disabled.
        _ when !InWorkspace => false,
        MenuCommand.CompileRun => Project is { Compiling: false, TexAvailable: true },
        MenuCommand.CompileStop => Project is { Compiling: true },
        MenuCommand.PdfSave or MenuCommand.PdfShare or MenuCommand.PdfFind or MenuCommand.ViewZoomIn or MenuCommand.ViewZoomOut
            or MenuCommand.ViewFitWidth or MenuCommand.ViewFitHeight or MenuCommand.SyncInverse =>
            Project is { PdfVersion: > 0 },
        MenuCommand.SyncForward => Project is { PdfVersion: > 0, OpenPath: not null },
        MenuCommand.FileSave or MenuCommand.EditFind
            or MenuCommand.EditBold or MenuCommand.EditItalic or MenuCommand.EditMath or MenuCommand.EditComment
            or MenuCommand.EditGotoLine => Editing,
        _ => true,
    };

    /// <summary>The open project is on screen, not under Settings.</summary>
    private bool InWorkspace => Project is not null && Workspace.Visibility == Visibility.Visible;

    private bool Editing => InWorkspace && Project is { OpenPath: not null };

    /// <summary>Commands that switch something on and off, shown with a check mark.</summary>
    internal static bool IsToggle(MenuCommand command) => command is MenuCommand.ViewToggleSidebar
        or MenuCommand.ViewTogglePdf or MenuCommand.ViewToggleLogs or MenuCommand.ViewToggleInspector
        or MenuCommand.CompileToggleAuto or MenuCommand.ViewFullScreen;

    internal bool IsChecked(MenuCommand command) => command switch
    {
        MenuCommand.ViewToggleSidebar => Preferences.SidebarVisible,
        MenuCommand.ViewTogglePdf => Preferences.PdfVisible,
        MenuCommand.ViewToggleLogs => Project?.ShowLogs ?? false,
        MenuCommand.ViewToggleInspector => Preferences.InspectorVisible,
        MenuCommand.CompileToggleAuto => Preferences.AutoCompile,
        MenuCommand.ViewFullScreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen,
        _ => false,
    };

    internal async void Perform(MenuCommand command)
    {
        // Ctrl+N with no project open starts one, as macOS's Command-N does
        // on its library.
        if (command == MenuCommand.FileNew && Project is null)
        {
            command = MenuCommand.ProjectNew;
        }
        if (!IsEnabled(command) || Dialogs.IsOpen)
        {
            return;
        }
        switch (command)
        {
            case MenuCommand.ProjectNew:
                await NewProjectAsync("article");
                return;
            case MenuCommand.AppSettings:
                OpenSettings();
                return;
            case MenuCommand.ViewUiScaleUp:
            case MenuCommand.ViewUiScaleDown:
                Preferences.UiScale = Preferences.StepUiScale(Preferences.UiScale, command == MenuCommand.ViewUiScaleUp ? 1 : -1);
                SavePreferences();
                AppearanceChanged();
                SettingsPage.Render();
                return;
            case MenuCommand.CompileToggleAuto:
                Preferences.AutoCompile = !Preferences.AutoCompile;
                SavePreferences();
                Workspace.Render();
                return;
            case MenuCommand.ViewFullScreen:
                ToggleFullScreen();
                Workspace.RenderMenus();
                return;
            case MenuCommand.AppExit:
                // As the close button does, so the open document is saved
                // first (OnClosing) and a failed save can keep the window.
                PostMessage(WindowNative.GetWindowHandle(this), WmSysCommand, ScClose, 0);
                return;
            case MenuCommand.EditUndo:
            case MenuCommand.EditRedo:
            case MenuCommand.EditCut:
            case MenuCommand.EditCopy:
            case MenuCommand.EditPaste:
            case MenuCommand.EditSelectAll:
                EditText(command);
                return;
        }
        if (Project is not { } project)
        {
            return;
        }
        switch (command)
        {
            case MenuCommand.ProjectClose:
                await CloseAsync();
                break;
            case MenuCommand.ProjectExport:
                if (await PickSaveAsync(project.Id, "ZIP archive", ".zip") is { } zip)
                {
                    await project.ExportZipAsync(zip);
                }
                break;
            case MenuCommand.ProjectSearch:
                if (InWorkspace)
                {
                    // Results show in the sidebar.
                    ShowPane(sidebar: true);
                }
                SearchBox.Focus(FocusState.Programmatic);
                break;
            case MenuCommand.FileNew:
                if (await Dialogs.PromptAsync(Root.XamlRoot, "New file", "Path (folders are created as needed)", "Create", placeholder: "sections/intro.tex") is { } file)
                {
                    await project.CreateEntryAsync(file, directory: false);
                }
                break;
            case MenuCommand.FileNewFolder:
                if (await Dialogs.PromptAsync(Root.XamlRoot, "New folder", "Path (folders are created as needed)", "Create", placeholder: "figures") is { } folder)
                {
                    await project.CreateEntryAsync(folder, directory: true);
                }
                break;
            case MenuCommand.FileUpload:
                if (await PickFilesAsync() is { Count: > 0 } files)
                {
                    await project.ImportFilesAsync(files);
                }
                break;
            case MenuCommand.FileUploadFolder:
                if (await PickFolderAsync() is { } added)
                {
                    await project.ImportFilesAsync([added]);
                }
                break;
            case MenuCommand.FileSave:
                await project.SaveNowAsync();
                break;
            case MenuCommand.PdfSave:
                if (await PickSaveAsync(project.Id, "PDF document", ".pdf") is { } pdf)
                {
                    project.SavePdf(pdf);
                }
                break;
            case MenuCommand.EditFind:
                Format(project, "find");
                break;
            case MenuCommand.EditBold:
                Format(project, "bold");
                break;
            case MenuCommand.EditItalic:
                Format(project, "italic");
                break;
            case MenuCommand.EditMath:
                Format(project, "math");
                break;
            case MenuCommand.EditComment:
                Format(project, "comment");
                break;
            case MenuCommand.EditGotoLine:
                if (await Dialogs.PromptAsync(Root.XamlRoot, "Go to line", "Line number", "Go") is { } text
                    && int.TryParse(text, out var line))
                {
                    project.Reveal(line);
                    Editor.Focus();
                }
                break;
            case MenuCommand.PdfShare:
                SharePdf();
                break;
            case MenuCommand.PdfFind:
                ShowPdf();
                Workspace.Pdf.BeginFind();
                break;
            case MenuCommand.ViewToggleSidebar:
                ShowPane(sidebar: !Preferences.SidebarVisible);
                break;
            case MenuCommand.ViewTogglePdf:
                Preferences.PdfVisible = !Preferences.PdfVisible;
                SavePreferences();
                Workspace.Render();
                break;
            case MenuCommand.ViewToggleLogs:
                project.ShowLogs = !project.ShowLogs;
                break;
            case MenuCommand.ViewToggleInspector:
                Preferences.InspectorVisible = !Preferences.InspectorVisible;
                SavePreferences();
                Workspace.Render();
                break;
            case MenuCommand.ViewZoomIn:
            case MenuCommand.ViewZoomOut:
            case MenuCommand.ViewFitWidth:
            case MenuCommand.ViewFitHeight:
                // They act on a PDF the reader can see, so it comes into view
                // first rather than changing out of sight.
                ShowPdf();
                switch (command)
                {
                    case MenuCommand.ViewZoomIn:
                        Workspace.Pdf.ZoomBy(1.15);
                        break;
                    case MenuCommand.ViewZoomOut:
                        Workspace.Pdf.ZoomBy(1 / 1.15);
                        break;
                    case MenuCommand.ViewFitWidth:
                        Workspace.Pdf.FitWidth();
                        break;
                    default:
                        Workspace.Pdf.FitHeight();
                        break;
                }
                break;
            case MenuCommand.CompileRun:
                await project.CompileAsync();
                break;
            case MenuCommand.CompileStop:
                project.StopCompile();
                break;
            case MenuCommand.SyncForward:
                await project.ForwardSyncAsync();
                break;
            case MenuCommand.SyncInverse:
                ShowPdf();
                Workspace.Pdf.InverseFromView();
                break;
        }
    }

    /// <summary>Ask for a name, with a template chosen to start from, and open the new project.</summary>
    internal async Task NewProjectAsync(string template)
    {
        if (await Dialogs.NewProjectAsync(Root.XamlRoot, template) is { } created)
        {
            await CreateProjectAsync(created.Name, created.Template);
        }
    }

    private void Format(ProjectModel project, string name)
    {
        project.Format(name);
        Editor.Focus();
    }

    private void ShowPane(bool sidebar)
    {
        Preferences.SidebarVisible = sidebar;
        SavePreferences();
        Workspace.Render();
    }

    /// <summary>
    /// Bring the PDF into view, for commands that act on it: shown, and with
    /// the panel out of its way, as macOS does.
    /// </summary>
    internal void ShowPdf()
    {
        if (Project is { } project)
        {
            project.ShowLogs = false;
        }
        if (!Preferences.PdfVisible)
        {
            Preferences.PdfVisible = true;
            SavePreferences();
        }
        Workspace.Render();
    }

    // ---------- text editing ----------

    /// <summary>
    /// The native text box or page that last had focus, which Edit's
    /// commands act on; null for anything else, when they go to the editor.
    /// Kept as focus moves, since opening a menu takes focus from it.
    /// </summary>
    private DependencyObject? textTarget;

    /// <summary>Follow focus for the Edit menu. Called once, as the workspace is built.</summary>
    internal void WatchTextFocus() => FocusManager.GotFocus += (_, e) =>
    {
        // The menu or flyout being used to run a command is not its target.
        if (e.NewFocusedElement is MenuFlyoutItemBase or MenuBarItem or MenuFlyoutPresenter)
        {
            return;
        }
        var next = e.NewFocusedElement is TextBox or WebView2 ? e.NewFocusedElement : null;
        if (next != textTarget)
        {
            textTarget = next;
            Workspace.RenderMenus();
        }
    };

    /// <summary>
    /// Undo, redo and the clipboard for the focused text box, else the page
    /// that had focus, else the editor, as macOS sends them down the
    /// responder chain (parity D16, K15).
    /// </summary>
    private void EditText(MenuCommand command)
    {
        if (textTarget is TextBox box)
        {
            switch (command)
            {
                case MenuCommand.EditUndo:
                    box.Undo();
                    break;
                case MenuCommand.EditRedo:
                    box.Redo();
                    break;
                case MenuCommand.EditCut:
                    box.CutSelectionToClipboard();
                    break;
                case MenuCommand.EditCopy:
                    box.CopySelectionToClipboard();
                    break;
                case MenuCommand.EditPaste:
                    box.PasteFromClipboard();
                    break;
                default:
                    box.SelectAll();
                    break;
            }
            box.Focus(FocusState.Programmatic);
            return;
        }
        if (command is MenuCommand.EditUndo or MenuCommand.EditRedo)
        {
            _ = Editor.UndoAsync(redo: command == MenuCommand.EditRedo);
            Editor.Focus();
            return;
        }
        var key = command switch
        {
            MenuCommand.EditCut => 'X',
            MenuCommand.EditCopy => 'C',
            MenuCommand.EditPaste => 'V',
            _ => 'A',
        };
        _ = PressAsync(textTarget as WebView2 ?? Editor.View, key);
    }

    /// <summary>
    /// Ctrl and a letter, pressed in a page as the reader would press them.
    /// A script may not read or write the clipboard unasked, and the editor
    /// keeps its selection itself, so the page handles the keys as its own.
    /// </summary>
    private static async Task PressAsync(WebView2 view, char key)
    {
        view.Focus(FocusState.Programmatic);
        if (view.CoreWebView2 is not { } web)
        {
            return;
        }
        foreach (var type in new[] { "rawKeyDown", "keyUp" })
        {
            await web.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", JsonSerializer.Serialize(new
            {
                type,
                modifiers = 2, // Ctrl
                key = char.ToLowerInvariant(key).ToString(),
                code = $"Key{key}",
                windowsVirtualKeyCode = (int)key,
                nativeVirtualKeyCode = (int)key,
            }));
        }
    }

    private const uint WmSysCommand = 0x0112;
    private const nint ScClose = 0xF060;

    [DllImport("user32.dll")]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);

    // ---------- sharing ----------

    private DataTransferManager? share;

    /// <summary>
    /// The PDF to Windows' share sheet, as macOS offers its share menu. An
    /// unpackaged app reaches the sheet through its window handle.
    /// </summary>
    private void SharePdf()
    {
        var window = WindowNative.GetWindowHandle(this);
        if (share is null)
        {
            share = DataTransferManagerInterop.GetForWindow(window);
            share.DataRequested += OnShareRequested;
        }
        DataTransferManagerInterop.ShowShareUIForWindow(window);
    }

    private async void OnShareRequested(DataTransferManager sender, DataRequestedEventArgs args)
    {
        if (Project is not { PdfPath: { } path })
        {
            args.Request.FailWithDisplayText("Compile the project to share its PDF.");
            return;
        }
        var deferral = args.Request.GetDeferral();
        try
        {
            args.Request.Data.Properties.Title = Path.GetFileName(path);
            args.Request.Data.SetStorageItems([await StorageFile.GetFileFromPathAsync(path)]);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FileNotFoundException)
        {
            args.Request.FailWithDisplayText(e.Message);
        }
        finally
        {
            deferral.Complete();
        }
    }

    // ---------- file pickers ----------

    // An unpackaged app's pickers need to be told which window they belong to.
    private T Owned<T>(T picker)
    {
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        return picker;
    }

    private async Task<string?> PickSaveAsync(string name, string kind, string extension)
    {
        var picker = Owned(new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.Downloads,
            SuggestedFileName = name,
        });
        picker.FileTypeChoices.Add(kind, new List<string> { extension });
        try
        {
            return (await picker.PickSaveFileAsync())?.Path;
        }
        catch (COMException e)
        {
            Report(e.Message);
            return null;
        }
    }

    /// <summary>Choose the folder with TeX's programs; a TeX Live or MiKTeX root works too.</summary>
    internal async Task ChooseTexFolderAsync()
    {
        var picker = Owned(new FolderPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder, CommitButtonText = "Use this folder" });
        picker.FileTypeFilter.Add("*");
        try
        {
            if (await picker.PickSingleFolderAsync() is { } folder)
            {
                await SetTexDirAsync(folder.Path);
            }
        }
        catch (COMException e)
        {
            Report(e.Message);
        }
    }

    private async Task<string?> PickFolderAsync()
    {
        var picker = Owned(new FolderPicker { CommitButtonText = "Add" });
        picker.FileTypeFilter.Add("*");
        try
        {
            return (await picker.PickSingleFolderAsync())?.Path;
        }
        catch (COMException e)
        {
            Report(e.Message);
            return null;
        }
    }

    private async Task<IReadOnlyList<string>?> PickFilesAsync()
    {
        var picker = Owned(new FileOpenPicker { CommitButtonText = "Add" });
        picker.FileTypeFilter.Add("*");
        try
        {
            return (await picker.PickMultipleFilesAsync()).Select(f => f.Path).ToList();
        }
        catch (COMException e)
        {
            Report(e.Message);
            return null;
        }
    }
}
