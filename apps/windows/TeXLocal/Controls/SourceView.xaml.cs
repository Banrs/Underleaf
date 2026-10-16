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
using VirtualKey = Windows.System.VirtualKey;
using Windows.UI;
using Windows.UI.Core;

namespace TeXLocal.Controls;

/// A completion as the list shows it: what's typed of it in Semibold.
public sealed class CompletionRow(Completion item, int typed, string glyph, FontFamily font)
{
    public Completion Item => item;
    public string Typed => item.Label[..Math.Clamp(typed, 0, item.Label.Length)];
    public string Rest => item.Label[Math.Clamp(typed, 0, item.Label.Length)..];
    public string Glyph => glyph;
    public FontFamily Font => font;
}

/// The source editor: a RichEditBox whose text and highlighting are the session document's, and whose typing the core
/// assists (brackets, indentation, snippets, completion) as texlocal-syntax answers it.
public sealed partial class SourceView : UserControl
{
    const int ShownCompletions = 8;
    readonly TaskCompletionSource ready = new();
    readonly List<TextBlock> numbers = [];
    readonly List<(IssueLine Issue, Border Box)> boxes = [];
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer partnerTimer;
    Source? source;
    ScrollViewer? scroller;
    string text = "";
    bool setting, changed, undoing, restoring, composing, loading, stale, mirroring, reoffer;
    int loads, lastEnd = -1, edits;
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
            composing = false;
            Composing?.Invoke(false);
            NextUndoGroup();
        };
        Editor.LostFocus += (_, _) =>
        {
            CloseCompletions();
            PreviewMath();
        };
        Editor.GotFocus += (_, _) => PreviewMath();
        Editor.SizeChanged += (_, e) =>
        {
            FindBar.Width = Math.Clamp(e.NewSize.Width - 40, 0, 480);
            Refresh();
        };
        SizeChanged += (_, e) => Clip = new RectangleGeometry { Rect = new(0, 0, e.NewSize.Width, e.NewSize.Height) };
        Editor.LayoutUpdated += (_, _) =>
        {
            if (scroller is not null || Descendant<ScrollViewer>(Editor) is not { } found) return;
            scroller = found;
            ready.TrySetResult();
            scroller.ViewChanged += (_, _) =>
            {
                Refresh();
                CloseCompletions();
                PreviewMath();
            };
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

    /// The font, its size and the syntax theme (the core's id); the text is coloured again for them.
    public void SetLook(string family, double size, string themeId)
    {
        var font = new FontFamily($"{family}, Cascadia Mono, Consolas");
        var same = Editor.FontFamily.Source == font.Source && Editor.FontSize == size && theme == themeId;
        (Editor.FontFamily, Editor.FontSize, theme) = (font, size, themeId);
        var numberSize = Math.Max(12, size - 2);
        foreach (var key in (string[])["NumberStyle", "CurrentNumberStyle"])
        {
            var style = (Style)Resources[key];
            if (style.IsSealed) continue;
            style.Setters.Add(new Setter(TextBlock.FontSizeProperty, numberSize));
        }
        foreach (var number in numbers) number.FontSize = numberSize;
        if (same) return;
        stale = true;
        if (IsLoaded) Recolour();
    }

    /// RichEdit drops colours given off screen (the page cached under Settings) or before it has
    /// laid out again, so a theme change recolours once the editor is back and drawn.
    void Recolour() => DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, async () =>
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

    /// A theme brush's colour as RichEdit can draw it, over the editor's background.
    Color Of(Rectangle r) => EditorPrefs.Over(((SolidColorBrush)r.Fill).Color, ((SolidColorBrush)PaperInk.Fill).Color);

    /// The theme's colours raised by the core to legibility on this background and current line, by highlight kind.
    void Inks()
    {
        ink = Of(TextInk);
        inked = ActualTheme;
        kinds = EditorPrefs.Colors(theme, ActualTheme == ElementTheme.Dark, ((SolidColorBrush)PaperInk.Fill).Color,
            ((SolidColorBrush)CurrentLine.Fill).Color, Of(SecondaryInk));
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
        Refresh();
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

    void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        static bool Down(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
        bool ctrl = Down(VirtualKey.Control), alt = Down(VirtualKey.Menu), shift = Down(VirtualKey.Shift);
        var plain = !ctrl && !alt;
        if (ctrl && !alt && e.Key is VirtualKey.Z or VirtualKey.Y)
        {
            if (e.Key == VirtualKey.Z && !shift) Undo();
            else Redo();
            e.Handled = true;
            return;
        }
        if (source is null || composing) return;
        if (offered is not null && plain && Completing(e.Key)) e.Handled = true;
        else if (ctrl && !alt && !shift && e.Key == VirtualKey.Space) e.Handled = Complete(true) || true;
        else if (plain && !shift && e.Key == VirtualKey.Escape) e.Handled = Escape();
        else if (plain && e.Key == VirtualKey.Enter) e.Handled = Newline();
        else if (plain && !shift && e.Key == VirtualKey.Back) e.Handled = DeleteBackward();
        else if (plain && e.Key == VirtualKey.Tab) e.Handled = Tab(shift ? -1 : 1);
        else if (alt && !ctrl && !shift && e.Key is VirtualKey.Up or VirtualKey.Down) e.Handled = MoveLines(e.Key == VirtualKey.Up) || true;
        else if (ctrl == alt && Typed(e) is { } typed) e.Handled = Type(typed);
    }

    public SourceRange Selected
    {
        get
        {
            var s = Document.Selection;
            return new(s.StartPosition, s.EndPosition - s.StartPosition);
        }
    }

    static object Range(SourceRange r) => new { start = r.Start, length = r.Length };

    /// The selection the core asked for, which is no reason to close the list.
    void Place(int start, int length = 0)
    {
        placed = (start, start + length);
        Document.Selection.SetRange(start, start + length);
        Document.Selection.ScrollIntoView(PointOptions.None);
    }

    void Place(SourceRange r) => Place(r.Start, r.Length);

    /// An edit of the core's into RichEdit and the session's document at once.
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

    /// One undo step, from the last edit, and the selection after.
    bool Apply(Change? change)
    {
        if (change is not { Edits.Length: > 0 }) return false;
        NextUndoGroup();
        foreach (var edit in change.Edits.Reverse()) Put(edit.Start, edit.Length, edit.Text);
        if (change.Selections is [var first, ..]) Place(first);
        NextUndoGroup();
        Refresh();
        return true;
    }

    /// The selection follows the edits.
    bool Apply(TextEdit[]? edits) => edits is { Length: > 0 } && Apply(new Change(edits,
        source!.Call<SourceRange[]>("map_selections", new { edits, selections = new[] { Range(Selected) } }) ?? []));

    void Insert(Insertion? insertion)
    {
        if (insertion is null) return;
        NextUndoGroup();
        Put(insertion.Edit.Start, insertion.Edit.Length, insertion.Edit.Text);
        Place(insertion.Caret);
        StartSnippet(insertion.Fields, insertion.Edit.Start);
        NextUndoGroup();
        Refresh();
    }

    void StartSnippet(SnippetField[] fields, int at)
    {
        if (source!.Call<SourceRange>("start_snippet", new { fields, at }) is { } first) Place(first);
    }

    bool Type(string typed)
    {
        var at = Selected;
        var stroke = source!.Call<Keystroke>("type", new { selection = Range(at), text = typed, autoPair = AutoPair });
        if (stroke?.Edit is { } edit) Put(edit.Start, edit.Length, edit.Text);
        else if (stroke?.Selection is null) Put(at.Start, at.Length, typed);
        Place(stroke?.Selection ?? new SourceRange(lastEnd, 0));
        if (!char.IsLetterOrDigit(typed, 0)) NextUndoGroup();
        Finish(stroke);
        Refresh();
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
        NextUndoGroup();
        Put(edit.Start, edit.Length, edit.Text);
        Place(stroke.Selection ?? new SourceRange(lastEnd, 0));
        NextUndoGroup();
        Finish(stroke);
        Refresh();
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
        NextUndoGroup();
        Put(edit.Start, edit.Length, edit.Text);
        Place(edit.Start + edit.Text.Length);
        NextUndoGroup();
        if (completing) Complete(false);
        else CloseCompletions();
        Refresh();
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
            return true;
        }
        if (!FindShown) return false;
        HideFind();
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

    void OnSelectionChanged()
    {
        if (!changed && CaretOffset != lastEnd) NextUndoGroup();
        var s = Selected;
        if (!changed) before = s;
        if (source is not null && !loading) source.Call("select", new { selection = Range(s), mirroring });
        if ((s.Start, s.End) != placed)
        {
            placed = (-1, -1);
            CloseCompletions();
            HidePartner();
        }
        Refresh();
        CaretMoved?.Invoke();
        PreviewMath();
    }

    void ShowPartner(int at)
    {
        if (source is null || at < 0 || at >= text.Length || source.Call<int?>("partner", new { at }) is not { } match) return;
        var r = RectOf(match, match + 1);
        if (r.Y < -1000) return;
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

    /// False when there's nothing to offer.
    public bool Complete(bool explicitly)
    {
        var s = Selected;
        if (source is null || s.Length > 0 || composing
            || source.Call<Completions>("completions", new { caret = s.Start, @explicit = explicitly }) is not { Items.Length: > 0 } found)
        {
            CloseCompletions();
            return false;
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
        CompletionList.ItemsSource = found.Items.Select(i => new CompletionRow(i, s.Start - found.Start, glyph, Editor.FontFamily)).ToList();
        CompletionList.SelectedIndex = 0;
        var at = RectOf(found.Start, found.Start);
        var height = Math.Min(found.Items.Length, ShownCompletions) * 32 + 10;
        CompletionList.MaxHeight = ShownCompletions * 32;
        CompletionPopup.HorizontalOffset = Math.Max(0, at.X - 41);
        CompletionPopup.VerticalOffset = at.Bottom + 4 + height <= ActualHeight || at.Y - height - 4 < 0 ? at.Bottom + 4 : at.Y - height - 4;
        CompletionPopup.IsOpen = true;
        Announce(found.Items[0].Label);
        return true;
    }

    public void CloseCompletions()
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
            VirtualKey.PageUp => -(ShownCompletions - 1),
            VirtualKey.PageDown => ShownCompletions - 1,
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
        if (key is VirtualKey.Enter or VirtualKey.Tab)
        {
            Accept(CompletionList.SelectedIndex);
            return true;
        }
        if (key != VirtualKey.Escape) return false;
        CloseCompletions();
        return true;
    }

    void OnCompletionClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is CompletionRow row && offered is { } o) Accept(Array.IndexOf(o.Items, row.Item));
        Editor.Focus(FocusState.Programmatic);
    }

    void Accept(int index)
    {
        var caret = CaretOffset;
        if (offered is not { } o || index < 0 || index >= o.Items.Length || caret < o.Start)
        {
            CloseCompletions();
            return;
        }
        var item = o.Items[index];
        CloseCompletions();
        NextUndoGroup();
        Put(o.Start, caret - o.Start, item.Text);
        Place(o.Start + item.Text.Length);
        StartSnippet(item.Fields, o.Start);
        NextUndoGroup();
        Refresh();
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
        var focused = Editor.FocusState != FocusState.Unfocused;
        var maths = source is null || loading || Selected.Length > 0 ? null : MathAt(CaretOffset);
        if (maths?.Start != dismissedMath) dismissedMath = null;
        if (maths is null || dismissedMath is not null || !focused)
        {
            shownMath = null;
            MathPopup.IsOpen = false;
            return;
        }
        var line = RectOf(source!.LineStart(source.LineAt(CaretOffset)), CaretOffset);
        if (line.Y < 0 || line.Bottom > ActualHeight)
        {
            MathPopup.IsOpen = false;
            return;
        }
        if (maths != shownMath)
        {
            shownMath = maths;
            var em = Editor.FontSize * 1.21;
            var color = EditorPrefs.Rgba(ink);
            var drawn = await Task.Run(() => Source.SyntaxCall<MathSvg>("math_svg", new { tex = maths.Tex, display = maths.Display, size = em, color }));
            if (shownMath != maths) return;
            await ShowMaths(drawn, maths.Tex);
            if (shownMath != maths) return;
        }
        MathSurface.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = MathSurface.DesiredSize;
        MathPopup.HorizontalOffset = Math.Clamp(line.X + RectOf(CaretOffset, CaretOffset).X - line.X - size.Width / 2, 0, Math.Max(0, ActualWidth - size.Width - 48));
        MathPopup.VerticalOffset = line.Y - size.Height - 8 >= 0 ? line.Y - size.Height - 8 : line.Bottom + 8;
        MathPopup.IsOpen = true;
    }

    async Task ShowMaths(MathSvg? drawn, string tex)
    {
        MathImage.Source = null;
        MathError.Text = "";
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
                return;
            }
        }
        MathError.Text = tex;
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

    public int CaretOffset
    {
        get
        {
            var s = Document.Selection;
            return s.Options.HasFlag(SelectionOptions.StartActive) ? s.StartPosition : s.EndPosition;
        }
    }

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

    /// Under the caret, in this view's coordinates: where a flyout for the text opens.
    public Point CaretPoint
    {
        get
        {
            var r = RectOf(CaretOffset, CaretOffset);
            var x = r.X + Gutter.ActualWidth;
            return r.Y < -1000 ? new Point(Gutter.ActualWidth + 16, 16) : new Point(x, r.Bottom);
        }
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
        NextUndoGroup();
        Put(at.Start, at.Length, pasted);
        Place(at.Start + pasted.Length);
        NextUndoGroup();
        Refresh();
    }

    int End(int line) => line < source!.LineCount ? source.LineStart(line + 1) - 1 : text.Length;

    /// RichEdit's own edits (input methods, Delete, Cut, undo, drops): what changed, read from the text. The selection
    /// before it tells where in a run of the same characters the change was.
    void OnEdited()
    {
        if (!changed || source is null) return;
        var restored = restoring;
        changed = restoring = false;
        Document.GetText(TextGetOptions.UseLf, out var now);
        var (start, removed, inserted) = Change(now);
        if (removed > 0 || inserted.Length > 0)
        {
            Mirror(start, removed, inserted, !restored);
            if (!restored && (removed > 0 || inserted.Length != 1 || !char.IsLetterOrDigit(inserted[0]))) NextUndoGroup();
            // RichEdit moved the selection before its text was read: the caret's line is the new text's.
            CaretMoved?.Invoke();
        }
        before = Selected;
        if (reoffer)
        {
            reoffer = false;
            Complete(false);
        }
        Refresh();
    }

    (int Start, int Removed, string Inserted) Change(string now)
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

    Rect RectOf(int start, int end)
    {
        Document.GetRange(start, end).GetRect(PointOptions.None, out var r, out _);
        return Shown(r);
    }

    /// RichEdit's rectangles are in the scrolled text's coordinates; these are the view's.
    Rect Shown(Rect r) => r.IsEmpty || !(r.Height >= 0) || scroller is null ? new(0, -10000, 0, 0) : new(r.X + Editor.Padding.Left - scroller.HorizontalOffset, r.Y + Editor.Padding.Top - scroller.VerticalOffset, Math.Max(r.Width, 0), r.Height);

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
        var numberSize = Math.Max(12, Editor.FontSize - 2);
        Gutter.Width = 16 + Math.Ceiling(numberSize * 0.6) * digits + 4;
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
            number.FontSize = numberSize;
            number.Text = line.ToString();
            number.Width = Gutter.Width - 12;
            number.Visibility = Visibility.Visible;
            Canvas.SetTop(number, r.Y + (r.Height - numberSize * 1.33) / 2);
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
