# Window chrome: what stands, what was rejected, what's proposed

Last updated 2026-11-03. This covers the sidebar (navigators), the status bar, the Logs bar and their sizes beside the
toolbar. Read it before changing any of them.

## What stands now

The sidebar and status bar are the Xcode replicas, restored in 75648edf:

- **Find's path:** drawn as Xcode's DVTPathControl (`Views/Breadcrumb.swift`), its chevron turning down under the
  pointer.
- **Filter bar:** `NavigatorFilterBar` (`Views/Navigators.swift`). It's AppKit interactive Liquid Glass in a 44 pt band:
  - a 28 pt `NavigatorField`, whose cell is laid out as Xcode's DVTSearchField
  - a 28 pt add (+) menu
  - Issues' errors toggle inside the field's end
- **Navigator chooser:** `NavigatorChooser`, an NSSegmentedControl in the tabs role, 7 pt in. Lists start 8 pt below it.
- **Rows:** small rows with body text, all navigators. `navigatorRow()` pulls them in with −2.5 pt of padding.
- **Lists:** stop at the toolbar's foot (`NavigatorArea`).
- **Status bar:** one 36 pt bar across both panes, with 8 pt insets (`BarMetrics`, `Views/StatusBar.swift`). The Logs
  panel has its own 36 pt bar.
- **Add menu:** opens upward, 4 pt above the + (`NavigatorFilterBar.showAdd`). The owner finds this too high, and placed
  beneath the +, AppKit pushed it over the + and the pointer. It still needs tuning on screen.

The Projects (start) window's New templates are a heading row, not a section header. As a header, New pinned at the
list's top at rest, and AppKit grew the toolbar's scroll pocket over it, from 52 pt to 80. That tinted the toolbar with
nothing beneath it and joined the two. `WindowTests.theProjectsToolbarStaysClearAtRestWithNothingPinnedBeneathIt` holds
this; keep the window full-size content.

## Rejected on 2026-11-03: don't repeat these without new evidence

| Attempt | Owner's verdict |
|---|---|
| Stock parts: a small `FilterBar` in a 38 pt split accessory, SwiftUI pop-ups with arrows, 32 pt standard rows, a status bar split per pane | "the sidebar is fully regressed. the xcode one looks better" |
| The Xcode look rebuilt from SwiftUI parts: `.glassEffect` bubbles, hover-chevron pickers, 26.5 pt body rows | "no, everything is off, please revert to xcode versin" |
| Standard rows for Files only | Inconsistent beside the small rows of the other navigators |
| The Finder's NSWorkspace file icons | "xcode doesn't use those icons … use the svgs not the icons" |
| The add menu 4 pt above the + | "too far up" |

The owner's open asks:

- Consistent sizes across the window, including against the toolbar.
- Glyphs drawn as Xcode draws them, from SF Symbols. A folder with contents shows a page inside it; an empty one shows a
  plain folder.
- The filter's relevant toggles, as Xcode's filter fields carry.
- "consider if xcode really is the best to copy".

## Measured (test host, 1400×800, real toolbar, at fb606ebc)

| Element | Height | Control | Insets | Font |
|---|---|---|---|---|
| Toolbar | 52 | XL items, 36 | 8 top and bottom | 13 |
| Navigator chooser | band 36 | large segmented, 28 | 7 at the sides, 0 at the top, 8 below (2 in Find) | – |
| Rows | 24 | symbol at body size | list highlight 10 in | 13 |
| Filter band | 44 | glass field and + at 28 | + 7 in, field 8 | 13 |
| Find header | 52 (+27 with results) | path 19, Aa 21×16, field 24 | field 6 in, path at x=2 | 11 / 13 |
| Status bar, Logs bar | 36 | small, targets 20 | 8 on every side | 11 |

That's four control sizes in one window (36, 28, 24, 20) and three bar heights (52, 44, 36). The 44 pt filter band
doesn't meet the 36 pt status bar across the divider.

The macOS 27 UI Kit (`design/Apple macOS 27 UI Kit.sketch`) has two bar builds:

- XL controls (36 pt) in a 52 pt bar.
- Regular controls (24 pt) in a 40 pt bar.

Both keep 8 pt from every edge. Its sidebar rows are 24, 32 or 40 pt, with 16, 20 or 24 pt icons.

## Proposal (an advisor's, not agreed by the owner)

**Is Xcode the right model?** Its structure, yes. Among Apple's apps, only Xcode holds files, a structure view, project
find with replace, and issues together:

- Finder, Notes and Mail hold one kind of thing per sidebar.
- Pages and Preview hide the choice of view in a menu.
- Overleaf stacks Files over the outline, which TeXLocal tried before 00f422cb.
- Texifier is shaped like Xcode.

Xcode's numbers are a different matter. Its 22 pt rows and 11 pt text were made for nine navigators and projects of
thousands of files.

**One rule:**

- The toolbar keeps its XL controls (36 pt in 52).
- Everything else uses regular controls (24 pt) in 40 pt bars, 8 pt from every edge.
- Rows are standard.

What changes:

- **Chooser:** regular, spanning the sidebar, 8 pt on every side, making a 40 pt band.
- **Filter band:** 40 pt, with the glass field and + at 24 pt and the + 8 pt in.
- **Toggles inside the filter field:**
  - Files: recent files (`clock`) and changed or unsaved files (`pencil`).
  - Issues: errors only (exists) and possibly latest build only.
- **Status bar and Logs bar:** 40 pt, regular controls, 13 pt text. They meet the filter band across the divider as one
  bottom band.
- **Find header:** fields 8 pt in, with 8 pt between rows.
- **Rows:** standard sidebar rows for all four navigators, following the Sidebar icon size setting (32 pt at the default
  Medium). Delete `.environment(\.sidebarRowSize, .small)` and `navigatorRow()`.
- **Icons:** SF Symbols only. A non-empty folder draws `folder` with a small centred `document` overlay, since no system
  symbol shows a folder holding a page; Xcode uses a private one.

Estimated net: about −20 lines.

**Suggested order:** one round each, shown on screen and accepted before the next.

1. The bar and band heights and control sizes.
2. The rows.
3. The icons.
4. The filter toggles.
5. The add menu's place.
