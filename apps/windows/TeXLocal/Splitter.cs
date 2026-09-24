using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// A divider between two columns of a Grid, resizing one of them — the one
/// before it (the sidebar) or the one after it (the PDF) — by dragging, or
/// with the arrow keys once it has focus. WinUI has no splitter of its own.
/// </summary>
internal sealed partial class Splitter : ContentControl
{
    private const double KeyStep = 16;

    private readonly ColumnDefinition target;
    private readonly bool targetIsBefore;
    private readonly double minimum;
    private double startX;
    private double startWidth;

    public Splitter(ColumnDefinition target, bool targetIsBefore, double minimum, string name)
    {
        this.target = target;
        this.targetIsBefore = targetIsBefore;
        this.minimum = minimum;
        Width = 8;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        // Transparent, not null: an element with no background is not hit-tested.
        Content = new Border { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetName(this, name);
        AutomationProperties.SetHelpText(this, "Use the left and right arrow keys to resize");
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += (_, e) => ReleasePointerCapture(e.Pointer);
        KeyDown += OnKeyDown;
    }

    /// <summary>Raised as the column is resized, with its new width.</summary>
    public event Action<double>? Resized;

    private void Resize(double width)
    {
        width = Math.Max(minimum, width);
        target.Width = new GridLength(width);
        Resized?.Invoke(width);
    }

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
        Resize(startWidth + (targetIsBefore ? delta : -delta));
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Right moves the divider right, whichever side it resizes.
        var step = e.Key switch
        {
            VirtualKey.Left => -KeyStep,
            VirtualKey.Right => KeyStep,
            _ => 0,
        };
        if (step != 0)
        {
            e.Handled = true;
            Resize(target.ActualWidth + (targetIsBefore ? step : -step));
        }
    }
}
