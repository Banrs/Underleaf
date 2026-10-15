using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace TeXLocal.Controls;

/// A splitter: drag or arrow keys raise Delta; the caller clamps the size.
public sealed partial class Sizer : Grid
{
    double? from;

    public Orientation Orientation { get; set; } = Orientation.Vertical;
    public event Action<double>? Delta;

    public Sizer()
    {
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        IsTabStop = true;
        UseSystemFocusVisuals = true;
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
        PointerReleased += (_, e) => { from = null; ReleasePointerCapture(e.Pointer); };
        PointerCaptureLost += (_, _) => from = null;
        KeyDown += (_, e) =>
        {
            var step = e.Key switch
            {
                VirtualKey.Left or VirtualKey.Up => -12,
                VirtualKey.Right or VirtualKey.Down => 12,
                _ => 0,
            };
            if (step == 0) return;
            Delta?.Invoke(step);
            e.Handled = true;
        };
    }

    double Along(Windows.Foundation.Point p) => Orientation == Orientation.Vertical ? p.X : p.Y;
}
