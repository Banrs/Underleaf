using System.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TeXLocal.Bridge;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;

namespace TeXLocal.Controls;

/// The source editor: a RichEditBox whose text and highlighting are the session document's.
public sealed partial class SourceView : UserControl
{
    readonly TaskCompletionSource ready = new();
    readonly List<TextBlock> numbers = [];
    readonly List<(IssueLine Issue, Border Box)> boxes = [];
    Source? source;
    ScrollViewer? scroller;
    string text = "";
    bool setting, changed, undoing, restoring, composing, loading, stale;
    int loads, lastEnd = -1;
    Color ink;
    Color[] kinds = [];
    ElementTheme inked;

    public string? Path { get; private set; }
    public event Action<bool>? Composing;
    public event Action? CaretMoved;
    public event Action<IssueLine>? IssueInvoked;

    RichEditTextDocument Document => Editor.Document;

    public SourceView()
    {
        InitializeComponent();
        Editor.TextChanging += (_, e) =>
        {
            if (setting || !e.IsContentChanging) return;
            changed = true;
            restoring |= undoing;
        };
        Editor.PreviewKeyDown += OnPreviewKeyDown;
        Editor.TextChanged += (_, _) => OnEdited();
        Editor.SelectionChanged += (_, _) =>
        {
            if (!changed && CaretOffset != lastEnd) NextUndoGroup();
            Refresh();
            CaretMoved?.Invoke();
        };
        Editor.Paste += OnPaste;
        Editor.TextCompositionStarted += (_, _) => Composing?.Invoke(composing = true);
        Editor.TextCompositionEnded += (_, _) =>
        {
            composing = false;
            Composing?.Invoke(false);
            NextUndoGroup();
        };
        Editor.SizeChanged += (_, _) => Refresh();
        SizeChanged += (_, e) => Clip = new RectangleGeometry { Rect = new(0, 0, e.NewSize.Width, e.NewSize.Height) };
        Editor.LayoutUpdated += (_, _) =>
        {
            if (scroller is not null || Descendant<ScrollViewer>(Editor) is not { } found) return;
            scroller = found;
            ready.TrySetResult();
            scroller.ViewChanged += (_, _) => Refresh();
            Refresh();
        };
        ActualThemeChanged += (_, _) =>
        {
            stale = true;
            if (IsLoaded) Recolour();
        };
        Loaded += (_, _) =>
        {
            stale |= ActualTheme != inked;
            if (stale) Recolour();
        };
    }

