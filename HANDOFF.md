# Handoff: TeXLocal

## Status (2026-09-28)

- `main` is pushed (`91bd62f`). CI hasn't reported on it yet.
- `claude/macos-polish` (not pushed) is the Mac polish pass: one window with a back button, menus on focused values, one family of native bar controls, split, sidebar and drop fixes, a consistency and VoiceOver sweep, main-actor default isolation, and the fixes from an on-screen check and a code review. Its Mac Debug and Release builds have no Swift warnings and its tests pass.
- **`claude/macos-polish` (not pushed): a clean-up pass over the whole Mac app** (short WHY comments, magic numbers named or taken from the system, fragile tricks replaced). `c700d05` is a snapshot with a measured toolbar fold (`ToolbarFit`); later commits drop the fold: each column's minimum is its content's and the toolbar is the system's to fit (below). Defaults keys live in `DefaultsKey`; split sizes in `PaneSizes`; the file watcher is FSEvents. Later still, the Mac UI layer was rewritten (AppKit window, split and toolbar; SwiftUI panes; below), then given an inspector, a Stop with a spinner, and toolbar menus hosted from the menu bar's SwiftUI items. The window's minimums are now the panes' own (the sidebar folds first), and both side columns open at AppKit's 270 pt inspector width. Debug and Release build with no Swift warnings and the tests pass.
- PR #11 (`claude/windows-parity`: the Fluent redesign, WebView2 recovery, a trimmed SDK, an Inno Setup installer) is merged into `main`, and `main` into `claude/macos-polish`.
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
  - `macos-app.yml`: the `xcode-27` runner (macOS 27, in preview; there is no `macos-27` label) and the XCTests;
  - `windows-app.yml`;
  - `release.yml`: runs on `v*` tags.
- **Mac Debug build on screen:** run it with `open -g -n --env TEXLOCAL_DATA=<library copy> <app> --args -openProject <id>`.
  - It shares the `com.texlocal.mac` defaults and window state with the installed app, so export them first and import them after.
  - Unregister scratch builds afterwards (`lsregister -u <app>`), or the Dock and Spotlight can open a stale copy.
  - Pressing Accessibility elements by substring can hit menu-bar items (it once opened System Settings); match exact titles within the window.

## macOS app (`apps/macos/TeXLocal`)

**Design:** AppKit owns the window, its split and its toolbar; SwiftUI draws every pane and bar inside them. The models (`AppModel`, `ProjectModel`, `PDFController`) drive the AppKit side through `track(_:initial:_:)` (`MainWindow.swift`), which uses Swift Observation's `Observations`.

