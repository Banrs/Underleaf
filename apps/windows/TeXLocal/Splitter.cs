using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace TeXLocal;

/// <summary>
/// A draggable divider between two columns of a Grid, resizing one of them:
/// the one before it (the sidebar) or the one after it (the PDF). WinUI has
/// no splitter of its own.
/// </summary>
internal sealed partial class Splitter : Grid
{
    private readonly ColumnDefinition target;
    private readonly bool targetIsBefore;
    private readonly double minimum;
    private double startX;
    private double startWidth;

    public Splitter(ColumnDefinition target, bool targetIsBefore, double minimum)
    {
        this.target = target;
        this.targetIsBefore = targetIsBefore;
        this.minimum = minimum;
        Width = 6;
        // Transparent, not null: an element with no background is not hit-tested.
        Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += (_, e) => ReleasePointerCapture(e.Pointer);
    }

    /// <summary>Raised as the column is dragged, with its new width.</summary>
    public event Action<double>? Resized;

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        startX = e.GetCurrentPoint(null).Position.X;
        startWidth = target.ActualWidth;
        CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (PointerCaptures is not { Count: > 0 })
        {
            return;
        }
        var delta = e.GetCurrentPoint(null).Position.X - startX;
        var width = Math.Max(minimum, startWidth + (targetIsBefore ? delta : -delta));
        target.Width = new GridLength(width);
        Resized?.Invoke(width);
    }
}
