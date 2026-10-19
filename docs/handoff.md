# Hand-over: what the October concise pass left (2026-10-19)

The audit branch (`claude/audit-cuts`, PR #53) gave the repo a pass under AGENTS.md's "Writing
code" rules, the Windows shell's redesign included; `docs/audit-2026-10.md` says what it cut.
These parts it didn't cut, and why.

## Paused on the Mac (2026-10-20)

Done on this branch:
- **Restored main's decided Mac behaviour**, which the branch had lost by being built on the reverted
  `claude/trim` line: 542 pt window with the side columns folding, the divider under the toolbar's
  separator, Compile's form from measured widths, detents and haptic, double-click to even, sidebar
  270/222, fixed inspector divider, the display link and quiet scrollers in pane animations, PDF white,
  dark or automatic paper and Settings' PDF pane, the untinted surfaces, the status bar's measures, Aa's
  glass tiles. AGENTS.md's Mac section is main's again. Seen on screen: the narrow window, the divider's
  detent and double-click, dark paper, the editor's surface around the PDF, Aa, completion, Compile and
  issues, Live Preview.
- `kill_all` at quit goes through the async path; core-api.md lists `locate` (allowed on the UI thread)
  and what `session_save`'s `reporting` does.
- **27.2 workarounds:** none could go on the headless evidence (ten probed today, their bugs still show:
  `characterIndex` on T1 fonts, replaced pages' memory, zoom limits, menu images, the Share item, the
  rendering-attribute underline, PDFKit's quarter-second fade, the frame guard, PDFKit's one drawer, no
  super for `constrainSplitPosition`). On screen against a build with each turned off: still needed are
  `HeadingRow`'s Equatable, `redrawFragments` and the width following a live resize; the sheets'
  `.controlSize(.regular)` was not, and is gone. Not yet looked at: the viewport after quick divider
  drags (`layOutViewportOnceSettled`), the display link for the PDF, inspector and panel (the sidebar
  animated without it in a 110 ms-per-frame capture), the PDF shown at launch then collapsed, the
  palette's text-only rows and `MathGlyphs.unmark`, `NameWidth`'s trailing space, and AppKit's own
  completion list.
- Once, after a slow then quick divider drags in Test Long, a blurred band about 115 pt tall showed
  over the source's last lines in this build; three later tries didn't show it, nor main's build.

**The review (2026-10-20)** found 29 issues a skeptic confirmed. Fixes are on three branches from
ae4116ab, pushed and not yet merged: `claude/fix-core` (done: the case-only rename, Return in tab
indentation; left: the `-` import, the 8 MB guard, the sleeping tests, the docs), `claude/fix-mac` (done:
the overtaken open, New File and Add Files during a switch; left: the fold classification, the
detent in `joinDivider`, Aa's highlight, the undo test, a failed-save test, `SessionOpened.pdf`, `free`),
`claude/fix-windows` (done, uncompiled: reloads of unshown documents, the TitleBar inset; left: a
reporting save before leaving a project, waiting for `set_ui_state` before a rename, `free`). The
findings:
- Core: a case-only rename of an open file or folder closes it and loses later edits (`paths::within`
  folds case; `session::rename`); Return in tab indentation adds tabs; File › Open of a `-name.tex`
  fails; Live Preview reads any changed text file whole (main's 8 MB guard); two tests sleep 100 ms;
  docs (live_page order, reloads of unshown documents, `kill_all`, texlocal.h's maths answer,
  design-tokens' Mac metrics, the audit's test count and Windows Home row).
- Mac: an open overtaken by a later one can leave the editor on a closed document, dropping typing;
  New File or Add Files during a project switch writes into the old project; a side column AppKit folds
  after a click is saved as hidden; `joinDivider` can snap to the even split's detent; Aa opens with
  Normal Text highlighted (main too); the mirrored-field undo test can't fail; no test of a failed
  save; `SessionOpened.pdf` unused; `create_entry`'s `free`.
- Windows: a `document_reload` for an unshown document blocks its saves; leaving a project closes the
  session without a reporting save; `session_rename` doesn't wait for `set_ui_state`; `create_entry`'s
  `free`; maybe main's TitleBar inset compensation.
To resume: check each branch's commits, merge into `claude/audit-cuts`, run the Mac tests named in the
Mac branch's report (`tools/qa/xctest.sh`), push for CI (Windows builds only there), then the on-screen
checks above, `tools/install-mac.sh`, and merge PR 53.

## On the Mac, first

Start from PR #53's branch (from `main` once it merges):

```sh
git fetch origin && git switch claude/audit-cuts
zsh tools/qa/typecheck.sh
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal   TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev test
```

1. **Check the pass on screen.** The pass edited the Swift without a compiler. CI built it and ran
   its tests, but nobody has used the app since. Go through a project with the QA driver
   (`tools/qa/README.md`), on its QA copy:
   - typing and completion;
   - Aa, Math and Insert, and the maths preview;
   - Compile, the build panel and its issues;
   - SyncTeX both ways;
   - Live Preview;
   - renaming and deleting in the sidebar, and Home.
2. **Test the 27.2 workarounds.** Turn each one below off, and remove it where its bug no longer shows
   on the current macOS.
3. **Then the rest:** the native replacements below, and the Mac items under "Kept as too risky".

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
  check; `PdfView.Load`'s catch, which keeps the last good PDF. `WorkspacePage.xaml`'s Light and
  Default colour sets for the command bar's checked toggles look alike but resolve against the
  theme; merge them only after checking light, dark and high contrast on screen.
- **Core:**
  - `tests/texpresso_live.rs` stays an integration test, as `texpresso.rs` is a single file.
  - `watch::relative` and `tree`'s `Entry::rel` stay apart: one drops names that aren't UTF-8 and
    the other keeps them with U+FFFD.
- **Tools:** `tools/qa/xctest.sh` has odd bytes in a comment and a grep pattern, possibly needed
  on macOS; it and `fg-guard.zsh` share a lock loop that one copy could serve, untested without zsh.

## Windows, for a later WindowsAppSDK

WinUI 2.3.9's `TitleBar` sets `RightPaddingColumn` (right of `RightHeader`) in native code from
`AppWindow.TitleBar.RightInset`; at 150% it comes out about twice the caption buttons' width, so
about one caption group's gap parts the Settings gear from Minimise. No supported setting changes
it: not the order of `PreferredHeightOption`, nor `TitleBarRightPaddingWidth` (the code overwrites
it), and `TitleBarMinDragRegionWidth` only gives back its 48.

## Out of scope

- `tools/texpresso/underleaf-pdf.patch` is a patch to TeXpresso's own code.
- `tools/qa/library-seed/` holds the QA test projects.
- The core's larger candidates are in `docs/audit-2026-10.md`, "Left for later".
