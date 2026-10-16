# Underleaf handoff

Status and decisions for the next agent. `README.md` is the overview and `docs/core-api.md`
the hosts' contract with the core.

## Shape

- **Rust core** (`crates/texlocal-core`) builds and tests on Windows, macOS and Linux. It owns
  everything but UI and OS integration: projects, path safety, latexmk and SyncTeX, log
  parsing, ZIP export, the JSON command service, and **project sessions** (`session/`):
  each open document's text, autosave, notify-based folder watching, builds, issues and the
  TeXpresso client. Hosts send commands and receive events (`tl_set_listener`).
- **`crates/texlocal-syntax`** is I/O-free and also builds to wasm. It owns editor logic:
  typing transforms, snippets, completion, highlighting, themes, the symbol and template
  catalogue, heading styles, and maths and glyph rendering through RaTeX (`math_svg`,
  `glyph_svg`).
- **`crates/texlocal-ffi`** is the C ABI: a static library for the Mac app, a dynamic one
  for the Windows app.
- **`crates/texlocal-server`** serves the API on `127.0.0.1` with a startup token. A web
  directory is optional: with none, it serves the API alone. A browser frontend is to be
  written on the same core.
- **macOS app** (`apps/macos`) is UI only, on the core.
- **Windows app**: a native WinUI 3 / Fluent app is in progress on branch `claude/windows`.
- **CI** is `.github/workflows/ci.yml`: a path-filtered `changes` job, Rust on Ubuntu and
  Windows, the Mac app's `xcodebuild test` on the `xcode-27` runner, and `ci-ok`, the one
  required check.

## The Mac app

- **Window, toolbar and splits are AppKit**: only `NSToolbar`'s tracking separators follow
  the source|PDF divider, and a three-column `NavigationSplitView` can't hide its detail
  column. Panes, bars, sheets, popovers, Settings and Home are SwiftUI, hosting AppKit's
  text and PDF views where SwiftUI has none.
- **Narrow windows**: the window stops at 542 pt, the toolbar's least (`ColumnMetrics`).
  Source and PDF keep minimums of 260 and 188 pt; the sidebar's is 222 and it opens at 270.
  Tools without room go to `NSToolbar`'s own overflow menu by `visibilityPriority`, and
  nowhere else. Sidebar and inspector fold for a narrow window and are not saved as hidden
  for it. The window's title is AppKit's, which keeps 160 pt for it (27.2); the system's
  title and overflow were chosen over a custom one.
- **Toolbar**: Compile is a symbol item (it becomes Stop while building). Aa is an
  `NSMenuToolbarItem` menu grouped as Notes'; Math and Insert are menus beside it.
- **Source**: one TextKit 2 `NSTextView` (`SourceTextView`) shared across files, in an
  `NSScrollView` of its own (`EditorView`), at Xcode's metrics for font, gutter and current
  line. The completion list (`CompletionList`) is Liquid Glass in a system menu's measures,
  a view of the editor's scroll view and not a window, since glass in a borderless
  non-key panel draws flat.
- **Issues** are on their lines as in Xcode: a gutter of numbers only, a band over the whole
  paragraph (`tertiarySystemFill`), and at the end of its first line a box
  (`IssueMessageView`, an `NSBox`) of system views holding the symbol and the core's
  one-line message, or the symbol alone where there is no room. A help tag and a click open
  the build panel on it. Its measures follow the text's size. Underline styles set as
  rendering attributes aren't drawn (27.2), so an undefined command's underline is drawn
  under the text.
- **Status bar**: the source and PDF columns' bottom accessory at Xcode's spacing
  (`BarMetrics`), on a ground of its own (83% of the editors' colour over a Core Image blur,
  `blurBackdrop`) and a point line above it. AppKit's own scroll edge can't be its ground on
  27.2: it goes to one pane's scroll view only, and stays there once the PDF has been hidden. After a failed save, or a Cancel in an alert about the file on disk, it says Not
  Saved and that button saves.
- **Build panel**: below the columns, so the status bar rides up as it opens. A bar at its
  foot, as Xcode's console bar: a pop-up for Issues, Build Log and Live Preview Log, then
  Warnings or Copy Log, then a filter. The bar is a SwiftUI safe-area bar, where the filter
  draws as a toolbar's capsule; the filter is a regular 24 pt control among small ones.
- **Splits**: AppKit's thin dividers. The source|PDF divider stops above the status bar
  (`ColumnsSplitView`) and a double-click restores the even split; a drag stops at the
  sidebar's opening width and the even split, with the alignment haptic
  (`RestoredSplitViewController.detent`). A display link lays the splits out during pane
  animations, which otherwise don't always reach the screen (27.2).
