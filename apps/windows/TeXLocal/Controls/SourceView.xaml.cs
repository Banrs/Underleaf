using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using TeXLocal.Bridge;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Storage.Streams;
using Windows.UI;
using Windows.UI.Core;
using VirtualKey = Windows.System.VirtualKey;

namespace TeXLocal.Controls;

public sealed record CompletionRow(Completion Item, int Count, string Glyph)
{
    public string Typed => Item.Label[..Math.Clamp(Count, 0, Item.Label.Length)];
    public string Rest => Item.Label[Math.Clamp(Count, 0, Item.Label.Length)..];
    public bool HasDetail => Item.Detail is not null;
}

/// An issue's label at its line's end, as Visual Studio 2022's inline diagnostics: the message where there is room, then
/// the core's fewer words that keep an undefined command's name, then cut at the tail, and the badge alone where fewer
/// than ten characters would show.
public sealed class IssueMark(IssueLine issue)
{
    const int Least = 10;
    static readonly TextBlock measure = new() { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
    string Whole => (issue.Short.Length > 0 ? issue.Short : issue.Message) + (issue.Others.Length > 0 ? $" +{issue.Others.Length}" : "");
    string Shortest => issue.Compact ?? Whole;
    /// The whole label's width, and the least the shortest takes: whole, or cut to its first ten characters.
    (double Whole, double Shortest)? widths;

    /// The label for this much room after the badge.
    public string Fit(double room)
    {
        static double Width(string text)
        {
            measure.Text = text;
            measure.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            return measure.DesiredSize.Width;
        }
        if (widths is null)
        {
            var cut = Shortest.Length < Least ? double.PositiveInfinity : Width(Shortest[..Least].TrimEnd() + "…");
            widths = (Width(Whole), Math.Min(Width(Shortest), cut));
        }
        var (whole, shortest) = widths.Value;
        return whole <= room ? Whole : shortest <= room ? Shortest : "";
    }

    public string Tip => string.Join("\n", [issue.Message, .. issue.Others]);
    public Style Badge => (Style)Application.Current.Resources[issue.Error ? "CriticalIconInfoBadgeStyle" : "CautionIconInfoBadgeStyle"];
}

public sealed partial class SourceView : UserControl
{
    // RowHeight: ListViewItemMinHeight, for a row not yet laid out. LabelInset: the list's border, padding, glyph and spacing
    // before a label. Badge: an icon InfoBadge's width.
    const int RowHeight = 32, ShownRows = 8, LabelInset = 1 + 12 + 16 + 12, Badge = 16;
    // Asynchronous, so the first text goes in after the layout pass that completes it.
    readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly List<(IssueLine Issue, IssueMark Label, Grid Mark, Polyline[] Squiggles)> marks = [];
    readonly DispatcherQueueTimer partnerTimer;
    readonly Windows.UI.ViewManagement.UISettings system = new();
    Source? source;
    ScrollViewer? scroller;
    bool setting, changed, undoing, restoring, composing, loading, stale, mirroring, reoffer, queued, moved;
    int loads, lastEnd = -1;
    double advance = 8.4;
    (int Start, int End) placed = (-1, -1);
    SourceRange before = new(0, 0);
    Completions? offered;
    /// A drag in the gutter: what it extends, and the line it started on.
    (SourceRange Anchor, SourceRange First)? dragging;
    /// A Ctrl+click's offset until its release.
    int? pressedAt;
    MathPreview? shownMath;
    int? dismissedMath;
    Color[] kinds = [];
    SolidColorBrush numbers = new();
    ElementTheme inked;
    string theme = "overleaf";

    public string? Path { get; set; }
    public string Text { get; private set; } = "";
    public Color Ink { get; private set; }
    public bool AutoPair { get; set; } = true;
    public bool AutoComplete { get; set; } = true;
    public bool LineNumbers { get; set { field = value; Invalidate(false); } } = true;
    public event Action<bool>? Composing;
    /// Once per dispatcher turn, after the edit is mirrored, so the caret's line is the new text's.
    public event Action? CaretMoved;
    public event Action? Scrolled;
    public event Action<IssueLine>? IssueInvoked;
    /// Files dropped on the text, by their absolute paths, and the offset they were dropped at.
    public event Action<string[], int>? FilesDropped;
    /// The first place the project defines a name the reader asked after.
    public event Action<Place>? DefinitionFound;
    /// A label or citation to rename, and the name's rectangle in the view.
    public event Action<Definition, Rect>? RenameAsked;

    /// A file dragged from the navigation pane, by its absolute path: as storage items, the pane's own drop would add it
    /// to the project again.
    public const string FileFormat = "TeXLocal.File";

    RichEditTextDocument Document => Editor.Document;

