# Handoff: TeXLocal

## Status (2026-09-28)

- `main` is pushed (`91bd62f`). CI hasn't reported on it yet.
- `claude/macos-polish` (not pushed) is the Mac polish pass: one window with a back button, menus on focused values, one family of native bar controls, split, sidebar and drop fixes, a consistency and VoiceOver sweep, main-actor default isolation, and the fixes from an on-screen check and a code review. Its Mac Debug and Release builds have no Swift warnings and its tests pass.
- **`claude/macos-polish` (not pushed): a clean-up pass over the whole Mac app** (short WHY comments, magic numbers named or taken from the system, fragile tricks replaced). `c700d05` is a snapshot with a measured toolbar fold (`ToolbarFit`); later commits drop the fold: each column's minimum is its content's and the toolbar is the system's to fit (below). Defaults keys live in `DefaultsKey`; split sizes in `PaneSizes`; the file watcher is FSEvents; the sidebar slide is an `NSAnimation`. Debug and Release build with no Swift warnings and the tests pass.
- PR #11 (`claude/windows-parity`: WebView2 recovery, a trimmed SDK, an Inno Setup installer) is open. It needs `main` merged in; the conflicts are in the Windows `Outline`, `Dialogs`, `LogsView`, `ProjectModel`, `SettingsView` and `WorkspaceView`.
- Last full check passed: `cargo fmt --check`, clippy `-D warnings`, `cargo test --workspace`, `npm test`, Mac Debug and Release builds with no Swift warnings, and the XCTests.

## Layout

One Rust core (`crates/`) under three clients:
- **macOS** (`apps/macos`): SwiftUI, deployment target macOS 27.0, Swift 6 with Approachable Concurrency and main-actor default isolation, as Xcode 27's App template sets them. CI builds with Xcode 27 on the `xcode-27` runner image.
- **Windows** (`apps/windows`): WinUI 3, C#.
- **Browser** (`web/`, served by `crates/texlocal-server`): local only.
- **Tauri** (`src-tauri`) still ships until both native apps are verified.

The editor is CodeMirror everywhere (`web/embed/editor.html`). The PDF is PDFKit on the Mac and pdf.js elsewhere.

## Architecture

- **`Service::call(cmd, json)`** (`crates/texlocal-core/src/service.rs`) is the one JSON command table every host forwards to. Nothing that takes raw bytes or a host-chosen absolute path belongs in it, because the browser server exposes it. `set_tex_dir` and `list_dirs` are the exception.
- **FFI** (`crates/texlocal-ffi`, header in `include/`): `tl_open`, `tl_call` (blocking, so call it off the main thread), `tl_free`, `tl_close`. Native-only commands: `pdf_path`, `raw_path`, `project_root`, `export_zip`, `import_files`, `import_project`, `kill_all`.
- **Hosts:**
  - the Mac (`Core.swift`) and Windows (`Core.cs`) link the FFI;
  - the browser server calls `Service` directly, and `web/src/bridge.js` is its client;
  - Tauri forwards to one `call` command;
  - `serve.rs` serves `__pdf` / `__raw`.
- **`analyze`** (`analyze.rs`): outline, words and lines, ported from the web's `analyzeDoc` (`web/src/state.js`), which stays the source of truth. `crates/texlocal-core/tests/fixtures/analyze.json` is checked by both `cargo test` and `test/analyze.test.js`.
- **Atomic saves** (`atomic.rs`): write a temporary file beside the target, sync it, then rename it over the target.
- **Embed protocol:** the host calls `window.texlocal`. The page posts `ready`, `changed`, `cursor`, `scroll` and `command` (plus find messages on the Mac). Insert blocks are named by id; their LaTeX is in `BLOCK_TEMPLATES` (`web/src/latex-data.js`), which `test/blocks.test.js` checks.

## Build, test, run

- **Web and core:** `npm install`, `npm test`, `npm run build`, `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`. `npm run serve` runs the browser version; `npm run app` runs Tauri.
- **macOS:** `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -derivedDataPath <dd> build` (or `test`).
  - Pre-build runs `cargo build -p texlocal-ffi`. Post-compile runs `npm run build` and copies the embed into `Resources/web`.
  - The app links the static `libtexlocal_ffi.a` by path.
  - Bundle id `com.texlocal.mac`.
  - `project.yml` and the committed `.xcodeproj` are kept in step by hand, since XcodeGen isn't installed.
