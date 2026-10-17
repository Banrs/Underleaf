# Underleaf handoff

Status and decisions for the next agent. `README.md` is the overview and `docs/core-api.md`
the hosts' contract with the core.

## Shape

- **Rust core** (`crates/texlocal-core`) builds and tests on macOS and Windows; Linux isn't
  supported. It owns everything but UI and OS integration: projects, path safety, latexmk
  and SyncTeX, log parsing, ZIP export, the JSON command service, and **project sessions**
  (`session/`): each open document's text, autosave, notify-based folder watching, builds,
  issues, the outline's analysis and the TeXpresso client. Hosts send commands and receive events
  (`tl_set_listener`). Logic both hosts need lives here, never in a host.
- **The core's `syntax` module** is I/O-free and owns editor logic: typing transforms,
  snippets, completion, highlighting, themes, the symbol and template catalogue, heading
  styles, the ranges spelling and Writing Tools leave alone, and maths and glyph rendering
  through RaTeX (`math_svg`, `glyph_svg`).
- **`crates/texlocal-ffi`** is the C ABI, built as a static library (and an rlib for its
  tests); the Windows app builds its DLL with `cargo rustc --crate-type cdylib`.
- **macOS app** (`apps/macos`) is UI only, on the core.
- **Windows app** (`apps/windows`) is a native WinUI 3 / Fluent app, UI only, on the core;
  `docs/windows.md` has its design and the core gaps it waits on.
