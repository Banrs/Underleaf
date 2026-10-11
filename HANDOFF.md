# Underleaf handoff — 12 October 2026

## Branches

`main` holds the work. `refactor/frontend-native` (the HIG refactor, the Xcode-style
completion list and the page-by-page live preview) was fast-forwarded into it on 12 October.

## The Mac app's shape

- **Window, toolbar and splits are AppKit**: only `NSToolbar`'s tracking separators follow
  the source|PDF divider, and a three-column `NavigationSplitView` can't hide its detail
  column. Panes, bars, sheets, popovers, Settings and Home are SwiftUI, hosting AppKit's text
  and PDF views where SwiftUI has none.
- **Narrow windows**: the window stops at 542 pt (about 605 with source and PDF); source and
  PDF keep minimums of 260 and 200 pt, the sidebar Xcode's navigator's 222. Tools without room
  go to `NSToolbar`'s own overflow menu by `visibilityPriority`, and nowhere else; Compile
  gives up its word for its symbol first. AppKit overflows by the toolbar's whole width, so
  between about 900 and 700 pt a pane's tools can sit over its neighbour. Sidebar and
  inspector fold for a narrow window and are not saved as hidden for it (`sidebarFolded`).
- **Source**: one TextKit 2 `NSTextView` (`SourceTextView`), shared across files, in an
  `NSScrollView` of its own (`EditorView`). Xcode's metrics for the font, gutter and current
  line; the completion list (`CompletionList`) is a copy of Xcode 27's, an opaque panel in a
  child window that never takes the keyboard.
- **Status bar**: the source/PDF columns' bottom accessory at Xcode's measured spacing (14 pt
  in, 9 between items, 36 high). Its ground is the editors' colour at 85% over AppKit's
  accessory edge, with a device-pixel separator line in a row of its own above it, the row of
  the File Outline header's line. SwiftUI's hard scroll edge (Xcode's look) draws only over a
  SwiftUI scroll view, and one around PDFKit's view takes its rubber-banding and insets
  (27.2), so the PDF view sits directly in its pane.
- **Build panel**: below the columns, so the status bar rides up as it opens, with AppKit's
  collapse animation. Its controls are a bar at its foot, as Xcode's console bar: a pop-up for
  Issues, Build Log and Live Preview Log, then Warnings or Copy Log, then a filter. Its list
  hides the system's wallpaper-tinted ground so it is the editors' colour.
- **Split dividers** are a device pixel (`HairlineSplitView`); the source|PDF divider stops
  above the status bar (`ColumnsSplitView`), and a double-click on it restores the even split.
  A display link lays the splits out during pane animations, which otherwise don't always
  reach the screen (27.2).
- **PDF**: a rebuilt document's pages replace those showing, in the same `PDFDocument`, since
  a new document flashes the pane's background for a few frames. PDFKit keeps every such
  page's objects for the document's life, so once the app has grown by 512 MB since a document
  was last shown whole, the next one is shown whole (`PDFController.memoryAtWhole`).
- **Live preview**: each edit goes to the core as the text storage makes it (`texpresso_edit`);
  a thread of the session's own waits in the core (`texpresso_wait`) for the pages in view,
  and each is drawn over PDFKit's page at once (`LiveCanvas`, an IOSurface). The whole
  document follows 300 ms after the last key and replaces only the pages that changed. The
  protocol and the engine's passes are in `docs/texpresso.md`.
- **Settings**: a five-pane window (General, Editor, Compiling, PDF, Live Preview).
- **Words**: the feature is Live Preview, and TeXpresso is named only where the program is the
  subject; the verb is Compile and a run and its result are a build.

Platform quirks met on the way (27.2) are in the code's comments where they're handled.

## Validation, 12 October

CI: `ci.yml` runs the web tests and bundle and the Rust core's rustfmt, clippy and tests on
Linux; `macos-app.yml` builds the app, checks the core is linked statically, runs the native
tests and fails a run in which none passed.

- Native: 140 tests in 19 suites pass. `npm test`: 183. Rust: 242, with rustfmt and clippy
  `-D warnings` clean. `npm run verify:texpresso`: 25 checks against the patched engine.
- Live preview, measured from 60 fps screen recordings of a Release build on a one-page
  document: the pane shows a key's page one frame after the editor shows the glyph (median
  17 ms, worst 42 ms); TeXpresso's own window, the same way, in zero to one frame (worst
  41 ms). Headless, a key reaches its page in 12.9 ms median through the core against 12.2 ms
  to the window's flush.

The native tests run a host app that shares the app's defaults unless built with another
bundle identifier: build with `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`, as CI does with
its own, or quit the installed app first.

## Build and install

Requires Xcode 27, Rust stable and installed npm dependencies.

```sh
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-dd \
  TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev CODE_SIGNING_ALLOWED=NO test

xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-release \
  CODE_SIGNING_ALLOWED=NO build
```

Quit TeXLocal, ad-hoc sign the Release product, replace `/Applications/TeXLocal.app`, verify
its signature, and compare the installed and built binaries.

## Open

- Live preview is about half a frame behind TeXpresso's own window at a steady typing pace;
  each page file carries its fonts whole, and most of drawing a fresh page is setting them up.
- `texpresso-xetex` has not been rebuilt with the patch's change that leaves TeX Live's `doc`
  and `source` folders out (it needs ICU, HarfBuzz and Graphite headers): run
  `tools/texpresso/build.sh` where they are installed.
- Not seen on screen since the live preview's rewrite: a restart after TeXpresso exits, a
  quick Stop and Start, Find and the selection while pages are replaced.
- Physical trackpad gestures and interactive IME remain manual checks. ZIP import has
  per-entry limits but no total extraction budget.
