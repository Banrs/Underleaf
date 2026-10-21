# What is open

## Mac, on screen

Check on the QA copy (`tools/qa/README.md`), then install with `zsh tools/install-mac.sh`:
- The haptic as the source|PDF divider stops at the even split (the stop itself is checked).
- Aa opens with no level highlighted and the first arrow key highlights the caret's level; Tab's
  path through the popover is unverified.
- An opened folder's menu on Home, and Install's password dialog with MacTeX (the rows, the
  button, its progress and a failure are checked).
- A click on a Live Preview issue opening the Live Preview Log (its look and a build's issue over
  one on its line are checked).

## 27.2 workarounds

Still needed, checked on screen: `HeadingRow`'s Equatable, `redrawFragments`, the width following
a live resize, `WorkspaceController`'s `pdfItem.isCollapsed = false` at the first layout,
`MathGlyphs`' `unmark` and `centre`, `NameWidth`. Still showing headless: `characterIndex` on T1
fonts, replaced pages' memory (`PDFController.wholeAt`), zoom limits, menu images, the Share item,
the drawn underline, PDFKit's fade, the frame guard, PDFKit's one drawer. Each comment says what
it works around.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- Windows, on a machine: Home's rows for an opened and a missing folder, and Install's UAC
  elevation (allowed and cancelled), which GitHub's runner can't show.
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
