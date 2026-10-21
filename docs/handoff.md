# What is open

## Mac, on screen

Check on the QA copy (`tools/qa/README.md`), then install with `zsh tools/install-mac.sh`:
- The haptic as the source|PDF divider stops at the even split (the stop itself is checked).
- Aa opens with no level highlighted and the first arrow key highlights the caret's level; Tab's
  path through the popover is unverified.
- Home's rows for an opened folder and a missing one, and their menu.
- Install in an issue row with `missing` (a `\usepackage` of one not installed): the button, its
  progress, and the password dialog with MacTeX.
- A click on a Live Preview issue opening the Live Preview Log (its look and a build's issue over
  one on its line are checked).

## 27.2 workarounds

Still needed, checked on screen: `HeadingRow`'s Equatable, `redrawFragments`, the width following
a live resize, `WorkspaceController`'s `pdfItem.isCollapsed = false` at the first layout,
`MathGlyphs`' `unmark` and `centre`, `NameWidth`. Still showing headless: `characterIndex` on T1
fonts, replaced pages' memory (`PDFController.wholeAt`), zoom limits, menu images, the Share item,
the drawn underline, PDFKit's fade, the frame guard, PDFKit's one drawer. Each comment says what
it works around.

## Opened folders

The core opens a folder where it is (`docs/core-api.md`, Opened folders); `import_project` and
`project_root` are gone, so until Windows follows, its Open and Show in Finder fail.
- Windows: `MainWindow.Import` calls `open_path`; `ProjectInfo` gains `Path`, `Opened`,
  `Missing` and `SessionOpened` `Name` for the title; Home shows the path, dims a missing folder,
  offers Remove from list in place of Rename and Delete, and reveals `Path`.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- Install for a missing package: the core and the Mac's build panel have it; Windows' Install is
  left, and its elevated install (UAC through PowerShell) has not yet run on Windows.
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
- TeXpresso's frontend (`texpresso`, not `texpresso-xetex`) is still to be rebuilt with the
  patch's fix for a worker killed as it starts (`docs/texpresso.md`). It needs MuPDF and SDL2
  (`brew install mupdf sdl2`). Until then `texpresso_live` fails at "Recovery without a restart".
