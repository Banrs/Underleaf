# What is open

## Mac, on screen

Check on the QA copy (`tools/qa/README.md`), then `zsh tools/install-mac.sh`:
- The source|PDF divider: a drag still meets the detents and haptic, while a position set from
  code (`setPosition`, as the toolbar's separator asks) skips them.
- Aa opens with no level highlighted and the first arrow key highlights the caret's level; Tab's
  path through the popover is unverified.

## Unchecked 27.2 workarounds

Each says why in its comment. Turn it off on a current build and remove it if the bug is gone:
- `MathGlyphs`' palette rows, `unmark` and `centre` (`MenuItems.swift`).
- `NameWidth`'s trailing space (`HomeView.swift`).

Still needed, checked on screen: `HeadingRow`'s Equatable, `redrawFragments`, the width
following a live resize, `WorkspaceController`'s `pdfItem.isCollapsed = false` at the first layout
(collapsed from the start, the source under a hidden PDF scrolls under the toolbar with no edge). Still showing headless: `characterIndex` on T1 fonts, replaced pages'
memory (`PDFController.wholeAt`), zoom limits, menu images, the Share item, the drawn underline,
PDFKit's fade, the frame guard, PDFKit's one drawer, `constrainSplitPosition`'s missing super.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- The hosts trashing for Replace, dropping the core's `trash` and 7 crates (−106 lines; 10–20
  lines per host).