    /// RichEdit drops colours given off screen (the page cached under Settings) or before it has
    /// laid out again, so a theme change recolours once the editor is back and drawn.
    void Recolour() => DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, async () =>
    {
        if (!stale || !IsLoaded || source is null || loading) return;
        stale = false;
        var at = CaretOffset;
        await SetText(text);
        Document.Selection.SetRange(at, at);
    });

    static T? Descendant<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T found) return found;
            if (Descendant<T>(child) is { } deeper) return deeper;
        }
        return null;
    }

    /// RichEdit ignores alpha, so a translucent ink is laid over the theme's base background first.
    Color Of(Rectangle r)
    {
        var (c, under) = (((SolidColorBrush)r.Fill).Color, ((SolidColorBrush)PaperInk.Fill).Color);
        byte Mix(byte a, byte b) => (byte)((a * c.A + b * (255 - c.A)) / 255);
        return Color.FromArgb(255, Mix(c.R, under.R), Mix(c.G, under.G), Mix(c.B, under.B));
    }

    /// The core's Overleaf theme raised to legibility on this background and current line, by
    /// highlight kind; a high-contrast theme keeps every kind in the window text colour.
    void Inks()
    {
        ink = Of(TextInk);
        inked = ActualTheme;
        static double[] Rgba(Color c) => [c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0];
        static byte Byte(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        var colours = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? null
            : Source.SyntaxCall<double[][]>("theme_colors", new
            {
                theme = "overleaf",
                dark = ActualTheme == ElementTheme.Dark,
                background = Rgba(((SolidColorBrush)PaperInk.Fill).Color),
                fill = Rgba(((SolidColorBrush)CurrentLine.Fill).Color),
            });
        kinds = [.. (colours ?? []).Select(c => Color.FromArgb(255, Byte(c[0]), Byte(c[1]), Byte(c[2])))];
    }

    /// Completes once the whole text is in. RichEdit drops the text's colours if it gets them before
    /// its template is applied, so the first file waits for that.
    public async Task Show(string path, string content, Source src)
    {
        await ready.Task;
        source?.Dispose();
        (Path, source) = (path, src);
        var lf = content.Replace("\r\n", "\n").Replace('\r', '\n');
        if (lf != content) src.Reload(lf);
        SetIssues([]);
        scroller?.ChangeView(0, 0, null, true);
        await SetText(lf);
    }

    public void Rename(string path) => Path = path;

    public void Clear()
    {
        source?.Dispose();
        (Path, source) = (null, null);
        _ = SetText("");
        SetIssues([]);
    }

    public async void Reload(string content)
    {
        if (source is null) return;
        var (line, column) = Caret;
        source.Reload(content);
        await SetText(content);
        line = Math.Min(line, source.LineCount);
        var at = Math.Min(source.LineStart(line) + column, End(line));
        Document.Selection.SetRange(at, at);
        Refresh();
    }

    /// Shows text with no edit and no undo history, coloured whole, so later colouring is only an
    /// edit's own, inside that edit's undo group. RichEdit lays out all it is given at once, so the
    /// first 200 lines go in first and the rest after that frame.
    async Task SetText(string content)
    {
        var generation = ++loads;
        Document.EndUndoGroup();
        Inks();
        var split = source is { LineCount: > 200 } s ? s.LineStart(201) : content.Length;
        setting = true;
        Document.SetText(TextSetOptions.FormatRtf, Rtf(content, 0, split));
        setting = changed = restoring = false;
        text = content[..split];
        if (split < content.Length)
        {
            loading = true;
            var shown = new TaskCompletionSource();
            void Drawn(object? sender, object e)
            {
                CompositionTarget.Rendering -= Drawn;
                DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, shown.SetResult);
            }
            CompositionTarget.Rendering += Drawn;
            await shown.Task;
            if (generation != loads) return;
            loading = false;
            setting = true;
            Document.GetRange(text.Length, text.Length).SetText(TextSetOptions.FormatRtf, Rtf(content, split, content.Length));
            setting = false;
            text += content[split..];
        }
        Document.ClearUndoRedoHistory();
        Document.BeginUndoGroup();
        Refresh();
    }

    /// Part of the text as RTF with its colours.
    string Rtf(string content, int from, int to)
    {
        var rtf = new StringBuilder(to - from + (to - from) / 4 + 128);
        rtf.Append(@"{\rtf1\ansi{\colortbl;");
        foreach (var c in kinds) rtf.Append($@"\red{c.R}\green{c.G}\blue{c.B};");
        rtf.Append('}');
        var at = from;
        foreach (var run in source?.Highlights(from, to - from) ?? [])
        {
            if (InkOf(run.Kind) is null || run.Start < at || run.Start + run.Length > to) continue;
            Escape(rtf, content.AsSpan(at, run.Start - at));
            rtf.Append($@"{{\cf{run.Kind + 1} ");
            Escape(rtf, content.AsSpan(run.Start, run.Length));
            rtf.Append('}');
            at = run.Start + run.Length;
        }
        Escape(rtf, content.AsSpan(at, to - at));
        return rtf.Append('}').ToString();
    }

    static void Escape(StringBuilder rtf, ReadOnlySpan<char> text)
    {
        foreach (var c in text)
            _ = c switch
            {
                '\\' or '{' or '}' => rtf.Append('\\').Append(c),
                '\n' => rtf.Append(@"\par "),
                '\t' => rtf.Append(@"\tab "),
                > (char)126 or < ' ' => rtf.Append(@"\u").Append((short)c).Append('?'),
                _ => rtf.Append(c),
            };
    }

    void NextUndoGroup()
    {
        if (composing) return;
        Document.EndUndoGroup();
        Document.BeginUndoGroup();
    }

    void OnPreviewKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        static bool Down(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
        if (!Down(VirtualKey.Control) || Down(VirtualKey.Menu)) return;
        var shift = Down(VirtualKey.Shift);
        if (e.Key == VirtualKey.Z && !shift) Undo();
        else if (e.Key == VirtualKey.Y && !shift || e.Key == VirtualKey.Z && shift) Redo();
        else return;
        e.Handled = true;
    }

    /// The caret's line (from 1) and column (UTF-16, from 0).
    public (int Line, int Column) Caret
    {
        get
        {
            if (source is null) return (1, 0);
            var at = CaretOffset;
            var line = source.LineAt(at);
            return (line, at - source.LineStart(line));
        }
    }

    public int CaretOffset
    {
        get
        {
            var s = Document.Selection;
            return s.Options.HasFlag(SelectionOptions.StartActive) ? s.StartPosition : s.EndPosition;
        }
    }

    public int LineCount => source?.LineCount ?? 1;

    public void GoTo(int line, int column = 0)
    {
        if (source is null) return;
        line = Math.Clamp(line, 1, source.LineCount);
        var at = Math.Min(source.LineStart(line) + column, End(line));
        Document.Selection.SetRange(at, at);
        Document.Selection.ScrollIntoView(PointOptions.None);
        Editor.Focus(FocusState.Programmatic);
    }

    /// RichEdit restores an edit's colours with its text, so undo and redo colour nothing: colouring
    /// would be a new action and clear the redo stack.
    public void Undo() => Restore(Document.Undo);
    public void Redo() => Restore(Document.Redo);

    void Restore(Action action)
    {
        Document.EndUndoGroup();
        undoing = true;
        action();
        undoing = false;
        Document.BeginUndoGroup();
    }

    /// After the view shrinks (the issues panel opening), once it has laid out.
    public void ScrollToCaret() => DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => Document.Selection.ScrollIntoView(PointOptions.None));

    public void Cut() => Document.Selection.Cut();
    public void Copy() => Document.Selection.Copy();
    public void Paste() => OnPaste(Editor, null);
    public new void Focus(FocusState state) => Editor.Focus(state);

    async void OnPaste(object sender, TextControlPasteEventArgs? e)
    {
        if (e is not null) e.Handled = true;
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text)) return;
        var pasted = (await content.GetTextAsync()).Replace("\r\n", "\n");
        Document.Selection.SetText(TextSetOptions.None, pasted);
        Document.Selection.Collapse(false);
    }

    int End(int line) => line < source!.LineCount ? source.LineStart(line + 1) - 1 : text.Length;

    void OnEdited()
    {
        if (!changed || source is null) return;
        var restored = restoring;
        changed = restoring = false;
        Document.GetText(TextGetOptions.UseLf, out var now);
        var start = text.AsSpan().CommonPrefixLength(now);
        var tail = 0;
        var most = Math.Min(text.Length, now.Length) - start;
        while (tail < most && text[^(tail + 1)] == now[^(tail + 1)]) tail++;
        var removed = text.Length - start - tail;
        var inserted = now.Substring(start, now.Length - start - tail);
        if (removed == 0 && inserted.Length == 0) return;
        source.Edit(start, removed, inserted);
        text = now;
        lastEnd = start + inserted.Length;
        if (!restored)
        {
            Colour(source.LineAt(start), source.LineAt(start + inserted.Length));
            if (removed > 0 || inserted.Length != 1 || !char.IsLetterOrDigit(inserted[0])) NextUndoGroup();
        }
        Refresh();
    }

    Color? InkOf(int kind) => kind >= 0 && kind < kinds.Length ? kinds[kind] : null;

    void Colour(int first, int last)
    {
        int a = source!.LineStart(first), b = End(last);
        var runs = source.Highlights(a, Math.Max(b - a, 0));
        Document.BatchDisplayUpdates();
        Document.GetRange(a, b).CharacterFormat.ForegroundColor = ink;
        foreach (var run in runs)
            if (InkOf(run.Kind) is { } c) Document.GetRange(run.Start, run.Start + run.Length).CharacterFormat.ForegroundColor = c;
        Document.ApplyDisplayUpdates();
    }

    Rect RectOf(int start, int end)
    {
        Document.GetRange(start, end).GetRect(PointOptions.None, out var r, out _);
        return Shown(r);
    }

    /// RichEdit's rectangles are in the scrolled text's coordinates; these are the view's.
    Rect Shown(Rect r) => r.IsEmpty || !(r.Height >= 0) ? new(0, -10000, 0, 0) : new(r.X + Editor.Padding.Left - scroller!.HorizontalOffset, r.Y + Editor.Padding.Top - scroller.VerticalOffset, Math.Max(r.Width, 0), r.Height);

    (int First, int Last) VisibleLines()
    {
        var y = scroller!.VerticalOffset;
        var top = Document.GetRangeFromPoint(new Point(0, y), PointOptions.ClientCoordinates).StartPosition;
        var bottom = Document.GetRangeFromPoint(new Point(Editor.ActualWidth, y + Editor.ActualHeight), PointOptions.ClientCoordinates).StartPosition;
        return (source!.LineAt(top), source.LineAt(bottom));
    }

    void Refresh()
    {
        if (source is null || scroller is null)
        {
            Gutter.Visibility = Backdrop.Visibility = Visibility.Collapsed;
            return;
        }
        Gutter.Visibility = Backdrop.Visibility = Visibility.Visible;
        var (first, last) = VisibleLines();
        var digits = Math.Max(3, source.LineCount.ToString().Length);
        Gutter.Width = 16 + 8 * digits;
        var caret = source.LineAt(CaretOffset);
        var used = 0;
        for (var line = first; line <= last; line++)
        {
            var r = RectOf(source.LineStart(line), source.LineStart(line));
            if (used == numbers.Count)
            {
                numbers.Add(new TextBlock());
                Gutter.Children.Add(numbers[used]);
            }
            var number = numbers[used++];
            number.Style = (Style)Resources[line == caret ? "CurrentNumberStyle" : "NumberStyle"];
            number.Text = line.ToString();
            number.Width = Gutter.Width - 12;
            number.Visibility = Visibility.Visible;
            Canvas.SetTop(number, r.Y + 2);
        }
        for (var i = used; i < numbers.Count; i++) numbers[i].Visibility = Visibility.Collapsed;

        var current = RectOf(source.LineStart(caret), End(caret));
        CurrentLine.Width = Backdrop.ActualWidth;
        CurrentLine.Height = current.Height;
        Canvas.SetTop(CurrentLine, current.Y);

        foreach (var (issue, box) in boxes)
        {
            if (issue.Line < first || issue.Line > last || issue.Line > source.LineCount)
            {
                box.Visibility = Visibility.Collapsed;
                continue;
            }
            var row = Document.GetRange(source.LineStart(issue.Line), source.LineStart(issue.Line));
            row.Expand(TextRangeUnit.Line);
            row.GetRect(PointOptions.None, out var r, out _);
            r = Shown(r);
            var rowEnd = Math.Min(row.EndPosition, End(issue.Line));
            var endRect = RectOf(rowEnd, rowEnd);
            var room = Overlay.ActualWidth - 16;
            var x = Math.Min(endRect.X + 16, room - 48);
            box.Height = r.Height;
            box.MaxWidth = Math.Max(room - x, 48);
            box.Visibility = Visibility.Visible;
            Canvas.SetLeft(box, x);
            Canvas.SetTop(box, r.Y);
        }
    }

    public void SetIssues(IssueLine[] lines)
    {
        boxes.ForEach(b => Overlay.Children.Remove(b.Box));
        boxes.Clear();
        foreach (var issue in lines)
        {
            var box = (Border)((DataTemplate)Resources[issue.Error ? "ErrorBox" : "WarningBox"]).LoadContent();
            var label = (TextBlock)((Grid)box.Child).Children[1];
            label.Text = (issue.Short.Length > 0 ? issue.Short : issue.Message) + (issue.Others.Length > 0 ? $" +{issue.Others.Length}" : "");
            ToolTipService.SetToolTip(box, string.Join("\n", [issue.Message, .. issue.Others]));
            box.Tapped += (_, _) => IssueInvoked?.Invoke(issue);
            Overlay.Children.Add(box);
            boxes.Add((issue, box));
        }
        Refresh();
    }
}
