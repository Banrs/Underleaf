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
- Install TinyTeX from Settings, and its alert when offline. The PDF pane's button, its
  progress and a build once it is done are checked on the QA copy with TeX hidden by
  `sandbox-exec` and `HOME` pointed at a scratch folder; tlmgr adds a package there unelevated.

## 27.2 workarounds

Rechecked on the 27.2 RC (26B118, Xcode 27.2) in throwaway tests, each workaround turned off; none
can go. Their bugs still show in the test host: `HeadingRow`'s Equatable (the heading opens
closed), `redrawFragments` (a theme change draws no fragment), the width following a live resize
(scrolled down, the container keeps its width until the resize ends), the top paragraph put back,
`scroll`'s two passes and `prepareContent` (their tests fail), Jump to Selection (AppKit's lands
30 pt off after a far jump), `MathGlyphs.centre` (palettes 13 pt in on the left, 5 on the right),
`NameWidth` (a trailing space hangs past the edge), `characterIndex` (wrong after a ligature, T1 or
OT1), replaced pages' memory (255 MB over 15 image pages, none for new documents), zoom limits,
the Share item, the drawn underline, PDFKit's fade (a 0.25 s `CATransition`), the frame guard,
PDFKit's one drawer (two draws take twice one) and `Mount` (a hidden hosting view still
re-evaluates). Not settled on the RC, needing the screen: `pdfItem.isCollapsed = false` at the
first layout (the view trees match), `MathGlyphs.unmark`, the palette's text-only rows, and a new
document's flash (`PDFController.show`). The measures hold: the inspector opens at 270, a sidebar
header row is 19 pt under 10, and Compile's word goes 2 pt before AppKit would take Zoom; AppKit
now keeps Compile down to 533 pt and Back to 481, under the 542 minimum. Each comment says what it
works around.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- Windows, on a machine: Home's rows for an opened and a missing folder, and Install's UAC
  elevation (allowed and cancelled), which GitHub's runner can't show.
- Windows, on a machine with no TeX: Install TinyTeX from Home's bar and from Settings into
  `%APPDATA%\TinyTeX`, its ring, a build after it, and Install adding a package to it.
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
