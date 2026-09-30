# Handoff: TeXLocal

## Status (2026-09-29)

- **`main`** has the Mac app's rewrite and polish (PR #12, `claude/macos-polish`): AppKit owns the window, split and toolbar, SwiftUI draws the panes; one window with a back button and an inspector; tests in Swift Testing.
- **`claude/native-editor`** (from `main`) is the native frontend study's first phase (the study: https://claude.ai/artifact/7ZvNe2J8nNvsG8vBxTxVVm):
  - `crates/texlocal-syntax`: the LaTeX editing logic, ported from the web's editor and CodeMirror's stex mode.
  - The Mac's editor is a native `NSTextView` over it; the Mac embeds no web page any more. The web and Windows keep CodeMirror.
- **Last full check (2026-09-29, `claude/native-editor`):** `npm test` (79) and `npm run build`; the Mac's 57 tests; Debug builds with no Swift warnings; `cargo fmt --check`, clippy `-D warnings` and `cargo test` for the core, syntax, FFI and server crates. On screen (a check copy): typing, colours light and dark, the gutter, completion and snippets, find, the outline's jumps, undo, Bold, JetBrains Mono, the maths preview (inline, `\[`, `align`; typing in it; closed outside maths and when the app deactivates).
- **Windows is a work in progress** (the owner's). It may change in the same commit as the core or the web; CI is its only check, since it can't be built here.

## Layout

One Rust core (`crates/`) under three clients:
- **macOS** (`apps/macos`):
  - AppKit and SwiftUI, deployment target macOS 27.0.
  - Swift 6 with Approachable Concurrency and main-actor default isolation, as Xcode 27's App template sets them.
  - CI builds with Xcode 27 on the `xcode-27` runner image (macOS 27.0).
- **Windows** (`apps/windows`): WinUI 3, C#.
- **Browser** (`web/`, served by `crates/texlocal-server`): local only.
- **Tauri** (`src-tauri`) still ships until both native apps are verified.

The editor is native on the Mac (TextKit 2 over `crates/texlocal-syntax`) and CodeMirror elsewhere (the browser; Windows embeds `web/embed/editor.html`). The PDF is PDFKit on the Mac and pdf.js elsewhere.

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
- **`texlocal-syntax`** (`crates/texlocal-syntax`): the editing logic, pure Rust with no I/O.
  - A `SourceDocument` mirrors the editor's text through its edits and answers in UTF-16 offsets: highlights (`highlight.rs`, CodeMirror's stex mode token for token, per-line states cached), completions with snippet fields (`complete.rs`), comments, indentation, headings and blocks (`edit.rs`), maths mode and the maths to preview (`maths.rs`). The editor owns the text, its undo and its drawing, and applies the edits it gets back.
  - The ports follow `web/src/editor.js`, regex for regex. `src/catalog.json` holds what both recognise and insert (commands, environments, blocks, sectioning), and `web/src/latex-data.js` reads it; `tests/fixtures/editing.json` holds both to the same answers (`cargo test`, `test/mathmode.test.js`, `test/editor.test.js`).
  - `texlocal-ffi` exposes it as `tl_source_*` beside `tl_call` (`include/texlocal.h`): edits, lines and highlights as plain C, the commands as JSON, which Windows could P/Invoke too. Hand-written: UniFFI generated 2,400 lines for a dozen functions.
- **`analyze`** (`analyze.rs`): outline, words and lines.
  - Ported from the web's `analyzeDoc` (`web/src/state.js`), which stays the source of truth.
  - `crates/texlocal-core/tests/fixtures/analyze.json` is checked by both `cargo test` and `test/analyze.test.js`.
- **Atomic saves** (`atomic.rs`): write a temporary file beside the target, sync it, then rename it over the target.
- **Embed protocol (Windows):** the host calls `window.texlocal`.
  - The page posts `ready`, `changed`, `cursor`, `scroll` and `command` (a menu chord).
  - Insert blocks are named by id; their LaTeX is the catalog's `blocks`, which `test/blocks.test.js` checks every client's ids against.
