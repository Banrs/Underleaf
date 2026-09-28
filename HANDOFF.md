# Handoff: TeXLocal

## Status (2026-09-29)

- **`main`** has PR #11 (`claude/windows-parity`: the Fluent redesign, WebView2 recovery, a trimmed SDK, an Inno Setup installer). Its macOS CI run fails in the old SwiftUI split's panel test, which the Mac rewrite below replaces.
- **`claude/macos-polish`** (pushed, `main` merged in) is the Mac app's rewrite and polish:
  - AppKit owns the window, split and toolbar; SwiftUI draws the panes.
  - One window, with a back button to the projects screen, and an inspector.
  - Compile turns to Stop with a spinner.
  - The toolbar's menus are the menu bar's own SwiftUI items.
  - Divider detents with the alignment haptic.
  - Tests in Swift Testing.
  - Files are named for what they hold.
- **Mac CI passes** (`b5f4a69`, the runner's macOS 27.0), for the first time since the rewrite. The first run showed the layout tests had never run on the runner's small screen, or on 27.0. Two fixes came of it: `UnclampedWindow`, and Show PDF holding its kept width, which also fixed a real 27.0 bug.
- **Last full check (2026-09-29):** `npm test` (87); the Mac's 51 tests; Debug and Release builds with no Swift warnings. `cargo fmt --check`, clippy `-D warnings` and `cargo test --workspace` pass, and the core hasn't changed since.
- **Windows is a work in progress** (the owner, 2026-09-29): leave `apps/windows` alone, including changes the core or the web would need there.

## Layout

One Rust core (`crates/`) under three clients:
- **macOS** (`apps/macos`):
  - AppKit and SwiftUI, deployment target macOS 27.0.
  - Swift 6 with Approachable Concurrency and main-actor default isolation, as Xcode 27's App template sets them.
  - CI builds with Xcode 27 on the `xcode-27` runner image (macOS 27.0).
- **Windows** (`apps/windows`): WinUI 3, C#.
- **Browser** (`web/`, served by `crates/texlocal-server`): local only.
- **Tauri** (`src-tauri`) still ships until both native apps are verified.

The editor is CodeMirror everywhere (`web/embed/editor.html`). The PDF is PDFKit on the Mac and pdf.js elsewhere.

## Architecture

- **`Service::call(cmd, json)`** (`crates/texlocal-core/src/service.rs`) is the one JSON command table every host forwards to.
  - Nothing that takes raw bytes or a host-chosen absolute path belongs in it, because the browser server exposes it.
  - `set_tex_dir` and `list_dirs` are the exception.
- **FFI** (`crates/texlocal-ffi`, header in `include/`): `tl_open`, `tl_call` (blocking, so call it off the main thread), `tl_free`, `tl_close`. Native-only commands: `pdf_path`, `raw_path`, `project_root`, `export_zip`, `import_files`, `import_project`, `kill_all`.
- **Hosts:**
  - the Mac (`Core.swift`) and Windows (`Core.cs`) link the FFI;
  - the browser server calls `Service` directly, and `web/src/bridge.js` is its client;
  - Tauri forwards to one `call` command;
  - `serve.rs` serves `__pdf` / `__raw`.
- **`analyze`** (`analyze.rs`): outline, words and lines.
  - Ported from the web's `analyzeDoc` (`web/src/state.js`), which stays the source of truth.
  - `crates/texlocal-core/tests/fixtures/analyze.json` is checked by both `cargo test` and `test/analyze.test.js`.
- **Atomic saves** (`atomic.rs`): write a temporary file beside the target, sync it, then rename it over the target.
- **Embed protocol:** the host calls `window.texlocal`.
  - The page posts `ready`, `changed`, `cursor`, `scroll` and `command` (plus find messages on the Mac).
  - `getDocument()` answers `{ path, text }`; a Mac save writes only the text of the file it read.
  - Insert blocks are named by id; their LaTeX is in `BLOCK_TEMPLATES` (`web/src/latex-data.js`), which `test/blocks.test.js` checks.
- **Commands and chords:** accelerators live in `web/src/shortcuts.json`, which the web and the Mac read.
  - `test/protocol.test.js` holds the Mac's and Windows' copies (commands, palettes, fonts, accelerators) to the web's.
  - It also checks that the Mac menu has every web command, less the web-only ones it lists.

## Build, test, run

- **Web and core:**
  - `npm install`, `npm test`, `npm run build`.
  - `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`.
  - `npm run serve` runs the browser version; `npm run app` runs Tauri.
- **macOS:** `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -derivedDataPath <dd> build` (or `test`).
  - Pre-build runs `cargo build -p texlocal-ffi`. Post-compile runs `npm run build` and copies the embed into `Resources/web`.
  - The app links the static `libtexlocal_ffi.a` by path.
  - Bundle id `com.texlocal.mac`.
  - `project.yml` and the committed `.xcodeproj` are kept in step by hand, since XcodeGen isn't installed. `apps/macos/scripts/add-source.py app|tests Name.swift` registers a new file with both.
- **Mac tests** are Swift Testing (`TeXLocalTests/`), one file per area:
  - `WorkspaceLayoutTests`: the split, on screen and unseen;
  - `CommandTests`: chords, the menu bar, Find routing;
  - `ProjectTests`: the file watcher, the core, project flows;
  - `DocumentTests`: SyncTeX, the outline, find;
  - `BarTests`;
  - `SettingsTests`.

  The scheme runs them one suite at a time (`parallelizable = NO`) in the scratch library `TEXLOCAL_DATA=/tmp/texlocal-xctest`. Run them under `caffeinate -d -i -u`: the split tests need an awake, unlocked display.
- **Typecheck against CI's SDK:** `xcrun swiftc -typecheck -swift-version 6 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos27.0 -I crates/texlocal-ffi/include apps/macos/TeXLocal/*.swift`.
- **Windows:** `cargo build -p texlocal-ffi`, then `dotnet build apps/windows/TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64` and `dotnet test apps/windows/TeXLocal.Tests/TeXLocal.Tests.csproj`.
- **CI:**
  - `ci.yml`: web, version check, Rust on Linux, Tauri bundles;
  - `macos-app.yml`: the `xcode-27` runner (macOS 27.0, in preview; there is no `macos-27` label) and the Mac tests;
  - `windows-app.yml`;
  - `release.yml`: runs on `v*` tags.
- **A Mac Debug build on screen, beside the installed app:**
  - Build it with `PRODUCT_BUNDLE_IDENTIFIER=com.texlocal.mac.check`, so its defaults and window state are its own.
  - Run it with `open -g -n --env TEXLOCAL_DATA=<library copy> <app> --args -openProject <id>` (add `-ApplePersistenceIgnoreState YES` for a clean window).
  - Afterwards run `lsregister -u <app>` (or the Dock and Spotlight can open a stale copy) and `defaults delete com.texlocal.mac.check`.
  - Capture it by window id (`screencapture -l`), choosing the process's largest window: it also owns a blank helper window.
  - Pressing Accessibility elements by substring can hit menu-bar items (it once opened System Settings); match exact titles within the window.
- **The test host is the app, with the app's defaults** (`com.texlocal.mac`). Export them before a run and compare them after; the suites put back what they change.

## macOS app (`apps/macos/TeXLocal`)

**Design:** AppKit owns the window, its split and its toolbar; SwiftUI draws every pane and bar inside them. The models (`AppModel`, `ProjectModel`, `PDFController`) drive the AppKit side through `track(_:initial:_:)` (`MainWindow.swift`), which uses Swift Observation's `Observations`.

**Files:**
- `TeXLocalApp`: the `@main` App, whose only scene is Settings.
  - The `AppDelegate` owns the main window, quits after it closes, and holds Quit until the open file is saved.
  - `windowModals()` hosts the window's sheets and alerts, and `alert(_:)` shows any `AppAlert`.
- `MainWindow`: `MainWindowController`, the one window.
  - It shows the projects screen (`HomeView` in an `NSHostingController`, whose SwiftUI toolbar, title and search are bridged in) until a project opens, then that project's `WorkspaceController` and toolbar.
  - It handles restoration (the `SavedWorkspace` JSON in the window's restorable state, frame autosave "Main Window") and Edit › Find routing.
  - Also here: `WindowMetrics` (the window's sizes) and `track`.
- `WorkspaceController`: nested split view controllers.
  - The sidebar item holds files over the File Outline.
  - The middle item holds source | PDF (`columns`) over the build panel, which spans both.
  - The inspector is the trailing column: `NSSplitViewItem(inspectorWithViewController:)`, AppKit's fixed 270 pt, whose divider takes no drag.
  - The sidebar opens at the same 270 pt and drags from 200 to 400 pt.
  - Bars are split-item accessories: the sidebar's search field, the find bars, the File Outline's header (`OutlineHeader`, at the files' foot folded or not), and the status bar at the foot of source + PDF.
  - Also here: `DetentSplitViewController` (the dividers' detents), `OutlineSplitViewController` (files over the outline, the header's line taking the divider's drags), `CornerBar` (the status bar's ends), `ColumnMetrics` (column and pane limits), `PaneSize` (sizes in the `PaneSizes` defaults dictionary) and `Hairline`.
- `WorkspaceToolbar`: the `NSToolbar`.
  - The sidebar section holds the toggle.
  - The source section holds back, the title, B I and Insert.
  - The PDF section, from an `NSTrackingSeparatorToolbarItem` on the source/PDF divider, holds zoom, Share and Compile. Compile is `.prominent`; while a build runs it's Stop with a spinner, at the same width, on clear glass (`CompileButton`).
  - The inspector section, from the system's `.inspectorTrackingSeparator`, holds the PDF toggle and the system's `.toggleInspector`. They sit over the inspector, or at the trailing edge while it's shut, so the columns' toggles keep to the window's edges.
  - Customize Toolbar adds Undo, Redo, Section Level, Math and the templates.
  - Its menus are `NSHostingMenu`s over the menu bar's SwiftUI items.
- `MenuItems`: `SectionLevelItems`, `SymbolItems` and `InsertMenuItems`, shared by the menu bar and the toolbar. `ScaleMenuItems` is in `PDFPane`.
- `WorkspaceModals`: the project's sheets and alerts (`workspaceModals`), New File or Folder, Go to Line and Go to Page.
- `InspectorView`: a grouped `Form` with the project's settings, the open file's facts and the build's.
- `SourceColumn`: the source column (the editor, a file preview or no file), `EditorView` (the editor's web view in SwiftUI) and `SourceFindBar`.
- `StatusBar`: the status bar and its build-panel toggle.
- `EditorBridge`: a project's editor, a plain `WKWebView`; the editor's commands, appearance and prefs; `FindQuery` and `FindMatches`.
- `BuildPanel`: the build panel (issues and the log).
- `PDFPane`: the PDF column, its find bar, the scale menu, `PDFFind` and `PDFPrefs`.
- `PDFController`: the PDF's state, `SyncPDFView` and the `PDFView` wrapper.
- `SidebarView`: the sidebar's search, the File Outline's header, the files and the outline.
- `Outline`, `HomeView`, `SettingsView`.
- `AppModel`: library, recents, imports, alerts; `DefaultsKey` (every defaults key, registered defaults).
- `ProjectModel`: the open project, saves, builds, file watching; `SavedWorkspace`. `FolderWatcher` is the FSEvents watch.
- `Core`, `Models` (the core's JSON types), `LaTeX` (the snippets the toolbar and menus write).
- `Commands`: menus and shortcuts.
  - Every item is a `MenuCommand`, which also lists the chords the editor page hands back.
  - The menus act on `app.commandProject`: the open project while the main window is key, otherwise nil.
  - Insert sits between View and Window. Format keeps Bold, Italic, the section level and Comment.
- `PaneBars`: bar metrics (the UI kit's), `Typography`, `FindBar`, `SearchField` and `FieldHandle`, `FindFieldEditor`, `SecondaryBar`, `TabsControl`, `DialogSheet`, and the rename pieces.
- `SyncTeXGeometry`.
- Leaf views have `#Preview`s that need no Rust core.

**AppKit that remains, and why:**
- **The window, split and toolbar.**
  - `NavigationSplitView` can't hide its last column (the PDF), can't run a panel under two of its columns, and has no split-item accessories.
  - SwiftUI's toolbar has no tracking separators, so it can't give each column its own section.
  - A SwiftUI scene's window owns its toolbar, so the window is AppKit's too.
- **The status bar's ends** (`CornerBar`): where the corner-adapted safe area (`edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))`) reports a window corner, the content sits 16 pt from the window's edge, as Xcode's bottom bars have it; the safe area's own 18 pt would hold it further in. SwiftUI's `containerCornerInsets` are zero inside an AppKit split item's accessory.
- **Its hairline and the File Outline header's** are a small view in the split's `dividerColor`, 1 pt like the dividers they continue.
- **The status bar and the folded header are 36 pt** (`BarMetrics.secondaryBarHeight`), Xcode's editor status bar between its hairlines (measured on 27.2), so the two lines run on as one.
- **A plain `WKWebView` for the editor.**
  - SwiftUI's `WebView` answers Edit › Find with WebKit's own find bar, which sees only the lines CodeMirror has drawn.
  - A plain web view passes `performFindPanelAction:` on to `MainWindowController`, which sends it to the pane with the keyboard (`WorkspaceController.findAction`).
  - The find bars' fields get `FindFieldEditor`, which passes the items on, through `windowWillReturnFieldEditor`.
- **The inspector is AppKit's split item**, the one SwiftUI's `.inspector` builds on. The modifier attaches to a SwiftUI split, and this window's split is AppKit's. Its content is SwiftUI.
- **Compile's own view** (a SwiftUI button in an `NSHostingView`): an item's image can't animate Stop's spinner.
  - The view fills the item's glass (36 pt, measured), which passes no clicks to it.
  - The title is medium weight, 12 pt from the ends, matching an item's title.
- **The segmented zoom and Math controls open their menu segment's menu from their action** (`openMenu(of:)`). AppKit opens a segment's menu on a click only in a control with no action, and these have one for their other segments.
- **`NSSharingServicePicker`**: SwiftUI opens one only from a `ShareLink`.
- **`TabsControl`** (`NSSegmentedControl`, tabs role): SwiftUI's tabs picker moved its thumb on hover.
- **`NSSearchField`** in the find bars, the sidebar and the log filter: SwiftUI's search field is toolbar or sidebar only.
- **`PDFView`**: SwiftUI has no PDF view.
- **An `NSTextView` for the build log**: a SwiftUI `Text` lays out LaTeX's megabyte logs whole on every change.
- **The drag pasteboard** (`NSPasteboard(name: .drag)`): a SwiftUI drop session names none of its items before the drop. The file drops read it to refuse what they can't take while it's dragged.

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

- **Full screen:** an assertion (`_relinquishTitlebar`) was seen once, when leaving full screen.
  - The prime suspect is the Home→Workspace toolbar swap, which is back with the single window.
  - Repro to check again: the window in full screen, Quit and Keep Windows, relaunch, Exit Full Screen.
  - Also not checked in full screen: the toolbar and the status bar's ends.
- In the browser client, Stop pressed after the save but before `compile` reaches the core stops nothing.
- Compile flakes, each seen once:
  - `a_timed_out_compile_keeps_the_output_it_wrote`;
  - a build reported as failed with a truncated log.
- **Not yet seen on screen:**
  - drag and drop (the projects screen's and the sidebar's, including a refused drag);
  - focus rings with Keyboard navigation on;
  - `defaultFocus` in the rename fields (context menu), and in the New File, Go to Line and New Project sheets.
- **The toolbar, checked on screen (Debug, active window, dark and light):**
  - At 1200 pt the PDF section starts at the source/PDF divider, and the line runs through the toolbar.
  - Items are 8 pt apart and 8 pt from section edges; B I is one 73 pt capsule; Compile is 75 pt.
  - A column narrower than its section's tools parts the section line from the divider; that's the system's layout. The source section needs about 350 pt with the sidebar shown, and about 480 pt without it (the traffic lights, the toggle, back, the title, which keeps about 160 pt, B I and Insert).
  - Short of room window-wide, zoom goes to `>>` first, then Share; Compile and the toggles last.
- **Window minimums:** the content goes down to 641 × 317 pt. That's source and PDF at 320 pt each, and the columns, build panel and status bar.
  - Narrowing folds the sidebar once source and PDF reach their minimums, and brings it back when there's room.
  - Window › Move & Resize › Left folds it to fit half the display.
  - The projects screen stops at the same size below its toolbar.
- **The launch log:** the app's own faults are fixed. What's left is the system's:
  - App Intents rejects the ad-hoc signature ("Unable to get teamId", `linkd.autoShortcut`). A team-signed build shouldn't log it; this Mac has no signing identity.
  - PDFKit's text recognition logs `e5rt` errors when pages show.
  - The editor's WebContent process logs sandbox and preferences errors.
- `theSideColumnsOpenAtTheirWidths` passes with or without the fix it covers. Before that fix, a project opened with the inspector shown squeezed the sidebar to 200 pt, but only in the real window (probably its toolbar). The fix was checked on screen.
- **Toolbar configurations:** the inspector section's items are immovable defaults.
  - A toolbar configuration saved before them (after a Customize Toolbar change) could lack them, with no way to add them back.
  - The toolbar saves as "Workspace", and none was saved on the owner's Mac; the owner accepted the risk.
- **Orphaned defaults:** split sizes are `PaneSizes` keys, and the old per-split keys are orphaned. On the owner's Mac they were deleted on 2026-09-28; other Macs keep them, unread.
- **The header's drag, not yet done by hand:** `theOutlineHeadersLineTakesTheDividersDrags` checks the wiring (the line's rect, none under the header), not a real drag.
- **Biber on macOS 27:** TeX Live 2026's `biber` 2.21 unpacks its arm64 half with `lipo -extract_family`, which Xcode 27's `lipo` no longer has ("extracting arm64 binary with lipo failed"), so biblatex with biber gets no bibliography. Replacing it with its arm64 half (`lipo -thin arm64`) works. The build panel shows it only as undefined citations.

## Deferred (not dropped)

- **Rust core and web:** the core and the web's `analyzeDoc` mark an untitled heading `"(untitled)"`, which the Mac (`Analysis.untitledTitle`) and Windows (`Outline.DisplayTitle`, `Rows.Untitled`) string-match.
  - The fix: send an empty title (the fixture, `analyze.rs`, `state.js`), and have each client name it by its kind. The web's outline, breadcrumb and section menu show the title as it comes.
  - Waits for Windows: its side must change in the same commit.
- **Core:** check it stays the only source of the default engine and library folder.
- **Windows (a work in progress; the owner's):**
  - Save with `getDocument` and check its path, as the Mac does (`EditorBridge.cs` still reads `getText`).
  - Read `web/src/shortcuts.json` rather than keeping `MenuCommand.Accel`'s copy (the protocol test holds the copy to it meanwhile).
  - Check for the bugs the Mac pass fixed: the non-text `flush()` loop, stale state after deleting the open file, the fixed-delay watcher re-arm, and a closed project's popovers and sheets carrying over.
  - Mirror the visible Mac changes if the platforms should match.

## Next

- Confirm the Mac CI run on the branch (above), then a PR from `claude/macos-polish` to `main`.
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

**Window and restoration**
- **`-ApplePersistenceIgnoreState YES` writes the new state to a temporary folder** and leaves the old one, so the next launch without it restores the state from before. Restoration repros need both launches without it.
- **Setting a window's `contentViewController` sizes the window to the new view and sets its `contentMinSize` to zero.**
  - `MainWindowController.setContent` gives the view the window's size first, then sets the minimum again. An unsized view shrank the window for a moment, and the projects' bridged toolbar laid its title out 9 pt wide: three conflicting-constraint faults per launch.
  - The projects screen's `NSHostingController` (with scene bridging) then sets it from its SwiftUI content's minimum, zero for a list, so `HomeRoot` carries the app's minimum as a frame.
- **`contentMinSize` counts the area under the toolbar** (full-size content view), but the panes' limits hold below it. With the build panel open, a project's window stops a toolbar's height taller than the minimum.
- **Ordered front, a titled window shrinks to the screen's visible frame.** The CI runner's screen is about 1024 pt wide, so `WorkspaceLayoutTests` use an `UnclampedWindow` (`constrainFrameRect` returns the frame).

**Split view**
- **A pane opens at its view's frame as it's added**, and on macOS 27.2 a collapsed one uncollapses to it. `WorkspaceController` sets each frame from `PaneSize`, or from its share of the window.
- **macOS 27.0 uncollapses a pane to its minimum**, not its frame. Show PDF (`setPDFShown`) sets both the PDF's frame and its minimum to its kept share until it's back. The frame alone left it at 320 pt on the runner.
- **Divider detents:** `NSSplitViewController` doesn't implement `splitView(_:constrainSplitPosition:ofSubviewAt:)` (`instancesRespond` is false), so there's no super to call. Swift still needs `override`.
  - The split view consults it on drags and on `setPosition(_:ofDividerAt:)`.
  - `DetentSplitViewController` snaps within 8 pt and taps `NSHapticFeedbackManager`'s `.alignment` once, as the divider arrives.
  - Only the sidebar (at its opening 270 pt) and the source/PDF divider (at half) have detents. The File Outline's and the build panel's dividers have no size worth stopping at, and a snap there would fight fine adjustment, so they have neither snap nor haptic.
- **No scroller while the editor resizes.** CodeMirror keeps the top line in place as lines re-wrap by scrolling, and WebKit shows its overlay scroller for any scroll, a native text view's none. The embed page marks itself `data-resizing` while its size changes and for 0.4 s after (`web/src/embed/editor.js`), and `editor.html` hides the Mac's overlay scroller meanwhile (not a scroller that takes room: hiding it would re-wrap the text). Measured with a knob detector on window captures after a divider move: the PDF and the editor each showed a scroller for about 0.7 s before, none after.
- **The column line and the toolbar's section line are one line only while they track.**
  - A section wider than its column parts them, and the toolbar draws its own short line off the divider.
  - The column minimums are the content's: sizing them to hold the toolbar's tools would be measuring the system's layout by hand.
- **The PDF column doesn't collapse on a drag** (`canCollapse = false`). Collapsed at the window's trailing edge, its divider would sit under the window's resize edge, so a drag back would resize the window instead of opening the PDF.
- **Sidebars fold on a window resize, inspectors don't** (`canCollapseFromWindowResize`: YES for sidebars, NO for inspectors).
  - The window's minimum is the source and PDF's, so a narrowing window squeezes the sidebar to 200 pt, folds it, and brings it back when there's room.
  - Tiling folds it too. `setContentSize` doesn't, so the minimum test hides the sidebar first.
- **A sidebar squeezes before it folds**, down to its minimum, and grows back as the window widens. That's AppKit's default: checked against a bare `NSSplitViewController`, whose sidebar went 299 → 238 → 178 pt, folded, and came back. Scripted resizes (AppleScript, Return to Previous Size) don't grow it back; a drag does.
- **Pane sizes are saved from drags only.** In a live resize the window squeezes the panes, and a squeezed sidebar used to be kept at 200 pt; `saveSizes` skips `inLiveResize`.
- **AppKit's inspector is fixed (270 pt minimum and maximum), yet its divider shows a resize cursor.** `WorkspaceController` overrides `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)` to give that divider no hit area.
- **The inspector item is made before the area**, which opens in the room both side columns leave. Sized past the sidebar alone, the area pushed the sidebar to its minimum.
- **The nested split view controllers answer `toggleSidebar:` and `toggleInspector:` before the window's split**, and they have neither. `WorkspaceToolbar.toolbarWillAddItem` points the system's toggles at the `WorkspaceController`.
- **The File Outline's header is the files pane's foot accessory, folded or not,** so it never swaps views and its title keeps its distance from the line.
  - The sidebar split's divider runs under it. That divider draws nothing (`QuietSplitView`) and takes no drags; the header's line takes them (`splitView(_:additionalEffectiveRectOfDividerAt:)`).
  - The header is the system's own collapsible sidebar section (`Section(isExpanded:)` in a one-section `.sidebar` list, no rows of its own). Checked on 27.2: a click anywhere on a collapsible section's header folds it, not only on its chevron, and the chevron shows on hover. The custom header it replaced showed its chevron only while hovered and took clicks only on it, so a click on the title did nothing.
  - Its list's own 10 pt over the header row keeps the title's distance from the line. Folded, it's 36 pt, level with the status bar; open, it ends with the header's 19 pt row (29 pt), where a section's first row would start. `scrollContentBackground(.hidden)` lets the sidebar's material through.
  - A sidebar `List`'s 10 pt over its first row is inside its table (`NSTableView` `.sourceList`), so `contentMargins(.scrollContent)` and `safeAreaPadding` don't reach it. The outline pulls its list up by 10 pt and clips it.
  - Clipped, the scroller's top went with it; `contentMargins(.top, 10, for: .scrollIndicators)` brings it back to the pane's top.
  - `scrollEdgeEffectStyle(.soft, for: .top)` shows nothing there: the effect draws in the clipped 10 pt, so rows cut hard under the header.
- **The sidebar column's minimum must be at least 140 pt.** Below that, hiding the sidebar pushes its toolbar toggle into the `>>` overflow, leaving no button to show it again.

**Toolbar**
- **Toolbar groups on macOS 27:**
  - Adjacent plain items share one glass capsule with no line between (73 pt for two, the kit's button group).
  - An `NSMenuToolbarItem` breaks that grouping.
  - An `NSToolbarItemGroup` with subitems draws a wider capsule (82 pt), with a line between its parts, and sits 3.5 pt from a tracking separator.
  - The segmented constructor (`images:selectionMode:`) draws lines between parts.
  - Zoom and Math stay segmented around their pull-downs, as the owner asked for zoom.
  - A `.prominent` item gets glass of its own; a `.plain` one joins its plain neighbours'. Stop stays `.prominent` with `backgroundTintColor = .clear`, which looks plain but keeps its own glass.
  - The system's `.toggleInspector` keeps glass of its own, so the PDF toggle beside it is a separate circle (the owner's choice: native, with the divide).
- **A toolbar item's own view** keeps the item's `.prominent` or `.plain` glass, 36 pt high, which wraps the view and passes it no clicks: the view must fill it. Customize Toolbar draws the view without the style, so its copy (`willBeInsertedIntoToolbar` false) is a title item.
- **Customize Toolbar compresses the default set's views.** The zoom control's palette copy resists compression, or its scale reads "…". The toolbar's own copy must not, or it holds the window 50 pt wider even from the overflow menu.
- **A segmented control's segment menu** opens on a click only in a control with no action. With one, it opens only on a press and hold, and the click sends the action. Momentary tracking resets `selectedSegment` before `mouseDown` returns, and segment frames aren't public, so the action opens the menu under the click.
- **Xcode's bottom bars, measured on 27.2:** a corner control's glyph 16.5 pt from the window's edge, and a 1 pt × 12 pt separator 8.5 pt from what's either side of it. A borderless icon-only toggle leaves 1 pt more around its symbol than a text button does around its text (`symbolEdgeAligned`).
- **Toolbar items at the same visibility priority overflow together**: Share went to `>>` with zoom where it still fitted. Rank the widest lowest.
- **Closing a toolbar popover logs "Invalid attempt to open a new transaction during CA commit"** on macOS 27.2, from AppKit: a bare SwiftUI app with one toolbar popover logs it too. It is not the app's.

**Swift and SwiftUI**
- **`Core` makes the blocking `tl_call` on a GCD thread**, not in a `@concurrent` function, which would block Swift's cooperative pool. `Core.Handle` is nonisolated so that thread can read it.
- **`track` needs `nonisolated` Equatable values** (`OutlineState`, the toolbar's `State`, `SavedWorkspace`), or a main-actor conformance can't satisfy `Sendable`. It runs after the change, never inside a SwiftUI update, so collapsing a split item there is safe.
- **An `NSMenuItem` subclass can't override its initialisers under default main-actor isolation.** The toolbar's menus are `NSHostingMenu`s over SwiftUI items instead, which also keeps them the menu bar's.
- **A SwiftUI view at zero opacity leaves the accessibility tree.**
- **A SwiftUI `Picker` whose selection has no matching tag logs a fault**, nil included. The inspector's pickers list the current value as a choice until the settings and the file list come.
- **A field that appears while the editor has focus needs `focused = true` in `onAppear`.** `.defaultFocus` leaves focus in the editor's web view, so an in-place rename typed into the document. `defaultFocus` is right for sheets, which are a new focus scope.
- **`NSBox`'s separator is 1 px, the thin split divider 1 pt.** The bars' lines are a small view (`Hairline`) in the split's `dividerColor`.

**PDF**
- **PDFKit is left to itself.** A scroll-view inset for the gap above page one, and the resize pinning it needed, fought PDFKit's own fit-width layout: a re-layout on every resize step, so the scaling stuttered. A rebuild goes back to `currentDestination`. `hideLinkBorders` hides hyperref's boxes.
- **The pages keep PDFKit's own margins.** With `pageBreakMargins` set (8 pt all round, once), PDFKit scrolled the pages on every resize step, and its overlay scroller showed throughout a divider drag or a pane's animation. With its own (4 pt at the sides, 4.75 pt between pages) it keeps them still.
- **Command-click in the PDF jumps to the source**, as in the Mac's TeX apps; a double-click stays PDFKit's word selection. The web and Windows viewers use a double-click.
- **Core Image filters work in linear light:** dark paper's `colorInvert` turns sRGB 0.84 grey into 0.61, not 0.16.

**Files and TeX**
- **One FSEvents stream watches the project folder** (`FolderWatcher`).
  - The open file is checked when it or a folder above it changes.
  - The tree is read again when something comes, goes or moves in a folder it shows (the core decides what it shows).
  - The open file moved or deleted elsewhere closes, or, with unsaved edits, asks Save Again or Close.
  - Paths are compared with `realpath`: `resolvingSymlinksInPath` drops /private, which FSEvents keeps.
- **Spawn TeX tools by their full path.**
  - With PATH set for the child, std forks for a bare program name instead of using posix_spawn. A forked child of the multithreaded app can crash before exec (six reports while TeX was missing and `status` polled every 10 s).
  - `compile.rs` `program_path` finds the program on the child's PATH; `tools_start_by_posix_spawn_never_a_fork` guards it.

**Tests**
- **Swift Testing suites** set up in `init` and tear down in an `isolated deinit`. Suites that call the app's main-actor code are `@MainActor`.
- **`WorkspaceLayoutTests` save and restore the five defaults keys they change.** Recents aren't pruned when the library lists without them (`AppModel.recents` filters instead), since a scratch library would wipe them.
- **A timed-out `waitUntil` throws `TimedOut(state:)`** with what the test passes as `state`, so a failure on CI says what it saw.
- **Swift Testing's expansion of a failed `#expect` can mislabel nested calls' values.** `isClose(width(item), sidebarIdeal)` printed the width against `sidebarIdeal`. Put the values in the comment when they matter.
