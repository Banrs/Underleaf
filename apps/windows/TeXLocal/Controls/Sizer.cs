using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace TeXLocal.Controls;

/// The gap between two layers, as a splitter: drag or arrow keys raise Delta, and the caller clamps the size; Released
/// says when to save it. A grip shows in the gap under the pointer, while dragging and with keyboard focus, as the
/// toolkit's GridSplitter and Outlook's pane gaps show theirs.
public sealed partial class Sizer : Grid
{
    readonly Border grip = new() { Style = (Style)Application.Current.Resources["SizerGripStyle"], Opacity = 0 };
    double? from;
    bool over;

    public Orientation Orientation { get; set; } = Orientation.Vertical;
    /// The size it sets, as UI Automation reads it.
    public Func<string>? Spoken { get; set; }
    public event Action<double>? Delta;
    public event Action? Released;

    public Sizer()
    {
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        Children.Add(grip);
        AutomationProperties.SetHelpText(this, "Use the arrow keys to resize");
        Loaded += (_, _) =>
        {
            var vertical = Orientation == Orientation.Vertical;
            if (vertical) Width = 8; else Height = 8;
            (grip.Width, grip.Height) = vertical ? (4, 24) : (24, 4);
            ProtectedCursor = InputSystemCursor.Create(vertical ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.SizeNorthSouth);
        };
        PointerEntered += (_, _) => Show(over = true);
        PointerExited += (_, _) => Show(over = false);
        GotFocus += (_, _) => Show(true);
        LostFocus += (_, _) => Show(over);
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
            var was = Spoken?.Invoke() ?? "";
            Delta?.Invoke(step);
            Released?.Invoke();
            FrameworkElementAutomationPeer.FromElement(this)?.RaisePropertyChangedEvent(ValuePatternIdentifiers.ValueProperty, was, Spoken?.Invoke() ?? "");
            e.Handled = true;
        };

        void End()
        {
            if (from is null) return;
            from = null;
            Show(over);
            Released?.Invoke();
        }
    }

    void Show(bool shown) => grip.Opacity = shown || from is not null ? 1 : 0;

    double Along(Windows.Foundation.Point p) => Orientation == Orientation.Vertical ? p.X : p.Y;

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    /// A thumb, as WPF's GridSplitter is to UI Automation, whose value is the size it sets.
    sealed partial class Peer(Sizer owner) : FrameworkElementAutomationPeer(owner), IValueProvider
    {
        public bool IsReadOnly => true;
        public string Value => ((Sizer)Owner).Spoken?.Invoke() ?? "";
        public void SetValue(string value) => throw new InvalidOperationException("The arrow keys resize it.");

        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Thumb;
        protected override string GetClassNameCore() => nameof(Sizer);
        protected override object GetPatternCore(PatternInterface patternInterface) =>
            patternInterface == PatternInterface.Value ? this : base.GetPatternCore(patternInterface);
    }
}