- **Typecheck against CI's SDK:** `xcrun swiftc -typecheck -swift-version 6 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos27.0 -I crates/texlocal-ffi/include apps/macos/TeXLocal/*.swift`.
- **Windows:** `cargo build -p texlocal-ffi`, then `dotnet build apps/windows/TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64` and `dotnet test apps/windows/TeXLocal.Tests/TeXLocal.Tests.csproj`.
- **CI:**
  - `ci.yml`: web, version check, Rust on Linux, Tauri bundles;
  - `macos-app.yml`: `xcode-27` runner and the XCTests;
  - `windows-app.yml`;
  - `release.yml`: runs on `v*` tags.
- **Mac Debug build on screen:** run it with `open -g -n --env TEXLOCAL_DATA=<library copy> <app> --args -openProject <id>`.
  - It shares the `com.texlocal.mac` defaults and window state with the installed app, so export them first and import them after.
  - Unregister scratch builds afterwards (`lsregister -u <app>`), or the Dock and Spotlight can open a stale copy.
  - Pressing Accessibility elements by substring can hit menu-bar items (it once opened System Settings); match exact titles within the window.

## macOS app (`apps/macos/TeXLocal`)

**Files:**
- `TeXLocalApp`: one window. It shows the projects (templates and recents) until one opens, then the project, with a back button (back only: one level, no history) and File › Close Project to return. Closing the window quits, and the quit saves. The window is `.windowManagerRole(.principal)`, for full screen rather than only zoom. `alert(_:)` shows any `AppAlert`.
- `AppModel`: library, recents, imports, alerts; `DefaultsKey` (every defaults key, registered defaults).
- `ProjectModel`: the open project, saves, builds, file watching.
- `Core`, `Models`, `Commands`: menus and shortcuts. Every item is a `MenuCommand`, which also lists the chords the editor page hands back. The menus act on the key window's project (`focusedSceneValue`). Insert sits between View and Window; Format keeps Bold, Italic, the section level and Comment.
- `WorkspaceView`: a three-column `NavigationSplitView` (sidebar | source | PDF), the PDF toggle, the Project Settings popover (`ProjectSettingsView`) and `ColumnMetrics`: the columns' minimums (their content's, not the toolbar's) and the window's minimum derived from them.
- `EditorView`: the source column (source, build panel, status bar) and its part of the toolbar.
- `EditorBridge`: a project's editor `WebPage`.
- `SourceBars`: the source's toolbar items (`SourceToolbar`), the section level, symbols, and the source's find bar.
- `PDFPane`: the PDF column, its toolbar items (`PDFToolbar`), Compile, and `PDFColumn`, which collapses the column.
- `LogsView`: the build panel.
- `SidebarView`, `Outline`, `HomeView`, `SettingsView`.
- `PaneBars`: bar metrics (the UI kit's), `Typography`, and pieces: the accessory bars (find bars, the build panel's header) at the regular control size; `PaneStack` and `FindBar` serve both panes; `TabsControl` is the build panel's tab switcher; `DialogSheet` is every small sheet; `InPlaceRename`, `RenameField` and `ItemMenuItems` are the gallery's and the sidebar's rename and item menu.
- `EditorPrefs` and `PDFPrefs` hold the typed keys and defaults (`EditorPalette`, `EditorFont`, `PDFPaper`) Settings shares with the editor and the PDF pane.
- Leaf views have `#Preview`s that need no Rust core.
- `SplitController`: `NSSplitViewController` panes, plus the sidebar's `SidebarSplit`; both keep pane sizes in `PaneSizes` (app-owned keys `"<autosave> Pane Sizes"`, not AppKit's autosave, which drops a hidden pane's size).
- `SyncTeXGeometry`.

