using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TeXLocal.Controls;

/// A settings card as the toolkit's SettingsCard draws one: a 20 glyph, the header over its description, and the
/// content at the right. Its style is the implicit one in Themes/Generic.xaml.
public sealed partial class Card : ContentControl
{
    public static readonly DependencyProperty HeaderProperty = Register(nameof(Header), typeof(string));
    public static readonly DependencyProperty DescriptionProperty = Register(nameof(Description), typeof(object));
    public static readonly DependencyProperty GlyphProperty = Register(nameof(Glyph), typeof(string));

    public string Header { get => (string)GetValue(HeaderProperty); set => SetValue(HeaderProperty, value); }
    public object Description { get => GetValue(DescriptionProperty); set => SetValue(DescriptionProperty, value); }
    public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }

    static DependencyProperty Register(string name, Type type) =>
        DependencyProperty.Register(name, type, typeof(Card), new PropertyMetadata(null));
}
