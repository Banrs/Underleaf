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
| Sidebar section header | Large: 20 tall, 13 Bold, 16 gap below |
| Traffic lights | 68 × 14 at x **18**, y **19** (centred in the 52 bar) |
| Menu row | kit 24 tall (28 here), radius 6, min-width 160, separator 11 |
| Switch (regular) | 54 × 24 |
| Dialog | kit 390 wide / 20 inset (Settings 520 wide, 52-tall rows) |
| Scrollbar | 12 |

## Platform abstraction

macOS-only chrome is gated on `html.mac`, set from `process.platform` — never
assumed. Windows keeps the same tokens and gets its own chrome later; see
[windows.md](windows.md) for what remains.

- `html.mac` — vibrancy materials, traffic-light inset, `⌘`-style shortcut glyphs
- `html.win` — reserved; opaque panels, Windows caption buttons
- `html.electron` — desktop shell in either OS (vs. browser mode)
