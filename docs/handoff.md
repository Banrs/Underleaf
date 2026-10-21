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
- Install TinyTeX on a Mac with no TeX (a user account without MacTeX, and no `~/Library/TinyTeX`):
  the PDF pane's and Settings' button, the progress, a build once it is done, Install adding a
  package to it, and a failure's alert (offline). The core's install itself is tested into a
  temporary folder.

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
- Windows, on a machine with no TeX: Install TinyTeX from Home's bar and from Settings into
  `%APPDATA%\TinyTeX`, its ring, a build after it, and Install adding a package to it.
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
