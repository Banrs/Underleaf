# What is open

## Mac, on screen

Check on the QA copy (`tools/qa/README.md`), then install with `zsh tools/install-mac.sh`:
- The source|PDF divider: a drag still meets the detents and haptic, while a position set from
  code (`setPosition`, as the toolbar's separator asks) skips them.
- Aa opens with no level highlighted and the first arrow key highlights the caret's level; Tab's
  path through the popover is unverified.

## 27.2 workarounds

Still needed, checked on screen: `HeadingRow`'s Equatable, `redrawFragments`, the width following
a live resize, `WorkspaceController`'s `pdfItem.isCollapsed = false` at the first layout,
`MathGlyphs`' `unmark` and `centre`, `NameWidth`. Still showing headless: `characterIndex` on T1
fonts, replaced pages' memory (`PDFController.wholeAt`), zoom limits, menu images, the Share item,
the drawn underline, PDFKit's fade, the frame guard, PDFKit's one drawer,
`constrainSplitPosition`'s missing super. Each comment says what it works around.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- The hosts trashing for Replace, dropping the core's `trash` and 7 crates (−106 lines; 10–20
  lines per host).
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
