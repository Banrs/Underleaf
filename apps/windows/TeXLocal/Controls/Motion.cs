using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Windows.UI.ViewManagement;

namespace TeXLocal.Controls;

/// Fluent's motion for what the app shows and hides itself, and the layers' rounded clip. Entrances decelerate from a
/// short offset over 250 ms (ControlNormalAnimationDuration, ControlFastOutSlowInKeySpline); exits accelerate over
/// 167 ms; neither runs while Windows' animation effects are off.
public static class Motion
{
    static readonly UISettings settings = new();

    public static bool Enabled => settings.AnimationsEnabled;

    /// Animates an element in and out as its Visibility changes: it slides from `x`, `y` and fades. Its own
    /// Translation (a shadow's elevation) stays.
    public static void Reveal(UIElement element, float x = 0, float y = 0)
    {
        if (!Enabled) return;
        var c = ElementCompositionPreview.GetElementVisual(element).Compositor;
        var (rest, away) = (element.Translation, element.Translation + new Vector3(x, y, 0));
        ElementCompositionPreview.SetIsTranslationEnabled(element, true);
        ElementCompositionPreview.SetImplicitShowAnimation(element, Move(c, away, rest, 0, 1, 250, c.CreateCubicBezierEasingFunction(new(0, 0), new(0, 1))));
        ElementCompositionPreview.SetImplicitHideAnimation(element, Move(c, rest, away, 1, 0, 167, c.CreateCubicBezierEasingFunction(new(0.7f, 0), new(1, 0.5f))));
    }

    static CompositionAnimationGroup Move(Compositor c, Vector3 from, Vector3 to, float fade, float into, int ms, CompositionEasingFunction ease)
    {
        var duration = TimeSpan.FromMilliseconds(ms);
        var move = c.CreateVector3KeyFrameAnimation();
        (move.Target, move.Duration) = ("Translation", duration);
        move.InsertKeyFrame(0, from);
        move.InsertKeyFrame(1, to, ease);
        var opacity = c.CreateScalarKeyFrameAnimation();
        (opacity.Target, opacity.Duration) = ("Opacity", duration);
        opacity.InsertKeyFrame(0, fade);
        opacity.InsertKeyFrame(1, into, ease);
        var group = c.CreateAnimationGroup();
        group.Add(move);
        group.Add(opacity);
        return group;
    }

    /// Clips an element to its rounded corners, as a layer's content scrolls under them.
    public static void Round(FrameworkElement element, float radius)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        var shape = visual.Compositor.CreateRoundedRectangleGeometry();
        shape.CornerRadius = new(radius, radius);
        visual.Clip = visual.Compositor.CreateGeometricClip(shape);
        element.SizeChanged += (_, e) => shape.Size = new((float)e.NewSize.Width, (float)e.NewSize.Height);
    }
}