- **CI** is `.github/workflows/ci.yml`: a path-filtered `changes` job, Rust on macOS and
  Windows, the Windows app's build, tests and smoke run, the Mac app's `xcodebuild test` on
  the `xcode-27` runner, and `ci-ok`, the one required check.

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
- **Toolbar**: Compile is the window's one prominent item, as a word, changing to its symbol
  only where the word has no room (as AppKit's search item changes form); while building it
  is Stop, with its spinner. Aa opens Notes' popover of text styles (`FormatPopover`); Math
  and Insert are menus beside it.
- **Source**: one TextKit 2 `NSTextView` (`SourceTextView`) shared across files, in an
  `NSScrollView` of its own (`EditorView`), at Xcode's metrics for font, gutter and current
  line. The completion list (`CompletionList`) is Liquid Glass in a system menu's measures,
  a view of the editor's scroll view and not a window, since glass in a borderless
  non-key panel draws flat.
- **Issues** are on their lines as in Xcode: a gutter of numbers only, a band over the whole
  paragraph (`tertiarySystemFill`), and at the end of its first line a SwiftUI box
  (`IssueBox`, hosted above the text's views by `IssueMessageView`) holding the symbol and
  the core's one-line message (its `compact` form where the line is short of room), or the
  symbol alone. A help tag and a click open
  the build panel on it. Its measures follow the text's size. Underline styles set as
  rendering attributes aren't drawn (27.2), so an undefined command's underline is drawn
  under the text.
- **Status bar**: across the source and PDF columns as Xcode's editor bar, measured on screen:
  a point line over a 36 pt bar (`BarMetrics`), over AppKit's own scroll edge, its automatic
  style. Each pane has an empty bottom accessory for its own edge, safe area and scrollers, and
  the bar lies over both (`buildStatusBar`): one accessory across the columns gave its edge to
  only one pane, about half the launches (27.2). Under the PDF the accessory is the text's opaque ground
  (`Ground`): the white pages showed through the edge as a grey slab in Dark. The bar's line is
  one opaque `Line` over AppKit's own pixel, which took another tone in Dark. A fitted page meets
  the pane's sides: PDFKit's 4 pt side margin drew a second edge inside the window's. The File Outline's header does the same under the files'
  hard edge, so folded the lines meet and the titles are level. The splits keep AppKit's weights,
  as Mail's and Xcode's: a point for the thin dividers between the columns and over the build
  panel, a device pixel for the window's sidebar. The build panel resizes from the bar's
  line, as Xcode's debug area does (`area.grip`). In Dark each pane's edge takes that pane's
  tone, AppKit's look. After a failed save, or a Cancel in an alert about the file on disk, it
  says Not Saved and that button saves.
- **Build panel**: below the columns, so the status bar rides up as it opens. A bar at its
  foot, as Xcode's console bar: a pop-up for Issues, Build Log and Live Preview Log, then
  Warnings or Copy Log, then a filter. The bar is a SwiftUI safe-area bar, where the filter
  draws as a toolbar's capsule; the filter is a regular 24 pt control among small ones.
- **Splits**: AppKit's thin dividers. The source|PDF divider stops above the status bar
  (`ColumnsSplitView`) and a double-click restores the even split; a drag stops at the
  sidebar's opening width and the even split, with the alignment haptic
  (`DetentSplitViewController.detent`). A display link lays the splits out during pane
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
- **Sessions**: the open project is a core session, numbered by the app before it opens
  (`Core.observe`), so none of its events can come before the app listens. Commands go
  through `tl_call_async` and are awaited, so no thread waits on the core; a session takes
  them in the order sent. Events are decoded on the core's thread and reach their session's
  `ProjectModel` on the main actor in order. `ProjectModel` is split by concern:
  `ProjectModel.swift` (state, events, editing, outline, conflicts, settings),
  `+Build`, `+Live` (live preview and SyncTeX), `+Files`, and `SessionEvents.swift`. The
  sidebar's open folders and folded headings are the project's settings (`get_ui_state`,
  `set_ui_state`, and a rename's answer), not UserDefaults.
- **Editor logic is the core's**: each key asks the source (`tl_source_call`: `type`,
  `delete_backward`, `insert_newline`) for the edit to type instead; each storage edit is
  told back once (`tl_source_edit`, which also answers a snippet's mirror edits) and each
  selection too (`tl_source_select`). The text comes from `tl_source_text`, and what
  spelling and Writing Tools skip from `code_ranges`. Command edits, theme colours, the menu
  catalogue and maths SVG come from `tl_syntax_call` (`Syntax`). The maths preview is set at
  1.21 times the text.
- **Other helpers are the core's**: SyncTeX finds the word (`synctex_match`,
  `synctex_inverse`); `session_analyze` gives the outline's tree with its fold keys, the
  word count and the main file's heading styles, and `session_outline_current` the heading
  at a line; an issue line carries its message's `compact` form and where its command is
  (`tokens`); a file's kind comes with `file_tree`; a free name with `create_entry`.
- **Live preview** belongs to its project session, by the session's number. The session
  sends each edit on to TeXpresso and reports its pages (`live_document`, `live_page`);
  `TeXpressoSession` reads them off the main actor and `PDFController` swaps them into the
  pane (`showLive`). The whole document follows 300 ms after the last key and replaces only
  the pages that changed. While the Live Preview Log shows, the `live` event carries its
  text (`session_live_log`). Settings ▸ Live Preview chooses the pane or TeXpresso's own
  window. The protocol is in `docs/texpresso.md`.
- **A file another app changed** while it has unsaved edits here is asked about in an AppKit
  alert (Save Anyway, Revert, Cancel) with no default button, since either answer loses a
  version; SwiftUI's alert can't omit the default. One moved or deleted gets a SwiftUI alert
  whose default saves it again. Cancel writes nothing (the session's `conflict` event,
  answered with `session_resolve`).
- **Dim, not hidden**, where hiding would make things jump: the File Outline, the panel's
  Warnings toggle with no warnings, Live Preview Log before Live Preview has run, and
  Format items in files the toolbar's are dim in.
- **Settings** has five panes: General, Editor, Compiling, PDF (white, dark or automatic
  paper), Live Preview.
- **Words**: the feature is Live Preview; TeXpresso is named only where the program is the
  subject. The verb is Compile, and a run and its result are a build. Interface spelling is
  British (Colours) except LaTeX's own terms (Math).
- **Home** offers new projects as template cards.

Platform quirks met on the way (27.2) are in the code's comments where they're handled.

## Testing

- `cargo test --workspace`; CI also runs `cargo fmt --all --check` (macOS) and
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
- The Windows app is not finished (no live preview yet); it follows `docs/core-api.md` and is
  ported to its "Changes for hosts (October 2026)".
