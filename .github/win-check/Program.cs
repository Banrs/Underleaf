using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;
using Microsoft.Win32;

namespace WinCheck;

/// Captures TeXLocal's screens, each launch from the same clean state: a fresh copy of the seed library with fixed
/// dates, no saved preferences, the system theme set, animations off and a caret that doesn't blink. Each screen is a
/// PNG of the window alone (PrintWindow, its popups drawn over it) and a text file of its UI Automation tree; logs/
/// holds what differs between runs by nature (timings, stderr, whole-screen grabs).
static class Program
{
    const int Width = 1280, Height = 800;
    static readonly DateTime Dated = new(2025, 6, 1, 9, 0, 0, DateTimeKind.Utc);
    static readonly UIA3Automation Uia = new();
    static string exe = "", seed = "", outDir = "", data = @"C:\TeXLocalQA", tex = "";
    static StreamWriter log = null!;
    static int failures;

    static int Main(string[] args)
    {
        for (var i = 0; i + 1 < args.Length; i += 2)
        {
            var value = args[i + 1];
            switch (args[i])
            {
                case "--exe": exe = Path.GetFullPath(value); break;
                case "--seed": seed = Path.GetFullPath(value); break;
                case "--out": outDir = Path.GetFullPath(value); break;
                case "--data": data = value; break;
                case "--tex": tex = value; break;
            }
        }
        Directory.CreateDirectory(Path.Combine(outDir, "logs", "screen"));
        log = new StreamWriter(Path.Combine(outDir, "logs", "capture.txt")) { AutoFlush = true };
        Prepare();

        foreach (var theme in new[] { "light", "dark" })
        {
            SetTheme(theme == "light");
            using (var app = Launch(theme, null))
            {
                if (app is null) continue;
                Step($"home-{theme}", () =>
                {
                    app.Wait("More options for Test Errors and Warnings", ControlType.Button);
                    app.Shot($"home-{theme}");
                });
                // Ctrl+F before any project has opened; what's typed filters the list only if the search box has the keys.
                if (theme == "light") Step("home-find-first-light", () =>
                {
                    app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_F);
                    app.Type("Article");
                    app.Shot("home-find-first-light");
                    app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
                    app.Keys(VirtualKeyShort.BACK);
                    app.Wait("More options for Test Errors and Warnings", ControlType.Button);
                });
                Step($"home-menu-{theme}", () =>
                {
                    app.Press(app.Wait("More options for Test Errors and Warnings", ControlType.Button));
                    app.Wait("Open", ControlType.MenuItem);
                    app.Shot($"home-menu-{theme}");
                });
                Step($"workspace-{theme}", () =>
                {
                    app.Press(app.Wait("Open", ControlType.MenuItem));
                    app.WaitTitle("main.tex - Test Errors and Warnings");
                    app.Wait("Compile", ControlType.Button);
                    app.Shot($"workspace-{theme}");
                });
                Step($"view-menu-{theme}", () =>
                {
                    app.Expand(app.Wait("View", ControlType.MenuItem));
                    app.Wait("Issues", ControlType.MenuItem);
                    app.Shot($"view-menu-{theme}");
                });
                Step($"issues-{theme}", () =>
                {
                    app.Press(app.Wait("Issues", ControlType.MenuItem));
                    app.Wait("Close issues", ControlType.Button);
                    app.Shot($"issues-{theme}");
                });
                Step($"settings-{theme}", () =>
                {
                    app.Press(app.Wait("Settings", ControlType.Button));
                    app.Wait("Appearance", ControlType.Text);
                    app.Shot($"settings-{theme}");
                });
                Step($"settings-end-{theme}", () =>
                {
                    app.ScrollToEnd();
                    app.Shot($"settings-end-{theme}");
                });
                if (theme == "light") Flows(app);
            }
        }

