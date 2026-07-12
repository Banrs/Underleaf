# Mobile / touch roadmap (Underleaf)

Groundwork and future plans for touch platforms, alongside the desktop design
systems (macOS Golden Gate/Tahoe, Windows Fluent). Saved so the intent survives
context compaction.

## Status

- **iPadOS (simulated, experimental).** `.ipad` variant in `web/styles.css`
  (last block). Key correction: **iPadOS follows the iOS HIG, not the macOS
  HIG** — so the block uses iOS metrics, not "macOS but bigger" (an earlier
  version did the latter and read as cramped). iOS values applied: SF Pro
  **Dynamic Type** (17pt Body, 15pt Subhead, 13pt Footnote — vs macOS 13px
  body), **320pt** sidebar column (UISplitViewController standard), **20pt**
  regular-width layout margins (vs macOS ~14px), 1.4 line-height, 44pt minimum
  touch targets, ~50pt nav/toolbars, and no window controls (no traffic lights
  / caption buttons). Pairs with the floating Liquid Glass sidebar
  (`.floating`). Nothing sets `.ipad` at runtime yet — preview-only, injected
  in screenshots. Verified at iPad Pro 11" (1194×834 @2x): rows 44px, sidebar
  320px.

## Planned: compact iOS (iPhone) version

Target: a **compact iOS build** for iPhone-class widths where the three panes
(file sidebar · editor · PDF preview) can't coexist.

- **3-window swipe navigation.** Instead of a split view, present the three
  surfaces as full-width pages the user **swipes between**: Files ⟷ Editor ⟷
  Preview. A page indicator / segmented control up top; swipe (or tap) to move.
  This keeps each surface full-width and touch-comfortable on a phone.
- Reuse the `.ipad` touch scale as the base; add an `.ios`/`.compact` mode that:
  - stacks the three panes as swipeable full-width pages (CSS scroll-snap or a
    small pager), rather than the side-by-side `.shell` flex layout;
  - hides the resizers; the editor↔PDF sync pill becomes a page action;
  - uses a bottom or top segmented control for Files / Editor / Preview;
  - iOS 26 Liquid Glass chrome, safe-area insets (`env(safe-area-inset-*)`),
    44pt minimum touch targets, larger SF Pro type.
- Keep it a pure CSS/JS layout mode keyed off a class (like `.win`/`.ipad`), so
  the desktop systems are untouched.

## Open desktop items (parked)

- Windows chrome + Mica are code-verified, not runtime-tested (no Windows here).
- Dynamic caption reserve via `navigator.windowControlsOverlay` instead of the
  static 138px.