    public SourceView()
    {
        InitializeComponent();
        partnerTimer = DispatcherQueue.CreateTimer();
        partnerTimer.Interval = TimeSpan.FromSeconds(1);
        partnerTimer.Tick += (_, _) => HidePartner();
        Editor.TextChanging += (_, e) =>
        {
            if (setting || !e.IsContentChanging) return;
            changed = true;
            restoring |= undoing;
        };
        Editor.PreviewKeyDown += OnPreviewKeyDown;
        Editor.TextChanged += (_, _) => OnEdited();
        Editor.SelectionChanged += (_, _) => OnSelectionChanged();
        Editor.Paste += OnPaste;
        Editor.TextCompositionStarted += (_, _) =>
        {
            CloseCompletions();
            Composing?.Invoke(composing = true);
        };
        Editor.TextCompositionEnded += (_, _) =>
        {
            Composing?.Invoke(composing = false);
            NextUndoGroup();
        };
        Editor.GotFocus += (_, _) => PreviewMath();
        Editor.LostFocus += (_, _) =>
        {
            CloseCompletions();
            PreviewMath();
        };
        Editor.SizeChanged += (_, e) =>
        {
            FindBar.Width = Math.Clamp(ActualWidth - 40, 0, 480);
            if (scroller is not null && e.NewSize.Width > 0) ready.TrySetResult();
            Invalidate(false);
        };
        // Applied here even while the view is collapsed; the first file waits for the editor's first layout too.
        Editor.Loaded += (_, _) =>
        {
            Editor.ApplyTemplate();
            // The template's ContentElement, a child of its root Grid.
            if (scroller is not null || VisualTreeHelper.GetChild(Editor, 0) is not Panel root
                || root.Children.OfType<ScrollViewer>().FirstOrDefault() is not { } found) return;
            scroller = found;
            scroller.ViewChanged += (_, _) =>
            {
                CloseCompletions();
                Invalidate(false);
                Scrolled?.Invoke();
            };
            if (Editor.ActualWidth > 0) ready.TrySetResult();
        };
        // Handled ones too, so a drag RichEdit answers for itself still reaches FilesDropped.
        AddHandler(DragOverEvent, new DragEventHandler(OnDragOver), true);
        AddHandler(DropEvent, new DragEventHandler(OnDrop), true);
        // RichEdit marks its presses and releases handled.
        Editor.AddHandler(PointerPressedEvent, new PointerEventHandler(OnPressed), true);
        Editor.AddHandler(PointerReleasedEvent, new PointerEventHandler(OnReleased), true);
        SizeChanged += (_, e) => Clip = new RectangleGeometry { Rect = new(0, 0, e.NewSize.Width, e.NewSize.Height) };
        ActualThemeChanged += (_, _) => Recolour(true);
        Loaded += (_, _) =>
        {
            system.ColorValuesChanged += OnColoursChanged;
            Recolour(ActualTheme != inked);
        };
        Unloaded += (_, _) => system.ColorValuesChanged -= OnColoursChanged;
    }

    /// Off the UI thread. A switch into, out of or between high-contrast themes may raise no ActualThemeChanged; kinds are
    /// none in high contrast.
    void OnColoursChanged(Windows.UI.ViewManagement.UISettings sender, object? args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (kinds.Length == 0 || new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast) Recolour(true);
    });

    public void SetLook(string family, double size, string themeId)
    {
        var font = new FontFamily($"{family}, Cascadia Mono, Consolas");
        if (Editor.FontFamily.Source == font.Source && Editor.FontSize == size && theme == themeId) return;
        (Editor.FontFamily, Editor.FontSize, theme) = (font, size, themeId);
        // The rows' container style sets Segoe, so the editor's font goes there rather than on the list.
        CompletionList.ItemContainerStyle = new Style(typeof(ListViewItem))
        {
            BasedOn = (Style)Resources["CompletionItemStyle"],
            Setters = { new Setter(FontFamilyProperty, font) },
        };
        var digits = new TextBlock { FontFamily = font, FontSize = size, Text = "0000000000" };
        digits.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        advance = digits.DesiredSize.Width / 10;
        Recolour(true);
    }

