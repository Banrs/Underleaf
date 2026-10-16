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

/// A completion as the list shows it: what's typed of it in SemiBold.
public sealed class CompletionRow(Completion item, int typed, string glyph)
{
    public Completion Item => item;
    public string Typed => item.Label[..Math.Clamp(typed, 0, item.Label.Length)];
    public string Rest => item.Label[Math.Clamp(typed, 0, item.Label.Length)..];
    public string Glyph => glyph;
}

/// A line's issues at its end, as Visual Studio's inline diagnostics: the first one's badge and short text.
public sealed class IssueMark(IssueLine issue)
{
    public string Label => (issue.Short.Length > 0 ? issue.Short : issue.Message) + (issue.Others.Length > 0 ? $" +{issue.Others.Length}" : "");
    public string Tip => string.Join("\n", [issue.Message, .. issue.Others]);
    public Style Badge => (Style)Application.Current.Resources[issue.Error ? "CriticalIconInfoBadgeStyle" : "CautionIconInfoBadgeStyle"];
}

/// The source editor: a RichEditBox whose text and highlighting are the session document's, and whose typing the core
/// assists (brackets, indentation, snippets, completion) as texlocal-syntax answers it.
public sealed partial class SourceView : UserControl
{
    // The completion list: rows, rows shown, and its labels' inset from its edge (border, padding, glyph, spacing).
    const int RowHeight = 32, ShownRows = 8, LabelInset = 1 + 12 + 16 + 12;
    readonly TaskCompletionSource ready = new();
    readonly List<TextBlock> numbers = [];
    readonly List<(IssueLine Issue, FrameworkElement Mark)> marks = [];
    readonly DispatcherQueueTimer partnerTimer;
    Source? source;
    ScrollViewer? scroller;
    string text = "";
    bool setting, changed, undoing, restoring, composing, loading, stale, mirroring, reoffer, queued, moved;
    int loads, lastEnd = -1, edits;
    double advance = 8.4;
    (int Start, int End) placed = (-1, -1);
    SourceRange before = new(0, 0);
    Completions? offered;
    (int Caret, int Edits, MathPreview? Value)? lastMath;
    MathPreview? shownMath;
    int? dismissedMath;
    Color ink;
    Color[] kinds = [];
    ElementTheme inked;
    string theme = "overleaf";

    public string? Path { get; private set; }
    public string Text => text;
    /// The text colour as drawn, for what is drawn to match it.
    public Color Ink => ink;
    public bool AutoPair { get; set; } = true;
    public bool AutoComplete { get; set; } = true;
    public event Action<bool>? Composing;
    /// Once per dispatcher turn, after the edit is mirrored, so the caret's line is the new text's.
    public event Action? CaretMoved;
    public event Action<IssueLine>? IssueInvoked;

    RichEditTextDocument Document => Editor.Document;

