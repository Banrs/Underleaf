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
    PdfShare,
    EditUndo,
    EditRedo,
    EditFind,
    EditFindNext,
    EditFindPrevious,
    EditBold,
    EditItalic,
    EditMath,
    EditComment,
    EditGotoLine,
    PdfFind,
    ViewToggleSidebar,
    ViewTogglePdf,
    ViewToggleLogs,
    ViewToggleInspector,
    ViewZoomIn,
    ViewZoomOut,
    ViewFitWidth,
    ViewFitHeight,
    ViewUiScaleUp,
    ViewUiScaleDown,
    CompileRun,
    CompileStop,
    CompileToggleAuto,
    SyncForward,
    SyncInverse,
    AppSettings,

    // Native only (IsNativeOnly): what a Windows app's menus hold and the
    // browser's own menus already give it.
    FileUploadFolder,
    EditCut,
    EditCopy,
    EditPaste,
    EditSelectAll,
    ViewFullScreen,
    AppExit,
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
        MenuCommand.PdfShare => "pdf.share",
        MenuCommand.EditUndo => "edit.undo",
        MenuCommand.EditRedo => "edit.redo",
        MenuCommand.EditFind => "edit.find",
        MenuCommand.EditFindNext => "edit.findNext",
        MenuCommand.EditFindPrevious => "edit.findPrevious",
        MenuCommand.EditBold => "edit.bold",
        MenuCommand.EditItalic => "edit.italic",
        MenuCommand.EditMath => "edit.math",
        MenuCommand.EditComment => "edit.comment",
        MenuCommand.EditGotoLine => "edit.gotoLine",
        MenuCommand.PdfFind => "pdf.find",
        MenuCommand.ViewToggleSidebar => "view.toggleSidebar",
        MenuCommand.ViewTogglePdf => "view.togglePdf",
        MenuCommand.ViewToggleLogs => "view.toggleLogs",
        MenuCommand.ViewToggleInspector => "view.toggleInspector",
        MenuCommand.ViewZoomIn => "view.zoomIn",
        MenuCommand.ViewZoomOut => "view.zoomOut",
        MenuCommand.ViewFitWidth => "view.fitWidth",
        MenuCommand.ViewFitHeight => "view.fitHeight",
        MenuCommand.ViewUiScaleUp => "view.uiScaleUp",
        MenuCommand.ViewUiScaleDown => "view.uiScaleDown",
        MenuCommand.CompileRun => "compile.run",
        MenuCommand.CompileStop => "compile.stop",
        MenuCommand.CompileToggleAuto => "compile.toggleAuto",
        MenuCommand.SyncForward => "sync.forward",
        MenuCommand.SyncInverse => "sync.inverse",
        MenuCommand.AppSettings => "app.settings",
        MenuCommand.FileUploadFolder => "file.uploadFolder",
        MenuCommand.EditCut => "edit.cut",
        MenuCommand.EditCopy => "edit.copy",
        MenuCommand.EditPaste => "edit.paste",
        MenuCommand.EditSelectAll => "edit.selectAll",
        MenuCommand.ViewFullScreen => "view.fullScreen",
        MenuCommand.AppExit => "app.exit",
        _ => throw new ArgumentOutOfRangeException(nameof(command)),
    };

    /// <summary>
    /// Menu text in sentence case, as Windows writes commands; an ellipsis
    /// marks a command that asks for more before it acts.
    /// </summary>
    public static string Title(this MenuCommand command) => command switch
    {
        MenuCommand.ProjectNew => "New project…",
        MenuCommand.ProjectClose => "Close project",
        MenuCommand.ProjectExport => "Export project as ZIP…",
        MenuCommand.ProjectSearch => "Find in project",
        MenuCommand.FileNew => "New file…",
        MenuCommand.FileNewFolder => "New folder…",
        MenuCommand.FileUpload => "Add files…",
        MenuCommand.FileSave => "Save",
        MenuCommand.PdfSave => "Save PDF as…",
        MenuCommand.PdfShare => "Share PDF…",
        MenuCommand.EditUndo => "Undo",
        MenuCommand.EditRedo => "Redo",
        MenuCommand.EditFind => "Find and replace",
        MenuCommand.EditFindNext => "Find next",
        MenuCommand.EditFindPrevious => "Find previous",
        MenuCommand.EditBold => "Bold",
        MenuCommand.EditItalic => "Italic",
        MenuCommand.EditMath => "Inline math",
        MenuCommand.EditComment => "Toggle comment",
        MenuCommand.EditGotoLine => "Go to line…",
        MenuCommand.PdfFind => "Find in PDF",
        MenuCommand.ViewToggleSidebar => "Sidebar",
        MenuCommand.ViewTogglePdf => "PDF",
        MenuCommand.ViewToggleLogs => "Panel",
        MenuCommand.ViewToggleInspector => "Details pane",
        MenuCommand.ViewZoomIn => "Zoom in",
        MenuCommand.ViewZoomOut => "Zoom out",
        MenuCommand.ViewFitWidth => "Fit width",
        MenuCommand.ViewFitHeight => "Fit height",
        MenuCommand.ViewUiScaleUp => "Increase editor size",
        MenuCommand.ViewUiScaleDown => "Decrease editor size",
        MenuCommand.CompileRun => "Compile",
        MenuCommand.CompileStop => "Stop",
        MenuCommand.CompileToggleAuto => "Compile automatically",
        MenuCommand.SyncForward => "Go to PDF position",
        MenuCommand.SyncInverse => "Go to source position",
        MenuCommand.AppSettings => "Settings",
        MenuCommand.FileUploadFolder => "Add folder…",
        MenuCommand.EditCut => "Cut",
        MenuCommand.EditCopy => "Copy",
        MenuCommand.EditPaste => "Paste",
        MenuCommand.EditSelectAll => "Select all",
        MenuCommand.ViewFullScreen => "Full screen",
        MenuCommand.AppExit => "Exit",
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
        MenuCommand.EditFindNext => "CmdOrCtrl+G",
        MenuCommand.EditFindPrevious => "CmdOrCtrl+Shift+G",
        MenuCommand.EditBold => "CmdOrCtrl+B",
        MenuCommand.EditItalic => "CmdOrCtrl+I",
        MenuCommand.EditMath => "CmdOrCtrl+Shift+M",
        MenuCommand.EditComment => "CmdOrCtrl+/",
        MenuCommand.EditGotoLine => "CmdOrCtrl+L",
        MenuCommand.PdfFind => "CmdOrCtrl+Alt+F",
        MenuCommand.ViewToggleSidebar => "CmdOrCtrl+\\",
        MenuCommand.ViewTogglePdf => "CmdOrCtrl+Shift+\\",
        MenuCommand.ViewToggleLogs => "CmdOrCtrl+Shift+L",
        // File Explorer's chord for its details pane, the Windows form of an inspector.
        MenuCommand.ViewToggleInspector => "Alt+Shift+P",
        MenuCommand.ViewZoomIn => "CmdOrCtrl+Plus",
        MenuCommand.ViewZoomOut => "CmdOrCtrl+Minus",
        MenuCommand.ViewFitWidth => "CmdOrCtrl+0",
        MenuCommand.ViewFitHeight => "CmdOrCtrl+Alt+0",
        MenuCommand.ViewUiScaleUp => "CmdOrCtrl+Alt+Plus",
        MenuCommand.ViewUiScaleDown => "CmdOrCtrl+Alt+Minus",
        MenuCommand.CompileRun => "CmdOrCtrl+Return",
        // Windows' Stop chord, as macOS has Command-period (see Parse).
        MenuCommand.CompileStop => "CmdOrCtrl+Pause",
        MenuCommand.SyncForward => "Ctrl+Return",
        MenuCommand.SyncInverse => "Ctrl+Shift+Return",
        MenuCommand.AppSettings => "CmdOrCtrl+,",
        MenuCommand.EditCut => "CmdOrCtrl+X",
        MenuCommand.EditCopy => "CmdOrCtrl+C",
        MenuCommand.EditPaste => "CmdOrCtrl+V",
        MenuCommand.EditSelectAll => "CmdOrCtrl+A",
        MenuCommand.ViewFullScreen => "F11",
        _ => null,
    };

    /// <summary>
    /// Commands the native apps add to the browser version's: panes and
    /// actions the web has no counterpart for (apps/macos has the same), and
    /// the standard items a Windows menu bar has: Exit, the clipboard, full
    /// screen.
    /// </summary>
    public static bool IsNativeOnly(this MenuCommand command) =>
        command is MenuCommand.PdfShare or MenuCommand.ViewToggleInspector or MenuCommand.CompileStop
            or MenuCommand.FileUploadFolder or MenuCommand.EditCut or MenuCommand.EditCopy or MenuCommand.EditPaste
            or MenuCommand.EditSelectAll or MenuCommand.ViewFullScreen or MenuCommand.AppExit;

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
    /// Undo, redo and the clipboard belong to whichever text field has focus
    /// — the editor page or a native box — and find next and previous to the
    /// editor page's find panel, which also answers F3 and Shift+F3, so the
    /// menu shows their chords but never claims them.
    /// </summary>
    public static bool IsTextEditing(this MenuCommand command) =>
        command is MenuCommand.EditUndo or MenuCommand.EditRedo
            or MenuCommand.EditCut or MenuCommand.EditCopy or MenuCommand.EditPaste or MenuCommand.EditSelectAll
            or MenuCommand.EditFindNext or MenuCommand.EditFindPrevious;

    /// <summary>
    /// Whether the window takes this command's chord. Windows has no Command
    /// key, so CmdOrCtrl+Return (compile) and Ctrl+Return (forward search)
    /// are one chord here; the command listed first keeps it, as it does in
    /// the browser version, and the other is left to its menu item.
    /// </summary>
    public static bool ClaimsChord(this MenuCommand command) =>
        command.Accel() is { } accel
        && !command.IsTextEditing()
        && !Enum.GetValues<MenuCommand>()
            .TakeWhile(earlier => earlier != command)
            .Any(earlier => earlier.Accel() is { } other && Accelerators.Parse(other) == Accelerators.Parse(accel));

    /// <summary>
    /// Every chord the menus claim. A page with focus sees a chord before the
    /// window does, so the embedded pages hand these back to the host.
    /// </summary>
    public static IReadOnlyList<(string Id, string Accel)> ClaimedChords { get; } =
        Enum.GetValues<MenuCommand>()
            .Where(c => c.ClaimsChord())
            .Select(c => (c.Id(), c.Accel()!))
            .ToList();

    /// <summary>
    /// The chords the editor page hands back: all but find and comment, which
    /// the editor implements itself (as it does undo and redo).
    /// </summary>
    public static IReadOnlyList<(string Id, string Accel)> HostKeys { get; } =
        ClaimedChords.Where(k => k.Id is not ("edit.find" or "edit.comment")).ToList();
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
            // Ctrl turns the Pause key into Break, which Windows reports as
            // Cancel; the web page names the physical key, "Pause".
            "Pause" => modifiers.HasFlag(VirtualKeyModifiers.Control) ? VirtualKey.Cancel : VirtualKey.Pause,
            _ when name.Length > 1 && name[0] == 'F' && int.TryParse(name[1..], out var f) && f is >= 1 and <= 12 =>
                VirtualKey.F1 + (f - 1),
            _ when name.Length == 1 && char.IsAsciiLetter(name[0]) => VirtualKey.A + (char.ToUpperInvariant(name[0]) - 'A'),
            _ when name.Length == 1 && char.IsAsciiDigit(name[0]) => VirtualKey.Number0 + (name[0] - '0'),
            _ => null,
        };
        return key is { } k ? new Chord(k, modifiers) : null;
    }

    /// <summary>
    /// Every key combination an accelerator stands for: its own, plus the
    /// numeric keypad's +, − and digits, as the web side accepts them
    /// (web/src/commands.js CODES). Enter is one key code for both keys.
    /// </summary>
    public static IReadOnlyList<Chord> Chords(string accel)
    {
        if (Parse(accel) is not { } chord)
        {
            return [];
        }
        VirtualKey? keypad = chord.Key switch
        {
            OemPlus => VirtualKey.Add,
            OemMinus => VirtualKey.Subtract,
            >= VirtualKey.Number0 and <= VirtualKey.Number9 => VirtualKey.NumberPad0 + (chord.Key - VirtualKey.Number0),
            _ => null,
        };
        if (keypad is { } key)
        {
            return [chord, chord with { Key = key }];
        }
        return [chord];
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
            // What Windows calls the chord Stop takes.
            "Pause" when names.Contains("Ctrl") => "Break",
            [var c] => char.ToUpperInvariant(c).ToString(),
            var key => key,
        });
        return string.Join('+', names);
    }
}

/// <summary>
/// Access keys (the letters Alt reveals) for a list of labels: a letter each,
/// unique within the list, preferring the start of a word as Windows does.
/// </summary>
public static class AccessKeys
{
    public static IReadOnlyList<string> Assign(IReadOnlyList<string> labels)
    {
        var taken = new HashSet<char>();
        var keys = new List<string>();
        foreach (var label in labels)
        {
            var starts = label.Where((c, i) => char.IsAsciiLetter(c) && (i == 0 || label[i - 1] == ' '));
            var key = starts.Concat(label.Where(char.IsAsciiLetter))
                .Select(char.ToUpperInvariant)
                .FirstOrDefault(c => !taken.Contains(c));
            if (key != default)
            {
                taken.Add(key);
            }
            keys.Add(key == default ? "" : key.ToString());
        }
        return keys;
    }
}
