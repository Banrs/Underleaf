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

/// The Insert menu, and the command bar's text style, Equation, Symbol and Insert (Notepad's formatting bar with Word's
/// Insert commands), from the core's catalogue (menus) and the main file's class (session_analyze's headingStyles);
/// symbols as RaTeX draws them (glyph_svg).
public sealed partial class WorkspacePage
{
    static readonly Menus Catalogue = Source.SyntaxCall<Menus>("menus", new { })!;
    /// The palette, drawn once for its ink: a second click while it draws waits for the same groups.
    Task<List<PaletteGroup>>? symbols;
    Color inked;

    void SetUpInsert()
    {
        var templates = Catalogue.Templates;
        Fill(InsertMenu.Items, InsertMenu.Items.IndexOf(MathsAnchor) + 1, templates.Math);
        Fill(InsertMenu.Items, InsertMenu.Items.IndexOf(InsertAnchor) + 1, templates.Insert);
        Fill(ListMenu.Items, 0, templates.List);
        Fill(ReferencesMenu.Items, 0, templates.References);
        // The command bar's Equation and Insert: the same templates, Insert's lists and references by kind.
        Fill(EquationMenu.Items, EquationMenu.Items.Count, templates.Math);
        Fill(InsertFlyout.Items, 0, templates.Insert);
        Fill(BarListMenu.Items, 0, templates.List);
        Fill(BarReferencesMenu.Items, 0, templates.References);
        ShowHeadings(Source.SyntaxCall<HeadingStyle[]>("heading_styles", new { }) ?? []);
    }

    void Fill(IList<MenuFlyoutItemBase> items, int at, Template[] templates)
    {
        foreach (var t in templates) items.Insert(at++, Item(t));
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
    internal static string Sentence(string title) => string.Join(' ', title.Split(' ').Select((word, i) =>
        i == 0 || word.Length < 2 || word.Skip(1).Any(char.IsUpper) ? word : char.ToLowerInvariant(word[0]) + word[1..]));

    /// Insert › Heading and the command bar's text style, as Word's styles gallery: each level in its own size, weight
    /// and shape, with its number; until a file is analysed, every level.
    void ShowHeadings(HeadingStyle[] styles)
    {
        foreach (var (menu, group) in new[] { (HeadingMenu.Items, "heading"), (StyleMenu.Items, "style") })
        {
            menu.Clear();
            foreach (var style in styles)
            {
                var item = new RadioMenuFlyoutItem
                {
                    Text = style.Marker is { } marker ? $"{marker} {Sentence(style.Title)}" : Sentence(style.Title),
                    GroupName = group,
                    Tag = style,
                    FontSize = Math.Round(14 * Math.Pow(Math.Max(style.Font.Scale, 1), 0.58)),
                    FontWeight = style.Font.Bold ? FontWeights.SemiBold : FontWeights.Normal,
                    FontStyle = style.Font.Shape == "italic" ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
                };
                item.Click += (_, _) => Editor.SetHeading(style.Command);
                menu.Add(item);
            }
        }
    }

    /// The caret line's level, and the selection's bold, italic and underline; LaTeX's commands only in a .tex file that
    /// shows.
    void ShowInsertChecks(OutlineNode? heading)
    {
        var latex = Model.Latex = SourceItem.IsChecked && Editor.Path?.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) == true;
        foreach (var item in InsertMenu.Items) item.IsEnabled = latex;
        var command = heading?.Command ?? "";
        foreach (var item in HeadingMenu.Items.Concat(StyleMenu.Items).OfType<RadioMenuFlyoutItem>())
            item.IsChecked = ((HeadingStyle)item.Tag).Command == command;
        Model.Style = StyleMenu.Items.OfType<RadioMenuFlyoutItem>().FirstOrDefault(i => i.IsChecked) is { } level ? Sentence(((HeadingStyle)level.Tag).Title) : "Normal text";
        var styles = latex ? Editor.Styles : new TextStyles(null, null, null);
        (Model.Bold, Model.Italic, Model.Underline) = (styles.Bold is not null, styles.Italic is not null, styles.Underline is not null);
    }

    // MARK: the symbol palette

    /// Below the caret's line, never over it; drawn again in the text's colour when that has changed.
    void ShowSymbols() => App.Run(null, async () =>
    {
        if (Editor.Path is null) return;
        if (symbols is null || inked != Editor.Ink) symbols = DrawSymbols(inked = Editor.Ink);
        await symbols;
        SymbolFilter.Text = "";
        FilterSymbols();
        var r = Editor.CaretRect;
        Palette.ShowAt(Editor, new FlyoutShowOptions { Position = new(r.X, r.Bottom), ExclusionRect = r, Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    });

    async Task<List<PaletteGroup>> DrawSymbols(Color ink)
    {
        var color = SourceView.Rgba(ink);
        var pixels = 24 * (XamlRoot?.RasterizationScale ?? 1);
        List<PaletteGroup> groups = [];
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
            groups.Add(new(group.Title, items));
        }
        return groups;
    }

    void FilterSymbols()
    {
        var filter = SymbolFilter.Text.Trim();
        Symbols.ItemsSource = new CollectionViewSource
        {
            IsSourceGrouped = true,
            Source = (symbols?.IsCompletedSuccessfully == true ? symbols.Result : []).Select(g => new PaletteGroup(g.Title, g.Where(s => s.Command.Contains(filter, StringComparison.OrdinalIgnoreCase))))
                .Where(g => g.Count > 0).ToList(),
        }.View;
    }

    void OnSymbol(object sender, ItemClickEventArgs e)
    {
        Palette.Hide();
        Editor.InsertSymbol(((PaletteItem)e.ClickedItem).Command);
    }
}
