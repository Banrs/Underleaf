using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using TeXLocal.Bridge;
using Windows.Data.Pdf;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Windows.System;
using Windows.UI.ViewManagement;

namespace TeXLocal.Controls;

/// The build's PDF through Windows.Data.Pdf, which renders pages and nothing else. The pages keep
/// their size in DIPs and the ScrollViewer zooms them; once the view settles, the pages near it are
/// drawn again at the pixels they're shown at.
public sealed partial class PdfView : UserControl
{
    /// A page's paper, its rendering, the canvas for its SyncTeX box, and its size in DIPs.
    sealed record Page(Border Box, Image Image, Canvas Marks, Size Size)
    {
        public int Rendered => (Image.Source as BitmapImage)?.DecodePixelWidth ?? 0;
    }

    enum Fit { None, Width, Page }

    /// Gap: round and between the pages. Edge: from the content's edge to a page, past its 1px stroke.
    const double Gap = 12, Edge = Gap + 1, PointToDip = 96.0 / 72;
    Page[] pages = [];
    double[] tops = [];
    Size largest;
    PdfDocument? document;
    Fit fit = Fit.Width;
    (int Number, Point At)? source;
    Canvas? marked;
    int loads;
    bool rendering, again;

    public event Action? ViewMoved;
    /// A page from 1 and a point on it in TeX points from its top left: a double-click, or Go to source position.
    public event Action<int, double, double>? Inverse;