        if (tex.Length == 0) Log("no TeX given: the compiled screens are skipped");
        else foreach (var theme in new[] { "light", "dark" })
        {
            SetTheme(theme == "light");
            using var app = Launch($"tex-{theme}", tex);
            if (app is null) continue;
            // Opening the project builds it once, as an automatic build: issues in the editor, no panel.
            Step($"tex-workspace-{theme}", () =>
            {
                app.Press(app.Wait("More options for Test Errors and Warnings", ControlType.Button));
                app.Press(app.Wait("Open", ControlType.MenuItem));
                app.WaitTitle("main.tex - Test Errors and Warnings");
                app.Wait(e => e.Properties.Name.ValueOrDefault is "Build failed" or "Build stopped" || e.Properties.Name.ValueOrDefault?.StartsWith("Built in") == true,
                    "a finished build", 300_000, cf => cf.ByAutomationId("BuildState"));
                app.WaitForPdf();
                app.Shot($"tex-workspace-{theme}");
            });
            // A build asked for that fails opens the issues and the Build failed bar.
            Step($"tex-compiled-{theme}", () =>
            {
                app.Press(app.Wait("Compile", ControlType.Button, e => e.Properties.IsEnabled.ValueOrDefault));
                app.Wait("Show issues", ControlType.Button, null, [], 300_000);
                app.WaitForPdf();
                app.Shot($"tex-compiled-{theme}");
            });
            if (theme == "light") Step("tex-log-light", () =>
            {
                // The tab and the log it shows share the name.
                ControlType[] boxes = [ControlType.Edit, ControlType.Document, ControlType.Text];
                app.Press(app.Wait(e => e.Properties.Name.ValueOrDefault == "Build log" && !boxes.Contains(e.Properties.ControlType.ValueOrDefault),
                    "the Build log tab", 30_000, cf => cf.ByName("Build log")));
                app.Wait(e => boxes.Contains(e.Properties.ControlType.ValueOrDefault), "the build log", 30_000, cf => cf.ByName("Build log"));
                app.Shot("tex-log-light");
            });
            if (theme == "light") PdfFlows(app);
        }