- **Commands and chords:** accelerators live in `web/src/shortcuts.json`, which the web and the Mac read.
  - `test/protocol.test.js` holds Windows' copies (commands, accelerators) and both apps' palettes and fonts to the web's.
  - It also checks that the Mac menu has every web command, less the web-only ones it lists.

## Build, test, run

- **Web and core:**
  - `npm install`, `npm test`, `npm run build`.
  - `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`.
  - `npm run serve` runs the browser version; `npm run app` runs Tauri.
- **macOS:** `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -derivedDataPath <dd> build` (or `test`).
  - Pre-build runs `cargo build -p texlocal-ffi`. Post-compile (`scripts/copy-resources.sh`) copies `shortcuts.json`, and JetBrains Mono and KaTeX from `node_modules` into `Resources/Fonts` and `Resources/KaTeX`, so `npm ci` comes first.
  - The app links the static `libtexlocal_ffi.a` by path.
  - Bundle id `com.texlocal.mac`.
  - `project.yml` and the committed `.xcodeproj` are kept in step by hand, since XcodeGen isn't installed. `apps/macos/scripts/add-source.py app|tests Name.swift` registers a new file with both.
- **Mac tests** are Swift Testing (`TeXLocalTests/`), one file per area:
  - `WorkspaceLayoutTests`: the split, on screen and unseen;
  - `CommandTests`: chords, the menu bar, Find routing;
  - `SourceEditorTests`: the native editor's typing, snippets, find and per-file undo;
  - `ProjectTests`: the file watcher, the core, project flows;
  - `DocumentTests`: SyncTeX, the outline, find;
  - `BarTests`.

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
  - Match Accessibility elements by exact title within the window: a substring can hit a menu-bar item.
- **The test host is the app, with the app's defaults** (`com.texlocal.mac`); the suites put back what they change.

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
  - The sidebar opens at the same 270 pt and has the system's limits: 144 pt, no maximum.
  - Bars are split-item accessories: the sidebar's search field, the find bars, the File Outline's header (`OutlineHeader`, at the files' foot folded or not), and the status bar at the foot of source + PDF.
  - Also here: `DetentSplitViewController` (the dividers' detents), `OutlineSplitViewController` (files over the outline, the header's line taking the divider's drags), `ColumnMetrics` (column and pane limits), `PaneSize` (sizes in the `PaneSizes` defaults dictionary) and `Hairline`.
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
- `SourceColumn`: the source column (the editor, a file preview or no file) and `SourceFindBar`.
- `StatusBar`: the status bar and its build-panel toggle.
- `SourceEditor`: a project's editor: one `SourceTextView` for its files, each file's undo and selection kept while its text is unchanged; the find bar's search (`FindQuery`, CodeMirror's semantics); the formatting commands; `EditorView`; the palettes, fonts and prefs.
- `SourceTextView`: the text view: it tells the core (`SourceDocument.swift`) every edit, draws the gutter and current line in `drawBackground`, colours what shows with TextKit 2 rendering attributes, and types as the web's editor does (closing brackets, indentation, completion with linked snippet fields).
- `MathPopover`: the maths preview's popover and the KaTeX page it shows.
- `BuildPanel`: the build panel (issues and the log).
- `PDFPane`: the PDF column, its find bar, the scale menu, `PDFFind` and `PDFPrefs`. The find bar stays open across rebuilds (the web closes it): each new PDF is searched again, keeping the current match and leaving the pages where they are.
- `PDFController`: the PDF's state, `SyncPDFView` and the `PDFView` wrapper. Dark paper inverts the pages only (`documentView`'s filters), so the view's background and scrollers stay the window's.
- `SidebarView`: the sidebar's search, the File Outline's header, the files and the outline.
  - Files: rows drag out as the file (copied by other apps, opened by the editor) and move within the tree onto a folder, a file's folder or the Files header (the top level), as in Finder; files from elsewhere are copied in.
  - Outline: headings are native list rows, the current heading the selection; choosing one (click anywhere on the row, or the arrow keys) scrolls the source to it and leaves the keyboard in the list. A click on the current row goes back to its heading, which an unchanged selection wouldn't.
  - Return or Escape in a rename gives the keyboard back to the list, as in Finder; a click elsewhere leaves it there.
