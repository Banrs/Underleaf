using Windows.System;

namespace TeXLocal;

/// <summary>
/// The app's commands, with the browser version's ids and accelerators
/// (web/src/workspace.js <c>commandDefs</c>). The accelerator string is the
/// one source for the window's keyboard accelerators, the shortcut text the
/// menus show, and the chords the embedded pages hand back to the host.
/// </summary>
public enum MenuCommand
{
    ProjectNew,
    ProjectClose,
    ProjectExport,
    ProjectSearch,
    FileNew,
    FileNewFolder,
    FileUpload,
    FileSave,
    PdfSave,
    EditUndo,
    EditRedo,
    EditFind,
    EditBold,
    EditItalic,
    EditMath,
    EditComment,
    EditGotoLine,
    PdfFind,
    ViewToggleSidebar,
    ViewTogglePdf,
    ViewToggleLogs,
    ViewZoomIn,
    ViewZoomOut,
    ViewFitWidth,
    ViewFitHeight,
    CompileRun,
    CompileToggleAuto,
    SyncForward,
    SyncInverse,
    AppSettings,
}

public static class MenuCommands
{
    public static string Id(this MenuCommand command) => command switch
    {
        MenuCommand.ProjectNew => "project.new",
        MenuCommand.ProjectClose => "project.close",
        MenuCommand.ProjectExport => "project.export",
        MenuCommand.ProjectSearch => "project.search",
        MenuCommand.FileNew => "file.new",
        MenuCommand.FileNewFolder => "file.newFolder",
        MenuCommand.FileUpload => "file.upload",
        MenuCommand.FileSave => "file.save",
        MenuCommand.PdfSave => "pdf.save",
        MenuCommand.EditUndo => "edit.undo",
        MenuCommand.EditRedo => "edit.redo",
        MenuCommand.EditFind => "edit.find",
        MenuCommand.EditBold => "edit.bold",
        MenuCommand.EditItalic => "edit.italic",
        MenuCommand.EditMath => "edit.math",
        MenuCommand.EditComment => "edit.comment",
        MenuCommand.EditGotoLine => "edit.gotoLine",
        MenuCommand.PdfFind => "pdf.find",
        MenuCommand.ViewToggleSidebar => "view.toggleSidebar",
        MenuCommand.ViewTogglePdf => "view.togglePdf",
        MenuCommand.ViewToggleLogs => "view.toggleLogs",
        MenuCommand.ViewZoomIn => "view.zoomIn",
        MenuCommand.ViewZoomOut => "view.zoomOut",
        MenuCommand.ViewFitWidth => "view.fitWidth",
        MenuCommand.ViewFitHeight => "view.fitHeight",
        MenuCommand.CompileRun => "compile.run",
        MenuCommand.CompileToggleAuto => "compile.toggleAuto",
        MenuCommand.SyncForward => "sync.forward",
        MenuCommand.SyncInverse => "sync.inverse",
        MenuCommand.AppSettings => "app.settings",
        _ => throw new ArgumentOutOfRangeException(nameof(command)),
    };

    public static string Title(this MenuCommand command) => command switch
    {
        MenuCommand.ProjectNew => "New Project…",
        MenuCommand.ProjectClose => "Close Project",
        MenuCommand.ProjectExport => "Export Project as ZIP…",
        MenuCommand.ProjectSearch => "Find in Project",
        MenuCommand.FileNew => "New File…",
        MenuCommand.FileNewFolder => "New Folder…",
        MenuCommand.FileUpload => "Add Files…",
        MenuCommand.FileSave => "Save",
        MenuCommand.PdfSave => "Save PDF As…",
        MenuCommand.EditUndo => "Undo",
        MenuCommand.EditRedo => "Redo",
        MenuCommand.EditFind => "Find & Replace",
        MenuCommand.EditBold => "Bold",
        MenuCommand.EditItalic => "Italic",
        MenuCommand.EditMath => "Inline Math",
        MenuCommand.EditComment => "Toggle Comment",
        MenuCommand.EditGotoLine => "Go to Line…",
        MenuCommand.PdfFind => "Find in PDF…",
        MenuCommand.ViewToggleSidebar => "Sidebar",
        MenuCommand.ViewTogglePdf => "PDF",
        MenuCommand.ViewToggleLogs => "Compile Log",
        MenuCommand.ViewZoomIn => "Zoom In",
        MenuCommand.ViewZoomOut => "Zoom Out",
        MenuCommand.ViewFitWidth => "Fit Width",
        MenuCommand.ViewFitHeight => "Fit Height",
        MenuCommand.CompileRun => "Compile",
        MenuCommand.CompileToggleAuto => "Compile Automatically",
        MenuCommand.SyncForward => "Go to PDF Position",
        MenuCommand.SyncInverse => "Go to Source Position",
        MenuCommand.AppSettings => "Settings…",
        _ => throw new ArgumentOutOfRangeException(nameof(command)),
    };

