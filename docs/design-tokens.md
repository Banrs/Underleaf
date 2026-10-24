# Design tokens

Each app uses its platform's own controls, colours and metrics. What they share is the editor's
appearance, defined once in the core (`crates/texlocal-core/src/syntax/theme.rs`).

## Syntax themes

Settings › Editor › Theme: Overleaf, TeXstudio and System (the default), each
Light and Dark. Every theme has five colours, one per highlight kind (`theme_colors` answers them
in the kinds' order). Text, braces and brackets, and what `\verb` and the verbatim environments
hold, are plain; nothing is bold or italic.

| Kind | Overleaf | TeXstudio | System |
| --- | --- | --- | --- |
| command (`\x`, `\begin`, `\end`, escapes, `\\`, maths' `^ _ &`) | `#0000FF` / `#8BE9FD` | `#800000` / `#60CDF2` | pink |
| argument (environment, package, label, reference, citation, numbers in text) | `#318495` / `#FFB86C` | `#008000` / `#60F260` | teal |
| maths (delimiters, letters and numbers in maths) | `#036A07` / `#F1FA8C` | `#509600` / `#85F218` | purple |
| comment | `#4C886B` / `#6272A4` | `#808080` / `#667299` | secondary label |
| invalid (stray brace, what maths can't hold; foreground only) | `#FF0000` / `#FF79C6` | `#C00000` / `#F2F218` | red |

Values are Light / Dark. System names a colour each app resolves in its own appearance
(`systemPink`, `systemTeal`, `systemPurple`, `secondaryLabelColor`, `systemRed`); the theme carries
Apple's published values for an app without them. `theme_colors` raises each colour to 4.5:1
against the editor's ground and its current line's fill (7:1 under Increase Contrast).

Sources:
- **Overleaf**: the editor's `textmate` (Light) and `overleaf_dark` themes (`themes/cm6/`), by the
  tags `languages/latex/latex-language.ts` gives LaTeX's nodes.
- **TeXstudio**: `defaultFormats.qxf` and `defaultFormatsDark.qxf` (`utilities/qxs/`), by the
  formats `tex.qnfa` gives. TeXstudio fills braceMismatch; the fill isn't drawn here, so Light takes
  the fill's colour and Dark the text's.

## Editor surfaces

- **Ground**: the text background without the wallpaper's tint, shared by the status bar, the
  build panel and the PDF pane's bars.
- **Selection** is the system's; the **current line** is Xcode 27's, #E8F2FF in light and #23252B in
  dark (`DVTSourceTextCurrentLineHighlightColor` in Xcode's `Default (Light)` and `Default (Dark)`
  `.xccolortheme` files, DVTUserInterfaceKit's FontAndColorThemes), and the core's `fill` for its contrast.
- **Gutter**: no fill, no rule, dim numbers; the current line's number brightens.
- **Font**: the system's monospace (SF Mono) unless chosen in Settings. It follows Xcode 27's measures: lines 1.1 times the font's, to whole points (18 at 13 pt), numbers a
  point smaller on the text's first baseline, the current line a rounded rectangle 14 pt in from
  the left and 8 pt from the right.
