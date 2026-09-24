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

            File.WriteAllText(path, "{not json");
            Assert.Equal("system", Preferences.Load(path).Theme);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