- **File Outline** sits at the sidebar's foot. On a file that isn't LaTeX it stays, folded
  and dim; it hides only for search results.
- **PDF**: a rebuilt document's pages replace those showing in the same `PDFDocument`, since
  a new document flashes the pane's background. PDFKit keeps every replaced page's objects
  for the document's life, so once the app has grown by 512 MB since a document was last
  shown whole, the next one is shown whole (`PDFController.memoryAtWhole`). Print prints the
  document showing; during Live Preview it reads the last build's file (`buildBehindLive`).
  The PDF view sits directly in its pane: SwiftUI's scroll edge needs a SwiftUI scroll view,
  and one around PDFKit's view takes its rubber-banding and insets (27.2).
- **Sessions**: the open project is a core session. The editor sends each edit once
  (`tl_source_edit`); `ProjectModel` learns what changed from events (`Core.observe`, on the
  main queue in order); session commands go one at a time on a queue of their own
  (`Core.session`, `Core.send`). The sidebar's open folders and folded headings are the
  project's settings (`get_ui_state`, `set_ui_state`), not UserDefaults.
- **Editor logic is the core's**: each key asks the source (`tl_source_call`: `type`,
  `delete_backward`, `insert_newline`) for the edit to type instead, and each storage edit
  and selection is told back (`follow`, `select`). Command edits, theme colours, the menu
  catalogue, heading styles and maths SVG come from `tl_syntax_call` (`Syntax`). The maths
  preview is set at 1.21 times the text.
- **Other helpers are the core's**: SyncTeX finds the word (`synctex_match`,
  `synctex_inverse`); the outline's tree and fold keys come with `analyze_project` and its
  current heading with `outline_current`; a file's kind with `file_tree`; a free name with
  `create_entry`; an issue box's message as `short`.
- **Live preview**: the session sends each edit on to TeXpresso and reports its pages
  (`live_document`, `live_page`); `TeXpressoSession` reads them off the main actor and
  `PDFController` swaps them into the pane (`showLive`). The whole document follows 300 ms
  after the last key and replaces only the pages that changed. The protocol is in
  `docs/texpresso.md`. The pane is the only display: TeXpresso opens no window of its own.
- **A file another app changed** while it has unsaved edits here is asked about in an AppKit
  alert (Save Anyway, Revert, Cancel) with no default button, since either answer loses a
  version; SwiftUI's alert can't omit the default. One moved or deleted gets a SwiftUI alert
  whose default saves it again. Cancel writes nothing (the session's `conflict` event,
  answered with `session_resolve`).
- **Dim, not hidden**, where hiding would make things jump: the File Outline, the panel's
  Warnings toggle with no warnings, Live Preview Log before Live Preview has run, and
  Format items in files the toolbar's are dim in.
- **Settings** has four panes: General, Editor, Compiling, Live Preview.
- **Words**: the feature is Live Preview; TeXpresso is named only where the program is the
  subject. The verb is Compile, and a run and its result are a build. Interface spelling is
  British (Colours) except LaTeX's own terms (Math).
- Removed on purpose: a dark-paper PDF, TeXpresso's own window, Home's template cards.

Platform quirks met on the way (27.2) are in the code's comments where they're handled.

## Testing

- `cargo test --workspace`; CI also runs `cargo fmt --all --check` (Linux) and
  `cargo clippy --workspace --all-targets -- -D warnings`.
- The Mac app: `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal test`
  (Swift Testing). The tests run a host app that shares the app's defaults unless built
  with another bundle identifier: pass `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`, as CI
  does with its own, or quit the installed app first.
- The live preview's end-to-end check needs the patched engine:
  `cargo test -p texlocal-core --test texpresso_live -- --ignored` (`docs/texpresso.md`).
- Physical trackpad gestures, the dividers' haptic, interactive IME and visual-material
  checks stay manual.

## Build and install the Mac app

Requires Xcode 27 and Rust stable.

```sh
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-release \
  CODE_SIGNING_ALLOWED=NO build
```

Quit TeXLocal, ad-hoc sign the Release product, replace `/Applications/TeXLocal.app`, verify
its signature, and compare the installed and built binaries.

## Open

- A long document's live preview latency has not been measured on screen.
- The TeXpresso engine on Daniel's Mac is the patched `texpresso` built against MuPDF and
  SDL2 made from source, and `texpresso-xetex` built against Homebrew's `icu4c`, `harfbuzz`
  and `graphite2`, which have to stay installed. `tools/texpresso/build.sh` builds both
  where Homebrew has all of TeXpresso's dependencies and `pkg-config`.
- Not watched on screen since the live preview's rewrite: a restart after TeXpresso exits,
  and a quick Stop and Start.
- The browser frontend and the Windows app are not finished.
