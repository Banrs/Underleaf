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
    /// <summary>
    /// Each command's id, its menu text (sentence case; an ellipsis when it
    /// asks for more before acting) and its accelerator. Alt+Shift+P is File
    /// Explorer's details-pane chord; Ctrl+Break is Windows' Stop.
    /// </summary>
    private static readonly Dictionary<MenuCommand, (string Id, string Title, string? Accel)> Defs = new()
    {
        [MenuCommand.ProjectNew] = ("project.new", "New project…", "CmdOrCtrl+Shift+N"),
        [MenuCommand.ProjectClose] = ("project.close", "Close project", null),
        [MenuCommand.ProjectExport] = ("project.export", "Export project as ZIP…", null),
        [MenuCommand.ProjectSearch] = ("project.search", "Find in project", "CmdOrCtrl+Shift+F"),
        [MenuCommand.FileNew] = ("file.new", "New file…", "CmdOrCtrl+N"),
        [MenuCommand.FileNewFolder] = ("file.newFolder", "New folder…", "CmdOrCtrl+Shift+Alt+N"),
        [MenuCommand.FileUpload] = ("file.upload", "Add files…", null),
        [MenuCommand.FileSave] = ("file.save", "Save", "CmdOrCtrl+S"),
        [MenuCommand.PdfSave] = ("pdf.save", "Save PDF as…", "CmdOrCtrl+Shift+S"),
        [MenuCommand.PdfShare] = ("pdf.share", "Share PDF…", null),
        [MenuCommand.EditUndo] = ("edit.undo", "Undo", "CmdOrCtrl+Z"),
        [MenuCommand.EditRedo] = ("edit.redo", "Redo", "CmdOrCtrl+Shift+Z"),
        [MenuCommand.EditFind] = ("edit.find", "Find and replace", "CmdOrCtrl+F"),
        [MenuCommand.EditFindNext] = ("edit.findNext", "Find next", "CmdOrCtrl+G"),
        [MenuCommand.EditFindPrevious] = ("edit.findPrevious", "Find previous", "CmdOrCtrl+Shift+G"),
        [MenuCommand.EditBold] = ("edit.bold", "Bold", "CmdOrCtrl+B"),
        [MenuCommand.EditItalic] = ("edit.italic", "Italic", "CmdOrCtrl+I"),
        [MenuCommand.EditMath] = ("edit.math", "Inline math", "CmdOrCtrl+Shift+M"),
        [MenuCommand.EditComment] = ("edit.comment", "Toggle comment", "CmdOrCtrl+/"),
        [MenuCommand.EditGotoLine] = ("edit.gotoLine", "Go to line…", "CmdOrCtrl+L"),
        [MenuCommand.PdfFind] = ("pdf.find", "Find in PDF", "CmdOrCtrl+Alt+F"),
        [MenuCommand.ViewToggleSidebar] = ("view.toggleSidebar", "Sidebar", "CmdOrCtrl+\\"),
        [MenuCommand.ViewTogglePdf] = ("view.togglePdf", "PDF", "CmdOrCtrl+Shift+\\"),
        [MenuCommand.ViewToggleLogs] = ("view.toggleLogs", "Panel", "CmdOrCtrl+Shift+L"),
        [MenuCommand.ViewToggleInspector] = ("view.toggleInspector", "Details pane", "Alt+Shift+P"),
        [MenuCommand.ViewZoomIn] = ("view.zoomIn", "Zoom in", "CmdOrCtrl+Plus"),
        [MenuCommand.ViewZoomOut] = ("view.zoomOut", "Zoom out", "CmdOrCtrl+Minus"),
        [MenuCommand.ViewFitWidth] = ("view.fitWidth", "Fit width", "CmdOrCtrl+0"),
        [MenuCommand.ViewFitHeight] = ("view.fitHeight", "Fit height", "CmdOrCtrl+Alt+0"),
        [MenuCommand.ViewUiScaleUp] = ("view.uiScaleUp", "Increase editor size", "CmdOrCtrl+Alt+Plus"),
        [MenuCommand.ViewUiScaleDown] = ("view.uiScaleDown", "Decrease editor size", "CmdOrCtrl+Alt+Minus"),
        [MenuCommand.CompileRun] = ("compile.run", "Compile", "CmdOrCtrl+Return"),
        [MenuCommand.CompileStop] = ("compile.stop", "Stop", "CmdOrCtrl+Pause"),
        [MenuCommand.CompileToggleAuto] = ("compile.toggleAuto", "Compile automatically", null),
        [MenuCommand.SyncForward] = ("sync.forward", "Go to PDF position", "Ctrl+Return"),
        [MenuCommand.SyncInverse] = ("sync.inverse", "Go to source position", "Ctrl+Shift+Return"),
        [MenuCommand.AppSettings] = ("app.settings", "Settings", "CmdOrCtrl+,"),
        [MenuCommand.FileUploadFolder] = ("file.uploadFolder", "Add folder…", null),
        [MenuCommand.EditCut] = ("edit.cut", "Cut", "CmdOrCtrl+X"),
        [MenuCommand.EditCopy] = ("edit.copy", "Copy", "CmdOrCtrl+C"),
        [MenuCommand.EditPaste] = ("edit.paste", "Paste", "CmdOrCtrl+V"),
        [MenuCommand.EditSelectAll] = ("edit.selectAll", "Select all", "CmdOrCtrl+A"),
        [MenuCommand.ViewFullScreen] = ("view.fullScreen", "Full screen", "F11"),
        [MenuCommand.AppExit] = ("app.exit", "Exit", null),
    };

    public static string Id(this MenuCommand command) => Defs[command].Id;

    public static string Title(this MenuCommand command) => Defs[command].Title;

    public static string? Accel(this MenuCommand command) => Defs[command].Accel;

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

    public static MenuCommand? FromId(string id) =>
        Defs.Where(d => d.Value.Id == id).Select(d => (MenuCommand?)d.Key).FirstOrDefault();

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
        return keypad is { } key ? [chord, chord with { Key = key }] : [chord];
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
