using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace TeXLocal.Controls;

/// A template's first page in outline, as a template gallery draws one: grey bars where its text lies, darker for
/// headings, on white paper in the light theme's colours.
public sealed partial class PagePreview : Canvas
{
    public static readonly DependencyProperty KindProperty =
        DependencyProperty.Register(nameof(Kind), typeof(string), typeof(PagePreview), new PropertyMetadata("", (d, _) => ((PagePreview)d).Draw()));

    public PagePreview() => RequestedTheme = ElementTheme.Light;

    public string Kind { get => (string)GetValue(KindProperty); set => SetValue(KindProperty, value); }

    /// Bars as (x, y, width, height, heading) in the DIPs of a 120 × 156 page, or a 160 × 90 slide.
    static (double X, double Y, double W, double H, bool Head)[] Bars(string kind) => kind switch
    {
        "article" =>
        [
            (34, 18, 52, 5, true), (44, 27, 32, 3, false), (48, 33, 24, 3, false),
            (48, 44, 24, 3, true), (22, 50, 76, 2, false), (22, 55, 76, 2, false), (22, 60, 50, 2, false),
            (14, 72, 40, 4, true), (14, 80, 92, 2, false), (14, 85, 92, 2, false), (14, 90, 92, 2, false), (14, 95, 64, 2, false),
            (14, 106, 34, 4, true), (14, 114, 92, 2, false), (14, 119, 92, 2, false), (14, 124, 92, 2, false), (14, 129, 92, 2, false), (14, 134, 52, 2, false),
        ],
        "report" =>
        [
            (14, 30, 28, 3, false), (14, 38, 68, 7, true),
            (14, 58, 92, 2, false), (14, 63, 92, 2, false), (14, 68, 92, 2, false), (14, 73, 70, 2, false),
            (14, 84, 46, 4, true), (14, 92, 92, 2, false), (14, 97, 92, 2, false), (14, 102, 92, 2, false), (14, 107, 92, 2, false), (14, 112, 40, 2, false),
            (14, 122, 92, 2, false), (14, 127, 92, 2, false), (14, 132, 60, 2, false),
        ],
        "beamer" =>
        [
            (12, 10, 72, 6, true),
            (18, 28, 3, 3, true), (26, 28, 90, 3, false), (18, 38, 3, 3, true), (26, 38, 74, 3, false),
            (18, 48, 3, 3, true), (26, 48, 98, 3, false), (18, 58, 3, 3, true), (26, 58, 60, 3, false),
        ],
        _ => [],
    };

    void Draw()
    {
        Children.Clear();
        foreach (var (x, y, w, h, head) in Bars(Kind))
        {
            var bar = new Rectangle
            {
                Width = w,
                Height = h,
                RadiusX = 1,
                RadiusY = 1,
                Style = (Style)Application.Current.Resources[head ? "PreviewHeadStyle" : "PreviewBarStyle"],
            };
            SetLeft(bar, x);
            SetTop(bar, y);
            Children.Add(bar);
        }
    }
}
