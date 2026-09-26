using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Microsoft.Windows.Storage.Pickers;
using Windows.Storage;
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
            or MenuCommand.EditFindNext or MenuCommand.EditFindPrevious
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
                if (await PickFolderAsync(new FolderPicker(AppWindow.Id) { CommitButtonText = "Add" }) is { } added)
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
            case MenuCommand.EditFind or MenuCommand.EditFindNext or MenuCommand.EditFindPrevious
                or MenuCommand.EditBold or MenuCommand.EditItalic or MenuCommand.EditMath or MenuCommand.EditComment:
                // The editor page names these as the ids do: edit.findNext is findNext.
                project.Format(command.Id()["edit.".Length..]);
                Editor.Focus();
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
            // These act on a PDF the reader can see, not out of sight.
            case MenuCommand.ViewZoomIn:
                ShowPdf();
                Workspace.Pdf.ZoomBy(1.15);
                break;
            case MenuCommand.ViewZoomOut:
                ShowPdf();
                Workspace.Pdf.ZoomBy(1 / 1.15);
                break;
            case MenuCommand.ViewFitWidth:
                ShowPdf();
                Workspace.Pdf.FitWidth();
                break;
            case MenuCommand.ViewFitHeight:
                ShowPdf();
                Workspace.Pdf.FitHeight();
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

    private void ShowPane(bool sidebar)
    {
        Preferences.SidebarVisible = sidebar;
        SavePreferences();
        Workspace.Render();
    }

    /// <summary>Bring the PDF into view for commands that act on it, the panel out of its way, as macOS does.</summary>
    internal void ShowPdf()
    {
        Project?.ShowLogs = false;
        if (!Preferences.PdfVisible)
        {
            Preferences.PdfVisible = true;
            SavePreferences();
        }
        Workspace.Render();
    }

    // ---------- text editing ----------

    /// <summary>The text box or page that last had focus, which Edit's commands act on; null means the editor.</summary>
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

    /// <summary>Undo, redo and the clipboard for the focused text box, else the page, else the editor (parity D16, K15).</summary>
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

    /// <summary>Ctrl and a letter pressed in a page, since a script may not use the clipboard unasked.</summary>
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

    /// <summary>The PDF to Windows' share sheet, reached through the window handle as the app is unpackaged.</summary>
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

    private async Task<string?> PickSaveAsync(string name, string kind, string extension)
    {
        var picker = new FileSavePicker(AppWindow.Id)
        {
            SuggestedStartLocation = PickerLocationId.Downloads,
            SuggestedFileName = name,
        };
        picker.FileTypeChoices.Add(kind, [extension]);
        try
        {
            return (await picker.PickSaveFileAsync())?.Path;
        }
        catch (COMException e)
        {
            Report("Couldn’t choose where to save", e.Message);
            return null;
        }
    }

    /// <summary>Choose the folder with TeX's programs; a TeX Live or MiKTeX root works too.</summary>
    internal async Task ChooseTexFolderAsync()
    {
        if (await PickFolderAsync(new FolderPicker(AppWindow.Id) { SuggestedStartLocation = PickerLocationId.ComputerFolder, CommitButtonText = "Use this folder" }) is { } folder)
        {
            await SetTexDirAsync(folder);
        }
    }

    private async Task<string?> PickFolderAsync(FolderPicker picker)
    {
        try
        {
            return (await picker.PickSingleFolderAsync())?.Path;
        }
        catch (COMException e)
        {
            Report("Couldn’t choose a folder", e.Message);
            return null;
        }
    }

    private async Task<IReadOnlyList<string>?> PickFilesAsync()
    {
        var picker = new FileOpenPicker(AppWindow.Id) { CommitButtonText = "Add" };
        try
        {
            return (await picker.PickMultipleFilesAsync()).Select(f => f.Path).ToList();
        }
        catch (COMException e)
        {
            Report("Couldn’t choose files", e.Message);
            return null;
        }
    }
}
