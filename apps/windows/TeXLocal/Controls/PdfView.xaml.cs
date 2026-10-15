using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Windows.System;
using Windows.UI.Core;
using Windows.UI.ViewManagement;

namespace TeXLocal.Controls;

/// A page: white paper sized to the PDF page × zoom, its rendering, and an overlay for the SyncTeX box.
public sealed class PageItem
{
    readonly Image image = new() { Stretch = Stretch.Fill };
    Windows.Foundation.Size size;
    double zoom = 1;

    public readonly Border Box;
    public readonly Canvas Overlay = new();

    public PageItem(Style style)
    {
        Box = new Border { Style = style, Child = new Grid { Children = { image, Overlay } } };
    }

    public double Height => size.Height * zoom;
    public double PageWidth => size.Width;
    public ImageSource? Bitmap => image.Source;
    public int Rendered { get; private set; }

    public void Set(int number, Windows.Foundation.Size page, double factor)
    {
        size = page;
        AutomationProperties.SetName(Box, $"Page {number}");
        Zoom(factor);
    }

    public void Zoom(double factor)
    {
        zoom = factor;
        (Box.Width, Box.Height) = (size.Width * zoom, size.Height * zoom);
    }

    public void Show(ImageSource? bitmap, int width)
    {
        image.Source = bitmap;
        Rendered = width;
    }
}

/// The build's PDF through Windows.Data.Pdf, which renders pages and nothing else. Zoom sizes the
/// pages (layout zoom), so page coordinates are page DIPs × zoom.
public sealed partial class PdfView : UserControl
{
    const double Gap = 12, PointToDip = 96.0 / 72, MinZoom = 0.25, MaxZoom = 4;
    readonly List<PageItem> items = [];
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer settle;
    PdfDocument? document;
    double zoom = 1;
    int loads;
    bool rendering, again;

    public event Action? ViewMoved;
    /// A double-click on a page: its number from 1 and the point in TeX points from its top left.
    public event Action<int, double, double>? Inverse;

    public PdfView()
    {
        InitializeComponent();
        settle = DispatcherQueue.CreateTimer();
        settle.Interval = TimeSpan.FromMilliseconds(150);
        settle.IsRepeating = false;
        settle.Tick += (_, _) => Render(true);
        Scroller.ViewChanged += (_, e) =>
        {
            ViewMoved?.Invoke();
            Render(!e.IsIntermediate);
        };
        Scroller.SizeChanged += (_, _) =>
        {
            Pages.MinWidth = Math.Max(Scroller.ViewportWidth - 2 * Gap, 0);
            Render(false);
        };
        Scroller.AddHandler(PointerWheelChangedEvent, new PointerEventHandler(OnWheel), true);
        Scroller.AddHandler(DoubleTappedEvent, new DoubleTappedEventHandler(OnDoubleTapped), true);
        Loaded += (_, _) => XamlRoot.Changed += (_, _) => Render(true);
    }

    public new bool Focus(FocusState state) => Scroller.Focus(state);

    public bool Compiling { set => Progress.Opacity = value ? 1 : 0; }
    public int PageCount => items.Count;
    public double Zoom => zoom;

    /// The page at the viewport's vertical centre, from 1.
    public int CurrentPage => items.Count == 0 ? 0 : PageAt(Scroller.VerticalOffset + Scroller.ViewportHeight / 2) + 1;

    double Top(int index)
    {
        var y = Gap;
        for (var i = 0; i < index && i < items.Count; i++) y += items[i].Height + Gap;
        return y;
    }

    int PageAt(double y)
    {
        var top = Gap;
        for (var i = 0; i < items.Count; i++)
        {
            top += items[i].Height + Gap;
            if (y < top) return i;
        }
        return Math.Max(items.Count - 1, 0);
    }

    int Pixels(double pageWidth) => (int)Math.Ceiling(pageWidth * zoom * (XamlRoot?.RasterizationScale ?? 1));

