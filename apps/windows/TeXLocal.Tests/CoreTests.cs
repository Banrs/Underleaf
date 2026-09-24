namespace TeXLocal.Tests;

public sealed class CoreTests
{
    [Fact]
    public async Task CommandsRoundTripThroughTheRustCore()
    {
        // The core picks its library folder from TEXLOCAL_DATA when it opens,
        // exactly as the app's does; a scratch folder keeps the test out of the
        // user's own library.
        var data = Directory.CreateTempSubdirectory("texlocal-test-").FullName;
        Environment.SetEnvironmentVariable("TEXLOCAL_DATA", data);
        try
        {
            var core = new Core();
            var info = await core.CallAsync<ProjectInfo>("create_project", new { name = "Test", template = "blank" });
            Assert.Equal("main.tex", info.MainFile);
            Assert.True(Directory.Exists(Path.Combine(data, info.Id)));

            await core.PerformAsync("write_file", new { id = info.Id, path = "a.tex", text = "hé" });
            var file = await core.CallAsync<FileText>("read_file", new { id = info.Id, path = "a.tex" });
            Assert.Equal("hé", file.Text);

            var tree = await core.CallAsync<List<TreeNode>>("file_tree", new { id = info.Id });
            Assert.Contains(tree, node => node.Path == "a.tex" && !node.IsDirectory);

            var refused = await Assert.ThrowsAsync<CoreException>(
                () => core.CallAsync<FileText>("read_file", new { id = info.Id, path = "../../x" }));
            Assert.Equal(400, refused.Status);

            // The native-only commands: absolute paths in and out.
            var pdf = await core.CallAsync<string>("pdf_path", new { id = info.Id });
            Assert.Equal(Path.Combine(data, info.Id, "build", "main.pdf"), pdf);

            var drop = Directory.CreateTempSubdirectory("texlocal-drop-").FullName;
            File.WriteAllText(Path.Combine(drop, "notes.tex"), "n");
            var imported = await core.CallAsync<ImportResult>(
                "import_files", new { id = info.Id, dir = "in", paths = new[] { Path.Combine(drop, "notes.tex") } });
            Assert.Equal("in/notes.tex", Assert.Single(imported.Saved));
            Directory.Delete(drop, recursive: true);

            var zip = Path.Combine(data, "out.zip");
            await core.PerformAsync("export_zip", new { id = info.Id, dest = zip });
            Assert.True(File.Exists(zip));

            core.KillAll();
        }
        finally
        {
            // Not delete_project: that moves the folder to the Recycle Bin. The
            // core's own tests cover it; here the scratch folder just goes.
            Directory.Delete(data, recursive: true);
        }
    }
}