    public PdfView()
    {
        InitializeComponent();
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
            if (pages.Length > 0 && Math.Abs(Zoom - FitZoom(largest)) > 0.001) fit = Fit.None;
        };
        foreach (var percent in (int[])[50, 75, 100, 125, 150, 200])
        {
            var item = new RadioMenuFlyoutItem { Text = $"{percent}%", GroupName = "Zoom", Tag = percent / 100.0 };
            item.Click += (_, _) => ZoomTo(percent / 100.0);
            Menu.Items.Add(item);
        }
        Loaded += (_, _) => XamlRoot.Changed += OnRootChanged;
        Unloaded += (_, _) => XamlRoot?.Changed -= OnRootChanged;
    }

    public new bool Focus(FocusState state) => Scroller.Focus(state);
    public bool Compiling { set => Progress.Visibility = value ? Visibility.Visible : Visibility.Collapsed; }
    public int PageCount => pages.Length;
    public double Zoom => Scroller.ZoomFactor;
    public MenuFlyout ZoomMenu => Menu;

    /// The page at the view's vertical centre, from 1.
    public int CurrentPage => pages.Length == 0 ? 0 : PageAt(tops, (Scroller.VerticalOffset + Scroller.ViewportHeight / 2) / Zoom) + 1;

    /// The last page whose top is at or above a y in the content's DIPs.
    static int PageAt(double[] tops, double y)
    {
        var i = Array.BinarySearch(tops, y);
        return Math.Clamp(i < 0 ? ~i - 1 : i, 0, tops.Length - 1);
    }

    /// The pages in a view whose top is at a content y, and one each side.
    (int First, int Last) Near(double[] tops, double y, double zoom) =>
        (Math.Max(PageAt(tops, y) - 1, 0), Math.Min(PageAt(tops, y + Scroller.ViewportHeight / zoom) + 1, tops.Length - 1));

    int Pixels(double width, double zoom) => (int)Math.Min(Math.Ceiling(width * zoom * (XamlRoot?.RasterizationScale ?? 1)), 4096);

    /// Draws the pages near a view at the zoom's pixels, and releases the pages further away.
    async Task Draw(PdfDocument doc, Page[] on, double[] at, double y, double zoom)
    {
        var (first, last) = Near(at, y, zoom);
        for (var i = 0; i < on.Length; i++)
        {
            if (i < first - 1 || i > last + 1) on[i].Image.Source = null;
            var width = Pixels(on[i].Size.Width, zoom);
            if (i < first || i > last || on[i].Rendered == width) continue;
            using var page = doc.GetPage((uint)i);
            using var stream = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = (uint)width, BitmapEncoderId = BitmapEncoder.BmpEncoderId });
            // At the drawn width: XAML would otherwise decode to the layout size, which leaves out the zoom.
            var bitmap = new BitmapImage { DecodePixelType = DecodePixelType.Physical, DecodePixelWidth = width };
            await bitmap.SetSourceAsync(stream);
            on[i].Image.Source = bitmap;
        }
    }

    /// Draws for the view as it is now, one pass at a time: a call during a pass runs another after it.
    async void Render()
    {
        if (rendering)
        {
            again = true;
            return;
        }
        rendering = true;
        try
        {
            do
            {
                again = false;
                if (document is { } doc) await Draw(doc, pages, tops, Scroller.VerticalOffset / Zoom, Zoom);
            } while (again);
        }
        finally { rendering = false; }
    }

    /// Shows a PDF from a copy, which leaves the file free for the next build. It keeps the place, the
    /// new pages in view are drawn before the swap, and a file that can't be read leaves the last good render up.
    public async Task Load(string path)
    {
        var load = ++loads;
        PdfDocument next;
        try
        {
            var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync((await File.ReadAllBytesAsync(path)).AsBuffer());
            stream.Seek(0);
            next = await PdfDocument.LoadFromStreamAsync(stream);
        }
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
        var most = new Size(fresh.Max(p => p.Size.Width), fresh.Max(p => p.Size.Height));
        var zoom = fit == Fit.None || Scroller.ViewportWidth == 0 ? Zoom : FitZoom(most);
        // The same page at the top of the view, and as far down it.
        var y = 0.0;
        if (pages.Length > 0)
        {
            var top = Scroller.VerticalOffset / Zoom;
            var old = PageAt(tops, top);
            var i = Math.Min(old, fresh.Length - 1);
            y =at[i] + (top - tops[old]) / pages[old].Size.Height * fresh[i].Size.Height;
        }
        await Draw(next, fresh, at, y, zoom);
        if (load != loads) return;

        Show(next, fresh, at);
        largest = most;
        Scroller.ChangeView(fit == Fit.None ? null : 0, y * zoom, (float)zoom, true);
    }

    /// A page's paper, which the panel's resources style. Its own coordinates are its DIPs at any zoom.
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
        Show(null, [], []);
    }

    void Show(PdfDocument? next, Page[] shown, double[] at)
    {
        (document, pages, tops, marked) = (next, shown, at, null);
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
        // About the view's centre across.
        var centre = Scroller.TransformToVisual(Pages).TransformPoint(new Point(Scroller.ViewportWidth / 2, 0)).X;
        View(zoom, Math.Max(centre * zoom - Scroller.ViewportWidth / 2, 0));
    }

    public void ZoomBy(double step) => ZoomTo(Zoom * step);
    public void FitWidth() => Refit(Fit.Width);
    /// The page at the view's centre, whole, with its top edge at the view's.
    public void FitPage() => Refit(Fit.Page, pages.Length == 0 ? null : tops[CurrentPage - 1] - Edge);

    /// The zoom at which the widest page fills the view across, and with Fit page the tallest one down.
    double FitZoom(Size most)
    {
        var zoom = Scroller.ViewportWidth / (most.Width + 2 * Edge);
        if (fit == Fit.Page) zoom = Math.Min(zoom, Scroller.ViewportHeight / (most.Height + 2 * Edge));
        return Math.Clamp(zoom, Scroller.MinZoomFactor, Scroller.MaxZoomFactor);
    }

    /// Sets a fit, which holds as the view resizes until a zoom of the reader's own.
    void Refit(Fit mode, double? y = null)
    {
        fit = mode;
        if (fit != Fit.None && pages.Length > 0 && Scroller.ViewportWidth > 0) View(FitZoom(largest), 0, y);
    }

    /// Zooms with a content y at the top of the view: by default the one there now.
    void View(double zoom, double? across, double? y = null) =>
        Scroller.ChangeView(across, (y ?? Scroller.VerticalOffset / Zoom) * zoom, (float)zoom, true);

    public void GoToPage(int number)
    {
        if (pages.Length > 0) Scroller.ChangeView(null, (tops[Math.Clamp(number, 1, pages.Length) - 1] - Edge) * Zoom, null);
    }

    /// Scrolls a SyncTeX point a third of the way down the view, and across only when its box is out
    /// of view, then flashes the box. With no box from the core it only scrolls (core gap 10).
    public void Reveal(ForwardSync at)
    {
        if (at.Page < 1 || at.Page > pages.Length) return;
        var page = pages[(int)at.Page - 1];
        var (x, y, width, height) = ((at.H ?? 0) * PointToDip, (at.V ?? 0) * PointToDip, (at.Width ?? 0) * PointToDip, (at.Height ?? 0) * PointToDip);
        var view = page.Marks.TransformToVisual(Scroller).TransformPoint(new Point(x, y));
        double? across = view.X < 0 || view.X + width * Zoom > Scroller.ViewportWidth ? Math.Max(Scroller.HorizontalOffset + view.X - 2 * Gap, 0) : null;
        Scroller.ChangeView(across, Math.Max(Scroller.VerticalOffset + view.Y - Scroller.ViewportHeight / 3, 0), null);
        if (at.Width is null || at.Height is null) return;

        marked?.Children.Clear();
        var box = new Rectangle { Width = width, Height = height };
        Canvas.SetLeft(box, x);
        Canvas.SetTop(box, y - height);
        (marked = page.Marks).Children.Add(box);
        var fade = new DoubleAnimation { To = 0, BeginTime = TimeSpan.FromSeconds(2), Duration = TimeSpan.FromMilliseconds(new UISettings().AnimationsEnabled ? 333 : 0) };
        Storyboard.SetTarget(fade, box);
        Storyboard.SetTargetProperty(fade, "Opacity");
        new Storyboard { Children = { fade } }.Begin();
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

    void OnZoomIn(object sender, RoutedEventArgs e) => ZoomBy(1.25);
    void OnZoomOut(object sender, RoutedEventArgs e) => ZoomBy(0.8);
    void OnFitWidth(object sender, RoutedEventArgs e) => FitWidth();
    void OnFitPage(object sender, RoutedEventArgs e) => FitPage();
    void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs e) => Render();
}