    /// RichEdit drops colours given off screen (the page cached under Settings) or before it has
    /// laid out again, so a theme change recolours once the editor is back and drawn.
    void Recolour(bool now)
    {
        stale |= now;
        if (stale && IsLoaded) DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, async () =>
        {
            if (!stale || !IsLoaded || source is null || loading) return;
            var at = CaretOffset;
            await SetText(Text);
            Document.Selection.SetRange(at, at);
        });
    }

    internal static Color Fill(Rectangle r) => ((SolidColorBrush)r.Fill).Color;

    /// Opaque, as RichEdit needs, and raised by the core to the text's contrast on the paper and the current line.
    Color Legible(Rectangle ink) => Opaque(Source.SyntaxCall<double[]>("legible",
        new { color = Rgba(Fill(ink)), background = Rgba(Fill(PaperInk)), fill = Rgba(Fill(CurrentLine)) })!);

    /// None in high contrast, where every kind is drawn in the window's text colour.
    public static Color[] SyntaxColors(string theme, bool dark, Color paper, Color line, Color secondary)
    {
        var colours = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? null
            : Source.SyntaxCall<double[][]>("theme_colors", new
            {
                theme,
                dark,
                background = Rgba(paper),
                fill = Rgba(line),
                system = new Dictionary<string, double[]> { ["secondaryLabelColor"] = Rgba(secondary) },
            });
        return [.. (colours ?? []).Select(Opaque)];
    }

    public static double[] Rgba(Color c) => [c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0];

    /// The core composites what it answers over the paper.
    static Color Opaque(double[] c)
    {
        static byte Byte(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        return Color.FromArgb(255, Byte(c[0]), Byte(c[1]), Byte(c[2]));
    }

    /// RichEdit drops the text's colours if it gets them before its template is applied and it has
    /// been laid out, so the first file waits for both.
    public async Task Show(string path, Source src)
    {
        await ready.Task;
        scroller!.ChangeView(0, 0, null, true);
        await Swap(path, src, src.Text);
    }

    public void Clear() => _ = Swap(null, null, "");

    Task Swap(string? path, Source? src, string text)
    {
        source?.Dispose();
        (Path, source) = (path, src);
        SetIssues([]);
        return SetText(text);
    }

    public async void Reload(string content)
    {
        var (line, column) = Caret;
        source!.Reload(content);
        await SetText(content);
        if (source is null) return;
        line = Math.Min(line, source.LineCount);
        var at = Math.Min(source.LineStart(line) + column, End(line));
        Document.Selection.SetRange(at, at);
    }

    /// Shows text with no edit and no undo history, coloured whole, so later colouring is only an
    /// edit's own, inside that edit's undo group. RichEdit lays out all it is given at once, so the
    /// first 200 lines go in first and the rest after that frame.
    async Task SetText(string content)
    {
        var generation = ++loads;
        CloseCompletions();
        HidePartner();
        (shownMath, dismissedMath) = (null, null);
        MathPopup.IsOpen = false;
        source?.Call<bool>("end_snippet", new { });
        Document.EndUndoGroup();
        (Ink, numbers, inked, stale) = (Legible(TextInk), new SolidColorBrush(Legible(NumberInk)), ActualTheme, !IsLoaded);
        kinds = SyntaxColors(theme, ActualTheme == ElementTheme.Dark, Fill(PaperInk), Fill(CurrentLine), Fill(SecondaryInk));
        var split = source is { LineCount: > 200 } s ? s.LineStart(201) : content.Length;
        setting = true;
        Document.SetText(TextSetOptions.FormatRtf, Rtf(content, 0, split));
        setting = changed = restoring = false;
        Text = content[..split];
        if (split < content.Length)
        {
            loading = true;
            var shown = new TaskCompletionSource();
            void Drawn(object? sender, object e)
            {
                CompositionTarget.Rendering -= Drawn;
                DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, shown.SetResult);
            }
            CompositionTarget.Rendering += Drawn;
            await shown.Task;
            if (generation != loads) return;
            loading = false;
            setting = true;
            Document.GetRange(Text.Length, Text.Length).SetText(TextSetOptions.FormatRtf, Rtf(content, split, content.Length));
            setting = false;
            Text += content[split..];
        }
        Document.ClearUndoRedoHistory();
        Document.BeginUndoGroup();
        before = Selected;
        Invalidate();
    }

    string Rtf(string content, int from, int to)
    {
        var rtf = new StringBuilder(@"{\rtf1\ansi{\colortbl;");
        foreach (var c in kinds.Append(Ink)) rtf.Append($@"\red{c.R}\green{c.G}\blue{c.B};");
        // Plain text in the ink, not RichEdit's automatic colour, which follows the control's state.
        rtf.Append($@"}}\cf{kinds.Length + 1} ");
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

    [LibraryImport("user32.dll")]
    private static unsafe partial int ToUnicodeEx(uint key, uint scan, byte* state, char* buffer, int size, uint flags, nint layout);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool GetKeyboardState(byte* state);

    [LibraryImport("user32.dll")]
    private static partial nint GetKeyboardLayout(uint thread);

    /// Flag 4 leaves a dead key's state alone.
    static unsafe string? Typed(KeyRoutedEventArgs e)
    {
        var state = stackalloc byte[256];
        var buffer = stackalloc char[8];
        if (!GetKeyboardState(state)) return null;
        var count = ToUnicodeEx((uint)e.Key, e.KeyStatus.ScanCode, state, buffer, 8, 4, GetKeyboardLayout(0));
        if (count <= 0) return null;
        var typed = new string(buffer, 0, count);
        return typed.Any(char.IsControl) ? null : typed;
    }

    internal static bool Down(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        bool ctrl = Down(VirtualKey.Control), alt = Down(VirtualKey.Menu), shift = Down(VirtualKey.Shift), plain = !ctrl && !alt;
        if (ctrl && !alt && e.Key is VirtualKey.Z or VirtualKey.Y)
        {
            if (e.Key == VirtualKey.Z && !shift) Undo();
            else Redo();
        }
        else if (source is null || composing) return;
        else if (ctrl && !alt && !shift && e.Key == VirtualKey.Space) Complete(true);
        else if (alt && !ctrl && !shift && e.Key is VirtualKey.Up or VirtualKey.Down) MoveLines(e.Key == VirtualKey.Up);
        else if (ctrl && !alt && !shift && e.Key == VirtualKey.D) ChangeLines("duplicate_lines");
        else if (ctrl && !alt && shift && e.Key == VirtualKey.K) ChangeLines("delete_lines");
        // Ctrl+] and Ctrl+[: the keys of ] and [ on a US layout (VK_OEM_6, VK_OEM_4), as Visual Studio reads them.
        else if (ctrl && !alt && !shift && (int)e.Key is 219 or 221) ShiftLines((int)e.Key == 221 ? 1 : -1);
        else
        {
            e.Handled = offered is not null && plain && Completing(e.Key)
                || plain && !shift && e.Key == VirtualKey.Escape && Escape()
                || plain && e.Key == VirtualKey.Enter && Newline()
                || plain && !shift && e.Key == VirtualKey.Back && DeleteBackward()
                || plain && e.Key == VirtualKey.Tab && Tab(shift ? -1 : 1)
                || ctrl == alt && Typed(e) is { } typed && Type(typed);
            return;
        }
        e.Handled = true;
    }

    SourceRange Selected => new(Document.Selection.StartPosition, Document.Selection.EndPosition - Document.Selection.StartPosition);

    /// The selection the core asked for, which is no reason to close the list.
    void Place(SourceRange r)
    {
        placed = (r.Start, r.End);
        Document.Selection.SetRange(r.Start, r.End);
        Document.Selection.ScrollIntoView(PointOptions.None);
    }

    void Put(int start, int length, string inserted)
    {
        setting = true;
        Document.GetRange(start, start + length).SetText(TextSetOptions.None, inserted);
        setting = false;
        Mirror(start, length, inserted, true);
    }

    /// What's typed in a snippet's field goes in its other places too.
    void Mirror(int start, int removed, string inserted, bool colour)
    {
        var mirrors = source!.Edit(start, removed, inserted, mirroring);
        Text = string.Concat(Text.AsSpan(0, start), inserted, Text.AsSpan(start + removed));
        lastEnd = start + inserted.Length;
        if (colour) Colour(source.LineAt(start), source.LineAt(start + inserted.Length));
        if (mirrors is not { Length: > 0 }) return;
        // The typing stays where it was, moved only by copies put in before it.
        var (from, to, end) = (Document.Selection.StartPosition, Document.Selection.EndPosition, lastEnd);
        mirroring = true;
        foreach (var edit in mirrors)
        {
            Put(edit.Start, edit.Length, edit.Text);
            var delta = edit.Text.Length - edit.Length;
            if (edit.Start + edit.Length <= from) (from, to) = (from + delta, to + delta);
            if (edit.Start + edit.Length <= end) end += delta;
        }
        mirroring = false;
        Document.Selection.SetRange(from, to);
        lastEnd = end;
    }

    bool Apply(Change? change)
    {
        if (change is not { Edits.Length: > 0 }) return false;
        NextUndoGroup();
        foreach (var edit in change.Edits.Reverse()) Put(edit.Start, edit.Length, edit.Text);
        if (change.Selections is [var first, ..]) Place(first);
        NextUndoGroup();
        Invalidate();
        return true;
    }

    /// Edits in the text's order, as one undo step, with the selection moved by them.
    bool Apply(TextEdit[]? edits) => edits is { Length: > 0 } && Apply(new Change(edits,
        source!.Call<SourceRange[]>("map_selections", new { edits, selections = new[] { Selected } }) ?? []));

    /// A replace's or rename's edits of the open document, at once as one undo step; not into another file shown meanwhile,
    /// or this one typed in since, whose offsets they aren't. RichEdit's own edit, not yet mirrored, is typing too.
    public void Apply(DocumentEdits? edits)
    {
        if (changed) OnEdited();
        if (edits is not null && edits.Path == Path && edits.Version == source?.Call<ulong?>("version", new { })) Apply(edits.Edits);
    }

    /// One edit as an undo step, with the caret after it unless the selection is given.
    bool Apply(TextEdit edit, SourceRange? selection = null) =>
        Apply(new Change([edit], [selection ?? new(edit.Start + edit.Text.Length, 0)]));

    /// The insertion, then its snippet's first field selected.
    void Insert(Insertion? insertion)
    {
        if (insertion is null) return;
        Apply(insertion.Edit, new(insertion.Caret, 0));
        var snippet = new { fields = insertion.Fields, at = insertion.Edit.Start };
        if (source!.Call<SourceRange>("start_snippet", snippet) is { } first) Place(first);
    }

    /// A word's letters are one undo step.
    static bool EndsWord(string typed) => typed.Length != 1 || !char.IsLetterOrDigit(typed[0]);

    bool Type(string typed)
    {
        var at = Selected;
        var stroke = source!.Call<Keystroke>("type", new { selection = at, text = typed, autoPair = AutoPair });
        if (stroke?.Edit is { } edit) Put(edit.Start, edit.Length, edit.Text);
        else if (stroke?.Selection is null) Put(at.Start, at.Length, typed);
        Place(stroke?.Selection ?? new SourceRange(lastEnd, 0));
        if (EndsWord(typed)) NextUndoGroup();
        Finish(stroke);
        Invalidate();
        return true;
    }

    void Finish(Keystroke? stroke)
    {
        if (stroke?.Partner is { } partner) ShowPartner(partner);
        if (stroke?.Completions == "offer" && (AutoComplete || offered is not null)) Complete(false);
        else if (stroke?.Completions == "close") CloseCompletions();
    }

    bool Newline()
    {
        if (source!.Call<Keystroke>("insert_newline", new { selection = Selected }) is not { Edit: { } edit } stroke) return false;
        Apply(edit, stroke.Selection);
        Finish(stroke);
        return true;
    }

    bool DeleteBackward()
    {
        var completing = offered is not null;
        if (source!.Call<Keystroke>("delete_backward", new { selection = Selected, autoPair = AutoPair }) is not { Edit: { } edit })
        {
            reoffer = completing;
            return false;
        }
        Apply(edit);
        if (completing) Complete(false);
        else CloseCompletions();
        return true;
    }

    bool Tab(int step)
    {
        var answer = source!.Call<Tabbing>("tab", new { selections = new[] { Selected }, step });
        if (answer?.Field is { } field) Place(field);
        else Apply(answer?.Edits);
        return true;
    }

    bool Escape()
    {
        if (source!.Call<bool>("end_snippet", new { })) return true;
        if (shownMath is not null && MathPopup.IsOpen)
        {
            dismissedMath = shownMath.Start;
            MathPopup.IsOpen = false;
        }
        else if (FindShown) HideFind();
        else return false;
        return true;
    }

    /// Shift right and Shift left: the lines, even from within a snippet's field, which Tab would leave for the next.
    public void ShiftLines(int step) => Command(() =>
    {
        source!.Call<bool>("end_snippet", new { });
        Tab(step);
    });

    public bool MoveLines(bool up) => Apply(source?.Call<Change>("move_lines", new { selections = new[] { Selected }, up }));

    public bool ChangeLines(string command) => Apply(source?.Call<Change>(command, new { selections = new[] { Selected } }));

    public void ToggleComment() => Command(() => Apply(source!.Call<TextEdit[]>("toggle_comment", new { selections = new[] { Selected } })));

    public void ToggleStyle(string style) => Command(() => Apply(source!.Call<Change>("toggle_style", new { selections = new[] { Selected }, style })));

    public void Wrap(string template, bool complete = false) => Command(() =>
    {
        var empty = Selected.Length == 0;
        Apply(source!.Call<Change>("wrap", new { selections = new[] { Selected }, template }));
        if (complete && empty) DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => Complete(true));
    });

    public void SetHeading(string command) => Command(() => Insert(source!.Call<Insertion>("set_heading", new { caret = CaretOffset, command })));

    public void InsertSymbol(string command) => Command(() => Insert(source!.Call<Insertion>("insert_symbol", new { command, selection = Selected })));

    public void InsertBlock(string id) => Command(() => Insert(source!.Call<Insertion>("insert_block", new { id, selection = Selected })));

    public TextStyles Styles => source?.Call<TextStyles>("text_styles", new { selection = Selected }) ?? new(null, null, null);

    void Command(Action action)
    {
        if (source is null) return;
        action();
        Editor.Focus(FocusState.Programmatic);
    }

    /// RichEdit moves the selection while an edit of ours goes in and before its own edit is mirrored; the core hears
    /// the selection once the text is the document's.
    void OnSelectionChanged()
    {
        if (setting) return;
        if (!changed && CaretOffset != lastEnd) NextUndoGroup();
        var s = Selected;
        if (!changed)
        {
            before = s;
            if (source is not null && !loading) source.Select(s, mirroring);
        }
        if ((s.Start, s.End) != placed)
        {
            placed = (-1, -1);
            CloseCompletions();
            HidePartner();
        }
        Invalidate();
    }

    void ShowPartner(int at)
    {
        if (at < 0 || at >= Text.Length || source!.Call<int?>("partner", new { at }) is not { } match
            || RectOf(match, match + 1) is not { } r) return;
        (PartnerBox.Width, PartnerBox.Height) = (Math.Max(r.Width, 4) + 2, r.Height);
        Canvas.SetLeft(PartnerBox, r.X - 1);
        Canvas.SetTop(PartnerBox, r.Y);
        PartnerBox.Opacity = 1;
        partnerTimer.Stop();
        partnerTimer.Start();
    }

    void HidePartner()
    {
        partnerTimer.Stop();
        PartnerBox.Opacity = 0;
    }

    void Complete(bool explicitly)
    {
        var s = Selected;
        if (source is null || s.Length > 0 || composing
            || source.Call<Completions>("completions", new { caret = s.Start, @explicit = explicitly }) is not { Items.Length: > 0 } found
            || RectOf(found.Start, found.Start) is not { } at)
        {
            CloseCompletions();
            return;
        }
        offered = found;
        var glyph = found.Kind switch
        {
            "environment" => "\uE8FD",
            "label" => "\uE8EC",
            "citation" => "\uE8F1",
            "entryType" => "\uE8A5",
            "file" => "\uE7C3",
            _ => "\uE943",
        };
        CompletionList.ItemsSource = found.Items.Select(i => new CompletionRow(i, s.Start - found.Start, glyph)).ToList();
        CompletionList.SelectedIndex = 0;
        // Near the text's left edge the list reaches over the gutter, so its labels still line up with the typed text.
        CompletionPopup.HorizontalOffset = Math.Max(-Gutter.ActualWidth, at.X - LabelInset);
        // Laid out open, before it is drawn, so a row is measured: text scaling makes rows taller.
        CompletionPopup.IsOpen = true;
        CompletionList.UpdateLayout();
        var row = CompletionList.ContainerFromIndex(0) is FrameworkElement { ActualHeight: > 0 } shown ? shown.ActualHeight : RowHeight;
        CompletionList.MaxHeight = ShownRows * row;
        // The surface's padding and border are the 10 past the rows; above the line when there's no room below.
        var height = Math.Min(found.Items.Length, ShownRows) * row + 10;
        CompletionPopup.VerticalOffset = at.Bottom + 4 + height <= ActualHeight || at.Y - height - 4 < 0 ? at.Bottom + 4 : at.Y - height - 4;
        Announce(found.Items[0]);
    }

    void CloseCompletions()
    {
        if (offered is null) return;
        offered = null;
        CompletionPopup.IsOpen = false;
        CompletionList.ItemsSource = null;
    }

    bool Completing(VirtualKey key)
    {
        var count = offered!.Items.Length;
        var step = key switch
        {
            VirtualKey.Up => -1,
            VirtualKey.Down => 1,
            VirtualKey.PageUp => 1 - ShownRows,
            VirtualKey.PageDown => ShownRows - 1,
            _ => 0,
        };
        if (step != 0)
        {
            var i = CompletionList.SelectedIndex + step;
            CompletionList.SelectedIndex = Math.Abs(step) == 1 ? (i + count) % count : Math.Clamp(i, 0, count - 1);
            CompletionList.ScrollIntoView(CompletionList.SelectedItem);
            Announce(offered.Items[CompletionList.SelectedIndex]);
            return true;
        }
        if (key is VirtualKey.Enter or VirtualKey.Tab) Accept(CompletionList.SelectedIndex);
        else if (key == VirtualKey.Escape) CloseCompletions();
        else return false;
        return true;
    }

    void OnCompletionClick(object sender, ItemClickEventArgs e)
    {
        Accept(Array.IndexOf(offered!.Items, ((CompletionRow)e.ClickedItem).Item));
        Editor.Focus(FocusState.Programmatic);
    }

    void Accept(int index)
    {
        var (o, caret) = (offered!, CaretOffset);
        CloseCompletions();
        if (caret < o.Start) return;
        var item = o.Items[index];
        Insert(new Insertion(new(o.Start, caret - o.Start, item.Text), o.Start + item.Text.Length, item.Fields));
    }

    /// The list never has the keyboard, so Narrator hears the chosen item, and its detail, from the editor.
    void Announce(Completion item)
    {
        var peer = FrameworkElementAutomationPeer.FromElement(Editor) ?? FrameworkElementAutomationPeer.CreatePeerForElement(Editor);
        peer.RaiseNotificationEvent(AutomationNotificationKind.ItemAdded, AutomationNotificationProcessing.MostRecent,
            item.Detail is { } detail ? $"{item.Label}, {detail}" : item.Label, "completion");
    }

    async void PreviewMath()
    {
        var maths = source is null || loading || Selected.Length > 0 ? null : source.Call<MathPreview>("math_at", new { caret = CaretOffset });
        if (maths?.Start != dismissedMath) dismissedMath = null;
        if (maths is null || dismissedMath is not null || Editor.FocusState == FocusState.Unfocused)
        {
            shownMath = null;
            MathPopup.IsOpen = false;
            return;
        }
        var caret = CaretOffset;
        if (RectOf(source!.LineStart(source.LineAt(caret)), caret) is not { } line || RectOf(caret, caret) is not { } at
            || line.Y < Editor.Padding.Top || line.Bottom > ActualHeight)
        {
            MathPopup.IsOpen = false;
            return;
        }
        if (maths != shownMath)
        {
            shownMath = maths;
            var size = Editor.FontSize * 1.21;
            var color = Rgba(Ink);
            var drawn = await Task.Run(() => Source.SyntaxCall<MathSvg>("math_svg", new { tex = maths.Tex, display = maths.Display, size, color }));
            if (shownMath != maths) return;
            await ShowMaths(drawn);
            if (shownMath != maths) return;
        }
        MathSurface.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var (w, h) = (MathSurface.DesiredSize.Width, MathSurface.DesiredSize.Height);
        MathPopup.HorizontalOffset = Math.Clamp(at.X - w / 2, 0, Math.Max(0, Editor.ActualWidth - w - 16));
        MathPopup.VerticalOffset = line.Y - h - 8 >= Editor.Padding.Top ? line.Y - h - 8 : line.Bottom + 8;
        MathPopup.IsOpen = true;
    }

    async Task ShowMaths(MathSvg? drawn)
    {
        MathImage.Source = null;
        if (drawn is { Svg: { } svg, Width: > 0, Height: > 0 })
        {
            var scale = XamlRoot?.RasterizationScale ?? 1;
            var widest = Math.Min(drawn.Width, 640);
            var (width, height) = (widest, drawn.Height * widest / drawn.Width);
            var image = new SvgImageSource { RasterizePixelWidth = width * scale, RasterizePixelHeight = height * scale };
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(Encoding.UTF8.GetBytes(svg).AsBuffer());
            stream.Seek(0);
            if (await image.SetSourceAsync(stream) == SvgImageSourceLoadStatus.Success)
            {
                (MathImage.Width, MathImage.Height, MathImage.Source) = (width, height, image);
                (MathImage.Visibility, MathError.Visibility) = (Visibility.Visible, Visibility.Collapsed);
                return;
            }
        }
        MathErrorText.Text = drawn?.Error ?? "Can't draw this maths.";
        (MathImage.Visibility, MathError.Visibility) = (Visibility.Collapsed, Visibility.Visible);
    }

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

    int CaretOffset => Document.Selection.Options.HasFlag(SelectionOptions.StartActive) ? Document.Selection.StartPosition : Document.Selection.EndPosition;

    public int LineCount => source?.LineCount ?? 1;

    /// The line at the view's top, in view in part or whole; once a file shows.
    public int TopLine => source!.LineAt(Document.GetRangeFromPoint(new Point(0, scroller!.VerticalOffset), PointOptions.ClientCoordinates).StartPosition);

    public void GoTo(int line, int column = 0, int length = 0)
    {
        line = Math.Clamp(line, 1, source!.LineCount);
        var at = Math.Min(source.LineStart(line) + column, End(line));
        Document.Selection.SetRange(at, Math.Min(at + length, End(line)));
        Document.Selection.ScrollIntoView(PointOptions.None);
        Editor.Focus(FocusState.Programmatic);
    }

    /// Where a flyout for the text opens: below the caret's row, never over it.
    public Rect CaretRect => RectOf(CaretOffset, CaretOffset) is { } r
        ? new Rect(Gutter.ActualWidth + r.X, r.Y, Math.Max(0, Editor.ActualWidth - r.X), r.Height)
        : new Rect(Gutter.ActualWidth + 16, 0, 0, 16);

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

    /// Once the view has laid out again.
    public void ScrollToCaret() => DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => Document.Selection.ScrollIntoView(PointOptions.None));

    public void Cut() => Document.Selection.Cut();
    public void Copy() => Document.Selection.Copy();
    public void Paste() => OnPaste(Editor, null);
    public new void Focus(FocusState state) => Editor.Focus(state);

    async void OnPaste(object sender, TextControlPasteEventArgs? e)
    {
        if (e is not null) e.Handled = true;
        var content = Clipboard.GetContent();
        if (source is null || !content.Contains(StandardDataFormats.Text)) return;
        var pasted = (await content.GetTextAsync()).Replace("\r\n", "\n").Replace('\r', '\n');
        var at = Selected;
        Apply(new TextEdit(at.Start, at.Length, pasted));
    }

    static bool HasFiles(DataPackageView data) => data.Contains(StandardDataFormats.StorageItems) || data.Contains(FileFormat);

    void OnDragOver(object sender, DragEventArgs e)
    {
        if (source is null || !HasFiles(e.DataView)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.Handled = true;
    }

    /// The offset is read before the paths, while the drop's point holds.
    async void OnDrop(object sender, DragEventArgs e)
    {
        if (source is null || !HasFiles(e.DataView)) return;
        e.Handled = true;
        var at = OffsetAt(e.GetPosition(Editor));
        var deferral = e.GetDeferral();
        var paths = e.DataView.Contains(FileFormat) ? new[] { await e.DataView.GetDataAsync(FileFormat) as string ?? "" }
            : (await e.DataView.GetStorageItemsAsync()).Select(i => i.Path).ToArray();
        deferral.Complete();
        FilesDropped?.Invoke(paths, at);
    }

    /// The text's offset at a point of the editor's: RichEdit's points are the scrolled text's, inside its padding.
    int OffsetAt(Point p) => Document.GetRangeFromPoint(new Point(Math.Max(0, p.X - Editor.Padding.Left + scroller!.HorizontalOffset),
        Math.Max(0, p.Y - Editor.Padding.Top + scroller.VerticalOffset)), PointOptions.ClientCoordinates).StartPosition;

    /// Ctrl+click, Visual Studio's and VS Code's Go to definition, taken on a release where it was pressed, as VS Code
    /// does: a selection made during the press would follow RichEdit's drag from it.
    void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(Editor);
        pressedAt = e.KeyModifiers == Windows.System.VirtualKeyModifiers.Control && point.Properties.IsLeftButtonPressed ? OffsetAt(point.Position) : null;
    }

    void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (pressedAt is { } at && OffsetAt(e.GetCurrentPoint(Editor).Position) == at) Define(at);
        pressedAt = null;
    }

    /// F12, at the caret.
    public void GoToDefinition() => Define(CaretOffset);

    /// The first of the places, as Visual Studio goes with one; where nothing is defined, nothing changes.
    void Define(int at)
    {
        if (DefinitionAt(at) is { Places: [var first, ..] }) DefinitionFound?.Invoke(first);
    }

    Definition? DefinitionAt(int at) => source?.Call<Definition>("definition", new { at });

    /// F2, VS Code's Rename Symbol: only a label or a citation, the names the core renames, its box under the name.
    public void RenameSymbol()
    {
        var caret = CaretOffset;
        if (DefinitionAt(caret) is not { Kind: "label" or "citation" } symbol) return;
        // The name the caret is in or just after: the first that starts no further back than its length.
        var start = Text.IndexOf(symbol.Name, Math.Max(0, caret - symbol.Name.Length), StringComparison.Ordinal);
        if (RectOf(start, start + symbol.Name.Length) is { } r)
            RenameAsked?.Invoke(symbol, new Rect(Gutter.ActualWidth + r.X, r.Y, r.Width, r.Height));
    }

    /// Visual Studio's Go to definition and VS Code's Rename Symbol after the text commands, which the menu makes again
    /// each time it opens.
    void OnContextOpening(object sender, object e)
    {
        var commands = ((TextCommandBarFlyout)sender).SecondaryCommands;
        var defined = DefinitionAt(CaretOffset);
        void Add(string label, string key, bool enabled, Action invoked)
        {
            var item = new AppBarButton { Label = label, KeyboardAcceleratorTextOverride = key, IsEnabled = enabled };
            // Once the menu has closed and handed the editor its focus back, so the rename box keeps the keys.
            item.Click += (_, _) => DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => invoked());
            commands.Add(item);
        }
        commands.Add(new AppBarSeparator());
        Add("Go to definition", "F12", defined is { Places.Length: > 0 }, GoToDefinition);
        Add("Rename symbol", "F2", defined is { Kind: "label" or "citation" }, RenameSymbol);
    }

    /// A dropped file's text, put in where it was dropped and selected, as on the Mac. Not Drop, UIElement's event.
    public void InsertDropped(int at, string text) =>
        Command(() => Apply(new TextEdit(at, 0, text), new(at, text.Length)));

    int End(int line) => line < source!.LineCount ? source.LineStart(line + 1) - 1 : Text.Length;

    /// Input methods, Delete, Cut, undo, drops: what changed, read from the text. The selection before it tells where
    /// in a run of the same characters the change was.
    void OnEdited()
    {
        if (!changed || source is null) return;
        var restored = restoring;
        changed = restoring = false;
        Document.GetText(TextGetOptions.UseLf, out var now);
        var (start, removed, inserted) = Diff(now);
        if (removed > 0 || inserted.Length > 0)
        {
            Mirror(start, removed, inserted, !restored);
            if (!restored && (removed > 0 || EndsWord(inserted))) NextUndoGroup();
        }
        before = Selected;
        source.Select(before, mirroring);
        if (reoffer)
        {
            reoffer = false;
            Complete(false);
        }
        Invalidate();
    }

    (int Start, int Removed, string Inserted) Diff(string now)
    {
        bool Fits(int start, int removed)
        {
            var inserted = now.Length - Text.Length + removed;
            return start >= 0 && removed >= 0 && inserted >= 0 && start + removed <= Text.Length
                && Text.AsSpan(0, start).SequenceEqual(now.AsSpan(0, start))
                && Text.AsSpan(start + removed).SequenceEqual(now.AsSpan(start + inserted));
        }
        (int, int, string) At(int start, int removed) => (start, removed, now.Substring(start, now.Length - Text.Length + removed));
        var shorter = Text.Length - now.Length;
        if (Fits(before.Start, before.Length)) return At(before.Start, before.Length);
        if (before.Length == 0 && shorter > 0 && Fits(before.Start - shorter, shorter)) return At(before.Start - shorter, shorter);
        var head = Text.AsSpan().CommonPrefixLength(now);
        var tail = 0;
        var most = Math.Min(Text.Length, now.Length) - head;
        while (tail < most && Text[^(tail + 1)] == now[^(tail + 1)]) tail++;
        return At(head, Text.Length - head - tail);
    }

    Color? InkOf(int kind) => kind >= 0 && kind < kinds.Length ? kinds[kind] : null;

    void Colour(int first, int last)
    {
        int a = source!.LineStart(first), b = End(last);
        setting = true;
        Document.BatchDisplayUpdates();
        Document.GetRange(a, b).CharacterFormat.ForegroundColor = Ink;
        foreach (var run in source.Highlights(a, Math.Max(b - a, 0)))
            if (InkOf(run.Kind) is { } c) Document.GetRange(run.Start, run.Start + run.Length).CharacterFormat.ForegroundColor = c;
        Document.ApplyDisplayUpdates();
        setting = false;
    }

    /// A range's rectangle in the view's coordinates (RichEdit's are the scrolled text's); null before it's laid out.
    Rect? RectOf(int start, int end)
    {
        Document.GetRange(start, end).GetRect(PointOptions.None, out var r, out _);
        return r.IsEmpty || !(r.Height >= 0) || scroller is null ? null
            : new Rect(r.X + Editor.Padding.Left - scroller.HorizontalOffset, r.Y + Editor.Padding.Top - scroller.VerticalOffset, Math.Max(r.Width, 0), r.Height);
    }

    /// The line under the pointer with its line break, scrolled to where the pointer is past the text's edge.
    SourceRange LineUnder(PointerRoutedEventArgs e)
    {
        var y = e.GetCurrentPoint(Editor).Position.Y;
        var at = Document.GetRangeFromPoint(new Point(0, Math.Max(0, y - Editor.Padding.Top + scroller!.VerticalOffset)), PointOptions.ClientCoordinates);
        if (y < Editor.Padding.Top || y > Editor.ActualHeight - Editor.Padding.Bottom) at.ScrollIntoView(PointOptions.None);
        var line = source!.LineAt(at.StartPosition);
        var start = source.LineStart(line);
        return new(start, (line < source.LineCount ? source.LineStart(line + 1) : Text.Length) - start);
    }

    /// The Mac's gutter: a press selects its line, a drag the lines it crosses, Shift extends the selection to them.
    void OnGutterPressed(object sender, PointerRoutedEventArgs e)
    {
        if (source is null || !e.GetCurrentPoint(Gutter).Properties.IsLeftButtonPressed) return;
        var first = LineUnder(e);
        dragging = (Down(VirtualKey.Shift) ? Selected : first, first);
        Gutter.CapturePointer(e.Pointer);
        Editor.Focus(FocusState.Pointer);
        OnGutterMoved(sender, e);
        e.Handled = true;
    }

    void OnGutterMoved(object sender, PointerRoutedEventArgs e)
    {
        if (dragging is not { Anchor: var anchor }) return;
        var line = LineUnder(e);
        Document.Selection.SetRange(Math.Min(anchor.Start, line.Start), Math.Max(anchor.End, line.End));
    }

    /// A press that selected only its line opens that line's issue, as a click on its box does.
    void OnGutterReleased(object sender, PointerRoutedEventArgs e)
    {
        if (dragging is not { First: var first }) return;
        Gutter.ReleasePointerCapture(e.Pointer);
        dragging = null;
        var line = source!.LineAt(first.Start);
        if (Selected == first && marks.Where(m => m.Issue.Line == line).Select(m => m.Issue).FirstOrDefault() is { } issue) IssueInvoked?.Invoke(issue);
    }

    void OnGutterCaptureLost(object sender, PointerRoutedEventArgs e) => dragging = null;

    /// One refresh, CaretMoved and maths preview per dispatcher turn. RichEdit can raise TextChanged after
    /// SelectionChanged, so an edit of its own is mirrored first.
    void Invalidate(bool caret = true)
    {
        moved |= caret;
        if (queued) return;
        queued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (changed) OnEdited();
            queued = false;
            Refresh();
            if (moved)
            {
                moved = false;
                CaretMoved?.Invoke();
            }
            PreviewMath();
        });
    }

    void Refresh()
    {
        var shown = source is not null && scroller is not null;
        Gutter.Visibility = Backdrop.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;
        var y = scroller!.VerticalOffset;
        var first = TopLine;
        var last = source!.LineAt(Document.GetRangeFromPoint(new Point(Editor.ActualWidth, y + Editor.ActualHeight), PointOptions.ClientCoordinates).StartPosition);
        var caret = source.LineAt(CaretOffset);
        Gutter.Width = LineNumbers ? Math.Ceiling(16 + Math.Max(3, source.LineCount.ToString().Length) * advance + 8) : 16;
        // Only beside the text's viewport, so nothing shows in the find bar's band.
        var view = new Rect(0, Editor.Padding.Top, Gutter.Width + Editor.ActualWidth, Math.Max(0, Editor.ActualHeight - Editor.Padding.Top - Editor.Padding.Bottom));
        foreach (var layer in (UIElement[])[Gutter, Backdrop, Overlay]) layer.Clip = new RectangleGeometry { Rect = view };

        var used = 0;
        for (var line = first; LineNumbers && line <= last; line++)
        {
            if (RectOf(source.LineStart(line), source.LineStart(line)) is not { } r) continue;
            if (used == Gutter.Children.Count)
            {
                var added = new TextBlock { TextAlignment = TextAlignment.Right };
                AutomationProperties.SetAccessibilityView(added, AccessibilityView.Raw);
                Gutter.Children.Add(added);
            }
            // The editor's font and size at the line's top: the number sits on the text's baseline.
            var number = (TextBlock)Gutter.Children[used++];
            (number.FontFamily, number.FontSize, number.Width) = (Editor.FontFamily, Editor.FontSize, Gutter.Width - 8);
            (number.Text, number.Foreground) = (line.ToString(), line == caret ? TextInk.Fill : numbers);
            number.Visibility = Visibility.Visible;
            Canvas.SetTop(number, r.Y);
        }
        for (var i = used; i < Gutter.Children.Count; i++) Gutter.Children[i].Visibility = Visibility.Collapsed;

        if (RectOf(source.LineStart(caret), End(caret)) is { } current)
        {
            (CurrentLine.Width, CurrentLine.Height) = (Backdrop.ActualWidth, current.Height);
            Canvas.SetTop(CurrentLine, current.Y);
        }

        var right = Overlay.ActualWidth - Editor.Padding.Right;
        foreach (var (issue, label, mark, squiggles) in marks)
        {
            var seen = issue.Line >= first && issue.Line <= last;
            var start = seen ? source.LineStart(issue.Line) : 0;
            for (var i = 0; i < squiggles.Length; i++)
            {
                var token = seen ? RectOf(start + issue.Tokens[i].Start, start + issue.Tokens[i].End) : null;
                squiggles[i].Visibility = token is null ? Visibility.Collapsed : Visibility.Visible;
                if (token is not { } t) continue;
                Squiggle(squiggles[i].Points, t.Width);
                Canvas.SetLeft(squiggles[i], t.X);
                // In the line's descent, under the baseline, as Visual Studio draws it.
                Canvas.SetTop(squiggles[i], t.Bottom - 3);
            }
            var end = seen ? RectOf(End(issue.Line), End(issue.Line)) : null;
            var x = (end?.X ?? 0) + 16;
            if (end is not { } r || right - x < Badge)
            {
                mark.Visibility = Visibility.Collapsed;
                continue;
            }
            mark.Visibility = Visibility.Visible;
            // The template's label, past its badge and spacing.
            ((TextBlock)mark.Children[1]).Text = label.Fit(right - x - Badge - 8);
            (mark.MaxWidth, mark.Height) = (right - x, r.Height);
            Canvas.SetLeft(mark, x);
            Canvas.SetTop(mark, r.Y);
        }
    }

    /// A zigzag 2 px deep every 4 px, redrawn only when the token's width changes.
    static void Squiggle(PointCollection points, double width)
    {
        if (points.Count > 0 && points[points.Count - 1].X == width) return;
        points.Clear();
        for (var x = 0.0; x < width; x += 2) points.Add(new Point(x, x % 4));
        points.Add(new Point(width, 2 - Math.Abs(width % 4 - 2)));
    }

    public void SetIssues(IssueLine[] lines)
    {
        foreach (var (_, _, mark, squiggles) in marks)
            foreach (var shown in (FrameworkElement[])[mark, .. squiggles]) Overlay.Children.Remove(shown);
        marks.Clear();
        foreach (var issue in lines)
        {
            var label = new IssueMark(issue);
            var mark = (Grid)((DataTemplate)Resources["IssueTemplate"]).LoadContent();
            (mark.DataContext, mark.Visibility) = (label, Visibility.Collapsed);
            mark.Tapped += (_, _) => IssueInvoked?.Invoke(issue);
            var style = (Style)Resources[issue.Error ? "ErrorSquiggleStyle" : "WarningSquiggleStyle"];
            Polyline[] squiggles = [.. issue.Tokens.Select(_ => new Polyline { Style = style, Visibility = Visibility.Collapsed })];
            foreach (var shown in (FrameworkElement[])[mark, .. squiggles]) Overlay.Children.Add(shown);
            marks.Add((issue, label, mark, squiggles));
        }
        Invalidate(false);
    }
}