    static async Task<BitmapImage> Draw(PdfDocument from, int index, int width)
    {
        using var page = from.GetPage((uint)index);
        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = (uint)width, BitmapEncoderId = BitmapEncoder.BmpEncoderId });
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }

    /// Draws the pages in view and one each side: missing ones always, sharper ones once a zoom settles.
    async void Render(bool sharpen)
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
                if (document is not { } doc || items.Count == 0) return;
                var first = Math.Max(PageAt(Scroller.VerticalOffset) - 1, 0);
                var last = Math.Min(PageAt(Scroller.VerticalOffset + Scroller.ViewportHeight) + 1, items.Count - 1);
                for (var i = 0; i < items.Count; i++)
                {
                    var item = items[i];
                    if (i < first - 2 || i > last + 2)
                    {
                        if (item.Bitmap is not null) item.Show(null, 0);
                        continue;
                    }
                    var width = Pixels(item.PageWidth);
                    if (i < first || i > last || item.Bitmap is not null && (!sharpen || item.Rendered == width)) continue;
                    var bitmap = await Draw(doc, i, width);
                    if (doc != document) break;
                    item.Show(bitmap, width);
                }
            } while (again);
        }
        finally { rendering = false; }
    }

    /// Shows a PDF, keeping the place: the new pages in view are drawn before the swap, and a
    /// file that can't be read leaves the last good render up.
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
        if (load != loads) return;

        var sizes = new Windows.Foundation.Size[next.PageCount];
        for (var i = 0; i < sizes.Length; i++)
        {
            using var page = next.GetPage((uint)i);
            sizes[i] = page.Size;
        }
        if (sizes.Length == 0) return;
        var fresh = items.Count == 0;
        if (fresh && sizes[0].Width + 2 * Gap > Scroller.ViewportWidth)
            zoom = Math.Clamp((Scroller.ViewportWidth - 2 * Gap) / sizes.Max(s => s.Width), MinZoom, MaxZoom);
        var (anchor, within) = Place();
        anchor = Math.Min(anchor, sizes.Length - 1);

        var drawn = new Dictionary<int, (BitmapImage, int)>();
        var first = Math.Max(anchor - 1, 0);
        for (var i = first; i <= first + 3 && i < sizes.Length; i++)
        {
            var width = Pixels(sizes[i].Width);
            drawn[i] = (await Draw(next, i, width), width);
        }
        if (load != loads) return;

        document = next;
        Empty.Visibility = Visibility.Collapsed;
        while (items.Count > sizes.Length)
        {
            Pages.Children.Remove(items[^1].Box);
            items.RemoveAt(items.Count - 1);
        }
        for (var i = 0; i < sizes.Length; i++)
        {
            if (i == items.Count)
            {
                items.Add(new PageItem((Style)Resources["PageStyle"]));
                Pages.Children.Add(items[i].Box);
            }
            items[i].Set(i + 1, sizes[i], zoom);
            var (bitmap, width) = drawn.TryGetValue(i, out var d) ? d : (null, 0);
            items[i].Show(bitmap, width);
        }
        Restore(anchor, within);
        Render(true);
        ViewMoved?.Invoke();
    }

    /// The page at the top of the view and how far down it the view starts, as a fraction.
    (int Page, double Within) Place()
    {
        if (items.Count == 0) return (0, 0);
        var page = PageAt(Scroller.VerticalOffset);
        return (page, (Scroller.VerticalOffset - Top(page)) / items[page].Height);
    }

    void Restore(int page, double within, double? x = null)
    {
        Scroller.UpdateLayout();
        var y = Top(page) + within * items[page].Height;
        Scroller.ChangeView(x ?? Scroller.HorizontalOffset, y, null, true);
    }

    public void Clear()
    {
        loads++;
        document = null;
        items.Clear();
        Pages.Children.Clear();
        Empty.Visibility = Visibility.Visible;
        ViewMoved?.Invoke();
    }

    public void ZoomTo(double factor)
    {
        factor = Math.Clamp(factor, MinZoom, MaxZoom);
        if (items.Count == 0 || factor == zoom) return;
        var (page, within) = Place();
        var centre = (Scroller.HorizontalOffset + Scroller.ViewportWidth / 2 - Gap) * factor / zoom + Gap - Scroller.ViewportWidth / 2;
        zoom = factor;
        foreach (var item in items) item.Zoom(zoom);
        Restore(page, within, Math.Max(centre, 0));
        ViewMoved?.Invoke();
        settle.Start();
    }

    public void ZoomBy(double step) => ZoomTo(zoom * step);

    double Widest => items.Max(p => p.PageWidth);

    public void FitWidth()
    {
        if (items.Count > 0) ZoomTo((Scroller.ViewportWidth - 2 * Gap) / Widest);
    }

    public void FitPage()
    {
        if (items.Count == 0) return;
        var page = CurrentPage - 1;
        var tallest = items.Max(p => p.Height) / zoom;
        ZoomTo(Math.Min((Scroller.ViewportWidth - 2 * Gap) / Widest, (Scroller.ViewportHeight - 2 * Gap) / tallest));
        Scroller.ChangeView(null, Top(page) - Gap, null, true);
    }

    public void GoToPage(int number)
    {
        if (items.Count == 0) return;
        Scroller.ChangeView(null, Top(Math.Clamp(number, 1, items.Count) - 1) - Gap, null);
    }

    void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down)) return;
        ZoomBy(e.GetCurrentPoint(Scroller).Properties.MouseWheelDelta > 0 ? 1.1 : 1 / 1.1);
        e.Handled = true;
    }

    /// Scrolls a SyncTeX point (TeX points from the page's top left) a third of the way down, and
    /// flashes its box when there is one.
    public void Reveal(int number, double h, double v, double? width, double? height)
    {
        if (number < 1 || number > items.Count) return;
        var index = number - 1;
        var scale = PointToDip * zoom;
        Scroller.UpdateLayout();
        var left = Gap + Math.Max((Pages.ActualWidth - items[index].Box.Width) / 2, 0) + h * scale;
        var right = left + (width ?? 0) * scale;
        double? x = left < Scroller.HorizontalOffset || right > Scroller.HorizontalOffset + Scroller.ViewportWidth ? Math.Max(left - 2 * Gap, 0) : null;
        Scroller.ChangeView(x, Math.Max(Top(index) + v * scale - Scroller.ViewportHeight / 3, 0), null);
        if (width is not { } w || height is not { } ht) return;
        var overlay = items[index].Overlay;
        var box = new Rectangle { Width = w * scale, Height = ht * scale, Style = (Style)Resources["SyncBox"] };
        Canvas.SetLeft(box, h * scale);
        Canvas.SetTop(box, (v - ht) * scale);
        overlay.Children.Add(box);
        var fade = new DoubleAnimation
        {
            To = 0,
            BeginTime = TimeSpan.FromSeconds(1),
            Duration = new UISettings().AnimationsEnabled ? TimeSpan.FromMilliseconds(333) : TimeSpan.Zero,
        };
        Storyboard.SetTarget(fade, box);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var story = new Storyboard { Children = { fade } };
        story.Completed += (_, _) => overlay.Children.Remove(box);
        story.Begin();
    }

    void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        for (var at = e.OriginalSource as DependencyObject; at is not null && at != Scroller; at = VisualTreeHelper.GetParent(at))
        {
            var index = items.FindIndex(p => p.Box == at);
            if (index < 0) continue;
            var point = e.GetPosition(items[index].Box.Child);
            Inverse?.Invoke(index + 1, point.X / PointToDip / zoom, point.Y / PointToDip / zoom);
            e.Handled = true;
            return;
        }
    }
}
