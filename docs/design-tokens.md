# Design tokens

Every value here was read out of **Apple's macOS 27 UI Kit** (Sketch, from
[Apple Design Resources](https://developer.apple.com/design/resources/)) rather
than eyeballed, so the app's chrome matches the platform it sits in. The kit
lives outside the repo (`~/Documents/Design Resources/`); this file is the
extracted spec that `web/styles.css` implements.

## Typography — SF Pro

macOS's base *control* size is 13px — but see the roles below: a list-dense
window uses 15px for its rows, and treating 13 as the app-wide size is what makes
a Mac app look shrunken.

**The scale is expressed as five roles, not five sizes** (`--fs-title`,
`--fs-body`, `--fs-header`, `--fs-control`, `--fs-small`, `--fs-micro` plus
`--fs-large-title`). Every `font-size` in `web/styles.css` refers to a role, so a
value can't drift: the earlier pass had 15 separate uses of 11px against 2 of
15px, which is what made the interface read small no matter what the row spec was.

| Role | Size | Used for |
| --- | --- | --- |
| large-title | 26 / 32 | welcome heading |
| title | 15 / 20 Bold | window title, dialog titles |
| **body** | **15 / 20** | **lists, rows, content, form rows** |
| header | 13 / 16 Bold | section headers (kit Large header, 20px box) |
| control | 13 / 16 | buttons, fields, menus, toolbars, breadcrumb, status |
| small | 12 / 15 | hints, timestamps, metadata, log text |
| micro | 11 / 14 | count badges only |

Section headers scale with the variant too: Small/Medium use 11 Bold in an 18px
box, **Large uses 13 Bold in a 20px box** — pairing an 11px header with 15px rows
is the mismatch that reads wrong.

**Row height follows the text size, so one sidebar gets one row height.** The
outline used 32px rows next to the file tree's 40px while both rendered 15/20
text; the kit's Large `Items` master — the variant that carries 15/20 — is 40, so
both are 40 now. Two densities in one pane was the mismatch, not the type size.

**Measured component text** (weights matter as much as sizes — most control text
is *Medium*, not Regular, and titles are heavier than web defaults):

| Component text | Kit spec |
| --- | --- |
| Window title | **15 Bold** (subtitle: 11 Medium) |
| Toolbar pop-up/pull-down label, search field | 13 Medium |
| Toolbar button symbol | 13pt SF Symbol (≈16px optical) |
| Sidebar file row | 13 Regular; folder rows 13 **Medium** |
| Sidebar section header | 11 **Bold**, 14px box in an 18px band |
| Menu item | 13 Medium in a 24px row; menu header 13 Bold |
| Text-field value | 13 Medium |
| Dialog form label | 13 Regular (primary color, not dimmed) |
| Alert title / informative | 14–15 Bold / 11 Medium |

The kit's full named ramp, for reference when a new role is needed:
Large Title 26/32 · Title 1 22/26 · Title 2 17/22 · Title 3 15/20 ·
Headline 13/16 Bold · Body 13/16 · Callout 12/15 · Subheadline 11/14 ·
Footnote & Caption 10/13. Note that "Body 13" is the *control* text size; a
list-based app at the Large density uses Title 3 (15/20) for its rows, which is
why `--fs-body` here is 15 rather than 13.

## Color — semantic, not literal

Labels and fills are alpha over the window background, which is what makes them
work on both opaque panels and vibrant materials.

| Role | Light | Dark |
| --- | --- | --- |
| Label primary | `rgba(0,0,0,.85)` | `#fff` |
| Label secondary | `rgba(0,0,0,.50)` | `rgba(255,255,255,.55)` |
| Label tertiary | `rgba(0,0,0,.25)` | `rgba(255,255,255,.25)` |
| Label quaternary | `rgba(0,0,0,.10)` | `rgba(255,255,255,.10)` |
| Fill primary → quinary | black `.10 .08 .05 .03 .02` | white, same ramp |
| Separator | `rgba(60,60,67,.29)` | `rgba(255,255,255,.15)` |
| Window background | `#ffffff` | `#1e1e1e` |

System colors (light / dark): blue `#0088FF` / `#0091FF`, red `#FF383C` /
`#FF4245`, orange `#FF8D28` / `#FF9230`, yellow `#FFCC00` / `#FFD600`, green
`#34C759` / `#30D158`, gray `#8E8E93` / `#98989D`.

Materials (the fill behind a `backdrop-filter`), light / dark:

| | Light | Dark |
| --- | --- | --- |
| Ultra thin | `rgba(236,236,236,.38)` | `rgba(41,41,41,.40)` |
| Thin | `rgba(236,236,236,.50)` | `rgba(41,41,41,.49)` |
| Regular | `rgba(236,236,236,.63)` | `rgba(44,44,44,.61)` |
| Thick | `rgba(236,236,236,.76)` | `rgba(44,44,44,.71)` |

## Geometry

**Control size ramp** — mini 16, small 20, regular 24, large 28, XL 36.

**Sidebar/list variants — text scales with row height.** This is the decision
that sets the app's overall legibility:

| Variant | Row | Leading icon | Title |
| --- | --- | --- | --- |
| Small | 24 | 16 | 11 Medium |
| Medium | 32 | 20 | 13 Regular |
| **Large ← used here** | **40** | **24** | **15 Regular** |

**Toolbar band heights**, measured off every window style in the kit — these are
the only correct values, so "what height should the toolbar be?" has one answer
per style:

| Window style | Bands |
| --- | --- |
| Default (title only) | titlebar 52 (32 without title) |
| **Unified toolbar ← title bar here** | one band, **52** |
| Unified *compact* | one band, 40 |
| **Expanded toolbar ← in-pane bars here** | titlebar 32 + toolbar **44** |
| Utility panel | 56 |

**Standardization (this app):** two control sizes — **36 (XL)** in the 52px title
bar, **28** for every interactive control below it (toolbar buttons, inputs,
segmented controls, steppers, search). No mini/small controls anywhere.

Components keeping their own kit spec: switch 54×24, scrollbar 12, menu text
13 Medium (the row box follows this app's list density at 28).

Touch/iPad sizing is deliberately out of scope for this build (future SwiftUI
effort).

**Corner radius is `height / 4`.** Measured off the text-field set (16→4, 20→5,
24→6, 28→7, 36→9) and confirmed by the sidebar rows (32→8, 40→10). One rule, so
nothing needs an ad-hoc radius.

| Element | Value |
| --- | --- |
| Unified titlebar + toolbar | **52** tall, XL (36) controls inset 8 |
| In-pane toolbar | **44** tall, 28 controls (kit's Expanded-toolbar band) |
| Sidebar | **256** wide |
| Sidebar row | 40 tall, radius 10, icon 24, icon→label gap 4 |
| Sidebar content inset | 14 (selection pill bleeds to 10) |
| Sidebar section header | 20 tall, 13 Bold, content 16 tall centred (y=2), **no gap before the rows** |
| Section header accessory | 20 wide (kit's `Headers - Trailing`); square here for a kinder target |
| Sidebar footer | 44 — a toolbar band, not the 46 that asymmetric padding produced |
| Traffic lights | 68 × 14 at x **18**, y **19** (centred in the 52 bar) |
| Menu row | kit 24 tall (28 here), radius 6, min-width 160, separator 11 |
| Switch (regular) | 54 × 24 |
| Dialog | kit 390 wide / 20 inset (Settings 520 wide, 52-tall rows) |
| Scrollbar | 12 |

## The editor: Xcode 27's Default themes

The reference app for this one is Xcode, so the editor uses **Xcode 27's own
Default (Light) and Default (Dark)**, read out of the installed beta rather than
sampled by eye:

```
/Applications/Xcode-beta.app/Contents/SharedFrameworks/
  DVTUserInterfaceKit.framework/Versions/A/Resources/FontAndColorThemes/
    Default (Light).xccolortheme      # plists; DVTSourceTextSyntaxColors
    Default (Dark).xccolortheme       # holds "r g b a" component strings
```

It previously shipped CodeMirror's generic `defaultHighlightStyle` in light and
**One Dark** in dark, so the largest surface in the app was the one that looked
least like macOS.

The LaTeX (`stex`) mode's tokens are mapped to Xcode's categories **by meaning**,
read off the mode's source rather than guessed at:

| stex token | What it is in LaTeX | Xcode category | Light | Dark |
| --- | --- | --- | --- | --- |
| `tagName` | `\commands`, `\%` escapes | keyword | `#9B2393` | `#FC5FA3` |
| `atom` | braced args — environment, class, package, label, ref, cite | identifier.type | `#1C464A` | `#9EF1DD` |
| `keyword` | math delimiters `$ $$ \[ \(` | preprocessor | `#643820` | `#FD8F3F` |
| `special(variableName)` | identifiers inside math | identifier.variable | `#326D74` | `#67B7A4` |
| `number` | numbers in math | number | `#1C00CF` | `#D0BF69` |
| `comment` | `%…` | comment | `#5D6C79` | `#6C7986` |
| `string` | quoted | string | `#C41A16` | `#FC6A5D` |
| `bracket` | `{}` `[]` | *plain* — Xcode leaves punctuation uncoloured | | |

Math delimiters get the preprocessor colour because they switch mode the way a
preprocessor directive does, and having them stand out is worth more here than
category purity.

Surfaces: selection `#A4CDFF`/`#515B70`, current line `#E8F2FF`/`#23252B`,
invisibles `#CCCCCC`/`#424D5B`. The **background is deliberately not** Xcode's
(`#FFFFFF`/`#1F1F24`) — the editor sits flush against this app's panels, so it
follows `--bg-panel` and a one-value difference can't show as a seam.

Gutter: no fill, no rule, dim numbers, and the current line's number brightens —
Xcode's treatment. (The previous rule mixed `--text-dim` and `--border`, neither
of which exists in the token set, so every declaration in it was invalid and
dropped; the grey that appeared came from One Dark.)

**Monospace: the platform's, not a bundled one.** `--mono` starts at
`ui-monospace`, which resolves to SF Mono on macOS (what Xcode sets) and Cascadia
Mono on Windows. JetBrains Mono stays bundled and selectable in Settings, but an
app that should read as native shouldn't ship its own code face ahead of the
platform's. Leading is 1.45 — code wants tighter than prose, Xcode's is about 1.3,
and 1.6 was costing a line of context per screen.

**Xcode has no semantic colour catalogue to copy.** Its `Assets.car` holds only 27
unnamed branding colours (`assetutil --info` will show them); the chrome is drawn
with system `NSColor`s. So the macOS 27 UI Kit stays the authority for everything
outside the editor, and matching "Xcode" means matching the system.

## Platform abstraction

macOS-only chrome is gated on `html.mac`, set from the host platform — never
assumed. Windows keeps the same tokens under standard window decorations; see
[windows.md](windows.md).

- `html.mac` — vibrancy materials, traffic-light inset, `⌘`-style shortcut glyphs
- `html.win` — opaque panels under a standard title bar
- `html.desktop` — running in the desktop shell rather than browser mode
