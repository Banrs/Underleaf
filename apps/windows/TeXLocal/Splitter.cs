using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;

namespace TeXLocal;

/// <summary>
/// A divider resizing the Grid column or row (or SplitView pane) before or
/// after it, by dragging or with the arrow keys; WinUI has none. It takes no
/// room: an 8 px grip overhangs both panes, over an optional 1 px line.
/// </summary>
internal sealed partial class Splitter : ContentControl
{
    private const double KeyStep = 16;
    private const double Grip = 8;

    private readonly Func<double> actual;
    private readonly Action<double> set;
    private readonly bool vertical;
    private readonly bool targetIsBefore;
    private readonly double minimum;
    private readonly Func<double> maximum;
    private double start;
    private double startLength;

    /// <summary>Between two columns; the maximum is asked for on each move, as the room can change.</summary>
    public Splitter(ColumnDefinition target, bool targetIsBefore, double minimum, Func<double> maximum, string name, bool line = true)
        : this(() => target.ActualWidth, w => target.Width = new GridLength(w), targetIsBefore, minimum, maximum, name, line)
    {
    }

    /// <summary>Between two rows.</summary>
    public Splitter(RowDefinition target, bool targetIsBefore, double minimum, Func<double> maximum, string name, bool line = true)
        : this(() => target.ActualHeight, h => target.Height = new GridLength(h), targetIsBefore, minimum, maximum, name, line, vertical: true)
    {
    }

    /// <summary>Beside a SplitView's pane, resizing it through <paramref name="set"/>.</summary>
    public Splitter(Func<double> actual, Action<double> set, bool targetIsBefore, double minimum, Func<double> maximum, string name,
        bool line = true, bool vertical = false)
    {
        this.actual = actual;
        this.set = set;
        this.vertical = vertical;
        this.targetIsBefore = targetIsBefore;
        this.minimum = minimum;
        this.maximum = maximum;
        // NaN is the unset length.
        Width = vertical ? double.NaN : Grip;
        Height = vertical ? Grip : double.NaN;
        Margin = vertical ? new Thickness(0, -Grip / 2, 0, -Grip / 2) : new Thickness(-Grip / 2, 0, -Grip / 2, 0);
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        // Transparent, not null: an element with no background is not hit-tested.
        var grip = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        if (line)
        {
            // Styled, so the line follows the theme of the window it is in.
            grip.Children.Add(new Rectangle
            {
                Style = (Style)Application.Current.Resources["SplitterRuleStyle"],
                Width = vertical ? double.NaN : 1,
                Height = vertical ? 1 : double.NaN,
            });
        }
        Content = grip;
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetName(this, name);
        AutomationProperties.SetHelpText(this, vertical
            ? "Use the up and down arrow keys to resize"
            : "Use the left and right arrow keys to resize");
        ProtectedCursor = InputSystemCursor.Create(vertical ? InputSystemCursorShape.SizeNorthSouth : InputSystemCursorShape.SizeWestEast);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += OnReleased;
        KeyDown += OnKeyDown;
        KeyUp += OnKeyUp;
    }

    /// <summary>Raised as the column or row is resized, with its new length.</summary>
    public event Action<double>? Resized;

    /// <summary>Raised when a drag or an arrow-key resize ends: the length to remember.</summary>
    public event Action? Committed;

    private void Resize(double length)
    {
        length = Math.Clamp(length, minimum, Math.Max(minimum, maximum()));
        set(length);
        Resized?.Invoke(length);
    }

    private double Position(PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(null).Position;
        return vertical ? point.Y : point.X;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        start = Position(e);
        startLength = actual();
        CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (PointerCaptures is not { Count: > 0 })
        {
            return;
        }
        var delta = Position(e) - start;
        Resize(startLength + (targetIsBefore ? delta : -delta));
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (PointerCaptures is { Count: > 0 })
        {
            ReleasePointerCapture(e.Pointer);
            Committed?.Invoke();
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down)
        {
            Committed?.Invoke();
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Right (or down) moves the divider right (or down), whichever side it resizes.
        var step = (e.Key, vertical) switch
        {
            (VirtualKey.Left, false) or (VirtualKey.Up, true) => -KeyStep,
            (VirtualKey.Right, false) or (VirtualKey.Down, true) => KeyStep,
            _ => 0,
        };
        if (step != 0)
        {
            e.Handled = true;
            Resize(actual() + (targetIsBefore ? step : -step));
        }
    }
}