**Files:**
- `TeXLocalApp`: the `@main` App, whose only scene is Settings, and its commands. The `AppDelegate` owns the main window (`MainWindowController`), quits after it closes, and holds Quit until the open file is saved. `windowModals()` hosts the window's sheets and alerts, and `alert(_:)` shows any `AppAlert`.
- `MainWindow`: `MainWindowController`, the one window. It shows the projects screen (`HomeView` in an `NSHostingController`, whose SwiftUI toolbar, title and search are bridged in) until a project opens, then that project's `WorkspaceController` and toolbar. It also handles restoration (the `SavedWorkspace` JSON in the window's restorable state, frame autosave "Main Window") and Edit › Find routing. `WindowMetrics` holds the window's sizes; `track` is here.
- `WorkspaceController`: nested `NSSplitViewController`s. The sidebar item holds files over the File Outline; the middle item holds source | PDF over the build panel, and the panel spans both; the inspector (`NSSplitViewItem(inspectorWithViewController:)`, AppKit's fixed 270 pt, its divider taking no drag) is the trailing column. The sidebar opens at the same width and drags from 200 to 400 pt. Bars are split-item accessories:
  - the sidebar's search field;
  - the find bars;
  - the folded outline's bar;
  - the status bar, at the foot of source + PDF.

  It also has `ColumnMetrics` (column and pane limits) and `PaneSize` (sizes in the `PaneSizes` defaults dictionary).
- `WorkspaceToolbar`: the `NSToolbar`. The sidebar section holds the toggle. The source section holds back, the title, B I and Insert. The PDF section, from an `NSTrackingSeparatorToolbarItem` on the source/PDF divider, holds zoom, Share, Compile (`.prominent`; Stop with a spinner while a build runs, at the same width, on clear glass) and the PDF toggle. The inspector section, from the system's `.inspectorTrackingSeparator`, holds the system's `.toggleInspector`. Customize Toolbar adds Undo, Redo, Section Level, Math and the templates. Its menus are `NSHostingMenu`s over the menu bar's SwiftUI items (`InsertMenuItems`, `SymbolItems`, `SectionLevelItems`, `ScaleMenuItems`).
- `WorkspaceView`: `workspaceModals` (the project's sheets and alerts), the sheets, and `InspectorView` (a grouped `Form`: the project's settings, the open file's facts, the build's).
- `EditorView`: the source column (the editor, a file preview or no file) and the `StatusBar`.
- `EditorBridge`: a project's editor, a plain `WKWebView`.
- `SourceBars`: the source's find bar and the Format and Insert menus' pieces.
- `PDFPane`: the PDF column and its find bar.
- `PDFKitView`: `PDFController` and the `PDFView` wrapper.
- `LogsView`: the build panel.
- `SidebarView`: the sidebar's search, the folded outline bar, the files and the outline.
- `Outline`, `HomeView`, `SettingsView`.
- `AppModel`: library, recents, imports, alerts; `DefaultsKey` (every defaults key, registered defaults).
- `ProjectModel`: the open project, saves, builds, file watching.
- `Core`, `Models`, `Commands`: menus and shortcuts.
  - Every item is a `MenuCommand`, which also lists the chords the editor page hands back.
  - The menus act on `app.commandProject`: the open project while the main window is key, otherwise nil.
  - Insert sits between View and Window. Format keeps Bold, Italic, the section level and Comment.
- `PaneBars`: bar metrics (the UI kit's), `Typography`, `FindBar`, `SearchField` and `FieldHandle`, `FindFieldEditor`, `SecondaryBar`, `TabsControl`, `DialogSheet`, and the rename pieces.
- `EditorPrefs` and `PDFPrefs`; `SyncTeXGeometry`. Leaf views have `#Preview`s that need no Rust core.

**AppKit that remains, and why:**
- **The window, split and toolbar.**
  - `NavigationSplitView` can't hide its last column (the PDF), can't run a panel under two of its columns, and has no split-item accessories.
  - SwiftUI's toolbar has no tracking separators, so it can't give each column its own section.
  - A SwiftUI scene's window owns its toolbar, so the window is AppKit's too.
- **The status bar's ends** use `layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))`. SwiftUI's `containerCornerInsets` are zero inside an AppKit split item's accessory.
- **Its hairline and the folded outline's** are a small view in the split's `dividerColor`, 1 pt like the dividers they continue.
- **A plain `WKWebView` for the editor.** SwiftUI's `WebView` answers Edit › Find with WebKit's own find bar, which sees only the lines CodeMirror has drawn. A plain web view passes `performFindPanelAction:` on to `MainWindowController`, which sends it to the pane with the keyboard (`WorkspaceController.findAction`). The find bars' fields get `FindFieldEditor`, which passes the items on, through `windowWillReturnFieldEditor`.
- **The inspector is AppKit's split item**, the one SwiftUI's `.inspector` builds on: the modifier attaches to a SwiftUI split, and this window's split is AppKit's. Its content is SwiftUI.
- **Compile's own view** (a SwiftUI button in an `NSHostingView`): an item's image can't animate Stop's spinner. The view fills the item's glass (36 pt, measured), which passes no clicks to it; the title is medium weight, 12 pt from the ends, as AppKit draws an item's.
- **The segmented zoom and Math controls open their menu segment's menu from their action** (`openMenu(of:)`): AppKit opens a segment's menu on a click only in a control with no action, and these have one for their other segments.
- **`NSSharingServicePicker`**: SwiftUI opens one only from a `ShareLink`.
- **`TabsControl`** (`NSSegmentedControl`, tabs role): SwiftUI's tabs picker moved its thumb on hover.
- **`NSSearchField`** in the find bars, the sidebar and the log filter: SwiftUI's search field is toolbar or sidebar only.
- **`PDFView`**: SwiftUI has no PDF view.
- **An `NSTextView` for the build log**: a SwiftUI `Text` lays out LaTeX's megabyte logs whole on every change.
- **The drag pasteboard** (`NSPasteboard(name: .drag)`): a SwiftUI drop session names none of its items before the drop, so the file drops read it to refuse what they can't take while it's dragged.

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

- **Projects:** `TeXLocal.Core` (FFI, models, preferences, no WinUI), `TeXLocal.Tests` (xUnit) and `TeXLocal` (WinUI 3, unpackaged x64, .NET 10; .NET and the Windows App SDK are bundled).
- **SDK packages:** WinUI, Foundation and InteractiveExperiences only, not the `Microsoft.WindowsAppSDK` metapackage (a Release publish went from 234 MB to 174 MB).
- **Web surfaces:** the editor and PDF pages each run in a WebView2; `web\` is served at `app.texlocal`, the PDF at `project.texlocal`. A renderer crash reloads the page; if the whole browser process dies, `EmbeddedPage.Replace` puts a new WebView2 in the old one's place. Window shortcuts stand down while a page has focus; the pages post chords back.
- **Layout (the 2026-09 Fluent redesign):** the Tall 48 px `TitleBar` over Mica (menus, a centred search box, PDF and Details toggles; `FitCaptionInset` corrects WinUI's caption column at scales above 100%); 48 px rows and 32 px detail rows; the sidebar and Details pane are inline `SplitView` panes that slide both ways; the source and PDF bars are `CommandBar`s whose overflow folds them. Motion is in `Motion.cs`.
- **Insert blocks** are named by id (`LatexTemplates.Lists` / `Environments`) and sent with the editor's `block` command; `test/blocks.test.js` checks the ids.
- **Compile/Stop:** the PDF pane shows Compile, or a spinner and Stop while a build runs (`stop_compile`); a stopped build reads "Build stopped" and sends no notification. Settings has Stop on first error, per project. An import onto taken names asks once (Replace, Keep both, Stop). The outline, words and lines come from the core's `analyze`.
- **Installer:** `apps/windows/installer/TeXLocal.iss` (Inno Setup 6), per user into `%LOCALAPPDATA%\Programs\TeXLocal`; the Windows workflow's "Installer" job builds `TeXLocal-<version>-setup.exe`. By hand, build the core with `--release` first: a stale `target\release\texlocal_ffi.dll` was once published.
- **Deviations:** settings cards and dividers are hand-written, not the Community Toolkit; Interface Size scales only the editor page.
- **Verified by hand on Windows 11 (26340), TeX Live 2026, before `main`'s Stop / clash / analyze work was merged in:** PDF rendering and find, compiling and recompiling, choosing the TeX folder, the title bar's hit-testing, the redesign's measurements, pane motion, the source bar and its overflow, the symbol palette and section level, the outline following the editor, a file changed on disk reloading, and WebView2 browser-process recovery.
- **Known issues:** a Release build once fail-fasted in `ucrtbase.dll` while idle (it linked the stale core; not reproduced since). A window once showed a frozen frame while it went on working.
- **Running a Debug build beside the installed one** breaks the Debug build's WebView2 pages (they share `%LOCALAPPDATA%\TeXLocal\WebView2`); run one at a time.
- **Still to check by hand:** the merged-in Stop, Stop on first error, import clash dialog and core-analyzed outline; shortcuts firing once from every pane; the title bar (themes, high contrast, Snap Layouts); access keys; dividers by keyboard; Settings surviving a restart; the unsaved-edits conflict dialog; drops; saving and closing during a compile; SyncTeX both ways; Narrator; no `latexmk` left after quitting; the installer's install and uninstall.

## Known issues

- A full-screen assertion (`_relinquishTitlebar`) was seen once, when leaving full screen. Its prime suspect is the Home→Workspace toolbar swap, which is back with the single window; the repro (the window in full screen, Quit and Keep Windows, relaunch, Exit Full Screen) needs checking again.
- In the browser client, Stop pressed after the save but before `compile` reaches the core stops nothing.
- Compile flakes, each seen once:
  - `a_timed_out_compile_keeps_the_output_it_wrote`;
  - a build reported as failed with a truncated log.
- Not yet seen on screen: drag and drop (the projects screen's and the sidebar's, including a refused drag), and focus rings with Keyboard navigation on.
- **Toolbar, checked on screen 2026-09-28, after the AppKit rewrite** (Debug, active window, dark and light):
  - At 1200 pt the PDF section starts at the source/PDF divider, and the line runs through the toolbar. (The sidebar opened at the kit's 256 pt then; it opens at 270 now.)
  - Items are 8 pt apart and 8 pt from section edges; B I is one 73 pt capsule; Compile is 75 pt.
  - When a column is narrower than its section's tools, the section line leaves the divider; this is the system's layout, left to it. The source section needs about 350 pt with the sidebar shown. Without it, about 480 pt: the traffic lights, the toggle, back, the title (which keeps about 160 pt), B I and Insert.
  - Short of room window-wide, zoom goes to `>>` first, then Share; Compile and the PDF toggle last. (At the same priority, AppKit hid Share with zoom where Share still fitted.)
  - A drag stops at the PDF's minimum; only Hide PDF collapses it, and Show PDF brings it back at its width.
  - Not checked in full screen.
- Not yet checked on screen from the clean-up pass: `defaultFocus` in the rename fields (context menu), New File / Go to Line and New Project sheets; the projects screen as one `List` with the system toolbar background; `.controlGroupStyle(.automatic)` (kept `.navigation`); the status bar's ends in full screen (the corner-adapted safe area; right windowed).
- Split sizes moved to `PaneSizes` keys, so the first launch after this pass opens the build panel and the outline at their default shares. The old `NSSplitView Subview Frames …`, `OutlineSplit Unfolded 1`, `showInspector`, `outlineOpen`, `pdfSplit`, `uiScale` and per-split `"<autosave> Pane Sizes"` defaults are orphaned; the one `PaneSizes` dictionary replaced them. On the owner's Mac they were deleted on 2026-09-28 (69 keys, with the old `NSToolbar Configuration project/source/workspace` and old window frames); other Macs keep them, unread.
- The folded "File Outline" bar has the divider's line over it now, level with the status bar's, but its secondary label still reads a little like a disabled one.
- **Window minimums, checked on screen 2026-09-28:** the content goes down to 601 × 309 pt (source and PDF at their minimums; the columns, build panel and status bar). Narrowing folds the sidebar once the source and PDF reach their minimums and brings it back when there's room; Window › Move & Resize › Left folds it to fit half the display. The projects screen stops at 601 × 309 below its toolbar.
- **The launch log, 2026-09-28:** the app's own faults are fixed (the toolbar title's conflicting constraints, the inspector pickers' untagged selection). What's left is the system's: App Intents rejects the ad-hoc signature ("Unable to get teamId", `linkd.autoShortcut`; a team-signed build shouldn't log it, and this Mac has no signing identity), PDFKit's text recognition logs `e5rt` errors when pages show, and the editor's WebContent process logs sandbox and preferences errors.
- `testTheSideColumnsOpenAtTheirWidths` passes with or without the fix it covers: before it, a project opened with the inspector shown squeezed the sidebar to 200 pt only in the real window (probably its toolbar). The fix was checked on screen.
- The inspector's toolbar items are immovable defaults. A toolbar configuration saved before them (after a Customize Toolbar change) could lack them with no way to add them back. The toolbar saves as "Workspace", and none was saved on the owner's Mac (the old lowercase ones were deleted); the owner accepted the risk.

## Deferred (outside the Mac app; not dropped)

Found by the 2026-09-28 audit, left because they need code outside `apps/macos`:
- **`web/` (done 2026-09-28):** the page answers `getDocument() → { path, text }` and a Mac save writes only the text of the file it read; accelerators live in `web/src/shortcuts.json`, which the web and the Mac read; `test/protocol.test.js` checks the Mac's and Windows' command, palette, font and accelerator copies against the web's; the SyncTeX flash values are `SYNC_FLASH` in `pdfview.js`, with comments both ways; a block inserted at the start of a line no longer adds a blank line.
- **Rust core:** the core marks an untitled heading `"(untitled)"` (`analyze.rs`), which the app string-matches (`Analysis.untitledTitle`); send an empty title instead. Check the core stays the only source of the default engine and library folder.
- **Tooling:** XcodeGen isn't installed, so `apps/macos/scripts/add-source.py app|tests Name.swift` registers a new file with the committed project. `TeXLocalTests.swift` could now be split, and moved to Swift Testing.
- **Windows:** save with `getDocument` and check its path, as the Mac does (`EditorBridge.cs` still reads `getText`); read `web/src/shortcuts.json` rather than keeping `MenuCommand.Accel`'s copy (the protocol test holds the copy to it meanwhile). Also check for the bugs this pass fixed on the Mac (the non-text `flush()` loop, stale state after deleting the open file, the fixed-delay watcher re-arm, a closed project's popovers and sheets carrying over), and mirror the visible Mac changes if the platforms should match.

## Next

- **The Rust core, then the web**: the owner's next steps after the Mac UI rewrite (2026-09-28).
- Confirm CI on `main`; the Windows hand checks above.
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
- **The column line and the toolbar's section line are one line only while they track.** A section wider than its column parts them, and the toolbar draws its own short line off the divider, as Mail does. The column minimums are the content's: sizing them to hold the toolbar's tools would be measuring the system's layout by hand.
- **The PDF column doesn't collapse on a drag** (`canCollapse = false`). Collapsed at the window's trailing edge, its divider sits under the window's resize edge, so a drag back resizes the window instead of opening the PDF.
- **A field that appears while the editor has focus needs `focused = true` in `onAppear`.** `.defaultFocus` leaves focus in the editor's web view, so an in-place rename typed into the document. `defaultFocus` is right for sheets, which are a new focus scope.
- **One FSEvents stream watches the project folder** (`FolderWatcher`): the open file is checked when it or a folder above it changes, and the tree is read again when something comes, goes or moves in a folder it shows (the core decides what it shows). The open file moved or deleted elsewhere closes, or with unsaved edits asks Save Again or Close. Paths are compared with `realpath`: `resolvingSymlinksInPath` drops /private, which FSEvents keeps.
- **Spawn TeX tools by their full path.** With PATH set for the child, std forks for a bare program name instead of using posix_spawn, and a forked child of the multithreaded app can crash before exec (six reports while TeX was missing and `status` polled every 10 s). `compile.rs` `program_path` finds the program on the child's PATH; `tools_start_by_posix_spawn_never_a_fork` guards it.
- **Closing a toolbar popover logs "Invalid attempt to open a new transaction during CA commit"** on macOS 27.2, from AppKit: a bare SwiftUI app with one toolbar popover logs it too. It is not the app's.
- **The split-view tests need an awake, unlocked display.** Asleep or locked, `WorkspaceLayoutTests` times out (split animations don't run); run the suite under `caffeinate -u -d`.
- **The sidebar column's minimum must be at least 140 pt.** Below that, hiding the sidebar pushes its toolbar toggle into the `>>` overflow, leaving no button to show it again.
- **Setting a window's `contentViewController` sizes the window to the new view and sets its `contentMinSize` to zero.** `MainWindowController.setContent` gives the view the window's size first (an unsized one shrank the window for a moment, and the projects' bridged toolbar laid its title out 9 pt wide: three conflicting-constraint faults per launch), then sets the minimum again. The projects screen's `NSHostingController` (with scene bridging) then sets it from its SwiftUI content's minimum, zero for a list, so `HomeRoot` carries the app's minimum as a frame.
- **`contentMinSize` counts the area under the toolbar** (full-size content view), but the panes' limits hold below it: with the build panel open, a project's window stops a toolbar's height taller than the minimum.
- **A sidebar squeezes before it folds**, down to its minimum, and grows back as the window widens: AppKit's default, checked against a bare `NSSplitViewController` (its sidebar went 299 → 238 → 178 pt, folded, and came back). Scripted resizes (AppleScript, Return to Previous Size) don't grow it back; a drag does.
- **Customize Toolbar compresses the default set's views.** The zoom control's palette copy resists compression, or its scale reads "…"; the toolbar's own copy must not, or it holds the window 50 pt wider even from the overflow menu.
- **A SwiftUI `Picker` whose selection has no matching tag logs a fault**, nil included. The inspector's pickers list the current value as a choice until the settings and the file list come.
- **Sidebars fold on a window resize, inspectors don't** (`canCollapseFromWindowResize`: YES for sidebars, NO for inspectors). The window's minimum is the source and PDF's, so a narrowing window squeezes the sidebar to 200 pt, folds it, and brings it back when there's room. Tiling folds it too; `setContentSize` doesn't, so the minimum test hides the sidebar first.
- **Pane sizes are saved from drags only.** In a live resize the window squeezes the panes, and a squeezed sidebar used to be kept at 200 pt; `saveSizes` skips `inLiveResize`.
- **AppKit's inspector is fixed (270 pt minimum and maximum) yet its divider shows a resize cursor.** `WorkspaceController` overrides `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)` to give that divider no hit area.
- **The inspector item is made before the area**, which opens in the room both side columns leave; sized past the sidebar alone, the area pushed the sidebar to its minimum.
- **The nested split view controllers answer `toggleSidebar:` and `toggleInspector:` before the window's split**, and they have neither. `WorkspaceToolbar.toolbarWillAddItem` points the system's toggles at the `WorkspaceController`.
- **A pane opens at its view's frame as it's added**, and a collapsed one uncollapses to it. `WorkspaceController` sets each frame from `PaneSize`, or from its share of the window.
- **Toolbar groups on macOS 27:**
  - Adjacent plain items share one glass capsule with no line between (73 pt for two, the kit's button group).
  - An `NSMenuToolbarItem` breaks that grouping.
  - An `NSToolbarItemGroup` with subitems draws a wider capsule (82 pt) and sits 3.5 pt from a tracking separator.
  - The segmented constructor (`images:selectionMode:`) draws lines between parts.
  - Zoom and Math stay segmented around their pull-downs, as the owner asked for zoom.
  - A `.prominent` item gets glass of its own; a `.plain` one joins its plain neighbours'. Stop stays `.prominent` with `backgroundTintColor = .clear`, which looks plain but keeps its own glass.
- **A toolbar item's own view** keeps the item's `.prominent` or `.plain` glass, 36 pt high, which wraps the view and passes it no clicks: the view must fill it. Customize Toolbar draws the view without the style, so its copy (`willBeInsertedIntoToolbar` false) is a title item.
- **A segmented control's segment menu** opens on a click only in a control with no action; with one, only on a press and hold, and the click sends the action. Momentary tracking resets `selectedSegment` before `mouseDown` returns, and segment frames aren't public, so the action opens the menu under the click.
- **Toolbar items at the same visibility priority overflow together**: Share went to `>>` with zoom where it still fitted. Rank the widest lowest.
- **`track` needs `nonisolated` Equatable values** (`OutlineState`, the toolbar's `State`, `SavedWorkspace`), or a main-actor conformance can't satisfy `Sendable`. It runs after the change, never inside a SwiftUI update, so collapsing a split item there is safe.
- **An `NSMenuItem` subclass can't override its initialisers under default main-actor isolation.** The toolbar's menus are `NSHostingMenu`s over SwiftUI items instead, which also keeps them the menu bar's.
- **`NSBox`'s separator is 1 px, the thin split divider 1 pt.** The bars' lines are a small view (`Hairline`) in the split's `dividerColor`.
- **PDFKit is left to itself.** A scroll-view inset for the gap above page one, and the resize pinning it needed, fought PDFKit's own fit-width layout (a re-layout on every resize step: the scaling stuttered); the gap is a page-break margin now, and a rebuild goes back to `currentDestination`. `hideLinkBorders` hides hyperref's boxes.
- **Core Image filters work in linear light:** dark paper's `colorInvert` turns sRGB 0.84 grey into 0.61, not 0.16.
- **macOS 26's `setPosition`** doesn't lay out panes that were just added, as 27's does. The split tests size a window explicitly.
- **The tests' host is the app, with the app's defaults** (`com.texlocal.mac`) and the scheme's scratch `TEXLOCAL_DATA`. `WorkspaceLayoutTests` save and restore the five defaults keys they change; recents aren't pruned when the library lists without them (`AppModel.recents` filters instead), since a scratch library would wipe them.
