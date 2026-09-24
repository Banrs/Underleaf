using System.Runtime.InteropServices;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace TeXLocal;

// Every command the menus, the toolbar, the keyboard and the embedded pages
// can run: when each is available, and what it does.
public sealed partial class MainWindow
{
    internal bool IsEnabled(MenuCommand command) => command switch
    {
        MenuCommand.ProjectNew or MenuCommand.AppSettings => true,
        MenuCommand.CompileRun => Project is { Compiling: false, TexAvailable: true },
        MenuCommand.PdfSave or MenuCommand.PdfFind or MenuCommand.ViewZoomIn or MenuCommand.ViewZoomOut
            or MenuCommand.ViewFitWidth or MenuCommand.ViewFitHeight or MenuCommand.SyncInverse =>
            Project is { PdfVersion: > 0 },
        MenuCommand.SyncForward => Project is { PdfVersion: > 0, OpenPath: not null },
        MenuCommand.FileSave or MenuCommand.EditUndo or MenuCommand.EditRedo or MenuCommand.EditFind
            or MenuCommand.EditBold or MenuCommand.EditItalic or MenuCommand.EditMath or MenuCommand.EditComment
            or MenuCommand.EditGotoLine => Project is { OpenPath: not null },
        _ => Project is not null,
    };

    /// <summary>Commands that switch something on and off, shown with a check mark.</summary>
    internal static bool IsToggle(MenuCommand command) => command is MenuCommand.ViewToggleSidebar
        or MenuCommand.ViewTogglePdf or MenuCommand.ViewToggleLogs or MenuCommand.CompileToggleAuto;

    internal bool IsChecked(MenuCommand command) => command switch
    {
        MenuCommand.ViewToggleSidebar => Preferences.SidebarVisible,
        MenuCommand.ViewTogglePdf => Preferences.PdfVisible,
        MenuCommand.ViewToggleLogs => Project?.ShowLogs ?? false,
        MenuCommand.CompileToggleAuto => Preferences.AutoCompile,
        _ => false,
    };

    internal async void Perform(MenuCommand command)
    {
        if (!IsEnabled(command) || Dialogs.IsOpen)
        {
            return;
        }
        switch (command)
        {
            case MenuCommand.ProjectNew:
                if (await Dialogs.NewProjectAsync(Root.XamlRoot) is { } created)
                {
                    await CreateProjectAsync(created.Name, created.Template);
                }
                return;
            case MenuCommand.AppSettings:
                await Dialogs.SettingsAsync(Root.XamlRoot, Preferences, () =>
                {
                    SavePreferences();
                    ApplyTheme();
                });
                return;
            case MenuCommand.CompileToggleAuto:
                Preferences.AutoCompile = !Preferences.AutoCompile;
                SavePreferences();
                Workspace.Render();
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
                ShowPane(sidebar: true);
                Workspace.FocusSearch();
                break;
            case MenuCommand.FileNew:
                if (await Dialogs.PromptAsync(Root.XamlRoot, "New File", "Path — folders are created as needed", "Create") is { } file)
                {
                    await project.CreateEntryAsync(file, directory: false);
                }
                break;
            case MenuCommand.FileNewFolder:
                if (await Dialogs.PromptAsync(Root.XamlRoot, "New Folder", "Path — folders are created as needed", "Create") is { } folder)
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
            case MenuCommand.FileSave:
                await project.SaveNowAsync();
                break;
            case MenuCommand.PdfSave:
                if (await PickSaveAsync(project.Id, "PDF document", ".pdf") is { } pdf)
                {
                    project.SavePdf(pdf);
                }
                break;
            case MenuCommand.EditUndo:
                Format(project, "undo");
                break;
            case MenuCommand.EditRedo:
                Format(project, "redo");
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
                if (await Dialogs.PromptAsync(Root.XamlRoot, "Go to Line", "Line number", "Go") is { } text
                    && int.TryParse(text, out var line))
                {
                    project.Reveal(line);
                    Editor.Focus();
                }
                break;
            case MenuCommand.PdfFind:
                project.ShowLogs = false;
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
            case MenuCommand.ViewZoomIn:
                Workspace.Pdf.ZoomBy(1.15);
                break;
            case MenuCommand.ViewZoomOut:
                Workspace.Pdf.ZoomBy(1 / 1.15);
                break;
            case MenuCommand.ViewFitWidth:
                Workspace.Pdf.FitWidth();
                break;
            case MenuCommand.ViewFitHeight:
                Workspace.Pdf.FitHeight();
                break;
            case MenuCommand.CompileRun:
                await project.CompileAsync();
                break;
            case MenuCommand.SyncForward:
                await project.ForwardSyncAsync();
                break;
            case MenuCommand.SyncInverse:
                project.ShowLogs = false;
                ShowPdf();
                Workspace.Pdf.InverseFromView();
                break;
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

    /// <summary>Bring the PDF into view, for commands that act on it.</summary>
    internal void ShowPdf()
    {
        if (!Preferences.PdfVisible)
        {
            Preferences.PdfVisible = true;
            SavePreferences();
        }
        Workspace.Render();
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
