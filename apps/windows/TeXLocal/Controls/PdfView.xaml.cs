using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Printing;
using Microsoft.UI.Xaml.Shapes;
using TeXLocal.Bridge;
using Windows.Data.Pdf;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Graphics.Printing;
using Windows.Storage.Streams;
using Windows.System;

namespace TeXLocal.Controls;

/// The pages keep their size in DIPs and the ScrollViewer zooms them; once the view settles, the
/// pages near it are drawn again at the pixels they're shown at.
public sealed partial class PdfView : UserControl
{
    sealed record Page(Border Box, Image Image, Canvas Marks, Size Size);

    enum Fit { None, Width, Page }

    /// Gap: round and between the pages. Edge: from the content's edge to a page, past its 1px stroke.
    const double Gap = 12, Edge = Gap + 1, PointToDip = 96.0 / 72;
    Page[] pages = [];
    double[] tops = [];
    PdfDocument? document;
    Fit fit = Fit.Width;
    (int Number, Point At)? source;
    int loads;
    bool rendering, again, dark;
    readonly Debounce marked;

    public event Action? ViewMoved;
    /// A page from 1 and a point on it in TeX points from its top left: a double-click, or Go to source position.
    public event Action<int, double, double>? Inverse;

    public PdfView()
    {
        InitializeComponent();
        marked = new(2000, () =>
        {
            foreach (var page in pages) page.Marks.Children.Clear();
        });
        Scroller.ViewChanged += (_, e) =>
        {
            ViewMoved?.Invoke();
            if (!e.IsIntermediate) Render();
        };
        Scroller.SizeChanged += (_, _) => Refit(fit);
        // A zoom of the reader's own ends the fit: Ctrl+wheel, or a pinch that changed it. Not a
        // final ViewChanged, which can still report the zoom of a fit superseded mid-resize.
        Scroller.AddHandler(PointerWheelChangedEvent, new PointerEventHandler((_, e) =>
        {
            if (pages.Length > 0 && e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control)) fit = Fit.None;
        }), true);
        Scroller.DirectManipulationCompleted += (_, _) =>
        {
            if (pages.Length > 0 && Math.Abs(Zoom - FitZoom(pages)) > 0.001) fit = Fit.None;
        };
        foreach (var percent in (int[])[50, 75, 100, 125, 150, 200])
        {
            var item = new RadioMenuFlyoutItem { Text = $"{percent}%", GroupName = "Zoom", Tag = percent / 100.0 };
            item.Click += (_, _) => ZoomTo(percent / 100.0);
            Menu.Items.Add(item);
        }
        Loaded += (_, _) =>
        {
            XamlRoot.Changed += OnRootChanged;
            Repaper();
        };
        ActualThemeChanged += (_, _) => Repaper();
        Unloaded += (_, _) => XamlRoot?.Changed -= OnRootChanged;
    }

    public new bool Focus(FocusState state) => Scroller.Focus(state);

    /// With no PDF, says why Compile is off, as Home's tip does.
    public bool TexMissing
    {
        set
        {
            EmptyTitle.Text = value ? "TeX isn't installed" : "No PDF yet";
            EmptyText.Text = value ? "TeXLocal compiles with TeX Live." : "Compile to see the PDF here.";
            GetTex.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        }
    }
    /// The file the pages shown were read from, for Export and Share.
    public string? FilePath { get; private set; }
    public int PageCount => pages.Length;
    public double Zoom => Scroller.ZoomFactor;
    public MenuFlyout ZoomMenu => Menu;

    public int CurrentPage => pages.Length == 0 ? 0 : PageAt(tops, (Scroller.VerticalOffset + Scroller.ViewportHeight / 2) / Zoom) + 1;

    /// The last page whose top is at or above a y in the content's DIPs.
    static int PageAt(double[] tops, double y)
    {
        var i = Array.BinarySearch(tops, y);
        return Math.Clamp(i < 0 ? ~i - 1 : i, 0, tops.Length - 1);
    }

    async Task Draw(PdfDocument doc, Page[] on, double[] at, double y, double zoom)
    {
        var (first, last) = (Math.Max(PageAt(at, y) - 1, 0), Math.Min(PageAt(at, y + Scroller.ViewportHeight / zoom) + 1, at.Length - 1));
        for (var i = 0; i < on.Length; i++)
        {
            if (i < first - 1 || i > last + 1) on[i].Image.Source = null;
            var width = (int)Math.Min(Math.Ceiling(on[i].Size.Width * zoom * (XamlRoot?.RasterizationScale ?? 1)), 4096);
            if (i < first || i > last || ((on[i].Image.Source as BitmapImage)?.DecodePixelWidth ?? 0) == width && Equals(on[i].Image.Tag, dark)) continue;
            using var page = doc.GetPage((uint)i);
            using var stream = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = (uint)width, BitmapEncoderId = BitmapEncoder.BmpEncoderId });
            var ink = dark;
            using var darkened = ink ? await Darken(stream) : null;
            // At the drawn width: XAML would otherwise decode to the layout size, which leaves out the zoom.
            var bitmap = new BitmapImage { DecodePixelType = DecodePixelType.Physical, DecodePixelWidth = width };
            await bitmap.SetSourceAsync(darkened ?? stream);
            (on[i].Image.Source, on[i].Image.Tag) = (bitmap, ink);
        }
    }

    /// The Mac's dark paper: inverted, then turned 180° in hue, which together turn each colour's luma over and keep its
    /// chroma, c + 1 − 2Y. Per pixel off the UI thread, as Windows.Data.Pdf has no filter and composition's need Win2D.
    static async Task<InMemoryRandomAccessStream> Darken(IRandomAccessStream page)
    {
        page.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.BmpDecoderId, page);
        var pixels = (await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, new BitmapTransform(),
            ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)).DetachPixelData();
        await Task.Run(() =>
        {
            for (var i = 0; i < pixels.Length; i += 4)
            {
                var turn = 255 - ((29 * pixels[i] + 150 * pixels[i + 1] + 77 * pixels[i + 2]) >> 7);
                for (var c = i; c < i + 3; c++) pixels[c] = (byte)Math.Clamp(pixels[c] + turn, 0, 255);
            }
        });
        var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.BmpEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, decoder.PixelWidth, decoder.PixelHeight, decoder.DpiX, decoder.DpiY, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        return stream;
    }

    /// Follows Settings' page colour and, for its Use app theme, the app's; the pages showing are drawn again.
    void Repaper()
    {
        var colour = Prefs.PageColour;
        var now = colour == PageColour.Dark || colour == PageColour.App && ActualTheme == ElementTheme.Dark;
        if (now == dark) return;
        dark = now;
        Pages.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
        Render();
    }

    /// Draws for the view as it is now, one pass at a time: a call during a pass runs another after it.
    void Render()
    {
        again = true;
        if (rendering) return;
        rendering = true;
        App.Run("Can't show the PDF", async () =>
        {
            try
            {
                while (again)
                {
                    again = false;
                    if (document is { } doc) await Draw(doc, pages, tops, Scroller.VerticalOffset / Zoom, Zoom);
                }
            }
            finally { rendering = false; }
        });
    }

    /// Shows a PDF from a copy, which leaves the file free for the next build. It keeps the place, the
    /// new pages in view are drawn before the swap, and a file that can't be read leaves the last good render up.
    public async Task Load(string path)
    {
        var load = ++loads;
        PdfDocument next;
        try { next = await PdfDocument.LoadFromStreamAsync(new MemoryStream(await File.ReadAllBytesAsync(path)).AsRandomAccessStream()); }
        catch (Exception) { return; }
        if (load != loads || next.PageCount == 0) return;

        var fresh = new Page[next.PageCount];
        var at = new double[fresh.Length];
        for (var i = 0; i < fresh.Length; i++)
        {
            using var page = next.GetPage((uint)i);
            fresh[i] = Paper(i + 1, page.Size);
            at[i] = i == 0 ? Edge : at[i - 1] + fresh[i - 1].Size.Height + 2 + Gap;
        }
        var zoom = fit == Fit.None || Scroller.ViewportWidth == 0 ? Zoom : FitZoom(fresh);
        // The same page at the top of the view, and as far down it.
        var y = 0.0;
        if (pages.Length > 0)
        {
            var top = Scroller.VerticalOffset / Zoom;
            var old = PageAt(tops, top);
            var i = Math.Min(old, fresh.Length - 1);
            y = at[i] + (top - tops[old]) / pages[old].Size.Height * fresh[i].Size.Height;
        }
        await Draw(next, fresh, at, y, zoom);
        if (load != loads) return;

        FilePath = path;
        Show(next, fresh, at);
        View(zoom, fit == Fit.None ? null : 0, y);
    }

    /// Its own coordinates are its DIPs at any zoom.
    Page Paper(int number, Size size)
    {
        var image = new Image { Stretch = Stretch.Fill };
        AutomationProperties.SetName(image, $"Page {number}");
        var marks = new Canvas();
        var grid = new Grid { Width = size.Width, Height = size.Height, Children = { image, marks } };
        var box = new Border { Child = grid };
        box.DoubleTapped += (_, e) =>
        {
            var p = e.GetPosition(grid);
            Inverse?.Invoke(number, p.X / PointToDip, p.Y / PointToDip);
            e.Handled = true;
        };
        return new Page(box, image, marks, size);
    }

    public void Clear()
    {
        loads++;
        FilePath = null;
        Show(null, [], []);
    }

    void Show(PdfDocument? next, Page[] shown, double[] at)
    {
        (document, pages, tops) = (next, shown, at);
        Pages.Children.Clear();
        foreach (var page in shown) Pages.Children.Add(page.Box);
        Empty.Visibility = shown.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ViewMoved?.Invoke();
    }

    public void ZoomTo(double factor)
    {
        if (pages.Length == 0) return;
        fit = Fit.None;
        var zoom = Math.Clamp(factor, Scroller.MinZoomFactor, Scroller.MaxZoomFactor);
        var centre = Scroller.TransformToVisual(Pages).TransformPoint(new Point(Scroller.ViewportWidth / 2, 0)).X;
        View(zoom, Math.Max(centre * zoom - Scroller.ViewportWidth / 2, 0));
    }

    public void ZoomToActualSize() => ZoomTo(1);
    public void ZoomIn() => ZoomTo(Zoom * 1.25);
    public void ZoomOut() => ZoomTo(Zoom * 0.8);
    public void FitWidth() => Refit(Fit.Width);
    /// The page at the view's centre, whole, with its top edge at the view's.
    public void FitPage() => Refit(Fit.Page, pages.Length == 0 ? null : tops[CurrentPage - 1] - Edge);

    double FitZoom(Page[] on)
    {
        var zoom = Scroller.ViewportWidth / (on.Max(p => p.Size.Width) + 2 * Edge);
        if (fit == Fit.Page) zoom = Math.Min(zoom, Scroller.ViewportHeight / (on.Max(p => p.Size.Height) + 2 * Edge));
        return Math.Clamp(zoom, Scroller.MinZoomFactor, Scroller.MaxZoomFactor);
    }

    /// Sets a fit, which holds as the view resizes until a zoom of the reader's own.
    void Refit(Fit mode, double? y = null)
    {
        fit = mode;
        if (fit != Fit.None && pages.Length > 0 && Scroller.ViewportWidth > 0) View(FitZoom(pages), 0, y);
    }

    /// y: the content's at the top of the view, by default the one there now.
    void View(double zoom, double? across, double? y = null) =>
        Scroller.ChangeView(across, (y ?? Scroller.VerticalOffset / Zoom) * zoom, (float)zoom, true);

    /// The page at the top of the view, from 1, as GoToPage leaves it, and the zoom, as a project's ui state keeps them.
    public (int? Page, object Zoom) Place => (pages.Length == 0 ? null : PageAt(tops, Scroller.VerticalOffset / Zoom + Edge) + 1,
        fit switch { Fit.Width => "fitWidth", Fit.Page => "fitPage", _ => Zoom });

    /// Back to a Place, in one move: a page after the zoom would scroll by the zoom being left. A page past the last
    /// is left where the view is.
    public void GoTo(int? page, JsonElement zoom)
    {
        if (pages.Length == 0) return;
        fit = zoom.ValueKind == JsonValueKind.Number ? Fit.None : zoom.ValueKind == JsonValueKind.String && zoom.GetString() == "fitPage" ? Fit.Page : Fit.Width;
        var factor = fit == Fit.None ? Math.Clamp(zoom.GetDouble(), Scroller.MinZoomFactor, Scroller.MaxZoomFactor)
            : Scroller.ViewportWidth == 0 ? Zoom : FitZoom(pages);
        View(factor, 0, page is { } n && n <= pages.Length ? tops[n - 1] - Edge : null);
    }

    public void GoToPage(int number)
    {
        if (pages.Length > 0) Scroller.ChangeView(null, (tops[Math.Clamp(number, 1, pages.Length) - 1] - Edge) * Zoom, null);
    }

    /// Scrolls a SyncTeX point a third of the way down the view, and across only when its box is out
    /// of view, then shows the box for 2 s, a later one's 2 s from its own. With no box from the core it only scrolls
    /// (core gap 10).
    public void Reveal(ForwardSync at)
    {
        if (at.Page < 1 || at.Page > pages.Length) return;
        var page = pages[(int)at.Page - 1];
        var (x, y, width, height) = ((at.H ?? 0) * PointToDip, (at.V ?? 0) * PointToDip, (at.Width ?? 0) * PointToDip, (at.Height ?? 0) * PointToDip);
        var view = page.Marks.TransformToVisual(Scroller).TransformPoint(new Point(x, y));
        double? across = view.X < 0 || view.X + width * Zoom > Scroller.ViewportWidth ? Math.Max(Scroller.HorizontalOffset + view.X - 2 * Gap, 0) : null;
        Scroller.ChangeView(across, Math.Max(Scroller.VerticalOffset + view.Y - Scroller.ViewportHeight / 3, 0), null);
        if (at.Width is null || at.Height is null) return;

        foreach (var other in pages) other.Marks.Children.Clear();
        var box = new Rectangle { Width = width, Height = height };
        Canvas.SetLeft(box, x);
        Canvas.SetTop(box, y - height);
        page.Marks.Children.Add(box);
        marked.Restart();
    }

    /// Windows' print dialog for the build's pages, on white, each fitted to the sheet and drawn at the printer's
    /// resolution up to 600 dpi: XAML holds every sheet until the job is spooled, and PNG keeps them small until then.
    public void Print() => App.Run("Can't print", async () =>
    {
        if (document is not { } doc) return;
        var window = Microsoft.UI.Win32Interop.GetWindowFromWindowId(App.Window.AppWindow.Id);
        var printing = new PrintDocument();
        var source = printing.DocumentSource;
        var paper = new Size();
        printing.Paginate += (_, e) =>
        {
            paper = e.PrintTaskOptions.GetPageDescription(0).PageSize;
            printing.SetPreviewPageCount((int)doc.PageCount, PreviewPageCountType.Final);
        };
        printing.GetPreviewPage += (_, e) => App.Run("Can't print", async () =>
            printing.SetPreviewPage(e.PageNumber, await Sheet(doc, e.PageNumber - 1, paper, 96 * (XamlRoot?.RasterizationScale ?? 1))));
        printing.AddPages += (_, e) => App.Run("Can't print", async () =>
        {
            var sheet = e.PrintTaskOptions.GetPageDescription(0);
            for (var i = 0; i < doc.PageCount; i++) printing.AddPage(await Sheet(doc, i, sheet.PageSize, Math.Min(sheet.DpiX, 600)));
            printing.AddPagesComplete();
        });
        var title = System.IO.Path.GetFileNameWithoutExtension(FilePath);
        // The interop throws when Windows has no printing for the window.
        var manager = PrintManagerInterop.GetForWindow(window);
        manager.PrintTaskRequested += Requested;
        try { await PrintManagerInterop.ShowPrintUIForWindowAsync(window); }
        finally { manager.PrintTaskRequested -= Requested; }

        void Requested(PrintManager sender, PrintTaskRequestedEventArgs e) => e.Request.CreatePrintTask(title, r => r.SetSource(source));
    });

    /// A page fitted to a sheet of paper in DIPs, drawn at a resolution in dpi.
    static async Task<Image> Sheet(PdfDocument doc, int index, Size paper, double dpi)
    {
        using var page = doc.GetPage((uint)index);
        var width = (int)Math.Ceiling(page.Size.Width * Math.Min(paper.Width / page.Size.Width, paper.Height / page.Size.Height) / 96 * dpi);
        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = (uint)width });
        var bitmap = new BitmapImage { DecodePixelType = DecodePixelType.Physical, DecodePixelWidth = width };
        await bitmap.SetSourceAsync(stream);
        return new Image { Source = bitmap, Width = paper.Width, Height = paper.Height };
    }

    // At the right-click, or from the keyboard a third of the way down the view's centre.
    void OnContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if (pages.Length == 0) return;
        var point = e.TryGetPosition(Scroller, out var p) ? p : new Point(Scroller.ViewportWidth / 2, Scroller.ViewportHeight / 3);
        var i = PageAt(tops, (Scroller.VerticalOffset + point.Y) / Zoom);
        var at = Scroller.TransformToVisual(pages[i].Marks).TransformPoint(point);
        source = new Rect(new Point(), pages[i].Size).Contains(at) ? (i + 1, at) : null;
        Menu.ShowAt(Scroller, new FlyoutShowOptions { Position = point });
        e.Handled = true;
    }

    void OnMenuOpening(object sender, object e)
    {
        // Go to source position only from a page, not from the status bar's zoom button.
        if (Menu.Target != Scroller) source = null;
        SourceItem.Visibility = SourceRule.Visibility = source is null ? Visibility.Collapsed : Visibility.Visible;
        FitWidthItem.IsChecked = fit == Fit.Width;
        FitPageItem.IsChecked = fit == Fit.Page;
        foreach (var item in Menu.Items.OfType<RadioMenuFlyoutItem>())
            if (item.Tag is double zoom) item.IsChecked = fit == Fit.None && Math.Abs(Zoom - zoom) < 0.001;
    }

    void OnGoToSource(object sender, RoutedEventArgs e)
    {
        if (source is (var number, var at)) Inverse?.Invoke(number, at.X / PointToDip, at.Y / PointToDip);
    }

    void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs e) => Render();
}
