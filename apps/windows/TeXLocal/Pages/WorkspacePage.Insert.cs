using System.Text;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media.Imaging;
using TeXLocal.Bridge;
using TeXLocal.Controls;
using Windows.UI;

namespace TeXLocal.Pages;

public sealed record PaletteItem(string Command, SvgImageSource Image)
{
    public override string ToString() => Command;
}

public sealed class PaletteGroup(string title, IEnumerable<PaletteItem> items) : List<PaletteItem>(items)
{
    public string Title => title;
}

/// The Insert menu and the symbol palette, from the core's catalogue (menus) and the main file's class (heading_styles);
/// symbols as RaTeX draws them (glyph_svg).
public sealed partial class WorkspacePage
{
    static readonly Menus Catalogue = Source.SyntaxCall<Menus>("menus", new { })!;
    List<PaletteGroup> symbols = [];
    Color inked;

    void SetUpInsert()
    {
        var templates = Catalogue.Templates;
        After(MathsAnchor, templates.Math);
        After(InsertAnchor, templates.Insert);
        foreach (var t in templates.List) ListMenu.Items.Add(Item(t));
        foreach (var t in templates.References) ReferencesMenu.Items.Add(Item(t));
        ShowHeadings(Source.SyntaxCall<HeadingStyle[]>("heading_styles", new { @class = (string?)null }) ?? []);
    }

    void After(MenuFlyoutItemBase anchor, Template[] templates)
    {
        var at = InsertMenu.Items.IndexOf(anchor);
        foreach (var t in templates) InsertMenu.Items.Insert(++at, Item(t));
    }

    /// A catalogue block by its id, or an inline command round the selection, whose argument then completes.
    MenuFlyoutItem Item(Template t)
    {
        var item = new MenuFlyoutItem { Text = Sentence(t.Title) };
        item.Click += (_, _) =>
        {
            if (t.Inline) Editor.Wrap(t.Body, complete: true);
            else Editor.InsertBlock(t.Body);
        };
        return item;
    }

    /// Windows' sentence case for the catalogue's titles: "Aligned Equations" is "Aligned equations"; "URL" stays (core gap 17).
    static string Sentence(string title) => string.Join(' ', title.Split(' ').Select((word, i) =>
        i == 0 || word.Length < 2 || word.Skip(1).Any(char.IsUpper) ? word : char.ToLowerInvariant(word[0]) + word[1..]));

    /// The levels the main file's class has, each numbered and set as the class sets it (core gap 19).
    async Task ReadHeadingStyles()
    {
        string? text;
        try { text = mainFile == Editor.Path ? Editor.Text : (await Core.CallAsync("read_file", new { id, path = mainFile })).GetProperty("text").GetString(); }
        catch (CoreException) { text = null; }
        var documentClass = text is null ? null : Source.SyntaxCall<DocumentClass>("document_class", new { text });
        ShowHeadings(Source.SyntaxCall<HeadingStyle[]>("heading_styles", new
        {
            @class = documentClass?.Name,
            pointSize = documentClass?.PointSize ?? 10,
            hasChapters = analysis?.Outline.Any(h => h.Depth == 1) ?? false,
        }) ?? []);
    }

    /// Insert › Heading, as Word's styles gallery: each level in its own size, weight and shape, with its number.
    void ShowHeadings(HeadingStyle[] styles)
    {
        HeadingMenu.Items.Clear();
        foreach (var style in styles)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = style.Marker is { } marker ? $"{marker} {Sentence(style.Title)}" : Sentence(style.Title),
                GroupName = "heading",
                Tag = style.Command,
                FontSize = Math.Round(14 * Math.Pow(Math.Max(style.Font.Scale, 1), 0.58)),
                FontWeight = style.Font.Bold ? FontWeights.SemiBold : FontWeights.Normal,
                FontStyle = style.Font.Shape == "italic" ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            };
            item.Click += (_, _) => Editor.SetHeading(style.Command);
            HeadingMenu.Items.Add(item);
        }
    }

    /// The caret line's level, and the selection's bold, italic and underline; LaTeX's commands only in a .tex file.
    void ShowInsertChecks(Heading? heading)
    {
        var latex = Editor.Path?.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) == true;
        foreach (var item in InsertMenu.Items) item.IsEnabled = latex;
        var command = heading is { Depth: var d } && d < Catalogue.HeadingLevels.Length ? Catalogue.HeadingLevels[d].Command : "";
        foreach (var item in HeadingMenu.Items.OfType<RadioMenuFlyoutItem>()) item.IsChecked = (string)item.Tag == command;
        var styles = latex ? Editor.Styles : new TextStyles(null, null, null);
        (BoldItem.IsChecked, ItalicItem.IsChecked, UnderlineItem.IsChecked) = (styles.Bold is not null, styles.Italic is not null, styles.Underline is not null);
    }

    void OnStyle(object sender, RoutedEventArgs e) => Editor.ToggleStyle((string)((FrameworkElement)sender).Tag);
    void OnInlineMaths(object sender, RoutedEventArgs e) => Editor.Wrap("$$0$");
    void OnDisplayMaths(object sender, RoutedEventArgs e) => Editor.Wrap("\\[$0\\]");

    // MARK: the symbol palette

    /// Below the caret's line, never over it; drawn again in the text's colour when that has changed.
    async void OnSymbols(object sender, RoutedEventArgs e)
    {
        if (Editor.Path is null) return;
        if (symbols.Count == 0 || inked != Editor.Ink) await DrawSymbols();
        SymbolFilter.Text = "";
        ShowSymbols();
        var r = Editor.CaretRect;
        Palette.ShowAt(Editor, new FlyoutShowOptions { Position = new(r.X, r.Bottom), ExclusionRect = r, Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    async Task DrawSymbols()
    {
        inked = Editor.Ink;
        var color = SourceView.Rgba(inked);
        var pixels = 24 * (XamlRoot?.RasterizationScale ?? 1);
        symbols = [];
        foreach (var group in Catalogue.SymbolGroups)
        {
            List<PaletteItem> items = [];
            foreach (var symbol in group.Symbols)
            {
                if (Source.SyntaxCall<MathSvg>("glyph_svg", new { command = symbol.Command, size = 18, side = 24, color }) is not { Svg: { } svg }) continue;
                var image = new SvgImageSource { RasterizePixelWidth = pixels, RasterizePixelHeight = pixels };
                await image.SetSourceAsync(new MemoryStream(Encoding.UTF8.GetBytes(svg)).AsRandomAccessStream());
                items.Add(new(symbol.Command, image));
            }
            symbols.Add(new(group.Title, items));
        }
    }

    void ShowSymbols()
    {
        var filter = SymbolFilter.Text.Trim();
        Symbols.ItemsSource = new CollectionViewSource
        {
            IsSourceGrouped = true,
            Source = symbols.Select(g => new PaletteGroup(g.Title, g.Where(s => s.Command.Contains(filter, StringComparison.OrdinalIgnoreCase))))
                .Where(g => g.Count > 0).ToList(),
        }.View;
    }

    void OnSymbolFilter(object sender, TextChangedEventArgs e) => ShowSymbols();

    void OnSymbol(object sender, ItemClickEventArgs e)
    {
        Palette.Hide();
        Editor.InsertSymbol(((PaletteItem)e.ClickedItem).Command);
    }
}
