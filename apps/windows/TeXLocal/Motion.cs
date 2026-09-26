using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.UI.ViewManagement;

namespace TeXLocal;

/// <summary>
/// Motion from the Windows animation library. Its theme transitions play
/// only as an element joins the tree, and the app's screens and panes are
/// shown and hidden, so the matching theme animations are started as they
/// come into view instead: drill in and out between screens, as Settings and
/// File Explorer move through a hierarchy; pop in for a pane, from its edge.
/// Nothing moves when Windows' animation effects are off.
/// </summary>
internal static class Motion
{
    private static readonly UISettings Settings = new();

    /// <summary>Shows or hides <paramref name="element"/>, playing <paramref name="entrance"/> as it comes into view.</summary>
    internal static void Show(UIElement element, bool visible, Func<UIElement, Timeline> entrance)
    {
        var appearing = visible && element.Visibility == Visibility.Collapsed;
        element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (appearing && Settings.AnimationsEnabled)
        {
            var story = new Storyboard();
            story.Children.Add(entrance(element));
            story.Begin();
        }
    }

    /// <summary>A screen deeper in the app: the library to a project, either to Settings.</summary>
    internal static Timeline DrillIn(UIElement screen) => new DrillInThemeAnimation { EntranceTarget = screen };

    /// <summary>Back up the hierarchy.</summary>
    internal static Timeline DrillOut(UIElement screen) => new DrillOutThemeAnimation { EntranceTarget = screen };

    /// <summary>A pane coming in from the edge it's docked to, (x, y) away.</summary>
    internal static Func<UIElement, Timeline> Pane(double x, double y) => pane =>
    {
        var pop = new PopInThemeAnimation { FromHorizontalOffset = x, FromVerticalOffset = y };
        Storyboard.SetTarget(pop, pane);
        return pop;
    };

    /// <summary>A part of a pane that stands in for another, as search results for the trees.</summary>
    internal static Timeline FadeIn(UIElement element)
    {
        var fade = new FadeInThemeAnimation();
        Storyboard.SetTarget(fade, element);
        return fade;
    }
}
