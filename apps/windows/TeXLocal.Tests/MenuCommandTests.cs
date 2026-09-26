using System.Text.RegularExpressions;
using Windows.System;

namespace TeXLocal.Tests;

public sealed partial class MenuCommandTests
{
    [GeneratedRegex(@"\{ id: '([^']+)'.*?accel: '((?:[^'\\]|\\.)+)'")]
    private static partial Regex CommandDef();

    /// <summary>
    /// Every (id, accel) pair in the browser version's commandDefs
    /// (web/src/workspace.js), read from the source so the two cannot drift.
    /// </summary>
    private static List<(string Id, string Accel)> CommandDefs()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "web", "src", "workspace.js")))
        {
            dir = dir.Parent;
        }
        Assert.NotNull(dir);
        var source = File.ReadAllText(Path.Combine(dir.FullName, "web", "src", "workspace.js"));
        return CommandDef().Matches(source)
            .Select(m => (m.Groups[1].Value, Regex.Unescape(m.Groups[2].Value)))
            .ToList();
    }

    [Fact]
    public void EveryCommandDefsAcceleratorParses()
    {
        var defs = CommandDefs();
        Assert.Contains(("compile.run", "CmdOrCtrl+Return"), defs);
        Assert.Contains(("view.toggleSidebar", "CmdOrCtrl+\\"), defs);
        foreach (var (id, accel) in defs)
        {
            Assert.True(Accelerators.Parse(accel) is not null, $"{id}: {accel}");
        }
    }

    [Fact]
    public void TheMenuUsesTheBrowserVersionsIdsAndChords()
    {
        var defs = CommandDefs().ToDictionary(d => d.Id, d => d.Accel);
        foreach (var command in Enum.GetValues<MenuCommand>())
        {
            Assert.Equal(command, MenuCommands.FromId(command.Id()));
            if (command.Accel() is { } accel && !command.IsNativeOnly())
            {
                Assert.Equal(defs[command.Id()], accel);
            }
            // A native-only command must not take an id the browser version uses.
            Assert.True(!command.IsNativeOnly() || !defs.ContainsKey(command.Id()), command.Id());
        }
        Assert.Null(MenuCommands.FromId("nope"));
    }

    [Fact]
    public void AcceleratorsBecomeWindowsChords()
    {
        const VirtualKeyModifiers ctrl = VirtualKeyModifiers.Control;
        Assert.Equal(new Chord(VirtualKey.Enter, ctrl), Accelerators.Parse("CmdOrCtrl+Return"));
        Assert.Equal(new Chord(VirtualKey.Enter, ctrl | VirtualKeyModifiers.Shift), Accelerators.Parse("Ctrl+Shift+Return"));
        Assert.Equal(new Chord((VirtualKey)0xBB, ctrl), Accelerators.Parse("CmdOrCtrl+Plus"));
        Assert.Equal(new Chord((VirtualKey)0xDC, ctrl | VirtualKeyModifiers.Shift), Accelerators.Parse("CmdOrCtrl+Shift+\\"));
        Assert.Equal(new Chord(VirtualKey.F, ctrl | VirtualKeyModifiers.Menu), Accelerators.Parse("CmdOrCtrl+Alt+F"));
        Assert.Equal(new Chord(VirtualKey.Number0, ctrl), Accelerators.Parse("CmdOrCtrl+0"));
        Assert.Equal(new Chord(VirtualKey.N, ctrl | VirtualKeyModifiers.Shift | VirtualKeyModifiers.Menu), Accelerators.Parse("CmdOrCtrl+Shift+Alt+N"));
        Assert.Equal(new Chord(VirtualKey.F11, VirtualKeyModifiers.None), Accelerators.Parse("F11"));
        // With Ctrl held, Windows reports the Pause key as Cancel (Break).
        Assert.Equal(new Chord(VirtualKey.Cancel, ctrl), Accelerators.Parse("CmdOrCtrl+Pause"));
        Assert.Equal(new Chord(VirtualKey.Pause, VirtualKeyModifiers.None), Accelerators.Parse("Pause"));
        Assert.Null(Accelerators.Parse("F13"));
        // Windows has no Command key to give a Cmd-only chord to.
        Assert.Null(Accelerators.Parse("Cmd+K"));
        Assert.Null(Accelerators.Parse("CmdOrCtrl+Home"));
    }

    [Fact]
    public void MenusShowWindowsShortcutText()
    {
        Assert.Equal("Ctrl+Alt+Shift+N", Accelerators.Label("CmdOrCtrl+Shift+Alt+N"));
        Assert.Equal("Ctrl+Enter", Accelerators.Label("CmdOrCtrl+Return"));
        Assert.Equal("Ctrl+Shift+Enter", Accelerators.Label("Ctrl+Shift+Return"));
        Assert.Equal("Ctrl+Plus", Accelerators.Label("CmdOrCtrl+Plus"));
        Assert.Equal("Ctrl+\\", Accelerators.Label("CmdOrCtrl+\\"));
        Assert.Equal("Ctrl+B", Accelerators.Label("CmdOrCtrl+B"));
        Assert.Equal("Ctrl+Break", Accelerators.Label("CmdOrCtrl+Pause"));
        Assert.Equal("F11", Accelerators.Label("F11"));
        // The details pane takes File Explorer's chord.
        Assert.Equal("Alt+Shift+P", Accelerators.Label(MenuCommand.ViewToggleInspector.Accel()!));
        Assert.Equal(new Chord(VirtualKey.P, VirtualKeyModifiers.Menu | VirtualKeyModifiers.Shift),
            Accelerators.Parse(MenuCommand.ViewToggleInspector.Accel()!));
    }

    [Fact]
    public void EachChordRunsOneCommand()
    {
        // CmdOrCtrl+Return and Ctrl+Return are the same keys on Windows;
        // compile, listed first, keeps them.
        Assert.True(MenuCommand.CompileRun.ClaimsChord());
        Assert.False(MenuCommand.SyncForward.ClaimsChord());
        var chords = Enum.GetValues<MenuCommand>()
            .Where(c => c.ClaimsChord())
            .SelectMany(c => Accelerators.Chords(c.Accel()!))
            .ToList();
        Assert.Equal(chords.Count, chords.Distinct().Count());
    }

    [Fact]
    public void TheKeypadWorksAsTheWebAcceptsIt()
    {
        const VirtualKeyModifiers ctrl = VirtualKeyModifiers.Control;
        Assert.Equal(
            new[] { new Chord((VirtualKey)0xBB, ctrl), new Chord(VirtualKey.Add, ctrl) },
            Accelerators.Chords("CmdOrCtrl+Plus"));
        Assert.Equal(
            new[] { new Chord((VirtualKey)0xBD, ctrl | VirtualKeyModifiers.Menu), new Chord(VirtualKey.Subtract, ctrl | VirtualKeyModifiers.Menu) },
            Accelerators.Chords("CmdOrCtrl+Alt+Minus"));
        Assert.Equal(
            new[] { new Chord(VirtualKey.Number0, ctrl), new Chord(VirtualKey.NumberPad0, ctrl) },
            Accelerators.Chords("CmdOrCtrl+0"));
        Assert.Equal(new[] { new Chord(VirtualKey.S, ctrl) }, Accelerators.Chords("CmdOrCtrl+S"));
        Assert.Empty(Accelerators.Chords("Cmd+K"));
    }

    [Fact]
    public void AccessKeysAreUniqueAndPreferWordStarts()
    {
        Assert.Equal(new[] { "F", "E", "V", "C" }, AccessKeys.Assign(["File", "Edit", "View", "Compile"]));
        // "Save" takes S; "Save PDF as…" then takes the P of PDF.
        Assert.Equal(new[] { "S", "P", "E" }, AccessKeys.Assign(["Save", "Save PDF as…", "Export project as ZIP…"]));
        Assert.Equal(new[] { "A", "B", "" }, AccessKeys.Assign(["a", "ab", "…"]));
        var keys = AccessKeys.Assign(Enum.GetValues<MenuCommand>().Select(c => c.Title()).ToList())
            .Where(k => k.Length > 0)
            .ToList();
        Assert.Equal(keys.Count, keys.Distinct().Count());
    }

    [Fact]
    public void TheEditorKeepsTheChordsItImplements()
    {
        var ids = MenuCommands.HostKeys.Select(k => k.Id).ToHashSet();
        Assert.Contains("compile.run", ids);
        Assert.Contains("edit.gotoLine", ids);
        Assert.Contains("sync.inverse", ids);
        Assert.DoesNotContain("edit.find", ids);
        Assert.DoesNotContain("edit.comment", ids);
        Assert.DoesNotContain("edit.undo", ids);
        Assert.DoesNotContain("project.close", ids);
        // Stop and full screen reach the host from inside the editor too.
        Assert.Contains("compile.stop", ids);
        Assert.Contains("view.fullScreen", ids);
        Assert.False(MenuCommand.EditRedo.ClaimsChord());
        Assert.True(MenuCommand.EditFind.ClaimsChord());

        // The PDF page implements none of them, so it hands back every chord
        // the menus claim — but never the text-editing ones.
        var claimed = MenuCommands.ClaimedChords.Select(k => k.Id).ToHashSet();
        Assert.Contains("edit.find", claimed);
        Assert.Contains("app.settings", claimed);
        Assert.DoesNotContain("edit.undo", claimed);
        Assert.Subset(claimed, ids);
    }

    [Fact]
    public void TheClipboardBelongsToTheFocusedField()
    {
        // Shown in the Edit menu, never taken from a text box or the editor.
        foreach (var command in new[] { MenuCommand.EditCut, MenuCommand.EditCopy, MenuCommand.EditPaste, MenuCommand.EditSelectAll })
        {
            Assert.True(command.IsTextEditing(), command.Id());
            Assert.False(command.ClaimsChord(), command.Id());
            Assert.NotNull(command.Accel());
        }
        Assert.Equal("CmdOrCtrl+C", MenuCommand.EditCopy.Accel());
    }

    [Fact]
    public void WindowsOnlyCommandsAreNativeOnly()
    {
        // Web commandDefs has none of these; the id check above keeps them
        // from ever taking one it adds.
        foreach (var command in new[]
        {
            MenuCommand.FileUploadFolder, MenuCommand.EditCut, MenuCommand.EditCopy, MenuCommand.EditPaste,
            MenuCommand.EditSelectAll, MenuCommand.ViewFullScreen, MenuCommand.AppExit, MenuCommand.CompileStop,
        })
        {
            Assert.True(command.IsNativeOnly(), command.Id());
        }
        Assert.True(MenuCommand.ViewFullScreen.ClaimsChord());
        Assert.True(MenuCommand.CompileStop.ClaimsChord());
        Assert.False(MenuCommand.CompileRun.IsNativeOnly());
    }
}
