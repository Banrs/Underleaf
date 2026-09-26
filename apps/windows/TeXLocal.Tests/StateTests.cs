namespace TeXLocal.Tests;

public sealed class ProjectPathsTests
{
    [Fact]
    public void ARenamedFolderCarriesItsFilesAlong()
    {
        Assert.Equal("text/intro.tex", ProjectPaths.Remap("chapters/intro.tex", "chapters", "text"));
        Assert.Equal("text", ProjectPaths.Remap("chapters", "chapters", "text"));
        // A sibling that merely shares the prefix is not inside the folder.
        Assert.Equal("chapters2/a.tex", ProjectPaths.Remap("chapters2/a.tex", "chapters", "text"));
        Assert.Null(ProjectPaths.Remap(null, "chapters", "text"));
    }

    [Fact]
    public void ContainmentIsByWholeSegments()
    {
        Assert.True(ProjectPaths.Contains("figs", "figs/a.png"));
        Assert.True(ProjectPaths.Contains("main.tex", "main.tex"));
        Assert.False(ProjectPaths.Contains("figs", "figs.tex"));
        Assert.False(ProjectPaths.Contains("figs", null));
    }
}

public sealed class PreferencesTests
{
    [Fact]
    public void SettingsSurviveARestartAndFallBackToDefaults()
    {
        var dir = Directory.CreateTempSubdirectory("texlocal-prefs-").FullName;
        try
        {
            var path = Path.Combine(dir, "sub", "settings.json");
            Assert.True(Preferences.Load(path).AutoCompile);

            new Preferences { Theme = "dark", EditorFontSize = 18, AutoCompile = false }.Save(path);
            var loaded = Preferences.Load(path);
            Assert.Equal("dark", loaded.Theme);
            Assert.Equal(18, loaded.EditorFontSize);
            Assert.False(loaded.AutoCompile);
            Assert.Equal("onedark", loaded.EditorPalette);
            Assert.Equal(100, loaded.UiScale);
            Assert.Equal("white", loaded.PdfPaper);
            Assert.True(loaded.ShowWordCount);
            // No layout until the reader drags one, then the one they dragged.
            Assert.Null(loaded.SidebarWidth);
            Assert.Null(loaded.PdfSplit);

            loaded.SidebarWidth = 300;
            loaded.PdfSplit = 0.4;
            loaded.PanelHeight = 180;
            loaded.InspectorWidth = 240;
            loaded.Save(path);
            var layout = Preferences.Load(path);
            Assert.Equal(300, layout.SidebarWidth);
            Assert.Equal(0.4, layout.PdfSplit);
            Assert.Equal(180, layout.PanelHeight);
            Assert.Equal(240, layout.InspectorWidth);

            File.WriteAllText(path, "{not json");
            Assert.Equal("system", Preferences.Load(path).Theme);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}

public sealed class InterfaceSizeTests
{
    [Fact]
    public void TheEditorSizeStepsAlongTheWebsScalesAndStopsAtTheEnds()
    {
        Assert.Equal(110, Preferences.StepUiScale(100, 1));
        Assert.Equal(90, Preferences.StepUiScale(100, -1));
        Assert.Equal(130, Preferences.StepUiScale(130, 1));
        Assert.Equal(80, Preferences.StepUiScale(80, -1));
        // A hand-edited settings file with an odd size starts over at 100.
        Assert.Equal(100, Preferences.StepUiScale(105, 1));
    }
}