- `Outline`, `HomeView`, `SettingsView`.
- `AppModel`: library, recents, imports, alerts; `DefaultsKey` (every defaults key, registered defaults).
- `ProjectModel`: the open project, saves, builds, file watching; `SavedWorkspace`. `FolderWatcher` is the FSEvents watch.
- `Core`, `Models` (the core's JSON types), `LaTeX` (the snippets the toolbar and menus write).
- `Commands`: menus and shortcuts.
  - Every item is a `MenuCommand`.
  - The menus act on `app.commandProject`: the open project while the main window is key, otherwise nil.
  - File › Rename, Show in Finder, Move to Trash (⌘⌫, without asking, as in Finder) and Share… aren't `MenuCommand`s: the web has no ids for them. The first three act on the chosen item of the list with the keyboard, whose actions (`ItemActions`, also its context menu's) the list passes to `AppModel.chosenItem` (`offersActions`): a SwiftUI focused value doesn't reach the menus from an AppKit window's hosting views. A bare ⌫ does nothing. Share… is a `ShareLink`, the system's item.
  - Insert sits between View and Window, its symbols one submenu down (a section). Format keeps Bold, Italic, the section level (the caret line's ticked) and Comment.
  - Mac chords that leave the shared table (`macAccel`): ⇧⌘W Close Project, ⌥⌘E Inline Math (Pages' Insert › Equation), ⌥⌘J Go to PDF Position; Go to Source Position has none (⌘-click, or the PDF's context menu).
- `PaneBars`: bar metrics (the UI kit's), `Typography`, `FindBar`, `SearchField` and `FieldHandle`, `FindPassingTextView` (the find bars' field editor and the source's base class), `DialogSheet`, the rename pieces, and `ItemActions` (`offersActions`).
- `SyncTeXGeometry`.
- Leaf views have `#Preview`s that need no Rust core.

**AppKit that remains, and why:**
- **The window, split and toolbar.**
  - `NavigationSplitView` can't hide its last column (the PDF), can't run a panel under two of its columns, and has no split-item accessories.
  - SwiftUI's toolbar has no tracking separators, so it can't give each column its own section.
  - A SwiftUI scene's window owns its toolbar, so the window is AppKit's too.
- **The status bar's ends:** constraints to the corner-adapted safe area's layout guide (`layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))`) put the content 16 pt from the window's edge where there's a corner, as Xcode's bottom bars have it, and at the bar's own 8 pt elsewhere. SwiftUI's `containerCornerInsets` are zero inside an AppKit split item's accessory.
- **Its hairline and the File Outline header's** are a small view in the split's `dividerColor`, 1 pt like the dividers they continue.
- **The status bar and the folded header are 36 pt** (`BarMetrics.secondaryBarHeight`), Xcode's editor status bar between its hairlines (measured on 27.2), so the two lines run on as one. Their content sits under their lines, and the header's title is raised the 1.5 pt the list puts it low (`titleDrop`), so both bars' words are centred and level, as in Xcode.
- **An `NSTextView` (TextKit 2) for the source.** SwiftUI's `TextEditor` has no gutter, no viewport hook to colour only what shows, no completion list, and one undo manager rather than one per file.
  - The caret, context menu, Services, dictation, text drags, completion list, find indicator and Undo are the system's; each file has its own undo manager (`SourceEditor.undoManager(for:)`), and the core's edits go in as one named step each.
  - Edit › Find's items pass on (`FindPassingTextView`) to `MainWindowController`, which sends them to the pane with the keyboard; the find bars' field editor is the same class.
  - Spelling is underlined in the prose only (the delegate drops what the core colours; comments are prose), a kept setting (`EditorPrefs.spellCheck`). No substitutions: smart dashes and quotes would rewrite LaTeX.
  - The completion list is the system's, words only (native over custom, the owner's call).
  - A drag with files opens them (`fileDrop`). JetBrains Mono is the web's WOFF2, registered with CoreText on first use.
  - The maths preview (`MathPopover`): the core's `math_at`, typeset by the web's KaTeX in the system's popover over where the maths starts, while the caret is in it and the text has the keyboard. A web view that takes no clicks or keys draws it: there's no system maths typesetter.
- **The inspector is AppKit's split item**, the one SwiftUI's `.inspector` builds on. The modifier attaches to a SwiftUI split, and this window's split is AppKit's. Its content is SwiftUI.
- **Compile's own view** (a SwiftUI button in an `NSHostingView`): an item's image can't animate Stop's spinner.
  - The title is the system font, 12 pt from the ends, as an item's title is (by glyph width: medium read wider and bolder).
  - One view for both states: swapping an item's `view` in or out while it's in the toolbar throws in `NSToolbarItemViewer` on the next layout (27.2).
- **The segmented zoom and Math controls open their menu segment's menu from their action** (`openMenu(of:)`). AppKit opens a segment's menu on a click only in a control with no action, and these have one for their other segments.
  - So a click opens it as the mouse goes up, and a press and hold opens AppKit's own after 0.26 s (real clicks on a prototype, 27.2).
  - Without an action AppKit opens it on the press, but the control then doesn't say which other segment was clicked (`selectedSegment` is back to -1 when `mouseDown` returns), and keyboard and VoiceOver presses send nothing. Segment frames aren't public API.
- **`NSSearchField`** in the find bars, the sidebar and the log filter: SwiftUI's search field is toolbar or sidebar only.
- **`PDFView`**: SwiftUI has no PDF view.
- **An `NSTextView` for the build log**: a SwiftUI `Text` lays out LaTeX's megabyte logs whole on every change.
- **The drag pasteboard** (`NSPasteboard(name: .drag)`): a SwiftUI drop session names none of its items before the drop. The file drops read it to refuse what they can't take while it's dragged.

## Core behaviour (every host)

- **Compiling past errors:** builds run with latexmk `-f`, so a PDF is returned even on failure. The per-project `stopOnFirstError` passes `-halt-on-error` instead.
- **Stopping:** `stop_compile {id}` stops one project's build; `kill_all` is for quit.
- **Import name clashes** are per file: Replace (moves the old file to the Trash), Keep Both, or cancel (the Mac's Cancel, Windows' Stop).
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
  - Entering and leaving full screen (View menu) was clean on 27.2, the toolbar and the status bar's ends in place; that repro itself wasn't run again.
- In the browser client, Stop pressed after the save but before `compile` reaches the core stops nothing.
- Compile flakes, each seen once:
  - `a_timed_out_compile_keeps_the_output_it_wrote`;
  - a build reported as failed with a truncated log.
- **Not yet seen on screen:** focus rings with Keyboard navigation on (a system setting).
- **The toolbar short of room:**
  - A column narrower than its section's tools parts the section line from the divider; that's the system's layout. The source section needs about 350 pt with the sidebar shown, and about 480 pt without it (the traffic lights, the toggle, back, the title, which keeps about 160 pt, B I and Insert).
  - Short of room window-wide, zoom goes to `>>` first, then Share; Compile and the toggles last.
- **Window minimums:** the content goes down to 641 × 318 pt, or 641 × 370 pt with the build panel open, where the panes' own minimums bind (a live drag of the corner, 27.2). Hiding the PDF doesn't let it narrow.
  - Narrowing folds the sidebar once source and PDF reach their minimums, and brings it back when there's room.
  - Window › Move & Resize › Left folds it to fit half the display.
  - The projects screen stops at the same size below its toolbar.
- **The launch log:** the app's own faults are fixed. What's left is the system's:
  - App Intents rejects the ad-hoc signature ("Unable to get teamId", `linkd.autoShortcut`). A team-signed build shouldn't log it; this Mac has no signing identity.
  - PDFKit's text recognition logs `e5rt` errors when pages show.
- `theSideColumnsOpenAtTheirWidths` doesn't catch a727502's bug (the inspector shown at open squeezed the sidebar to 200 pt): it showed only in the real window, probably its toolbar.
- **Toolbar configurations:** the inspector section's items are immovable defaults.
  - A toolbar configuration saved before them (after a Customize Toolbar change) could lack them, with no way to add them back.
  - The toolbar saves as "Workspace", and none was saved on the owner's Mac; the owner accepted the risk.
- **Orphaned defaults:** split sizes are `PaneSizes` keys; the old per-split keys stay, unread, on Macs that ran earlier builds.
- **Biber on macOS 27:** TeX Live 2026's `biber` 2.21 unpacks its arm64 half with `lipo -extract_family`, which Xcode 27's `lipo` no longer has ("extracting arm64 binary with lipo failed"), so biblatex with biber gets no bibliography. Replacing it with its arm64 half (`lipo -thin arm64`) works. The build panel shows it only as undefined citations.

## Deferred (not dropped)

- **From the 2026-09-29 native review, not done:**
  - PDF find is synchronous: the first query in a 392-page PDF blocks about 445 ms (text extraction), later ones 4–87 ms. `beginFindString` would avoid it, but PDFKit doesn't say which thread its find delegate runs on.
  - The build panel's issue list clears its selection whenever the filter or Warnings change what shows (rows by position, as LaTeX repeats identical warnings).
  - The Mac works out the library folder itself (`Core.libraryFolder`, the core's rule repeated), where Windows lets the core choose (`tl_open(null)`). The core as its only source needs a small FFI getter for the path the Mac shows when it can't open it.
  - An empty-space drop on the Files list does nothing: a List hands it to neither `dropDestination` nor `onDrop` (27.2), so the Files header takes the top level.
- **From the HIG review (2026-09-29):** the app icon is a flat PNG set (`AppIcon.appiconset`). macOS 27's layered icon with dark, clear and tinted looks needs an `AppIcon.icon` made in Icon Composer: new artwork, the owner's to make.
- **Decided by the owner (2026-09-29):** the sidebar keeps two panes, files over the outline (one list with sections declined: the outline would scroll away under a long file list); `QLPreviewView` for file previews declined (it draws hyperref's link boxes, which no LaTeX editor shows).

- **The native editor (2026-09-29), not done:**
  - The web still runs CodeMirror's stex and its own completion; it could run `texlocal-syntax` through wasm and drop its copies (the fixtures keep them equal meanwhile).
  - One caret: typing over several selections replaces the first (CodeMirror has multiple carets). Quotes aren't paired (LaTeX's are two backticks and two apostrophes).
  - The session (open files, undo, saves) stays in each host; the core takes it when a second native host would share it.
- **Rust core and web:** the core and the web's `analyzeDoc` mark an untitled heading `"(untitled)"`, which the Mac (`Outline.untitledTitle`) and Windows (`Outline.DisplayTitle`, `Rows.Untitled`) string-match.
  - The fix: send an empty title (the fixture, `analyze.rs`, `state.js`), and have each client name it by its kind. The web's outline, breadcrumb and section menu show the title as it comes.
  - Waits for Windows: its side must change in the same commit.
- **Core:** check it stays the only source of the default engine and library folder.
- **Windows (a work in progress; the owner's):**
  - Check the path of the text a save writes, as the Mac's `SourceEditor.document` pairs them (`EditorBridge.cs` reads `getText`, which knows no path).
  - Read `web/src/shortcuts.json` rather than keeping `MenuCommand.Accel`'s copy (the protocol test holds the copy to it meanwhile).
  - Check for the bugs the Mac pass fixed: the non-text `flush()` loop, stale state after deleting the open file, the fixed-delay watcher re-arm, and a closed project's popovers and sheets carrying over.
  - Mirror the visible Mac changes if the platforms should match.

## Next

- Confirm CI on `claude/native-editor`; a PR to `main` when the owner asks.
- The study's next phases: Windows' editor (native, or CodeMirror over the core's logic through wasm), then the session (open files, undo, saves) in the core once two native hosts would share it.
- Deferred features:
  - error hints and gutter markers;
  - `.blg` parsing;
  - Clean and Compile;
  - TinyTeX / package install;
  - `!TEX` magic comments;
  - more templates;
  - version history;
  - duplicate project;
  - image drop to insert a figure (Overleaf's: an image dropped in the editor is uploaded and opens Insert Figure);
  - import UI on Windows and the web.
- Web follow-ups are in `docs/web.md`.
- Retire Tauri once both apps are verified: delete `src-tauri`, the Tauri path in `bridge.js`, `@tauri-apps/cli`, and the Tauri entries in `check-version.mjs`, `ci.yml` and `release.yml`.

## Gotchas

**Window and restoration**
- **`-ApplePersistenceIgnoreState YES` writes the new state to a temporary folder** and leaves the old one, so the next launch without it restores the state from before. Restoration repros need both launches without it.
- **Setting a window's `contentViewController` sizes the window to the new view and sets its `contentMinSize` to zero.**
  - `MainWindowController.setContent` gives the view the window's size first, then sets the minimum again: an unsized view squeezed the projects' bridged toolbar into conflicting constraints.
  - The projects screen's `NSHostingController` (with scene bridging) then sets it from its SwiftUI content's minimum, zero for a list, so `HomeRoot` carries the app's minimum as a frame.
- **`contentMinSize` counts the area under the toolbar** (full-size content view), but the panes' limits hold below it. With the build panel open, a project's window stops a toolbar's height taller than the minimum.
- **Ordered front, a titled window shrinks to the screen's visible frame.** The CI runner's screen is about 1024 pt wide, so `WorkspaceLayoutTests` use an `UnclampedWindow` (`constrainFrameRect` returns the frame).

**Split view**
- **A pane opens at its view's frame as it's added**, and on macOS 27.2 a collapsed one uncollapses to it. `WorkspaceController` sets each frame from `PaneSize`, or from its share of the window.
- **The build panel reopens at its kept height** (`setPanelShown`): its frame, set before it's shown. On 27.2 that's enough, and lowering a minimum raised for it jumped it a status bar's height for two frames; 27.0 needs the minimum (below). It fades in and out: it rises from under the status bar, whose glass otherwise showed its header.
- **macOS 27.0 uncollapses a pane to its minimum**, not its frame. Show PDF (`setPDFShown`) sets both the PDF's frame and its minimum to its kept share until it's back. The frame alone left it at 320 pt on the runner.
- **Divider detents:** `NSSplitViewController` doesn't implement `splitView(_:constrainSplitPosition:ofSubviewAt:)` (`instancesRespond` is false), so there's no super to call. Swift still needs `override`.
  - The split view consults it on drags and on `setPosition(_:ofDividerAt:)`.
  - `DetentSplitViewController` snaps within 8 pt and taps `NSHapticFeedbackManager`'s `.alignment` once, as the divider arrives.
  - Only the sidebar (at its opening 270 pt) and the source/PDF divider (at half) have detents. The File Outline's and the build panel's dividers have no size worth stopping at, and a snap there would fight fine adjustment, so they have neither snap nor haptic.
- **The column line and the toolbar's section line are one line only while they track.**
  - A section wider than its column parts them, and the toolbar draws its own short line off the divider.
  - The column minimums are the content's: sizing them to hold the toolbar's tools would be measuring the system's layout by hand.
- **Both columns run on under the toolbar.** The toolbar is adaptive, as Mail's: while each section holds its tools, AppKit paints each its own background; when a section can't (about 370 pt for the PDF's), it joins them into one band with one line, and both columns show through it with the system's edge effect. While apart, the PDF's section takes the titlebar material, which covers the pages, whenever the source column holds a scroll view of any kind, SwiftUI's or AppKit's (measured on 27.2 with the view tree; the cause is inside AppKit). Fit Height, the sync point and forward search measure the part that shows (`shownHeight`).
  - The source's scroll view runs under the toolbar and the find bar (`ignoresSafeArea`), and its automatic content insets take in both, so the first line and a line scrolled to sit below them while AppKit draws its edge effect over the text.
  - A SwiftUI-only `NavigationSplitView` (a `TextEditor`, a `ScrollView`, per-column toolbars) runs both columns' content under the toolbar with the soft effect in every state: its sections take the window background material, not the titlebar's.
- **The PDF column doesn't collapse on a drag**, AppKit's default for a plain item, kept on purpose: collapsed at the window's trailing edge, its divider would sit under the window's resize edge, so a drag back would resize the window instead of opening the PDF.
- **Sidebars fold on a window resize, inspectors don't** (`canCollapseFromWindowResize`: YES for sidebars, NO for inspectors).
  - The window's minimum is the source and PDF's, so a narrowing window squeezes the sidebar to 144 pt, folds it, and brings it back when there's room.
  - Tiling folds it too. `setContentSize` doesn't, so the minimum test hides the sidebar first.
- **A sidebar squeezes before it folds**, down to its minimum, and grows back as the window widens (AppKit's default). Scripted resizes (AppleScript, Return to Previous Size) don't grow it back; a drag does.
- **Pane sizes are saved as a divider's drag resizes them,** on macOS 27's `didResizeSubviews` message with `userResize`: never from a window resized in code or live, a collapse, a close or a quit.
- **AppKit's inspector is fixed (270 pt minimum and maximum), yet its divider shows a resize cursor.** `WorkspaceController` overrides `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)` to give that divider no hit area.
- **The inspector item is made before the area**, which opens in the room both side columns leave. Sized past the sidebar alone, the area pushed the sidebar to its minimum.
- **The nested split view controllers answer `toggleSidebar:` and `toggleInspector:` before the window's split**, and they have neither. `WorkspaceToolbar.toolbarWillAddItem` points the system's toggles at the `WorkspaceController`.
- **The File Outline's header is the files pane's foot accessory, folded or not,** so it never swaps views and its title keeps its distance from the line.
  - The sidebar split's divider runs under it. That divider draws nothing (`QuietSplitView`), and its own reach (AppKit's 2 pt either side of a thin divider) moves up onto the header's line (`splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)`); folded, it has none.
  - The header is the system's own collapsible sidebar section (`Section(isExpanded:)` in a one-section `.sidebar` list, no rows of its own): a click anywhere on it folds it, and the chevron shows on hover.
  - Its list's own 10 pt over the header row keeps the title's distance from the line. Folded, it's 36 pt, level with the status bar; open, it ends with the header's 19 pt row (29 pt), where a section's first row would start. The list itself is its whole 39 pt content (its 10 pt under the row too), shown from the top: shorter, a drag from the header autoscrolled it, which `scrollDisabled` doesn't stop. `scrollContentBackground(.hidden)` lets the sidebar's material through.
  - A sidebar `List`'s 10 pt over its first row is inside its table (`NSTableView` `.sourceList`), so `contentMargins(.scrollContent)` and `safeAreaPadding` don't reach it. The outline pulls its list up by 10 pt and clips it.
  - Clipped, the scroller's top went with it; `contentMargins(.top, 10, for: .scrollIndicators)` brings it back to the pane's top.
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
- **Xcode's bottom bars, measured on 27.2:** a corner control's glyph 16.5 pt from the window's edge, and a 1 pt × 12 pt separator 8.5 pt from what's either side of it. The status bar's controls are the HIG's 20 × 20 pt at least (`hitTarget`: a frame and a content shape, as a borderless button's hit area is only what it draws), and the toggle takes 3 pt off either side so its glyph keeps Xcode's place.
- **Toolbar items at the same visibility priority overflow together**: Share went to `>>` with zoom where it still fitted. Rank the widest lowest.
- **Closing a toolbar popover logs "Invalid attempt to open a new transaction during CA commit"** on macOS 27.2, from AppKit: a bare SwiftUI app with one toolbar popover logs it too. It is not the app's.

**Swift and SwiftUI**
- **`Core` makes the blocking `tl_call` on a GCD thread**, not in a `@concurrent` function, which would block Swift's cooperative pool. `Core.Handle` is nonisolated so that thread can read it.
- **`track` needs `nonisolated` Equatable values** (the toolbar's `State`, `SavedWorkspace`), or a main-actor conformance can't satisfy `Sendable`. It runs after the change, never inside a SwiftUI update, so collapsing a split item there is safe.
- **An `NSMenuItem` subclass can't override its initialisers under default main-actor isolation.** The toolbar's menus are `NSHostingMenu`s over SwiftUI items instead, which also keeps them the menu bar's.
- **Hide an AppKit view to take it out of the key view loop.** A SwiftUI view at zero opacity leaves the accessibility tree but not the loop, and a hidden split-item accessory only folds to no height, its controls still in the loop and VoiceOver: `setHidden` hides the accessory's view too, and the source's scroll view is hidden (`SourceEditor.shown`) while a preview shows.
- **A SwiftUI `Picker` whose selection has no matching tag logs a fault**, nil included. The inspector's pickers list the current value as a choice until the settings and the file list come.
- **A field that appears while the editor has focus needs `focused = true` in `onAppear`.** `.defaultFocus` leaves focus in the source's text view, so an in-place rename typed into the document. `defaultFocus` is right for sheets, which are a new focus scope.
- **`NSBox`'s separator is 1 px, the thin split divider 1 pt.** The bars' lines are a small view (`Hairline`) in the split's `dividerColor`.

**The source's text view**
- **The text storage's edited range runs past the change** to the paragraph's end, taking in the attributes it fixed. The core's mirror takes the whole range (right either way); snippet fields and stepped-over brackets follow the range `shouldChangeText(inRanges:)` passed (`SourceTextView.changing`), or a field typed in would end its snippet.
- **The system's completion list closes on a typed key** with `NSTextMovement.other` and `isFinal`: that key is the user's text, not a choice, so `insertCompletion` takes only Return, Tab or a click, and the list opens again, narrowed, after the key goes in.
- **The selection draws over rendering attributes' backgrounds,** so the current find match is the selection, shown by the find indicator as it's reached; the other matches are tinted.
- **A taller line keeps its extra room above the text,** and a positive baseline offset shrinks the line rather than raising the text. `lineStyle` gives the line half the extra and line spacing the rest; TextKit lays that spacing out at the top of the next paragraph's fragment, so the current line's fill takes it from there.
- **Spell checking's results count from the start of the range checked** (`textView(_:didCheckTextIn:…)`, 27.2), not the document's.
- **The maths preview's web view** is transparent only through `drawsBackground` by key-value coding (`underPageBackgroundColor` isn't enough). Its size is measured after a layout and `document.fonts.ready`, or it's the fallback font's and the maths is cut short. `NSPopover.positioningRect` raises ("window must exist") until the popover shows.
- **`ATSApplicationFontsPath` doesn't load a WOFF2,** which CoreText registers from a URL (`EditorFont.registerJetBrains`).
- **In a test, a file's undo steps are one group:** `groupsByEvent` closes a group only as the run loop turns. Check one step per opened file.

**PDF**
- **PDFKit is left to itself:** no insets of the app's round its fit-width layout. A rebuild goes back to `currentDestination`, and `loadDocument` hides hyperref's boxes.
- **The pages keep PDFKit's own margins** (set ones made it scroll the pages on every resize step). They scale with the page, so Fit Height counts them, and PDFView keeps a set scale as it resizes, so `SyncPDFView.onResize` fits the height again.
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
- **Recents aren't pruned when the library lists without them** (`AppModel.recents` filters instead), since the tests' scratch library would wipe them.
- **Swift Testing's expansion of a failed `#expect` can mislabel nested calls' values.** `isClose(width(item), sidebarIdeal)` printed the width against `sidebarIdeal`. Put the values in the comment when they matter.
