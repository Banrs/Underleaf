# Design tokens

Hosts use their platform's own controls, semantic colours and metrics: the Mac app is
SwiftUI with AppKit for the window, toolbar, splits, text and PDF, and its design
decisions are in `HANDOFF.md`. What is shared is the editor's appearance, which
the core's syntax module defines once (`crates/texlocal-core/src/syntax/theme.rs`) and
hosts map to their own colour type.

## Syntax themes

The editor's colours are a setting (Settings › Editor › Theme): Overleaf (the default),
TeXstudio and System, each in Light and Dark. Every theme colours five kinds. Text, braces
and brackets are plain, and none draws bold or italic.

| Kind | Overleaf | TeXstudio | System |
| --- | --- | --- | --- |
| command (`\x`, `\begin`, `\end`, escapes, `\\`, maths' `^ _ &`) | `#0000FF` / `#8BE9FD` | `#800000` / `#60CDF2` | pink |
| argument (environment, package, label, reference, citation, `\importmodule`'s second argument; numbers in text) | `#318495` / `#FFB86C` | `#008000` / `#60F260` | teal |
| maths (delimiters, letters and numbers in maths, verbatim, `\importmodule`'s first argument) | `#036A07` / `#F1FA8C` | `#509600` / `#85F218` | purple |
| comment | `#4C886B` / `#6272A4` | `#808080` / `#667299` | secondary label |
| invalid (stray brace, what maths can't hold; foreground only) | `#FF0000` / `#FF79C6` | `#C00000` / `#F2F218` | red |

Values are Light / Dark. System names a colour a host resolves in its own appearance
(`systemPink`, `systemTeal`, `systemPurple`, `secondaryLabelColor`, `systemRed`); the theme
carries Apple's published values for a host without such colours.

Sources:

- **Overleaf**: the source editor's `textmate` (Light) and `overleaf_dark` themes
  (`themes/cm6/`), by the tags `languages/latex/latex-language.ts` gives LaTeX's nodes.
- **TeXstudio**: `defaultFormats.qxf` and `defaultFormatsDark.qxf` (`utilities/qxs/`); which
  format the LaTeX highlighter gives what is in `tex.qnfa`. TeXstudio fills braceMismatch;
  the fill isn't drawn here, so Light takes the fill's colour and Dark the text's.

`theme_colors` raises each colour to 4.5:1 against the editor's ground and its current
line's fill (7:1 under Increase Contrast), given the host's backgrounds.

## Editor surfaces

Each host uses its platform's own backgrounds, selection, current-line fill and monospace
font (SF Mono on macOS, Cascadia Mono on Windows) unless one is chosen in Settings; no
tuned measures.