        Log($"done, {failures} failed");
        return failures;
    }

    /// After Settings: back to the project, then Home, its keys, the project again, and typing and replacing in its
    /// editor. The menu bar is the project's only while it is shown.
    static void Flows(App app)
    {
        Step("settings-back-light", () =>
        {
            app.Press(app.Wait("Back", ControlType.Button));
            app.Wait("Compile", ControlType.Button);
            app.Wait("View", ControlType.MenuItem);
            app.Shot("settings-back-light");
        });
        Step("home-again-light", () =>
        {
            app.Press(app.Wait("Back", ControlType.Button));
            app.Wait("More options for Test Errors and Warnings", ControlType.Button);
            app.Shot("home-again-light");
        });
        // Ctrl+F again, after a project has come and gone.
        Step("home-find-light", () =>
        {
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_F);
            app.Type("Article");
            app.Shot("home-find-light");
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
            app.Keys(VirtualKeyShort.BACK);
        });
        Step("home-new-light", () =>
        {
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_N);
            app.Wait("New article project", ControlType.Text);
            app.Shot("home-new-light");
            app.Keys(VirtualKeyShort.ESCAPE);
        });
        Step("reopen-light", () =>
        {
            app.Press(app.Wait("More options for Test Errors and Warnings", ControlType.Button));
            app.Press(app.Wait("Open", ControlType.MenuItem));
            app.WaitTitle("main.tex - Test Errors and Warnings");
            app.Wait("View", ControlType.MenuItem);
            app.Shot("reopen-light");
        });
        // Last, so no Home above shows the time of its save. A completion asked for and accepted into its snippet; a
        // newline and a backspace; then Replace in the find bar.
        Step("completions-light", () =>
        {
            app.Wait("Source", ControlType.Edit).Focus();
            // After \end{document}: not in a comment, where nothing completes.
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.END);
            app.Type("\\sec");
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.SPACE);
            app.Wait("Completions", ControlType.List);
            app.Shot("completions-light");
        });
        Step("typed-light", () =>
        {
            app.Keys(VirtualKeyShort.ENTER);
            app.Type("Intro");
            app.Keys(VirtualKeyShort.ESCAPE);
            app.Keys(VirtualKeyShort.END);
            app.Keys(VirtualKeyShort.ENTER);
            app.Type("xy");
            app.Keys(VirtualKeyShort.BACK);
            app.Shot("typed-light");
        });
        Step("replaced-light", () =>
        {
            // In a project opened a second time, Ctrl+H has been seen to do nothing: the menu then, and the log says so.
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_H);
            try { app.Wait("Find", ControlType.Edit, null, null, 3_000); }
            catch (TimeoutException)
            {
                Log("Ctrl+H opened no find bar: Edit > Replace… instead");
                app.Expand(app.Wait("Edit", ControlType.MenuItem));
                app.Press(app.Wait("Replace…", ControlType.MenuItem));
            }
            app.Wait("Find", ControlType.Edit).Focus();
            app.Type("Intro");
            app.Wait("Replace", ControlType.Edit).Focus();
            app.Type("Outro");
            app.Press(app.Wait("Replace", ControlType.Button, e => e.Properties.IsEnabled.ValueOrDefault));
            app.Shot("replaced-light");
        });
    }

    /// The PDF hidden and shown by its key, its button and its View menu item, each telling the others; then Go to PDF
    /// position with the PDF shown and with it hidden.
    static void PdfFlows(App app)
    {
        Step("pdf-key-off-light", () =>
        {
            app.Wait("Source", ControlType.Edit).Focus();
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.KEY_P);
            app.WaitPdfButton(false);
            app.Shot("pdf-key-off-light");
        });
        Step("pdf-button-on-light", () =>
        {
            app.Click(app.WaitPdfButton(false));
            app.WaitPdfButton(true);
            app.Shot("pdf-button-on-light");
        });
        Step("pdf-menu-off-light", () =>
        {
            app.Click(app.WaitPdfButton(true));
            app.WaitPdfButton(false);
            app.Expand(app.Wait("View", ControlType.MenuItem));
            app.Wait("PDF", ControlType.MenuItem);
            app.Shot("pdf-menu-off-light");
        });
        Step("pdf-menu-on-light", () =>
        {
            app.Click(app.Wait("PDF", ControlType.MenuItem));
            app.WaitPdfButton(true);
            app.Shot("pdf-menu-on-light");
        });
        Step("forward-shown-light", () =>
        {
            app.Wait("Source", ControlType.Edit).Focus();
            // The last section, a few lines up from the end.
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.END);
            app.Keys(VirtualKeyShort.UP);
            app.Keys(VirtualKeyShort.UP);
            app.Keys(VirtualKeyShort.UP);
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.KEY_J);
            app.Shot("forward-shown-light");
        });
        Step("forward-hidden-light", () =>
        {
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.KEY_P);
            app.WaitPdfButton(false);
            app.Keys(VirtualKeyShort.CONTROL, VirtualKeyShort.ALT, VirtualKeyShort.KEY_J);
            app.WaitPdfButton(true);
            app.Shot("forward-hidden-light");
        });
    }

    static App? Launch(string name, string? texBin)
    {
        try { return App.Launch(name, texBin); }
        catch (Exception e)
        {
            failures++;
            Log($"FAILED launch {name}: {e}");
            return null;
        }
    }

    static void Step(string name, Action action)
    {
        var clock = Stopwatch.StartNew();
        try
        {
            action();
            Log($"ok {name} ({clock.ElapsedMilliseconds} ms)");
        }
        catch (Exception e)
        {
            failures++;
            Log($"FAILED {name}: {e}");
            App.Current?.Shot($"failed-{name}", settle: false);
        }
    }

    internal static void Log(string line)
    {
        var stamped = $"{DateTime.UtcNow:HH:mm:ss.fff} {line}";
        Console.WriteLine(stamped);
        log.WriteLine(stamped);
    }

    internal static string Out(string name) => Path.Combine(outDir, name);

    /// The largest display mode up to 1920 × 1080, animations off, a solid caret, the pointer in a corner.
    static void Prepare()
    {
        var mode = new Native.DevMode { dmSize = (short)Marshal.SizeOf<Native.DevMode>() };
        Native.EnumDisplaySettings(null, -1, ref mode);
        Log($"runner image {Environment.GetEnvironmentVariable("ImageOS")} {Environment.GetEnvironmentVariable("ImageVersion")}");
        Log($"display {mode.dmPelsWidth}x{mode.dmPelsHeight} at {Native.GetDpiForSystem()} dpi");
        var modes = new List<(int W, int H)>();
        var probe = new Native.DevMode { dmSize = mode.dmSize };
        for (var i = 0; Native.EnumDisplaySettings(null, i, ref probe); i++) modes.Add((probe.dmPelsWidth, probe.dmPelsHeight));
        Log($"modes {string.Join(" ", modes.Distinct().Select(m => $"{m.W}x{m.H}"))}");
        var best = modes.Where(m => m.W <= 1920 && m.H <= 1080).OrderByDescending(m => m.W * m.H).FirstOrDefault();
        if (best.W * best.H > mode.dmPelsWidth * mode.dmPelsHeight)
        {
            mode.dmPelsWidth = best.W;
            mode.dmPelsHeight = best.H;
            mode.dmFields = 0x80000 | 0x100000; // DM_PELSWIDTH | DM_PELSHEIGHT
            Log($"set {best.W}x{best.H}: {Native.ChangeDisplaySettings(ref mode, 0)}");
        }
        Log($"screen {Native.GetSystemMetrics(0)}x{Native.GetSystemMetrics(1)}");
        Log($"client-area animations off: {Native.SystemParametersInfo(0x1043, 0, 0, 3)}"); // SPI_SETCLIENTAREAANIMATION
        Log($"caret blink off: {Native.SetCaretBlinkTime(uint.MaxValue)}, now {Native.GetCaretBlinkTime()}");
        Native.SetCursorPos(Native.GetSystemMetrics(0) - 1, Native.GetSystemMetrics(1) - 1);
    }

    static void SetTheme(bool light)
    {
        const string key = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
        Registry.SetValue(key, "AppsUseLightTheme", light ? 1 : 0, RegistryValueKind.DWord);
        Registry.SetValue(key, "SystemUsesLightTheme", light ? 1 : 0, RegistryValueKind.DWord);
        Native.SendMessageTimeout(0xffff, 0x1A, 0, "ImmersiveColorSet", 2, 5000, out _);
        Log($"theme {(light ? "light" : "dark")}");
    }

    /// The seed library with every date the same, so Home lists it by name with one date; no preferences kept.
    internal static void Fresh()
    {
        foreach (var p in Process.GetProcessesByName("TeXLocal"))
        {
            try { p.Kill(true); p.WaitForExit(10_000); }
            catch (Exception e) { Log($"can't end {p.Id}: {e.Message}"); }
        }
        for (var attempt = 0; Directory.Exists(data); attempt++)
        {
            try { Directory.Delete(data, true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException && attempt < 20) { Thread.Sleep(500); }
        }
        Copy(seed, data);
        foreach (var file in Directory.EnumerateFiles(data, "*", SearchOption.AllDirectories)) File.SetLastWriteTimeUtc(file, Dated);
        foreach (var dir in Directory.EnumerateDirectories(data, "*", SearchOption.AllDirectories)) Directory.SetLastWriteTimeUtc(dir, Dated);
        Directory.SetLastWriteTimeUtc(data, Dated);
        // Prefs: ApplicationData.GetForUnpackaged("TeXLocal", "TeXLocal Dev").
        using (var local = Registry.CurrentUser.OpenSubKey(@"Software\Classes\Local Settings\Software\TeXLocal"))
            if (local is not null) Log($"preferences cleared: {string.Join(", ", local.GetSubKeyNames())}");
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\Local Settings\Software\TeXLocal", false);
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TeXLocal");
        if (Directory.Exists(folder))
        {
            Log($"cleared {folder}: {string.Join(", ", Directory.EnumerateFileSystemEntries(folder, "*", SearchOption.AllDirectories))}");
            Directory.Delete(folder, true);
        }

        static void Copy(string from, string to)
        {
            Directory.CreateDirectory(to);
            foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
            foreach (var dir in Directory.GetDirectories(from)) Copy(dir, Path.Combine(to, Path.GetFileName(dir)));
        }
    }

    sealed class App : IDisposable
    {
        public static App? Current;
        readonly Process process;
        readonly StreamWriter stderr;
        readonly nint window;

        App(Process process, StreamWriter stderr, nint window) => (this.process, this.stderr, this.window) = (process, stderr, window);

        public static App Launch(string name, string? texBin)
        {
            Fresh();
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(exe) };
            start.Environment["TEXLOCAL_DATA"] = data;
            if (texBin is not null)
            {
                start.Environment["PATH"] = texBin + ";" + start.Environment["PATH"];
                // The log's banner and the PDF's dates, fixed.
                start.Environment["SOURCE_DATE_EPOCH"] = $"{new DateTimeOffset(Dated).ToUnixTimeSeconds()}";
                start.Environment["FORCE_SOURCE_DATE"] = "1";
            }
            var stderr = new StreamWriter(Out(Path.Combine("logs", $"stderr-{name}.txt"))) { AutoFlush = true };
            var process = Process.Start(start)!;
            process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (stderr) stderr.WriteLine(e.Data); };
            process.BeginErrorReadLine();
            nint window = 0;
            var clock = Stopwatch.StartNew();
            while (window == 0 && clock.ElapsedMilliseconds < 60_000 && !process.HasExited)
            {
                Thread.Sleep(250);
                window = Windows(process.Id).FirstOrDefault(w => Native.ClassName(w) == "WinUIDesktopWin32WindowClass");
            }
            if (window == 0) throw new InvalidOperationException($"no window for {name} (exited: {process.HasExited})");
            Log($"launched {name}: pid {process.Id}, window {window:x}");
            Current = new App(process, stderr, window);
            Current.Place();
            return Current;
        }

        public void Dispose()
        {
            Current = null;
            try { process.Kill(true); process.WaitForExit(10_000); }
            catch (InvalidOperationException) { }
            lock (stderr) stderr.Dispose();
        }

        /// Visible, uncloaked top-level windows of the process, topmost first.
        static List<nint> Windows(int pid)
        {
            var found = new List<nint>();
            Native.EnumWindows((w, _) =>
            {
                Native.GetWindowThreadProcessId(w, out var owner);
                if (owner == pid && Native.IsWindowVisible(w) && !Native.Cloaked(w)) found.Add(w);
                return true;
            }, 0);
            return found;
        }

        /// The window's frame (without its invisible resize borders) at Width × Height, 16 px from the screen's corner.
        void Place()
        {
            Foreground();
            Native.SetWindowPos(window, 0, 16, 16, Width, Height, 0x0004 | 0x0010); // SWP_NOZORDER | SWP_NOACTIVATE
            var frame = Native.Frame(window);
            Native.GetWindowRect(window, out var outer);
            Native.SetWindowPos(window, 0, 16 - (frame.Left - outer.Left), 16 - (frame.Top - outer.Top),
                Width + outer.Width - frame.Width, Height + outer.Height - frame.Height, 0x0004 | 0x0010);
            frame = Native.Frame(window);
            Log($"window frame {frame.Left},{frame.Top} {frame.Width}x{frame.Height}");
        }

        void Foreground()
        {
            var foreground = Native.GetForegroundWindow();
            var theirs = Native.GetWindowThreadProcessId(foreground, out _);
            var mine = Native.GetCurrentThreadId();
            Native.AttachThreadInput(mine, theirs, true);
            Native.BringWindowToTop(window);
            Native.SetForegroundWindow(window);
            Native.AttachThreadInput(mine, theirs, false);
        }

        IEnumerable<AutomationElement> Roots() =>
            Uia.GetDesktop().FindAllChildren(cf => cf.ByProcessId(process.Id));

        public AutomationElement Wait(string name, ControlType type, Func<AutomationElement, bool>? ok = null, ControlType[]? alternatives = null, int timeout = 30_000)
        {
            ControlType[] types = [type, .. alternatives ?? []];
            return Wait(e => e.Properties.Name.ValueOrDefault == name && types.Contains(e.Properties.ControlType.ValueOrDefault) && (ok is null || ok(e)),
                $"{type} \"{name}\"", timeout, cf => cf.ByName(name));
        }

        /// The PDF shown, or a note of why not: Windows.Data.Pdf's verdict on the build's main.pdf, read as the app reads it.
        public void WaitForPdf()
        {
            try
            {
                Wait(e => e.Properties.Name.ValueOrDefault?.StartsWith("Page ") == true, "a page count", 30_000, cf => cf.ByAutomationId("PageText"));
                return;
            }
            catch (TimeoutException) { }
            var pdf = Path.Combine(data, "Test Errors and Warnings", "build", "main.pdf");
            var verdict = "missing";
            if (File.Exists(pdf))
                try
                {
                    var bytes = File.ReadAllBytes(pdf);
                    var stream = new MemoryStream(bytes).AsRandomAccessStream();
                    var document = global::Windows.Data.Pdf.PdfDocument.LoadFromStreamAsync(stream).AsTask().GetAwaiter().GetResult();
                    verdict = $"{bytes.Length} bytes, {document.PageCount} pages to Windows.Data.Pdf";
                }
                catch (Exception e) { verdict = $"unreadable: {e.GetType().Name}: {e.Message}"; }
            Log($"NO PDF SHOWN after 30 s; {pdf}: {verdict}");
        }

        public AutomationElement Wait(Func<AutomationElement, bool> match, string what, int timeout,
            Func<FlaUI.Core.Conditions.ConditionFactory, FlaUI.Core.Conditions.ConditionBase>? narrow = null)
        {
            var clock = Stopwatch.StartNew();
            while (true)
            {
                try
                {
                    foreach (var root in Roots())
                    {
                        var candidates = narrow is null ? root.FindAllDescendants() : root.FindAllDescendants(narrow);
                        if (candidates.FirstOrDefault(match) is { } found) return found;
                    }
                }
                catch (COMException) { }
                if (clock.ElapsedMilliseconds > timeout) throw new TimeoutException($"no {what} after {timeout} ms");
                Thread.Sleep(300);
            }
        }

        public void WaitTitle(string prefix)
        {
            var clock = Stopwatch.StartNew();
            while (!Native.Title(window).StartsWith(prefix))
            {
                if (clock.ElapsedMilliseconds > 30_000) throw new TimeoutException($"title is \"{Native.Title(window)}\", not \"{prefix}…\"");
                Thread.Sleep(250);
            }
        }

        /// Invoke, else toggle, select or expand; a click only when the element offers none of them.
        public void Press(AutomationElement element)
        {
            var p = element.Patterns;
            if (p.Invoke.IsSupported) p.Invoke.Pattern.Invoke();
            else if (p.Toggle.IsSupported) p.Toggle.Pattern.Toggle();
            else if (p.SelectionItem.IsSupported) p.SelectionItem.Pattern.Select();
            else if (p.ExpandCollapse.IsSupported) p.ExpandCollapse.Pattern.Expand();
            else Click(element);
        }

        public void Expand(AutomationElement element)
        {
            if (element.Patterns.ExpandCollapse.IsSupported) element.Patterns.ExpandCollapse.Pattern.Expand();
            else Press(element);
        }

        public void Click(AutomationElement element)
        {
            Log($"clicking {element.Properties.Name.ValueOrDefault}");
            Front();
            Mouse.Click(element.GetClickablePoint());
            Native.SetCursorPos(Native.GetSystemMetrics(0) - 1, Native.GetSystemMetrics(1) - 1);
        }

        /// Not when a popup of the app's has the foreground: activating the window would close it.
        void Front()
        {
            Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var front);
            if (front != process.Id) Foreground();
        }

        /// Keys pressed together, as a person would, then a moment for the app to take them.
        public void Keys(params VirtualKeyShort[] chord)
        {
            Front();
            Keyboard.TypeSimultaneously(chord);
            Thread.Sleep(400);
        }

        public void Type(string text)
        {
            Front();
            Keyboard.Type(text);
            Thread.Sleep(400);
        }

        public AutomationElement WaitPdfButton(bool on) =>
            Wait(e => e.Patterns.Toggle.IsSupported && e.Patterns.Toggle.Pattern.ToggleState.ValueOrDefault == (on ? ToggleState.On : ToggleState.Off),
                $"the PDF button {(on ? "on" : "off")}", 10_000, cf => cf.ByAutomationId("PdfButton"));

        /// The scroll viewer that shows the most, scrolled to its end.
        public void ScrollToEnd()
        {
            var scroller = Roots().SelectMany(r => r.FindAllDescendants())
                .Where(e => e.Patterns.Scroll.IsSupported && e.Patterns.Scroll.Pattern.VerticallyScrollable.ValueOrDefault)
                .MaxBy(e => e.BoundingRectangle.Width * e.BoundingRectangle.Height)
                ?? throw new InvalidOperationException("nothing scrolls");
            scroller.Patterns.Scroll.Pattern.SetScrollPercent(-1, 100);
        }

        /// The window once it has stopped changing, as <name>.png, with its tree as <name>.txt.
        public void Shot(string name, bool settle = true)
        {
            Front();
            var clock = Stopwatch.StartNew();
            var image = Capture();
            for (var same = 0; settle && same < 3 && clock.ElapsedMilliseconds < 20_000;)
            {
                Thread.Sleep(400);
                var next = Capture();
                var changed = Changed(image, next);
                same = changed.IsEmpty ? same + 1 : 0;
                if (!changed.IsEmpty && clock.ElapsedMilliseconds >= 20_000) Log($"unsettled {name}: still changing in {changed}");
                image.Dispose();
                image = next;
            }
            image.Save(Out($"{name}.png"), ImageFormat.Png);
            image.Dispose();
            Log($"shot {name} after {clock.ElapsedMilliseconds} ms, foreground {Native.GetForegroundWindow() == window}, " +
                $"windows {string.Join(" ", Windows(process.Id).Select(w => $"{Native.ClassName(w)}@{Native.Bounds(w)}"))}");
            try
            {
                using var screen = new Bitmap(Native.GetSystemMetrics(0), Native.GetSystemMetrics(1));
                using (var g = Graphics.FromImage(screen)) g.CopyFromScreen(0, 0, 0, 0, screen.Size);
                screen.Save(Out(Path.Combine("logs", "screen", $"{name}.png")), ImageFormat.Png);
            }
            catch (Exception e) { Log($"no screen grab for {name}: {e.Message}"); }
            File.WriteAllText(Out($"{name}.txt"), Tree());
        }

        /// The window and, over it, each popup of the process that overlaps it, drawn by PrintWindow; the image grows to
        /// hold a popup reaching past the window, grey where the window isn't.
        Bitmap Capture()
        {
            var frame = Native.Frame(window);
            var layers = Enumerable.Reverse(Windows(process.Id)).Select(w => (Window: w, Box: Native.Bounds(w)))
                .Where(l => l.Box.Width > 0 && l.Box.Height > 0 && (l.Window == window || l.Box.Overlaps(frame))).ToList();
            var area = layers.Where(l => l.Window != window).Aggregate(frame, (all, l) => all.Union(l.Box));
            var canvas = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppRgb);
            using var g = Graphics.FromImage(canvas);
            g.Clear(Color.Gray);
            foreach (var (w, box) in layers)
            {
                using var layer = Native.Print(w, box.Width, box.Height, opaque: w == window);
                if (w == window) g.SetClip(new Rectangle(frame.Left - area.Left, frame.Top - area.Top, frame.Width, frame.Height));
                g.DrawImage(layer, box.Left - area.Left, box.Top - area.Top, box.Width, box.Height);
                g.ResetClip();
            }
            return canvas;
        }

        /// The box of the pixels that differ, empty when none do.
        static Rectangle Changed(Bitmap a, Bitmap b)
        {
            if (a.Size != b.Size) return new Rectangle(Point.Empty, b.Size);
            var box = new Rectangle(0, 0, a.Width, a.Height);
            var da = a.LockBits(box, ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
            var db = b.LockBits(box, ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
            try
            {
                int left = int.MaxValue, top = int.MaxValue, right = -1, bottom = -1;
                var row = new int[a.Width];
                var other = new int[a.Width];
                for (var y = 0; y < a.Height; y++)
                {
                    Marshal.Copy(da.Scan0 + y * da.Stride, row, 0, a.Width);
                    Marshal.Copy(db.Scan0 + y * db.Stride, other, 0, a.Width);
                    for (var x = 0; x < a.Width; x++)
                    {
                        if ((row[x] & 0xFFFFFF) == (other[x] & 0xFFFFFF)) continue;
                        (left, top, right, bottom) = (Math.Min(left, x), Math.Min(top, y), Math.Max(right, x), Math.Max(bottom, y));
                    }
                }
                return right < 0 ? Rectangle.Empty : Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
            }
            finally
            {
                a.UnlockBits(da);
                b.UnlockBits(db);
            }
        }

        /// Each element as its control type, name, automation id and box relative to the window's frame.
        string Tree()
        {
            var frame = Native.Frame(window);
            var text = new StringBuilder();
            foreach (var root in Roots()) Walk(root, 0);
            return text.ToString();

            void Walk(AutomationElement e, int depth)
            {
                string Read<T>(Func<T> f) { try { return Convert.ToString(f()) ?? ""; } catch (Exception) { return "?"; } }
                var name = Read(() => e.Properties.Name.ValueOrDefault).Replace("\r", "\\r").Replace("\n", "\\n");
                var id = Read(() => e.Properties.AutomationId.ValueOrDefault);
                var type = Read(() => e.Properties.ControlType.ValueOrDefault);
                var box = Read(() =>
                {
                    var r = e.Properties.BoundingRectangle.ValueOrDefault;
                    return r.IsEmpty ? "-" : $"{r.X - frame.Left},{r.Y - frame.Top} {r.Width}x{r.Height}";
                });
                var off = Read(() => e.Properties.IsEnabled.ValueOrDefault) == "False" ? " disabled" : "";
                if (Read(() => e.Patterns.Toggle.IsSupported ? e.Patterns.Toggle.Pattern.ToggleState.ValueOrDefault.ToString() : "") is { Length: > 0 } state && state != "?")
                    off += $" {state.ToLowerInvariant()}";
                text.Append(' ', depth * 2).Append($"{type} \"{name}\"").Append(id.Length > 0 ? $" #{id}" : "").Append($" [{box}]{off}\n");
                if (depth > 60) return;
                AutomationElement[] children;
                try { children = e.FindAllChildren(); }
                catch (COMException) { return; }
                foreach (var child in children) Walk(child, depth + 1);
            }
        }
    }
}