**AppKit that remains, and why:**
- `SplitController` (the build panel under the source): `VSplitView` mislays panes and pins the window's width on macOS 27.2.
- `PDFColumn`: `NavigationSplitView` can't hide its last column, so the PDF's `NSSplitViewItem` is collapsed directly, and the source's holding priority matched to the PDF's so the two share the room.
- `TabsControl` (`NSSegmentedControl`, tabs role): SwiftUI's tabs picker style moved its thumb on hover.
- `SidebarSplit` is a plain `NSSplitView`: inside `NSSplitViewController` items, SwiftUI sidebar lists start 10 pt lower. Its divider slides on an `NSAnimation` (the split's displayLink stops while the screen is locked).
- `NSSearchField` in the find bars and the log filter: SwiftUI's search field is toolbar or sidebar only.
- `PDFView`: SwiftUI has no PDF view.
- An `NSTextView` for the build log: a SwiftUI `Text` lays out LaTeX's megabyte logs whole on every change.
- The `AppDelegate`'s terminate-later reply, so Quit waits for the open document's save.
- `FindMenuResponder`: Edit › Find is the system's (`TextEditingCommands`), whose items send `performFindPanelAction:` with a tag down the responder chain. `PDFView` doesn't answer it, so a responder after the project window takes it to the pane with the keyboard (`FocusedValues.find`). The editor's web view does answer it, with WebKit's own find bar, which searches only the lines CodeMirror has drawn; `.findDisabled()` doesn't stop that on 27.2, so a second responder goes in front of the web view's wrapper whenever it takes the keyboard. A find bar's field has its own field editor that passes the items on. Replacing `.textEditing` instead loses the spelling and substitution toggles' checkmarks.
- The drag pasteboard (`NSPasteboard(name: .drag)`): a SwiftUI drop session names none of its items before the drop, so the file drops read it to refuse what they can't take while it's dragged.

## Core behaviour (every host)

- **Compiling past errors:** builds run with latexmk `-f`, so a PDF is returned even on failure. The per-project `stopOnFirstError` passes `-halt-on-error` instead.
- **Stopping:** `stop_compile {id}` stops one project's build; `kill_all` is for quit.
- **Import name clashes** are per file: Replace (moves the old file to the Trash), Keep Both, or Stop.
- **`build` is reserved** at a project's top level: it holds the compiled PDF.
- **latexmkrc:** a project's own rc runs only with shell escape on (`-norc` otherwise).

## Browser server security (security-critical: shell escape runs code)

- It binds `127.0.0.1` only.
- A startup token goes in an `X-TeXLocal-Token` header on every `/api/` and `/__` request, never in a cookie. The page keeps it in sessionStorage.
- It refuses foreign Hosts (DNS rebinding) and non-GET requests with a foreign Origin, checking both on the request head before reading the body.
- Every response carries `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `nosniff` and `no-referrer`. Project files are served with a sandbox CSP.
- `httparse` is pinned to a GitHub tag; it can move to crates.io now.

## Windows (`apps/windows`)

- **Projects:** `TeXLocal.Core` (FFI, models, preferences), `TeXLocal.Tests` (xUnit) and `TeXLocal` (WinUI 3, unpackaged x64, .NET 10).
- **Written blind:** the last pass wired Windows from the Mac without building it, so CI must confirm it builds with warnings as errors and that the tests pass.
- **Still to check by hand:** shortcuts, the title bar, Settings, drops, Compile/Stop, SyncTeX and Narrator.

## Known issues

- A full-screen assertion (`_relinquishTitlebar`) was seen once, when leaving full screen. Its prime suspect is the Home→Workspace toolbar swap, which is back with the single window; the repro (the window in full screen, Quit and Keep Windows, relaunch, Exit Full Screen) needs checking again.
- In the browser client, Stop pressed after the save but before `compile` reaches the core stops nothing.
- Compile flakes, each seen once:
  - `a_timed_out_compile_keeps_the_output_it_wrote`;
  - a build reported as failed with a truncated log.
- Not yet seen on screen: drag and drop (the projects screen's and the sidebar's, including a refused drag), and focus rings with Keyboard navigation on.
- **Toolbar, checked on screen 2026-09-28** (Debug, 1200 pt window, against Mail): the source/PDF divider dragged both ways, the sidebar shown and hidden, the window at its 802 pt minimum. The PDF's section follows the divider both ways until a column is narrower than its section's tools; then the tools cross the divider, and the system draws a short section line and a full-width hairline, as Mail's viewer does (the PDF under ~385 pt, the source under ~345 pt, so only near their minimums). Short of room window-wide, zoom and Share go to the `>>` menu first (`visibilityPriority(.low)`; zoom shows there as a Zoom submenu), Compile and the PDF toggle last. The sidebar opens at the kit's 256 pt. A drag stops at the PDF's minimum; only Hide PDF collapses it, and Show PDF brings it back where it was. Not checked in full screen.
- Not yet checked on screen from the clean-up pass: `defaultFocus` in the rename fields (context menu), New File / Go to Line and New Project sheets; the projects screen as one `List` with the system toolbar background; `.controlGroupStyle(.automatic)` (kept `.navigation`); the status bar's ends in full screen (`containerCornerInsets` looked right windowed).
- Split sizes moved to `PaneSizes` keys, so the first launch after this pass opens the build panel and the outline at their default shares. The old `NSSplitView Subview Frames …`, `OutlineSplit Unfolded 1`, `showInspector`, `outlineOpen`, `pdfSplit` and `uiScale` defaults are orphaned.
- The sidebar's collapsed "File Outline" footer reads as a disabled label; not looked into.

## Deferred (outside the Mac app; not dropped)

Found by the 2026-09-28 audit, left because they need code outside `apps/macos`:
- **`web/` (done 2026-09-28):** the page answers `getDocument() → { path, text }` and a Mac save writes only the text of the file it read; accelerators live in `web/src/shortcuts.json`, which the web and the Mac read; `test/protocol.test.js` checks the Mac's and Windows' command, palette, font and accelerator copies against the web's; the SyncTeX flash values are `SYNC_FLASH` in `pdfview.js`, with comments both ways; a block inserted at the start of a line no longer adds a blank line.
- **Rust core:** the core marks an untitled heading `"(untitled)"` (`analyze.rs`), which the app string-matches (`Analysis.untitledTitle`); send an empty title instead. Check the core stays the only source of the default engine and library folder.
- **Tooling:** XcodeGen isn't installed, so `apps/macos/scripts/add-source.py app|tests Name.swift` registers a new file with the committed project. `TeXLocalTests.swift` could now be split, and moved to Swift Testing.
- **Windows:** save with `getDocument` and check its path, as the Mac does (`EditorBridge.cs` still reads `getText`); read `web/src/shortcuts.json` rather than keeping `MenuCommand.Accel`'s copy (the protocol test holds the copy to it meanwhile). Also check for the bugs this pass fixed on the Mac (the non-text `flush()` loop, stale state after deleting the open file, the fixed-delay watcher re-arm, a closed project's popovers and sheets carrying over), and mirror the visible Mac changes if the platforms should match.

## Next

- **Clean-slate refactor, rewrite and visual check of the macOS app**, starting fresh.
- Confirm CI on `main`, then update PR #11 and merge it after a Windows review.
- Deferred features:
  - error hints and gutter markers;
  - `.blg` parsing;
  - Clean and Compile;
  - TinyTeX / package install;
  - `!TEX` magic comments;
  - more templates;
  - version history;
  - duplicate project;
  - image drop to insert a figure;
  - import UI on Windows and the web.
- Web follow-ups are in `docs/web.md`.
- Retire Tauri once both apps are verified: delete `src-tauri`, the Tauri path in `bridge.js`, `@tauri-apps/cli`, and the Tauri entries in `check-version.mjs`, `ci.yml` and `release.yml`.

## Gotchas

- **`-ApplePersistenceIgnoreState YES` writes the new state to a temporary folder** and leaves the old one, so the next launch without it restores the state from before. Restoration repros need both launches without it.
- **`Core` makes the blocking `tl_call` on a GCD thread**, not in a `@concurrent` function, which would block Swift's cooperative pool. `Core.Handle` is nonisolated so that thread can read it.
- **A collapsed `NavigationSplitView` column's toolbar items move to the previous column's part of the toolbar by themselves.** Declare them unconditionally; removing them or adding copies elsewhere made Compile and Show PDF vanish mid-animation.
- **The column line and the toolbar's section line are one line only while they track.** An animated collapse or a section wider than its column parts them, and the toolbar draws its own short line off the divider and a hairline across the window, as Mail does. So the PDF column opens and shuts without animating. The column minimums are the content's: sizing them to hold the toolbar's tools was measuring the system's layout by hand.
- **The toolbar doesn't compress a SwiftUI item; it overflows it.** It lays each item out at its ideal width: `ViewThatFits` and `.frame(minWidth:)` are ignored (27.2), unlike AppKit's search item, which shrinks to a button (Mail). An item that changes width while a divider moves isn't laid out again: a Compile shortened and widened by hand painted over its neighbours until the window resized. So Compile keeps its title; short of room, zoom and Share go to the `>>` menu first. A compact Compile would take measuring the toolbar's layout, hand-made; `NSToolbar.visibleItems` and the items' view frames (window coordinates, `itemIdentifier` = the SwiftUI id) are there if it's ever wanted.
- **The PDF column doesn't collapse on a drag** (`canCollapse = false`). Collapsed at the window's trailing edge, its divider sits under the window's resize edge, so a drag back resizes the window instead of opening the PDF.
- **A `WebPage` shows in one `WebView`, once.** Each `ProjectModel` makes its own `EditorBridge`, and `SourcePane` keeps the `EditorView` mounted under a preview or the placeholder; rebuilding it on the same page traps in `_WebKit_SwiftUI makeViewProvider`. `EditorBridge.close()` removes the message handler (else the page leaks) and releases calls waiting on the page.
- **Don't collapse a split item inside a SwiftUI update.** It lays the window out there and then, re-enters the update and spins in an AttributeGraph cycle; `PaneSplitViewController.update` defers it a turn.
- **A field that appears while the editor has focus needs `focused = true` in `onAppear`.** `.defaultFocus` leaves focus in the editor's web view, so an in-place rename typed into the document. `defaultFocus` is right for sheets, which are a new focus scope.
- **One FSEvents stream watches the project folder** (`FolderWatcher`): the open file is checked when it or a folder above it changes, and the tree is read again when something comes, goes or moves in a folder it shows (the core decides what it shows). The open file moved or deleted elsewhere closes, or with unsaved edits asks Save Again or Close. Paths are compared with `realpath`: `resolvingSymlinksInPath` drops /private, which FSEvents keeps.
- **Spawn TeX tools by their full path.** With PATH set for the child, std forks for a bare program name instead of using posix_spawn, and a forked child of the multithreaded app can crash before exec (six reports while TeX was missing and `status` polled every 10 s). `compile.rs` `program_path` finds the program on the child's PATH; `tools_start_by_posix_spawn_never_a_fork` guards it.
- **Closing a toolbar popover logs "Invalid attempt to open a new transaction during CA commit"** on macOS 27.2, from AppKit: a bare SwiftUI app with one toolbar popover logs it too. It is not the app's.
- **The split-view tests need an awake, unlocked display.** Asleep or locked, `SplitControllerTests` times out on the previous commit too; run the suite under `caffeinate -u -d`.
- **Don't feed toolbar item geometry back into `navigationSplitViewColumnWidth(min:)`**: it loops layout and AppKit throws (`_crashOnException`). The navigation title is always 160 pt wide; `toolbarTitleDisplayMode` doesn't change it on macOS.
- **The sidebar column's minimum must be at least 140 pt.** Below that, hiding the sidebar pushes its toolbar toggle into the `>>` overflow, leaving no button to show it again.
- **`NSSplitViewController` opens an uncollapsed pane at its minimum** unless it has a size from this session. `PaneSplitViewController` holds a pane that has been hidden since launch at its stored size (`PaneSizes`), or its share, and then lets it go.
- **PDFKit** re-anchors page one on every resize while fitting the width. `SyncPDFView` keeps the reading position through resizes and rebuilds, and `hideLinkBorders` hides hyperref's boxes.
- **Core Image filters work in linear light:** dark paper's `colorInvert` turns sRGB 0.84 grey into 0.61, not 0.16.
- **macOS 26's `setPosition`** doesn't lay out panes that were just added, as 27's does. The split tests size a window explicitly.
- **The tests' host is the app, with the app's defaults** (`com.texlocal.mac`) and the scheme's scratch `TEXLOCAL_DATA`. Split tests remove their `PaneSizes` key in `tearDown` (after taking the controller out of its window); recents aren't pruned when the library lists without them (`AppModel.recents` filters instead), since a scratch library would wipe them.