    public static string? Accel(this MenuCommand command) => command switch
    {
        MenuCommand.ProjectNew => "CmdOrCtrl+Shift+N",
        MenuCommand.ProjectSearch => "CmdOrCtrl+Shift+F",
        MenuCommand.FileNew => "CmdOrCtrl+N",
        MenuCommand.FileNewFolder => "CmdOrCtrl+Shift+Alt+N",
        MenuCommand.FileSave => "CmdOrCtrl+S",
        MenuCommand.PdfSave => "CmdOrCtrl+Shift+S",
        MenuCommand.EditUndo => "CmdOrCtrl+Z",
        MenuCommand.EditRedo => "CmdOrCtrl+Shift+Z",
        MenuCommand.EditFind => "CmdOrCtrl+F",
        MenuCommand.EditBold => "CmdOrCtrl+B",
        MenuCommand.EditItalic => "CmdOrCtrl+I",
        MenuCommand.EditMath => "CmdOrCtrl+Shift+M",
        MenuCommand.EditComment => "CmdOrCtrl+/",
        MenuCommand.EditGotoLine => "CmdOrCtrl+L",
        MenuCommand.PdfFind => "CmdOrCtrl+Alt+F",
        MenuCommand.ViewToggleSidebar => "CmdOrCtrl+\\",
        MenuCommand.ViewTogglePdf => "CmdOrCtrl+Shift+\\",
        MenuCommand.ViewToggleLogs => "CmdOrCtrl+Shift+L",
        MenuCommand.ViewZoomIn => "CmdOrCtrl+Plus",
        MenuCommand.ViewZoomOut => "CmdOrCtrl+Minus",
        MenuCommand.ViewFitWidth => "CmdOrCtrl+0",
        MenuCommand.ViewFitHeight => "CmdOrCtrl+Alt+0",
        MenuCommand.CompileRun => "CmdOrCtrl+Return",
        MenuCommand.SyncForward => "Ctrl+Return",
        MenuCommand.SyncInverse => "Ctrl+Shift+Return",
        MenuCommand.AppSettings => "CmdOrCtrl+,",
        _ => null,
    };

    public static MenuCommand? FromId(string id)
    {
        foreach (var command in Enum.GetValues<MenuCommand>())
        {
            if (command.Id() == id)
            {
                return command;
            }
        }
        return null;
    }

    /// <summary>
    /// Undo and redo belong to whichever text field has focus — the editor
    /// page or a native box — so the menu shows their chords but never claims
    /// them.
    /// </summary>
    public static bool ClaimsChord(this MenuCommand command) =>
        command.Accel() is not null && command is not (MenuCommand.EditUndo or MenuCommand.EditRedo);

    /// <summary>
    /// Chords the embedded pages give back to the host. Find and comment stay
    /// with the editor, which implements them itself, as do undo and redo.
    /// </summary>
    public static IReadOnlyList<(string Id, string Accel)> HostKeys { get; } =
        Enum.GetValues<MenuCommand>()
            .Where(c => c.ClaimsChord() && c is not (MenuCommand.EditFind or MenuCommand.EditComment))
            .Select(c => (c.Id(), c.Accel()!))
            .ToList();
}

/// <summary>An accelerator string, as Windows reads it.</summary>
public readonly record struct Chord(VirtualKey Key, VirtualKeyModifiers Modifiers);

public static class Accelerators
{
    // The keys a US layout puts these characters on — the physical keys the
    // web side matches (web/src/commands.js codesFor).
    private const VirtualKey OemPlus = (VirtualKey)0xBB;
    private const VirtualKey OemMinus = (VirtualKey)0xBD;
    private const VirtualKey OemComma = (VirtualKey)0xBC;
    private const VirtualKey OemPeriod = (VirtualKey)0xBE;
    private const VirtualKey OemSlash = (VirtualKey)0xBF;
    private const VirtualKey OemBackslash = (VirtualKey)0xDC;

    /// <summary>"CmdOrCtrl+Shift+Z" → Ctrl+Shift and Z; null for anything unknown.</summary>
    public static Chord? Parse(string accel)
    {
        var parts = accel.Split('+');
        var modifiers = VirtualKeyModifiers.None;
        foreach (var part in parts[..^1])
        {
            VirtualKeyModifiers? modifier = part switch
            {
                // Windows has no Command key, so CmdOrCtrl is Ctrl.
                "CmdOrCtrl" or "Ctrl" or "Control" => VirtualKeyModifiers.Control,
                "Alt" or "Option" => VirtualKeyModifiers.Menu,
                "Shift" => VirtualKeyModifiers.Shift,
                _ => null,
            };
            if (modifier is not { } known)
            {
                return null;
            }
            modifiers |= known;
        }
        var name = parts[^1];
        VirtualKey? key = name switch
        {
            "Return" or "Enter" => VirtualKey.Enter,
            "Plus" => OemPlus,
            "Minus" => OemMinus,
            "," => OemComma,
            "." => OemPeriod,
            "/" => OemSlash,
            "\\" => OemBackslash,
            _ when name.Length == 1 && char.IsAsciiLetter(name[0]) => VirtualKey.A + (char.ToUpperInvariant(name[0]) - 'A'),
            _ when name.Length == 1 && char.IsAsciiDigit(name[0]) => VirtualKey.Number0 + (name[0] - '0'),
            _ => null,
        };
        return key is { } k ? new Chord(k, modifiers) : null;
    }

    /// <summary>
    /// The shortcut text a Windows menu shows: "CmdOrCtrl+Shift+Alt+N" →
    /// "Ctrl+Alt+Shift+N", modifiers in the order Windows lists them.
    /// </summary>
    public static string Label(string accel)
    {
        var parts = accel.Split('+');
        var modifiers = parts[..^1];
        var names = new List<string>();
        if (modifiers.Any(m => m is "CmdOrCtrl" or "Ctrl" or "Control")) names.Add("Ctrl");
        if (modifiers.Any(m => m is "Alt" or "Option")) names.Add("Alt");
        if (modifiers.Contains("Shift")) names.Add("Shift");
        names.Add(parts[^1] switch
        {
            "Return" or "Enter" => "Enter",
            [var c] => char.ToUpperInvariant(c).ToString(),
            var key => key,
        });
        return string.Join('+', names);
    }
}
