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
            if (command.Accel() is { } accel)
            {
                Assert.Equal(defs[command.Id()], accel);
            }
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
    }

    [Fact]
    public void TheEditorKeepsTheChordsItImplements()
    {
        var ids = MenuCommands.HostKeys.Select(k => k.Id).ToHashSet();
        Assert.Contains("compile.run", ids);
        Assert.Contains("edit.gotoLine", ids);
        Assert.Contains("sync.forward", ids);
        Assert.DoesNotContain("edit.find", ids);
        Assert.DoesNotContain("edit.comment", ids);
        Assert.DoesNotContain("edit.undo", ids);
        Assert.DoesNotContain("project.close", ids);
        Assert.False(MenuCommand.EditRedo.ClaimsChord());
        Assert.True(MenuCommand.EditFind.ClaimsChord());

        // The PDF page implements none of them, so it hands back every chord
        // the menus claim — but never the text-editing ones.
        var claimed = MenuCommands.ClaimedChords.Select(k => k.Id).ToHashSet();
        Assert.Contains("edit.find", claimed);
        Assert.Contains("app.settings", claimed);
        Assert.DoesNotContain("edit.undo", claimed);
        Assert.Superset(claimed, ids);
    }
}
