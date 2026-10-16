using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TeXLocal.Bridge;
using Windows.Storage.Streams;
using Windows.System;

namespace TeXLocal.Pages;

public sealed class PaletteItem(MathSymbol symbol)
{
    public MathSymbol Symbol => symbol;
    public SvgImageSource Image { get; } = new();
}

public sealed class PaletteGroup(string title, IEnumerable<PaletteItem> items) : List<PaletteItem>(items)
{
    public string Title => title;
}

/// The Insert menu and the symbol palette, made from the core's catalogue (menus) and the main file's class
/// (document_class, heading_styles); symbols as RaTeX draws them (glyph_svg).
public sealed partial class WorkspacePage
{
    static Menus? catalogue;
    static Menus Catalogue => catalogue ??= Source.SyntaxCall<Menus>("menus", new { })!;

    readonly MenuFlyoutSubItem headingMenu = new() { Text = "Heading", AccessKey = "H" };
    readonly ToggleMenuFlyoutItem boldItem = new() { Text = "Bold", AccessKey = "B" };
    readonly ToggleMenuFlyoutItem italicItem = new() { Text = "Italic", AccessKey = "I" };
    readonly ToggleMenuFlyoutItem underlineItem = new() { Text = "Underline", AccessKey = "U" };
    readonly List<MenuFlyoutItemBase> latexOnly = [];
    HeadingStyle[] headingStyles = [];
    Flyout? palette;
    ElementTheme paletteTheme;

