# What is open

## Mac, on screen

Check on the QA copy (`tools/qa/README.md`), then install with `zsh tools/install-mac.sh`:
- The haptic as the source|PDF divider stops at the even split (the stop itself is checked).
- Aa opens with no level highlighted and the first arrow key highlights the caret's level; Tab's
  path through the popover is unverified.

## 27.2 workarounds

Still needed, checked on screen: `HeadingRow`'s Equatable, `redrawFragments`, the width following
a live resize, `WorkspaceController`'s `pdfItem.isCollapsed = false` at the first layout,
`MathGlyphs`' `unmark` and `centre`, `NameWidth`. Still showing headless: `characterIndex` on T1
fonts, replaced pages' memory (`PDFController.wholeAt`), zoom limits, menu images, the Share item,
the drawn underline, PDFKit's fade, the frame guard, PDFKit's one drawer. Each comment says what
it works around.

## Opened folders

The core opens a folder where it is (`docs/core-api.md`, Opened folders); `import_project` and
`project_root` are gone, so until the Mac follows, File › Open and Show in Finder fail.
- Mac: File › Open, Finder's opens and the Dock call `open_path` and open `project.id` at `file`
  (no `locate` first); Home shows `path` under an opened folder's name, dims a `missing` one, and
  offers Show in Finder (`path`) and Remove from List (`forget_folder`), not Rename or Move to
  Trash; titles use `session_open`'s `name`; a bookmark per opened id, resolved for a `missing`
  one and given to `open_path`, follows a move.

## Left

- AppKit's own completion list in place of `CompletionList` once the system's has glass; until
  then the custom one stays (the look is decided).
- Install for a missing package: the core's `install_package`, the build items' `missing` and
  Windows' Install are done; the Mac's Install in the build panel is left, and Windows' elevated
  install (UAC through PowerShell) has not yet run on Windows.
- Windows: Live Preview and the rest of what it lacks against the Mac (`docs/windows.md`).
