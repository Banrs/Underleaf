# Hand-over: what the October concise pass left (2026-10-19)

The audit branch (`claude/audit-cuts`, PR #53) gave the repo a pass under AGENTS.md's "Writing
code" rules; `docs/audit-2026-10.md` says what it cut. These parts it didn't cut, and why.

## Windows files the redesign rewrites

`claude/windows-fluent` (unmerged, 3 ahead and about 80 behind `main`) rewrites these, so a
pass here would only conflict with it. Give them the pass on that branch, after rebasing it
onto `main`:

| File | Lines |
|---|---:|
| `Pages/WorkspacePage.xaml.cs` | 590 |
| `Pages/WorkspacePage.xaml` | 438 |
| `Pages/WorkspacePage.Sidebar.cs` | 389 |
| `Pages/HomePage.xaml`, `.xaml.cs` | 378 |
| `MainWindow.xaml`, `.xaml.cs` | 217 |
| `Pages/WorkspacePage.Insert.cs` | 151 |
| `Themes/Generic.xaml` | 75 |
| `Controls/Sizer.cs` | 58 |
| `install.ps1` | 20 |
| `docs/windows.md` | 486 |

## Needs a Mac on screen

No Swift compiler or screen was on hand, so these stayed. Each names a macOS 27.2 bug with no
capture on the current OS; AGENTS.md makes such a workaround a candidate for removal once the
bug is checked:

| File (apps/macos/TeXLocal) | Lines | What it works round |
|---|---|---|
| `SourceTextView+Viewport.swift` | 5, 10, 16, 56, 93, 127 | TextKit 2's viewport and scrolling |
| `SourceTextView+Colours.swift` | 45 | redrawing a fragment |
| `SyncPDFView.swift` | 38, 52, 71, 97, 188 | the live layer's drawing; SwiftUI resetting the frame, which may be gone now the pane is in AppKit splits |
| `PDFController.swift` | 171, 204, 223, 246 | print keeps its document; replaced pages keep their memory; a new document flashes; a document resets the zoom limits |
| `PDFController+Live.swift` | 8, 124 | PDFKit's fade-in |
| `PDFController+Sync.swift` | 91 | a wrong `characterIndex` with T1 fonts |
| `PDFPane.swift` | 11 | no scroll view round `PDFView` |
| `CompletionList.swift` | 20, 197 | a SwiftUI list because the system's has no glass; NSMenu's measures |
| `FormatPopover.swift` | 57 | Notes' Aa measures |
| `IssueBox.swift`, `IssueOverlay.swift` | 4; 105 | the box over `_NSTextSelectionView`; TextKit 2 drawing no underline from a rendering attribute |
| `Commands.swift` | 213, 297 | menu images only with `.titleAndIcon` |
| `MenuItems.swift` | 33, 110, 121 | the palette's rows, selection and width; `MathGlyphs.unmark`, `.centre` |
| `SidebarView.swift` | 65, 382, 417, 421 | the context menu's row −1 crash; `HeadingRow` being Equatable; the measured `sidebarListRoom` and `OutlineHeader.row` |
| `HomeView.swift` | 337 | `NameWidth` and a typed trailing space |
| `PaneBars.swift` | 131 | `.controlSize(.regular)` on sheets |
| `BuildPanel.swift` | 52, 136 | |
| `MainWindow.swift` | 175 | |
| `WorkspaceController.swift` | 92, 156, 163 | |
| `WorkspaceToolbar.swift` | 222, 233, 336, 366, 383, 406, 452, 466 | |

Native replacements that need a look on screen:
- The completion list as NSTextView's own completion (`CompletionList.swift:18` says the system's
  list still looks pre-glass).
- Aa's level rows (`FormatPopover.swift:133–193`) as a `Picker`: about 60 lines fewer, but not
  Notes' look.

## Kept as too risky without running the app

- **Mac:**
  - `SourceDocument`'s fallbacks for a missing answer: a crash while typing would lose work.
  - `Colors.swift`'s optional `contrastArguments`, as the high-contrast appearances may not exist.
  - The changed-on-disk alert's `runModal` fallback for a text view with no window.
  - The measured numbers in `IssueBox`, `EditorGutter` and `FormatPopover`.
  - `typingBackKeepsTheFieldsMatches`'s 300 ms sleep: it checks that nothing happens.
  - Folding `theOutlineReadsTheInputs` into `theLevelsAreTheMainFilesClasses`.
- **Windows:** the source checks in `Command`, `ShowFind`, `OnReplace` and `OnPaste` (the menus
  and find bar work after a file closes); `Reload`'s check after its `await`; `ShowPartner`'s range
  check; `PdfView.Load`'s catch, which keeps the last good PDF.
- **Core:**
  - `tests/texpresso_live.rs` stays an integration test, as `texpresso.rs` is a single file.
  - `watch::relative` and `tree`'s `Entry::rel` stay apart: one drops names that aren't UTF-8 and
    the other keeps them with U+FFFD.
- **Tools:** `tools/qa/xctest.sh` has odd bytes in a comment and a grep pattern, possibly needed
  on macOS.

## Out of scope

- `tools/texpresso/underleaf-pdf.patch` is a patch to TeXpresso's own code.
- `tools/qa/library-seed/` holds the QA test projects.
- The core's larger candidates are in `docs/audit-2026-10.md`, "Left for later".