    void SetUpInsert()
    {
        var templates = Catalogue.Templates;
        Add(headingMenu);
        Add(new MenuFlyoutSeparator());
        foreach (var (item, style, glyph, key) in new[] { (boldItem, "bold", "\uE8DD", VirtualKey.B), (italicItem, "italic", "\uE8DB", VirtualKey.I), (underlineItem, "underline", "\uE8DC", VirtualKey.U) })
        {
            item.Icon = new FontIcon { Glyph = glyph };
            item.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control });
            item.Click += (_, _) => Editor.ToggleStyle(style);
            Add(item);
        }
        Add(new MenuFlyoutSeparator());
        var inline = Item("Inline maths", () => Editor.Wrap("$$0$"), "\uE94C");
        inline.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = (VirtualKey)187, Modifiers = VirtualKeyModifiers.Menu });
        inline.KeyboardAcceleratorTextOverride = "Alt+=";
        Add(inline);
        Add(Item("Display maths", () => Editor.Wrap("\\[$0\\]")));
        foreach (var t in templates.Math) Add(Item(t));
        var symbols = Item("Symbol…", ShowPalette, "\uE8D2");
        symbols.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = (VirtualKey)187, Modifiers = VirtualKeyModifiers.Menu | VirtualKeyModifiers.Shift });
        symbols.KeyboardAcceleratorTextOverride = "Alt+Shift+=";
        Add(symbols);
        Add(new MenuFlyoutSeparator());
        foreach (var t in templates.Insert) Add(Item(t));
        Add(Sub("List", templates.List));
        Add(Sub("References and links", templates.References));
        ShowHeadings();
        CommentItem.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = (VirtualKey)191, Modifiers = VirtualKeyModifiers.Control });
    }

    void Add(MenuFlyoutItemBase item)
    {
        InsertMenu.Items.Add(item);
        if (item is not MenuFlyoutSeparator) latexOnly.Add(item);
    }

    MenuFlyoutItem Item(string title, Action action, string? glyph = null)
    {
        var item = new MenuFlyoutItem { Text = title };
        if (glyph is not null) item.Icon = new FontIcon { Glyph = glyph };
        item.Click += (_, _) => action();
        return item;
    }

    /// A catalogue block by its id, or an inline command round the selection, whose argument then completes.
    MenuFlyoutItem Item(Template t) => Item(Sentence(t.Title), () =>
    {
        if (t.Inline) Editor.Wrap(t.Body, complete: true);
        else Editor.InsertBlock(t.Body);
    });

    MenuFlyoutSubItem Sub(string title, Template[] templates)
    {
        var sub = new MenuFlyoutSubItem { Text = title };
        foreach (var t in templates) sub.Items.Add(Item(t));
        return sub;
    }

    /// Windows' sentence case for the catalogue's titles: "Aligned Equations" is "Aligned equations"; "URL" stays.
    static string Sentence(string title) => string.Join(' ', title.Split(' ').Select((word, i) =>
        i == 0 || word.Length < 2 || word.Skip(1).Any(char.IsUpper) ? word : char.ToLowerInvariant(word[0]) + word[1..]));

    /// The levels the main file's class has, each numbered and set as the class sets it.
    async Task ReadHeadingStyles()
    {
        string? text;
        try
        {
            text = mainFile == Editor.Path ? Editor.Text
                : (await Core.CallAsync("read_file", new { id, path = mainFile })).GetProperty("text").GetString();
        }
        catch (CoreException) { text = null; }
        var documentClass = text is null ? null : Source.SyntaxCall<DocumentClass>("document_class", new { text });
        headingStyles = Source.SyntaxCall<HeadingStyle[]>("heading_styles", new
        {
            @class = documentClass?.Name,
            pointSize = documentClass?.PointSize ?? 10,
            hasChapters = analysis?.Outline.Any(h => h.Depth == 1) ?? false,
        }) ?? [];
        ShowHeadings();
    }

    void ShowHeadings()
    {
        headingMenu.Items.Clear();
        var styles = headingStyles.Length > 0 ? headingStyles
            : [new HeadingStyle("Normal Text", "", new HeadingFont(1, false, "upright"), null), .. Catalogue.HeadingLevels.Select(l => new HeadingStyle(l.Title, l.Command, new HeadingFont(1, false, "upright"), null))];
        foreach (var style in styles)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = style.Marker is { } marker ? $"{marker} {Sentence(style.Title)}" : Sentence(style.Title),
                GroupName = "heading",
                Tag = style.Command,
                FontSize = Math.Round(14 * Math.Pow(Math.Max(style.Font.Scale, 1), 0.58)),
                FontWeight = style.Font.Bold ? FontWeights.SemiBold : FontWeights.Normal,
                FontStyle = style.Font.Shape == "italic" ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            };
            item.Click += (_, _) => Editor.SetHeading(style.Command);
            headingMenu.Items.Add(item);
        }
    }

    /// The caret line's level, and the selection's bold, italic and underline.
    void UpdateInsertChecks(Heading? heading)
    {
        var latex = Editor.Path?.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) == true;
        foreach (var item in latexOnly) item.IsEnabled = latex;
        var command = heading is { Depth: var d } && d < Catalogue.HeadingLevels.Length ? Catalogue.HeadingLevels[d].Command : "";
        foreach (var item in headingMenu.Items.OfType<RadioMenuFlyoutItem>()) item.IsChecked = (string)item.Tag == command;
        var styles = latex ? Editor.Styles : new TextStyles(null, null, null);
        (boldItem.IsChecked, italicItem.IsChecked, underlineItem.IsChecked) = (styles.Bold is not null, styles.Italic is not null, styles.Underline is not null);
    }

    async void ShowPalette()
    {
        if (Editor.Path is null) return;
        if (palette is null || paletteTheme != ActualTheme) await BuildPalette();
        var r = Editor.CaretRect;
        palette!.ShowAt(Editor, new FlyoutShowOptions { Position = new(r.X, r.Bottom), ExclusionRect = r, Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    /// The catalogue's symbols in a grid by kind, as the emoji panel: a click puts the command in, between dollars in text.
    async Task BuildPalette()
    {
        paletteTheme = ActualTheme;
        var ink = Editor.Ink;
        double[] color = [ink.R / 255.0, ink.G / 255.0, ink.B / 255.0, 1];
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var groups = Catalogue.SymbolGroups.Select(g => new PaletteGroup(g.Title, g.Symbols.Select(s => new PaletteItem(s)))).ToList();
        foreach (var item in groups.SelectMany(g => g))
        {
            if (Source.SyntaxCall<MathSvg>("glyph_svg", new { command = item.Symbol.Command, size = 18, side = 24, color }) is not { Svg: { } svg }) continue;
            item.Image.RasterizePixelWidth = item.Image.RasterizePixelHeight = 24 * scale;
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(Encoding.UTF8.GetBytes(svg).AsBuffer());
            stream.Seek(0);
            await item.Image.SetSourceAsync(stream);
        }
        var grid = new GridView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            Width = 7 * 44 + 16,
            MaxHeight = 360,
            Padding = new Thickness(8, 0, 8, 8),
            ItemTemplate = (DataTemplate)Resources["PaletteItemTemplate"],
            ItemContainerStyle = (Style)Resources["PaletteItemStyle"],
            ItemsSource = new CollectionViewSource { IsSourceGrouped = true, Source = groups }.View,
        };
        grid.GroupStyle.Add(new GroupStyle { HeaderTemplate = (DataTemplate)Resources["PaletteHeaderTemplate"] });
        AutomationProperties.SetName(grid, "Symbols");
        palette = new Flyout { Content = grid, FlyoutPresenterStyle = (Style)Resources["PalettePresenterStyle"] };
        grid.ItemClick += (_, e) =>
        {
            palette.Hide();
            Editor.InsertSymbol(((PaletteItem)e.ClickedItem).Symbol.Command);
        };
    }

    void OnFind(object sender, RoutedEventArgs e) => Editor.ShowFind(false);
    void OnReplace(object sender, RoutedEventArgs e) => Editor.ShowFind(true);
    void OnFindNext(object sender, RoutedEventArgs e) => Editor.FindNext(true);
    void OnFindPrevious(object sender, RoutedEventArgs e) => Editor.FindNext(false);
    void OnComment(object sender, RoutedEventArgs e) => Editor.ToggleComment();
    void OnMoveLineUp(object sender, RoutedEventArgs e) => Editor.MoveLines(true);
    void OnMoveLineDown(object sender, RoutedEventArgs e) => Editor.MoveLines(false);
}