    public SourceView()
    {
        InitializeComponent();
        partnerTimer = DispatcherQueue.CreateTimer();
        partnerTimer.Interval = TimeSpan.FromSeconds(1);
        partnerTimer.Tick += (_, _) => HidePartner();
        if (new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
            PartnerBox.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(250) };
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
            FindBar.Width = Math.Clamp(e.NewSize.Width - 40, 0, 480);
            Invalidate(false);
        };
        // Applied here even while the view is collapsed, so the first file waits only for the template.
        Editor.Loaded += (_, _) =>
        {
            Editor.ApplyTemplate();
            if (scroller is not null || Descendant<ScrollViewer>(Editor) is not { } found) return;
            scroller = found;
            scroller.ViewChanged += (_, _) =>
            {
                CloseCompletions();
                Invalidate(false);
            };
            ready.TrySetResult();
        };
        SizeChanged += (_, e) => Clip = new RectangleGeometry { Rect = new(0, 0, e.NewSize.Width, e.NewSize.Height) };
        ActualThemeChanged += (_, _) => Recolour(true);
        Loaded += (_, _) => Recolour(ActualTheme != inked);
    }

    /// The font, its size and the syntax theme (the core's id); the text is coloured again for them.
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
            await SetText(text);
            Document.Selection.SetRange(at, at);
        });
    }

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

    /// A theme brush's colour as RichEdit can draw it, over the editor's background.
    Color Of(Rectangle r) => Over(((SolidColorBrush)r.Fill).Color, ((SolidColorBrush)PaperInk.Fill).Color);

    /// The theme's colours raised by the core to legibility on this background and current line, by highlight kind.
    /// Text set with them keeps them unless it is set off screen.
    void Inks()
    {
        (ink, inked, stale) = (Of(TextInk), ActualTheme, !IsLoaded);
        kinds =SyntaxColors(theme, ActualTheme == ElementTheme.Dark, ((SolidColorBrush)PaperInk.Fill).Color,
            ((SolidColorBrush)CurrentLine.Fill).Color, Of(SecondaryInk));
    }

    /// A syntax theme's colours by highlight kind, made legible by the core on the editor's paper and current line;
    /// none in a high-contrast theme, which draws every kind in the window text colour. The System theme's secondary
    /// text is Windows' (`secondary`, opaque).
    public static Color[] SyntaxColors(string theme, bool dark, Color paper, Color line, Color secondary)
    {
        static byte Byte(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        var colours = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? null
            : Source.SyntaxCall<double[][]>("theme_colors", new
            {
                theme,
                dark,
                background = Rgba(paper),
                fill = Rgba(line),
                system = new Dictionary<string, double[]> { ["secondaryLabelColor"] = Rgba(secondary) },
            });
        return [.. (colours ?? []).Select(c => Color.FromArgb(255, Byte(c[0]), Byte(c[1]), Byte(c[2])))];
    }

    public static double[] Rgba(Color c) => [c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0];

    /// A translucent colour laid over an opaque one: RichEdit ignores alpha.
    public static Color Over(Color c, Color under)
    {
        byte Mix(byte a, byte b) => (byte)((a * c.A + b * (255 - c.A)) / 255);
        return Color.FromArgb(255, Mix(c.R, under.R), Mix(c.G, under.G), Mix(c.B, under.B));
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
        (lastMath, shownMath, dismissedMath) = (null, null, null);
        MathPopup.IsOpen = false;
        source?.Call("end_snippet", new { });
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
                DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, shown.SetResult);
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
        before = Selected;
        Invalidate();
    }

    /// Part of the text as RTF with its colours.
    string Rtf(string content, int from, int to)
    {
        var rtf = new StringBuilder(to - from + (to - from) / 4 + 128);
        rtf.Append(@"{\rtf1\ansi{\colortbl;");
        foreach (var c in kinds.Append(ink)) rtf.Append($@"\red{c.R}\green{c.G}\blue{c.B};");
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

    // MARK: keys: the core's typing, then RichEdit's

    [LibraryImport("user32.dll")]
    private static unsafe partial int ToUnicodeEx(uint key, uint scan, byte* state, char* buffer, int size, uint flags, nint layout);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool GetKeyboardState(byte* state);

    [LibraryImport("user32.dll")]
    private static partial nint GetKeyboardLayout(uint thread);

    /// The text a key types in the keyboard layout, without disturbing a dead key's state (flag 4); null for a dead key,
    /// a control character or no text.
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

    static bool Down(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

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
        else
        {
            // The first that takes the key; RichEdit has the rest.
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

    static object Range(SourceRange r) => new { start = r.Start, length = r.Length };

    /// The selection the core asked for, which is no reason to close the list.
    void Place(SourceRange r)
    {
        placed = (r.Start, r.End);
        Document.Selection.SetRange(r.Start, r.End);
        Document.Selection.ScrollIntoView(PointOptions.None);
    }

    /// The one write to RichEdit's text: an edit of the core's, into RichEdit and the session's document at once.
    void Put(int start, int length, string inserted)
    {
        setting = true;
        Document.GetRange(start, start + length).SetText(TextSetOptions.None, inserted);
        setting = false;
        Mirror(start, length, inserted, true);
    }

    /// The document takes an edit RichEdit has made; typing's closers and a snippet's fields move with it, and what's
    /// typed in a field goes in its other places.
    void Mirror(int start, int removed, string inserted, bool colour)
    {
        source!.Edit(start, removed, inserted);
        source.Call("follow", new { old = new { start, length = removed }, delta = inserted.Length - removed, mirroring });
        text = string.Concat(text.AsSpan(0, start), inserted, text.AsSpan(start + removed));
        lastEnd = start + inserted.Length;
        edits++;
        if (colour) Colour(source.LineAt(start), source.LineAt(start + inserted.Length));
        if (mirroring || source.Call<TextEdit[]>("mirror_snippet", new { }) is not { Length: > 0 } mirrors) return;
        var (from, to) = (Document.Selection.StartPosition, Document.Selection.EndPosition);
        mirroring = true;
        foreach (var edit in mirrors) Put(edit.Start, edit.Length, edit.Text);
        mirroring = false;
        Document.Selection.SetRange(from, to);
    }

    /// One undo step: the edits from the last, then the first selection after them.
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

    /// The selection follows the edits.
    bool Apply(TextEdit[]? edits) => edits is { Length: > 0 } && Apply(new Change(edits,
        source!.Call<SourceRange[]>("map_selections", new { edits, selections = new[] { Range(Selected) } }) ?? []));

    /// A block or a symbol, then its snippet's first field.
    void Insert(Insertion? insertion)
    {
        if (insertion is null) return;
        Apply(new Change([insertion.Edit], [new(insertion.Caret, 0)]));
        StartSnippet(insertion.Fields, insertion.Edit.Start);
    }

    void StartSnippet(SnippetField[] fields, int at)
    {
        if (source!.Call<SourceRange>("start_snippet", new { fields, at }) is { } first) Place(first);
    }

    /// A word's letters are one undo step; anything else ends it.
    static bool EndsWord(string typed) => typed.Length != 1 || !char.IsLetterOrDigit(typed[0]);

    bool Type(string typed)
    {
        var at = Selected;
        var stroke = source!.Call<Keystroke>("type", new { selection = Range(at), text = typed, autoPair = AutoPair });
        if (stroke?.Edit is { } edit) Put(edit.Start, edit.Length, edit.Text);
        else if (stroke?.Selection is null) Put(at.Start, at.Length, typed);
        Place(stroke?.Selection ?? new SourceRange(lastEnd, 0));
        if (EndsWord(typed)) NextUndoGroup();
        Finish(stroke);
        Invalidate();
        return true;
    }

    /// What follows a key's edit: the bracket's partner and the completion list.
    void Finish(Keystroke? stroke)
    {
        if (stroke?.Partner is { } partner) ShowPartner(partner);
        if (stroke?.Completions == "offer" && (AutoComplete || offered is not null)) Complete(false);
        else if (stroke?.Completions == "close") CloseCompletions();
    }

    /// Return keeps the line's indentation; between an empty pair the closer goes on a line of its own.
    bool Newline()
    {
        if (source!.Call<Keystroke>("insert_newline", new { selection = Range(Selected) }) is not { Edit: { } edit } stroke) return false;
        Apply(new Change([edit], [stroke.Selection ?? new(edit.Start + edit.Text.Length, 0)]));
        Finish(stroke);
        return true;
    }

    /// An empty pair put in for the user goes whole, and indentation back to a stop; otherwise RichEdit deletes.
    bool DeleteBackward()
    {
        var completing = offered is not null;
        if (source!.Call<Keystroke>("delete_backward", new { selection = Range(Selected), autoPair = AutoPair }) is not { Edit: { } edit })
        {
            reoffer = completing;
            return false;
        }
        Apply(new Change([edit], [new(edit.Start + edit.Text.Length, 0)]));
        if (completing) Complete(false);
        else CloseCompletions();
        return true;
    }

    /// A snippet's next field, or the lines indented.
    bool Tab(int step)
    {
        var answer = source!.Call<Tabbing>("tab", new { selections = new[] { Range(Selected) }, step });
        if (answer?.Field is { } field) Place(field);
        else Apply(answer?.Edits);
        return true;
    }

    /// A snippet, then the maths preview, then the find bar (the completion list goes before).
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

    public bool MoveLines(bool up) => Apply(source?.Call<Change>("move_lines", new { selections = new[] { Range(Selected) }, up }));

    public void ToggleComment() => Command(() => Apply(source!.Call<TextEdit[]>("toggle_comment", new { selections = new[] { Range(Selected) } })));

    /// bold, italic or underline.
    public void ToggleStyle(string style) => Command(() => Apply(source!.Call<Change>("toggle_style", new { selections = new[] { Range(Selected) }, style })));

    /// The selection round a template's "$0"; with nothing selected, an argument's completions after.
    public void Wrap(string template, bool complete = false) => Command(() =>
    {
        var empty = Selected.Length == 0;
        Apply(source!.Call<Change>("wrap", new { selections = new[] { Range(Selected) }, template }));
        if (complete && empty) DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => Complete(true));
    });

    public void SetHeading(string command) => Command(() => Insert(source!.Call<Insertion>("set_heading", new { caret = CaretOffset, command })));

    public void InsertSymbol(string command) => Command(() => Insert(source!.Call<Insertion>("insert_symbol", new { command, selection = Range(Selected) })));

    public void InsertBlock(string id) => Command(() => Insert(source!.Call<Insertion>("insert_block", new { id, selection = Range(Selected) })));

    /// The styles the whole selection has, for Bold, Italic and Underline's checks.
    public TextStyles Styles => source?.Call<TextStyles>("text_styles", new { selection = Range(Selected) }) ?? new(null, null, null);

    void Command(Action action)
    {
        if (source is null) return;
        action();
        Editor.Focus(FocusState.Programmatic);
    }

    // MARK: the selection

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
            if (source is not null && !loading) source.Call("select", new { selection = Range(s), mirroring });
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
        if (source is null || at < 0 || at >= text.Length || source.Call<int?>("partner", new { at }) is not { } match
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

    // MARK: completion: the core's items in a list under the caret

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
            _ => "\uE943",
        };
        CompletionList.ItemsSource = found.Items.Select(i => new CompletionRow(i, s.Start - found.Start, glyph)).ToList();
        CompletionList.SelectedIndex = 0;
        // The surface's padding and border are the 10 past the rows; above the line when there's no room below.
        var height = Math.Min(found.Items.Length, ShownRows) * RowHeight + 10;
        CompletionPopup.HorizontalOffset = Math.Max(0, at.X - LabelInset);
        CompletionPopup.VerticalOffset = at.Bottom + 4 + height <= ActualHeight || at.Y - height - 4 < 0 ? at.Bottom + 4 : at.Y - height - 4;
        CompletionPopup.IsOpen = true;
        Announce(found.Items[0].Label);
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
            Announce(offered.Items[CompletionList.SelectedIndex].Label);
            return true;
        }
        if (key is VirtualKey.Enter or VirtualKey.Tab) Accept(CompletionList.SelectedIndex);
        else if (key == VirtualKey.Escape) CloseCompletions();
        else return false;
        return true;
    }

    void OnCompletionClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is CompletionRow row && offered is { } o) Accept(Array.IndexOf(o.Items, row.Item));
        Editor.Focus(FocusState.Programmatic);
    }

    void Accept(int index)
    {
        var (o, caret) = (offered, CaretOffset);
        CloseCompletions();
        if (o is null || index < 0 || index >= o.Items.Length || caret < o.Start) return;
        var item = o.Items[index];
        Apply(new Change([new(o.Start, caret - o.Start, item.Text)], [new(o.Start + item.Text.Length, 0)]));
        StartSnippet(item.Fields, o.Start);
    }

    /// The list never has the keyboard, so Narrator hears the chosen item from the editor.
    void Announce(string label)
    {
        var peer = FrameworkElementAutomationPeer.FromElement(Editor) ?? FrameworkElementAutomationPeer.CreatePeerForElement(Editor);
        peer.RaiseNotificationEvent(AutomationNotificationKind.ItemAdded, AutomationNotificationProcessing.MostRecent, label, "completion");
    }

    // MARK: the maths preview: RaTeX's SVG of the maths the caret is in, above its line

    MathPreview? MathAt(int caret)
    {
        if (lastMath is { } last && last.Caret == caret && last.Edits == edits) return last.Value;
        var value = source?.Call<MathPreview>("math_at", new { caret });
        lastMath = (caret, edits, value);
        return value;
    }

    async void PreviewMath()
    {
        var maths = source is null || loading || Selected.Length > 0 ? null : MathAt(CaretOffset);
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
            var color = Rgba(ink);
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

    // MARK: undo, the caret and the clipboard

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

    int CaretOffset => Document.Selection.Options.HasFlag(SelectionOptions.StartActive) ? Document.Selection.StartPosition : Document.Selection.EndPosition;

    public int LineCount => source?.LineCount ?? 1;

    /// A line from 1 and a column from 0, selecting `length` units from there.
    public void GoTo(int line, int column = 0, int length = 0)
    {
        if (source is null) return;
        line = Math.Clamp(line, 1, source.LineCount);
        var at = Math.Min(source.LineStart(line) + column, End(line));
        Document.Selection.SetRange(at, Math.Min(at + length, End(line)));
        Document.Selection.ScrollIntoView(PointOptions.None);
        Editor.Focus(FocusState.Programmatic);
    }

    /// The caret's row from the caret to the text's right edge, in this view's coordinates: where a flyout for the
    /// text opens, below the row and never over it.
    public Rect CaretRect => source is not null && RectOf(CaretOffset, CaretOffset) is { } r
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

    /// After the view shrinks (the issues panel opening), once it has laid out.
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
        Apply(new Change([new(at.Start, at.Length, pasted)], [new(at.Start + pasted.Length, 0)]));
    }

    int End(int line) => line < source!.LineCount ? source.LineStart(line + 1) - 1 : text.Length;

    // MARK: RichEdit's own edits

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
        source.Call("select", new { selection = Range(before), mirroring });
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
            var inserted = now.Length - text.Length + removed;
            return start >= 0 && removed >= 0 && inserted >= 0 && start + removed <= text.Length
                && text.AsSpan(0, start).SequenceEqual(now.AsSpan(0, start))
                && text.AsSpan(start + removed).SequenceEqual(now.AsSpan(start + inserted));
        }
        (int, int, string) At(int start, int removed) => (start, removed, now.Substring(start, now.Length - text.Length + removed));
        var shorter = text.Length - now.Length;
        if (Fits(before.Start, before.Length)) return At(before.Start, before.Length);
        if (before.Length == 0 && shorter > 0 && Fits(before.Start - shorter, shorter)) return At(before.Start - shorter, shorter);
        var head = text.AsSpan().CommonPrefixLength(now);
        var tail = 0;
        var most = Math.Min(text.Length, now.Length) - head;
        while (tail < most && text[^(tail + 1)] == now[^(tail + 1)]) tail++;
        return At(head, text.Length - head - tail);
    }

    Color? InkOf(int kind) => kind >= 0 && kind < kinds.Length ? kinds[kind] : null;

    void Colour(int first, int last)
    {
        int a = source!.LineStart(first), b = End(last);
        var runs = source.Highlights(a, Math.Max(b - a, 0));
        setting = true;
        Document.BatchDisplayUpdates();
        Document.GetRange(a, b).CharacterFormat.ForegroundColor = ink;
        foreach (var run in runs)
            if (InkOf(run.Kind) is { } c) Document.GetRange(run.Start, run.Start + run.Length).CharacterFormat.ForegroundColor = c;
        Document.ApplyDisplayUpdates();
        setting = false;
    }

    // MARK: what's drawn beside and over the text

    /// A range's rectangle in the view's coordinates (RichEdit's are the scrolled text's); null before it's laid out.
    Rect? RectOf(int start, int end)
    {
        Document.GetRange(start, end).GetRect(PointOptions.None, out var r, out _);
        return r.IsEmpty || !(r.Height >= 0) || scroller is null ? null
            : new Rect(r.X + Editor.Padding.Left - scroller.HorizontalOffset, r.Y + Editor.Padding.Top - scroller.VerticalOffset, Math.Max(r.Width, 0), r.Height);
    }

    (int First, int Last) VisibleLines()
    {
        var y = scroller!.VerticalOffset;
        var top = Document.GetRangeFromPoint(new Point(0, y), PointOptions.ClientCoordinates).StartPosition;
        var bottom = Document.GetRangeFromPoint(new Point(Editor.ActualWidth, y + Editor.ActualHeight), PointOptions.ClientCoordinates).StartPosition;
        return (source!.LineAt(top), source.LineAt(bottom));
    }

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

    /// The gutter's numbers, the current line and the line-end issues for the lines in view.
    void Refresh()
    {
        var shown = source is not null && scroller is not null;
        Gutter.Visibility = Backdrop.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;
        var (first, last) = VisibleLines();
        var caret = source!.LineAt(CaretOffset);
        Gutter.Width = Math.Ceiling(16 + Math.Max(3, source.LineCount.ToString().Length) * advance + 8);
        // Only beside the text's viewport, so nothing shows in the find bar's band.
        var view = new Rect(0, Editor.Padding.Top, Gutter.Width + Editor.ActualWidth, Math.Max(0, Editor.ActualHeight - Editor.Padding.Top - Editor.Padding.Bottom));
        foreach (var layer in (UIElement[])[Gutter, Backdrop, Overlay]) layer.Clip = new RectangleGeometry { Rect = view };

        var used = 0;
        for (var line = first; line <= last; line++)
        {
            if (RectOf(source.LineStart(line), source.LineStart(line)) is not { } r) continue;
            if (used == numbers.Count)
            {
                numbers.Add(new TextBlock { TextAlignment = TextAlignment.Right });
                AutomationProperties.SetAccessibilityView(numbers[used], AccessibilityView.Raw);
                Gutter.Children.Add(numbers[used]);
            }
            // The editor's font and size at the line's top: the number sits on the text's baseline.
            var number = numbers[used++];
            (number.FontFamily, number.FontSize, number.Width) = (Editor.FontFamily, Editor.FontSize, Gutter.Width - 8);
            (number.Text, number.Foreground) = (line.ToString(), (line == caret ? TextInk : NumberInk).Fill);
            number.Visibility = Visibility.Visible;
            Canvas.SetTop(number, r.Y);
        }
        for (var i = used; i < numbers.Count; i++) numbers[i].Visibility = Visibility.Collapsed;

        if (RectOf(source.LineStart(caret), End(caret)) is { } current)
        {
            (CurrentLine.Width, CurrentLine.Height) = (Backdrop.ActualWidth, current.Height);
            Canvas.SetTop(CurrentLine, current.Y);
        }

        var right = Overlay.ActualWidth - Editor.Padding.Right;
        foreach (var (issue, mark) in marks)
        {
            var end = issue.Line >= first && issue.Line <= Math.Min(last, source.LineCount) ? RectOf(End(issue.Line), End(issue.Line)) : null;
            var x = (end?.X ?? 0) + 16;
            mark.Visibility = end is not null && right - x >= 16 ? Visibility.Visible : Visibility.Collapsed;
            if (end is not { } r) continue;
            (mark.MaxWidth, mark.Height) = (Math.Max(0, right - x), r.Height);
            Canvas.SetLeft(mark, x);
            Canvas.SetTop(mark, r.Y);
        }
    }

    public void SetIssues(IssueLine[] lines)
    {
        marks.ForEach(m => Overlay.Children.Remove(m.Mark));
        marks.Clear();
        foreach (var issue in lines)
        {
            var mark = (FrameworkElement)((DataTemplate)Resources["IssueTemplate"]).LoadContent();
            (mark.DataContext, mark.Visibility) = (new IssueMark(issue), Visibility.Collapsed);
            mark.Tapped += (_, _) => IssueInvoked?.Invoke(issue);
            Overlay.Children.Add(mark);
            marks.Add((issue, mark));
        }
        Invalidate(false);
    }
}
