# Underleaf: notes for agents

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
  non-key panel draws flat. Syntax colours are rendering attributes, which 27.2 doesn't redraw
  on fragments already shown: each fragment keeps the runs it was last coloured with, and a
  recolouring redraws the edited fragment and those whose runs changed, not every line on
  screen (typing in a long document costs about 40% less CPU for it).
- **Issues** are on their lines as in Xcode: a gutter of numbers only, a band over the whole
  paragraph (`tertiarySystemFill`), and at the end of its first line a SwiftUI box
  (`IssueBox`, hosted above the text's views by `IssueMessageView`) holding the symbol and
  the core's one-line message (its `compact` form where the line is short of room), or the
  symbol alone. A help tag and a click open
  the build panel on it. Its measures follow the text's size. Underline styles set as
  rendering attributes aren't drawn (27.2), so an undefined command's underline is drawn
  under the text.
- **Status bar**: across the source and PDF columns as Xcode's editor bar: a 36 pt bar
  (`BarMetrics`) over AppKit's hard scroll edge, which is Xcode's: each pane has an empty bottom
  accessory of the bar's height with the hard style, for its edge, safe area and scrollers, and the
  bar lies over both (one accessory across the columns gave its edge to one pane only, 27.2). Text
  and pages ghost through it, about 11% of their contrast, evenly over its height, under AppKit's
  own line. Until a scroll prepares content, TextKit's content view ends at the scroll view's
  insets, so the source prepares its visible rect after each viewport layout or the lines under the
  bar wouldn't draw after a launch or a resize (27.2). The splits keep AppKit's weights, as Mail's
  and Xcode's: a point between the columns and over the build panel, half a point for the sidebar
  and inspector. The build panel resizes from the bar's line and is dragged open and shut there, as
  Xcode's debug area (`area.grip`, an additional effective rect, which the split hit-tests before
  the bar; the panel's `canCollapse`). After a failed save, or a Cancel in an alert about the file
  on disk, it says Not Saved and that button saves; a failed autosave is also told once in an
  alert, as NSDocument's are.
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
  and one around PDFKit's view takes its rubber-banding and insets (27.2). A fitted page keeps
  PDFKit's side margins, which scale with it, as Preview's do. Pages have no top margin, so the
  first meets the toolbar's edge, and at the document's start it stays there as the pane resizes
  (`atDocumentStart` allows a device pixel for the clip view's rounding). AppKit draws the
  toolbar's line over the page at its top while the page is magnified past 1 and not below 1
  (27.2); no public setting changes it.
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
- The Windows app: `dotnet test apps/windows/TeXLocal.Tests -c Debug`; `TeXLocal.exe --smoke`
  opens Home and exits 0. Run dev builds with a scratch `TEXLOCAL_DATA`, never beside the
  installed copy (`docs/windows.md`, Building and testing).
- Quicker than a build: `zsh tools/qa/typecheck.sh` type-checks the app and its tests in about
  20 s; `tools/qa/xctest.sh <repo> <derived data> [-only-testing:…]` runs the native tests one
  at a time per session. Worktree agents use these rather than parallel `xcodebuild`s.
- On screen: the QA driver in `tools/qa` (its README has the setup and the rules), on a QA copy
  (`com.texlocal.mac.qa`, data in a scratchpad), never the installed app or `~/TeXLocal`.
- The live preview's end-to-end check needs the patched engine:
  `cargo test -p texlocal-core --test texpresso_live -- --ignored` (`docs/texpresso.md`).
- Physical trackpad gestures, the dividers' haptic, interactive IME and visual-material
  checks stay manual.

## Build and install the Mac app

Requires Xcode 27 and Rust stable. `zsh tools/install-mac.sh` builds the checkout it is in
(Release, derived data in `/private/tmp/underleaf-release`), quits TeXLocal, ad-hoc signs and
installs `/Applications/TeXLocal.app`, verifies its signature, compares the installed and built
binaries, and reopens it.

## Build and install the Windows app

Requires the .NET 10 SDK and Rust stable. Quit TeXLocal, then run `apps/windows/install.ps1`:
it publishes a self-contained Release build to `%LOCALAPPDATA%\Programs\TeXLocal`, replacing
what is there, and points the Start menu's TeXLocal shortcut at it.

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
- Measured on the 400-page test document (2026-10-18), not yet improved: a build's PDF shown in
  place costs the main thread about 0.7 s, mostly PDFKit relaying out its view per inserted and
  removed page (quadratic in the page count; a 20-page document is a few milliseconds); a SyncTeX
  query runs the `synctex` program, which reads the whole 14 MB file each time (about 80 ms).
  Keeping unchanged pages would need a comparison that also sees changed images and fonts, and an
  in-core SyncTeX index would have to match the program's box choice exactly.
- Profiling without the screen: `xcrun xctrace record --template 'Time Profiler' --attach <pid>`,
  with typing posted through Accessibility (`AXSelectedText`); a driver that walks the window's
  tree per key measures PDFKit building accessibility nodes (it runs text recognition on pages),
  not typing. The per-key core work is about 0.1 ms; AppKit's text checking and drawing are the rest.
- TeX on macOS 27 (MacTeX 2026, March package): biber's universal launcher calls
  `lipo -extract_family`, which macOS 27's `lipo` refuses, so biber exits with lipo's usage until
  `tlmgr update biber` (or its arm64 slice) replaces it. ConTeXt and arara are not in that package.
