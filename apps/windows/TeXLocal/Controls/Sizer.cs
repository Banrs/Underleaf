using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace TeXLocal.Controls;

/// A splitter: drag or arrow keys raise Delta, and the caller clamps the size; Released says when to save it.
public sealed partial class Sizer : Grid
{
    double? from;

    public Orientation Orientation { get; set; } = Orientation.Vertical;
    public event Action<double>? Delta;
    public event Action? Released;

    public Sizer()
    {
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetHelpText(this, "Use the arrow keys to resize");
        Loaded += (_, _) =>
        {
            var vertical = Orientation == Orientation.Vertical;
            if (vertical) Width = 8; else Height = 8;
            ProtectedCursor = InputSystemCursor.Create(vertical ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.SizeNorthSouth);
        };
        PointerPressed += (_, e) => { from = Along(e.GetCurrentPoint(null).Position); CapturePointer(e.Pointer); };
        PointerMoved += (_, e) =>
        {
            if (from is not { } start) return;
            var at = Along(e.GetCurrentPoint(null).Position);
            Delta?.Invoke(at - start);
            from = at;
        };
        PointerReleased += (_, e) => { End(); ReleasePointerCapture(e.Pointer); };
        PointerCaptureLost += (_, _) => End();
        KeyDown += (_, e) =>
        {
            var step = e.Key is VirtualKey.Left or VirtualKey.Up ? -12 : e.Key is VirtualKey.Right or VirtualKey.Down ? 12 : 0;
            if (step == 0) return;
            Delta?.Invoke(step);
            Released?.Invoke();
            e.Handled = true;
        };

        void End()
        {
            if (from is null) return;
            from = null;
            Released?.Invoke();
        }
    }

    double Along(Windows.Foundation.Point p) => Orientation == Orientation.Vertical ? p.X : p.Y;
}