static partial class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left, Top, Right, Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
        public override readonly string ToString() => $"{Left},{Top} {Width}x{Height}";
        public readonly bool Overlaps(Rect o) => Left < o.Right && o.Left < Right && Top < o.Bottom && o.Top < Bottom;
        public readonly Rect Union(Rect o) => new()
            { Left = Math.Min(Left, o.Left), Top = Math.Min(Top, o.Top), Right = Math.Max(Right, o.Right), Bottom = Math.Max(Bottom, o.Bottom) };
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DevMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    public delegate bool EnumProc(nint hwnd, nint param);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string? device, int mode, ref DevMode devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DevMode devMode, int flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, nint value, uint winIni);
    [DllImport("user32.dll")] public static extern bool SetCaretBlinkTime(uint ms);
    [DllImport("user32.dll")] public static extern uint GetCaretBlinkTime();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern nint SendMessageTimeout(nint hwnd, uint msg, nint wParam, string lParam, uint flags, uint timeout, out nint result);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, nint param);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(nint hwnd, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(nint hwnd, nint dc, uint flags);
    [DllImport("user32.dll")] public static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(nint hwnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint to, bool on);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(nint hwnd, StringBuilder name, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(nint hwnd, StringBuilder text, int max);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out Rect value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out int value, int size);

    public static string ClassName(nint hwnd)
    {
        var name = new StringBuilder(256);
        GetClassName(hwnd, name, name.Capacity);
        return name.ToString();
    }

    public static string Title(nint hwnd)
    {
        var text = new StringBuilder(512);
        GetWindowText(hwnd, text, text.Capacity);
        return text.ToString();
    }

    public static Rect Bounds(nint hwnd)
    {
        GetWindowRect(hwnd, out var r);
        return r;
    }

    /// DWMWA_EXTENDED_FRAME_BOUNDS: the window as drawn, without the invisible resize borders GetWindowRect includes.
    public static Rect Frame(nint hwnd) =>
        DwmGetWindowAttribute(hwnd, 9, out Rect r, Marshal.SizeOf<Rect>()) == 0 ? r : Bounds(hwnd);

    /// The window drawn by PrintWindow (PW_RENDERFULLCONTENT). A popup's window includes a margin for its shadow that
    /// PrintWindow leaves black with no alpha: unless `opaque`, black is left out, so what's under the popup shows.
    public static Bitmap Print(nint hwnd, int width, int height, bool opaque)
    {
        var info = new BitmapInfoHeader { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
        var dc = CreateCompatibleDC(0);
        var dib = CreateDIBSection(dc, ref info, 0, out var bits, 0, 0);
        var old = SelectObject(dc, dib);
        PrintWindow(hwnd, dc, 2);
        var pixels = new int[width * height];
        Marshal.Copy(bits, pixels, 0, pixels.Length);
        SelectObject(dc, old);
        DeleteObject(dib);
        DeleteDC(dc);
        for (var i = 0; i < pixels.Length; i++)
            pixels[i] = opaque || (pixels[i] & 0xFFFFFF) != 0 ? pixels[i] | unchecked((int)0xFF000000) : 0;
        var image = new Bitmap(width, height, PixelFormat.Format32bppPArgb);
        var data = image.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
        for (var y = 0; y < height; y++) Marshal.Copy(pixels, y * width, data.Scan0 + y * data.Stride, width);
        image.UnlockBits(data);
        return image;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BitmapInfoHeader
    {
        public int Size, Width, Height;
        public short Planes, BitCount;
        public int Compression, SizeImage, XPelsPerMeter, YPelsPerMeter, ClrUsed, ClrImportant;
    }

    [DllImport("gdi32.dll")] static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] static extern nint CreateDIBSection(nint dc, ref BitmapInfoHeader info, uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32.dll")] static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(nint dc);

    public static bool Cloaked(nint hwnd) => DwmGetWindowAttribute(hwnd, 14, out int cloaked, 4) == 0 && cloaked != 0;
}
