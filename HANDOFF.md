# Handoff: native apps and browser version

Status as of 2026-09-26, on `main` (all earlier branches are merged and deleted).

**Last session (2026-09-26): the macOS polish and a cleanup pass over it are both uncommitted in the working tree.** `main` has everything up to `4ae7f2b`. The Overleaf-style source bar, accessory-bar pane bars, the split sidebar and the scroll-following outline came first. The cleanup (macOS design pass against the UI kit, and a Rust optimisation pass, below) went on top. The ref `refs/cleanup/baseline` snapshots the tree before the cleanup, so `git diff refs/cleanup/baseline` shows the cleanup alone; delete it with `git update-ref -d refs/cleanup/baseline` once committed. `/Applications/TeXLocal.app` is still a Release build from before the cleanup. The old Tauri app is in the Trash.

All checks pass on the cleaned-up tree: the Debug build has no Swift warnings, 26 XCTests, `cargo fmt`, clippy `-D warnings`, `cargo test --workspace` and `npm test` (37). Not yet checked on screen (rendered frames don't show glass, vibrancy, selection or PDFKit pages):
- the outline selection following the source as it scrolls;
- the symbol palette in use;
- the sidebar's glass and selection, and the accent colour in the embedded editor;
- the Files list's Delete key, and that a single click in the Files list or outline keeps keyboard focus in the list.

Next:
- Bring the web version's editor toolbar and outline to the same Overleaf feature set, keeping it universal web design. The new editor operations are already shared.
- The Windows app, which the owner is picking up from `main`.

## Goal

TeXLocal is moving from a single Tauri web UI to three clients over one Rust core:

- **macOS app:** SwiftUI (macOS 27 design), in `apps/macos`.
- **Windows app:** WinUI 3 in C# (Windows 11 Fluent 2), in `apps/windows`.
- **Browser version:** the existing `web/` UI, served by `crates/texlocal-server`. It is local only, never exposed to the network.

Linux is deferred. Tauri (`src-tauri`) keeps shipping until both native apps reach parity, then gets deleted.

The window chrome is native on each platform: toolbar, sidebar, menus, dialogs, icons and settings. Two surfaces stay web-based:

| Surface | macOS | Windows | Browser |
|---|---|---|---|
| LaTeX editor | CodeMirror in a WKWebView (`web/embed/editor.html`) | CodeMirror in WebView2 | CodeMirror |
| PDF viewer | PDFKit | pdf.js in WebView2 (`web/embed/pdf.html`) | pdf.js |

WinUI has no code-editor control. Windows' built-in PDF API renders pages as images only, with no text selection or search.

## Architecture

- **`crates/texlocal-core/src/service.rs` (`Service`)** holds every command's behaviour once.
  - `Service::call(cmd, json)` is the JSON dispatch table shared by all hosts.
  - It deliberately leaves out uploads (raw bytes) and anything that takes a host-chosen absolute path, because the browser server exposes it.
  - The one exception is choosing the TeX folder. `set_tex_dir` stores it in `<data dir>/.texlocal-app.json`, and `list_dirs` lists folders (drives on Windows) so the browser version can browse for it. Both are documented in `Service::call`. The folder only goes first on latexmk's PATH; nothing is read from or written to it.
- **`crates/texlocal-core/src/serve.rs`** handles the `__pdf` and `__raw` routes, byte ranges and MIME types. The Tauri protocol handler and the server both use it.
- **`crates/texlocal-ffi`** is the C ABI the native apps link.
  - The functions are `tl_open`, `tl_call` (JSON in and out, blocking), `tl_free` and `tl_close`.
  - Native-only commands: `pdf_path`, `raw_path`, `export_zip`, `import_files` and `kill_all`.
  - The header and Swift module map live in `include/`.
- **`crates/texlocal-server`** is the browser host. Start it with `npm run serve`.
  - It binds `127.0.0.1` only.
  - The startup token is exchanged for an HttpOnly, SameSite=Strict cookie.
  - It rejects any Host header other than the bound address (DNS rebinding) and non-GET requests from a foreign Origin.
  - **This is security-critical.** `-shell-escape` makes compiling equivalent to running code.
  - It has its own small HTTP/1.1 layer (`src/http.rs`) built on `httparse`, pinned to a GitHub tag. See the network note below.
- **`web/src/bridge.js`** holds `httpBridge()`, the browser host.
  - `commands.js` draws an in-page menu bar and dispatches shortcuts only when there is no native menu.
  - `matchesAccel` matches physical keys.
- **`web/src/embed/`** contains the pages the native apps embed.
  - The host calls methods on `window.texlocal`.
  - The page posts `ready`, `changed`, `cursor` and `command` messages back.
  - The host passes its menu accelerators to `setHostKeys`, so chords that CodeMirror would otherwise capture (for example Mod-Enter) reach the native menu.

## Web design direction

The browser version (`web/`) is universal web design, not Mac- or Windows-styled. It should feel familiar to both, the way Google Docs, Overleaf and VS Code for the web do. As of 2026-09-26:
- **Shortcut labels are platform-correct:** ⌘ glyphs on the Mac, Ctrl+Enter elsewhere. Chords the browser keeps for itself (new window, tab or incognito) aren't advertised. Off the Mac, Go to PDF Position has no shortcut, because it would collide with Compile's Ctrl+Enter, as in the Windows app.
- **Text contrast meets WCAG AA.** Primary buttons fill with `--accent-fill`, and status text uses `--red-text`, `--orange-text` and `--green-text`.
- **In the browser (`html.browser`):**
  - menus, toasts and dialogs are opaque, raised surfaces with a neutral hover;
  - type is 14 px;
  - Interface Size is hidden, since the browser zooms the page itself.
- **The menu bar works like a standard web menu:** ARIA state, arrow keys and Tab, and a trigger that toggles its menu.
- **Recent projects are real links.**
- **The Tauri app keeps its Mac look (`html.mac`)** until it is retired.

## Done and verified

| Commit | Contents |
|---|---|
| `e409056` | Core service refactor; Tauri commands become thin wrappers |
| `d6b1b26` | FFI crate |
| `68939af` | Browser bridge and menu bar |
| `9ae3bc5` | Browser server |
| `45cfe04` | Embed pages |
| `4a5a6cf` | macOS app, first draft |

- `cargo fmt`, clippy and `cargo test --workspace` are clean, and `npm test` passes (37 tests).
- The browser version works end to end in real Chrome, driven over CDP:
  - sign-in, the editor, a compile, the PDF render, the menu bar, and ⌘↩ compiling;
  - a foreign Origin or Host is refused with 403.
- The embed pages work in Chrome:
  - open, format, `getText`, per-file undo across file switches, and host keys posting `command:compile.run`;
  - the PDF page loads the PDF and search works.

## CI for the native apps

Neither app can be built in a Linux or cloud session, so GitHub Actions is the compiler. Both workflows run on push and on pull requests, and only when a path the app builds from changes. Push runs are grouped by commit, so parallel pushes don't cancel each other.

- **`.github/workflows/macos-app.yml` ("macOS app")**, on `macos-26`:
  - It selects the newest Xcode on the image. Today that is 26.6 with the macOS 26.5 SDK.
  - While the runner is older than macOS 27, it builds and tests with `MACOSX_DEPLOYMENT_TARGET` set to the older of the host and SDK versions. An API that needs 27 still fails the build.
  - It fails if the app loads the Rust core as a dylib (checked with `otool -L`).
  - Then it runs the XCTests.
- **`.github/workflows/windows-app.yml` ("Windows app")**, on `windows-latest`:
  - It runs `npm run build` and `cargo build -p texlocal-ffi`.
  - It builds with `dotnet build` (.NET 10), treating warnings as errors.
  - It runs the xUnit tests with `dotnet test`.

## The macOS app (`apps/macos`): redesigned, run by hand in part

- **Project:** `project.yml` is the XcodeGen source, and the generated `TeXLocal.xcodeproj` is committed. Edit both by hand in step, or regenerate.
  - The pre-build script runs `cargo build -p texlocal-ffi`.
  - A post-compile script runs `npm run build` and copies the editor embed files into `Resources/web`.
  - The app links `target/{debug,release}/libtexlocal_ffi.a` by path, plus `-liconv`. `-ltexlocal_ffi` would pick the cdylib that sits beside it, and the app would then load it from `target/`.
  - The bundle ID is `com.texlocal.mac`. There is no sandbox and signing is ad hoc. `NSAppleEventsUsageDescription` is declared because `trash::delete` moves files to the Trash through Finder.
  - `open TeXLocal.app --args -openProject <id>` opens a project at launch.
- **Window:** one `NavigationSplitView`, sized to the macOS 27 UI kit (`~/Downloads/Apple macOS 27 UI Kit.sketch` on the owner's Mac).
  - Sidebar (Overleaf's layout): Files on top, with add in its header, over a docked "File Outline", split by a draggable `NSSplitView` divider. They are separate lists, each with its own selection. The outline's selection follows the section on screen: the top visible line, sent by the editor as `scroll` messages into `ProjectModel.topLine`. It does not follow the caret. Choosing a section scrolls it to the top (`reveal(line, atTop)`).
  - Detail: the source beside the PDF, a build panel below (Issues | Build Log, the log an `NSTextView`), a status bar, and a trailing inspector.
  - The window toolbar holds a back button (Close Project, as the web's and Windows' title bars have) and the PDF and inspector toggles. What acts on a pane sits over it.
  - Over the source: undo and redo, Heading, bold / italic | math, reference and citation, Insert. A LaTeX writer's tools, after Overleaf's; commenting out is only in the Format menu. Under that, a location row: project › folders › file › section.
  - Over the PDF: Compile (prominent), zoom (out | level | in), Share. Under that, the page and whether the preview is current.
  - **Design rules (cleanup pass, 2026-09-26):**
    - Liquid Glass only where the system gives it: the window toolbar, the sidebar column, popovers, menus, sheets, alerts. Pane bars, the location row and the status bar are flat content-layer bars on one opaque `BarMetrics.background` (`windowBackgroundColor`), so they read as one chrome block with the toolbar.
    - One set of metrics, from the kit, in `PaneBars.swift`: `BarMetrics` (bar = controls + 8 pt above and below, 8 pt side insets, 4 pt within a group, 8 pt between groups, 16 pt separators; secondary rows 28 pt) and `Typography` (the text role → system text style map: `.body` content, `sectionTitle` = `.title3` semibold, `secondary` = `.subheadline` with `.small` controls, SF Mono at the same size for the log). No literal point sizes except the editor's user-set size.
    - Bars: `PaneBar` (one row of actions), `PaneBarRows` (the find bar's two rows), `SecondaryBar` (the location row, the PDF's page row and the status bar: one text style and control size for all three).
    - Values are bordered system controls with their own indicators, actions are flat accessory-bar buttons. Section Level is a `Picker(.menu)` (checks the current level, names itself to VoiceOver); zoom is a bordered `Menu` (the scale is any percentage) holding Fit Width / Fit Height and an inline `Picker` of presets, the current one checked. The accessory-bar pull-down draws no indicator, so no value menu uses it. A menu of actions (⋯, +) is an icon-only pull-down.
    - The source's find bar is native (`SourceFindBar`, Edit › Find and Replace…, ⌘F in the text): an `NSSearchField` with the find options (Match Case, Whole Words, Regular Expression) in its own magnifier menu, as Xcode's and Safari's are, and a replace field under it that is the same `NSSearchField` with the magnifier's image cleared (AppKit's plain text field stays 24 pt at every control size; the search field grows to 28 / 36 pt), so both rows match at each toolbar size; previous / next, the match count, then Replace / Replace All and Done as bordered push buttons, apart from the icon buttons. A `ViewThatFits` folds it for narrow panes: Replace All moves into Replace's menu (`Menu` with `primaryAction`), then the fields shrink from `BarMetrics.fieldWidth` to `fieldMinWidth`, and only then does the count go, so the minimum window still says "Not found". The replace field gets an empty `searchMenuTemplate` so AppKit lays out the same magnifier-with-menu slot as the find field, and the two texts start on one line. CodeMirror still searches: the embed's `setHostFind(true)` swaps its search panel for an empty stand-in whose opening and closing post `findOpen` / `findClosed`, and the page posts `findMatches` as the selection moves. Other hosts (Windows) keep CodeMirror's panel.
    - The embed matches the chrome when the host sends `host` colours in `setAppearance` (text background, secondary label, find highlight, selected content): all of it scoped under `:root[data-host]` in `web/embed/editor.html`, so the browser version and Windows are unchanged. The gutter is Xcode's (numbers 2 px smaller in SF Mono), completions and the math preview are menu-like (12 px corners, 24 px rows, no kind icons, the system selection colour).
    - Vocabulary: the bottom panel is the "Build Panel" everywhere (View menu, status bar); durations come from `CompileResult.durationText` ("1.2 s"); short status strings are title case.
    - Semantic colours only. The embed takes the system accent and selection colours from the host (`setAppearance`); Windows and the browser keep their defaults.
    - Only APIs in the macOS 26 SDK, since CI builds with 26.5.
  - Pane bars use AppKit's accessory-bar style (`.accessoryBar`, set once on `PaneBar`), as Finder's and Mail's in-window bars do: flat buttons that highlight on hover, with `ToolSeparator` lines between groups. Compile is `.borderedProminent`. Glass was dropped: merged interactive glass (`glassEffectUnion`) glitched icons on hover, and pills read too heavy for bars stacked above content.
  - The source bar follows Overleaf's toolbar:
    - undo | redo, then a section-level menu for the caret's line (`setHeading`);
    - bold | italic, then inline math | display math | a symbol palette (a popover, `symbolGroups`);
    - link | reference | citation, figure | table, and bulleted | numbered;
    - a trailing ⋯ menu for the rest.
    Narrow panes fold groups into ⋯ from the end.
  - The editor operations are in `web/src/editor.js`, used by the embed page: `setHeading`, `insertText`, `inline` (a `pre$0post` wrap in the line) and `displayMath`.
  - PDF bar: Compile, then zoom as − / the scale as a percentage (a menu with Fit Width and presets) / +, a separator, then Share. Share uses `NSSharingServicePicker`, anchored to its button through `ViewAnchor`: `ShareLink` opened centred on the PDF.
  - Settings › General › Toolbar Size: Standard (stored as "compact") is regular controls in a 40 pt bar, the kit's Unified Compact toolbar; Large is extra-large controls with large symbols in 52 pt, the kit's Unified toolbar. The location row and status bar are 28 pt.
  - Settings: each tab is a grouped form at its content's height, so the window resizes per tab. Font Size is the system `Stepper(value:in:format:)`, whose editable value and arrows a grouped form lines up itself.
  - The build panel is at most 40% of the editors' height (`SplitPane.maxFraction`), so a small window keeps the source and PDF. The build's summary shows only in the status bar. Issues are a selectable list (double-click or Return opens the line); a failed build with no parsed error says so and offers the Build Log. Accessory-bar buttons measure 22 and 34 pt, 2 pt under the kit's, so those bars have 9 pt insets; the bar-fit test allows 8 to 9.
  - The PDF pane's empty states have one action each: Compile, Get MacTeX, or Show Build Panel after a build that made no PDF (hidden while the panel shows). With no build yet, the status bar, the inspector's Last Build and the Issues tab share one phrase (`ProjectModel.noBuildTitle`): "No Build This Session" over a PDF from an earlier session, else "Not Compiled". A failed build reads "Build Failed · 2 Errors" with one symbol. Issue rows show `file:line`, the main file's when the log names none, as double-click opens. The zoom menu checks Fit Width / Fit Height while fitting (`PDFController.fit`).
  - The sidebar lists open files and sections without focusing the editor (`ProjectModel.open(…, focus: false)`), so the arrow keys stay in the list; search hits, issues, Go to Line and SyncTeX still focus it.
  - Menus: Edit › Spelling and Grammar (the stateless items only; the While Typing toggles need an AppKit-validated menu item to show their checkmarks), "Comment Selection", and Help › TeXLocal on GitHub. The app icon is a flat PNG set from `assets/TeXLocal.png`; a layered Icon Composer `.icon` is the macOS 26+ ideal.
  - A library folder that can't be opened shows an alert and quits. The alert is posted on the next main-queue turn: `Core.shared` is first made during SwiftUI's first scene update, where a modal alert aborted the app.
  - The start window: template cards (plain system buttons: pressed dimming and the keyboard focus ring are the system's), then recent projects as a sortable table.
- Editor current line: `setAppearance` sends `current-line` (quaternary system fill) and `selection-match` host colours; `web/embed/editor.html` still has to use them for `.cm-activeLine`, `.cm-activeLineGutter` and `.cm-selectionMatch` under `:root[data-host]`.
- **Layout rules learnt the hard way:**
  - The window has one minimum size (960 × 600) whatever it shows. Changing it as a project opened crashed AppKit ("more Update Constraints in Window passes than there are views").
  - Every split is AppKit's `NSSplitView` (`SplitController.swift`; the bar components are in `PaneBars.swift`, the source's bars in `SourceBars.swift`): source | PDF, the editors over the panel, and the editors beside the inspector. Each pane is an `NSHostingView` made once (its views observe the models), with `sizingOptions = []` so SwiftUI's sizes stay out of Auto Layout; the delegate enforces minimums and maximums. A hidden pane is removed from the split, since AppKit kept room for a merely hidden one, and comes back at its previous size. Divider positions are autosaved.
  - SwiftUI's split views don't work in this window (2026-09-26). `.inspector` crashed on window resize with the same loop. `HSplitView` and `VSplitView` laid the PDF out under the inspector, and a pane shown after launch opened at zero size. `NSSplitViewController` blurred the pane bars with the toolbar's scroll-edge effect.
  - Menu clicks through System Events do update the window in the background. An earlier "frozen window" came from pane views built from values rather than views that observe the models.
  - Bars are stacked above their content, not attached with `safeAreaBar`: they are opaque, so content under them was only hidden.
  - Separators are stock `Divider()`s placed as siblings in a `VStack`. An overlaid `Divider()` takes its parent's layout context, so inside an `HStack` it turns vertical.
  - PDFKit re-anchors page one's top to the view on every resize while fitting the width, so the gap above page one is a scroll-view content inset.
- **Parity and review fixes:** every command in `commandDefs`, and the settings with a native meaning. Saves run one at a time; quit waits for a save in flight; compiles queue; a WebContent crash recovers the editor; overlapping file opens can no longer save one file's text into another; undo and redo always reach CodeMirror's history.
- **Tests:** 30 XCTests, including the outline tree, the bar heights and that a pane bar group fits its bar at each toolbar size, the build panel keeping within its largest share, the source find count, the duration text, and the Build Panel and spelling menu items. The test scheme sets `TEXLOCAL_DATA=/tmp/texlocal-xctest`, and its pre-action copies `web/src/workspace.js` there for the command-table test: the tests run inside TeXLocal.app, which would otherwise need Documents access, and macOS asks again after every re-signing build, blocking the read.
- **PDF links:** PDFKit draws hyperref's coloured link boxes, which pdf.js (browser, Windows) leaves out, so `hideLinkBorders` zeroes each link's border on load. The links still work.
- **Checked by hand on a Mac (2026-09-26), against a scratch `TEXLOCAL_DATA`:**
  - click-and-slide from Bold to Italic applied only Italic (with the hand-built groups since replaced by `ControlGroup`);
  - undo and redo move exactly one step, from the pane bar and from the Edit menu;
  - dark paper inverts the preview;
  - SyncTeX forward (highlights the line) and Go to Source Position;
  - killing the editor's WebContent recovers the editor. With an unsaved edit it shows one lost-edits alert, and the file is untouched;
  - quitting straight after an edit saves the edit first and leaves no `latexmk`;
  - a copied `TeXLocal.app`, with the build moved away, opens and compiles a project.
- **Found while checking:**
  - After the lost-edits alert, the PDF still says "Preview Out of Date", though the file matches the PDF.
  - One injected double-click on the "Method" heading went to line 28 (`\label`), where `synctex edit` gives line 24. Go to Source Position is correct, so this may be the injected events. Try a real double-click.
- **Still to check by hand on a Mac:** a real double-click for inverse SyncTeX, find field keys, rename with undo history, drag-and-drop import, the first delete's Automation prompt.
- **Driving the app without taking focus:** Accessibility actions work while TeXLocal is in the background: AXPress on the pane-bar buttons, menu items through System Events, and alert buttons. Synthetic key and mouse events posted to its process are dropped unless it is the active app. Setting AX text in the CodeMirror editor is ignored.
- **Looking at the app without Accessibility or Screen Recording** (Claude had neither on 2026-09-26): launch a Debug build directly (`TEXLOCAL_DATA=<scratch> …/TeXLocal.app/Contents/MacOS/TeXLocal -openProject <id>`; preferences can be overridden with launch arguments such as `-paneBarSize large`), attach `lldb --batch`, and in an Objective-C expression draw the largest visible window's theme frame with `cacheDisplayInRect:toBitmapImageRep:` into a PNG. Cast every message send (`(NSArray *)[(NSApplication *)[NSApplication sharedApplication] windows]`). This shows layout and sizes, but not glass, vibrancy, list selection or PDFKit pages.

## The Windows app (`apps/windows`): run by hand on Windows 11, partly verified

- **Projects:**
  - **`TeXLocal.Core`** has no WinUI. It holds:
    - `Core.cs`: `[LibraryImport]` over the FFI, with every call off the UI thread;
    - the data shapes, and `MenuCommand` (the ids and shortcuts from `commandDefs`);
    - the outline parser, `ProjectPaths` (moving the open file's path on a rename) and `Preferences` (JSON under `%LOCALAPPDATA%\TeXLocal`).
  - **`TeXLocal.Tests`** (xUnit): the FFI round trip, the shortcut table checked against `workspace.js`, and the pure logic.
  - **`TeXLocal`:** the WinUI 3 app.
    - It is unpackaged and x64. .NET 10 and Windows App SDK 2.5.1 are both bundled, so users install neither.
    - `texlocal_ffi.dll` is copied from `target\debug` or `target\release` to match the configuration.
- **Web surfaces:** the editor and PDF pages each run in a WebView2.
  - The bundled `web\` is served at `app.texlocal`. The PDF is answered at `project.texlocal` from `WebResourceRequested`, with a CORS header for `app.texlocal`. A folder mapping only applies to pages loaded after it is set, so it never reached the already-open viewer.
  - Window-level keyboard shortcuts stand down while a page has focus. The page posts the chord back instead: the editor page already did this, and `web/src/embed/pdf.js` now does too.
- **Parity:** every command in `commandDefs`, and every setting the macOS app has.
  - Done: menus, toolbar, sidebar (tree, search, outline), autosave and the compile queue, compile and log, PDF find and zoom, SyncTeX, import and export.
  - Also done: word count and the breadcrumb in a status bar, interface size, PDF paper, numpad shortcuts, and dropping files onto a tree folder to import into it.
  - Closing flushes first and then calls `kill_all`. A crashed editor page recovers.
  - Both macOS reviews' bug fixes are applied here too. The app uses `texlocal.rename` and the undo fallback from `web/src/embed/editor.js`.
  - On Windows, CmdOrCtrl+Return and Ctrl+Return are the same keys. Compile keeps the shortcut, and Go to PDF position is on the Compile menu only.
- **Windows design pass (Fluent 2):**
  - The Windows App SDK `TitleBar` control, over Mica, with back and pane buttons.
  - A card layer for the document area. Spacing on the 4 px grid, and theme resources only (no hard-coded colours).
  - The type ramp, and sentence-case labels throughout.
  - Segoe Fluent Icons.
  - Access keys on every menu and on the main toolbar buttons. Context menus in the standard order, with F2 and Delete.
  - `InfoBar`, `ProgressRing` and `InfoBadge` for feedback.
  - A Settings page in the Windows 11 style, with cards and an expander.
  - Accessibility:
    - accessible names on icon-only buttons and on tree, log and project rows;
    - the dividers take focus and resize with the arrow keys;
    - the editor's zoom follows the Windows text-size setting.
- **Deliberate deviations:**
  - The settings cards and the divider are hand-written, rather than taken from the Community Toolkit, to avoid adding NuGet packages.
  - Interface size scales only the editor page. Native controls follow Windows text size.
  - The file tree uses a copy of WinUI's own TreeViewItem template (`CompactTree.xaml`) with a 16 px expander column instead of 40 px. Re-copy it from the new `generic.xaml` when the Windows App SDK is upgraded.
- **Not done yet:**
  - recovery when the whole WebView2 browser process dies;
  - trimming the output size (the Windows App SDK brings its AI/ML parts);
  - an installer. For now, run `cargo build --release -p texlocal-ffi`, then `dotnet publish apps/windows/TeXLocal/TeXLocal.csproj -c Release -p:Platform=x64 -r win-x64 -o %LOCALAPPDATA%\Programs\TeXLocal`, and add a Start-menu shortcut to the exe. The owner's PC is set up this way, with no desktop shortcut.
- **Verified by hand on Windows 11 (build 26340), with TeX Live 2026:**
  - The PDF loads and renders with a text layer, and find works.
  - Compiling works, including a recompile after a failed run (latexmk now gets `-g`). A new TeX install is found without restarting the app.
  - Choosing the TeX folder works in both versions:
    - in the app, with Settings' Browse… and Use automatic;
    - in the browser version, with its folder browser. The browser version still creates, compiles and shows a project.
  - The title bar uses the tall height, with its content and the caption buttons on one line.
  - The library, the workspace and Settings were measured with UI Automation:
    - one left edge in the sidebar, and 16 px per tree level;
    - no band under the title bar;
    - 32 px buttons;
    - Settings' columns aligned.
  - The sidebar toggle, folders expanding and collapsing, the outline's disclosure, and the settings and engine footer.
  - Moving between the library, a project and Settings animates.
  - The installed Release build starts from the Start menu.
- **Known issues:**
  - Once, a window kept showing a frozen frame while it went on working. Fresh launches never did. It may be a GPU device loss on this Insider build, but that is unconfirmed.
- **Still to check by hand on Windows:**
  - Every shortcut fires exactly once whether focus is in the editor, the PDF or the sidebar.
  - The title bar:
    - back and pane buttons, and dragging;
    - the caption buttons with a forced light or dark theme and with high contrast;
    - Snap Layouts.
  - The Alt access keys don't collide.
  - Tab reaches the dividers, and the arrow keys resize them.
  - Settings apply straight away and survive a restart.
  - Editor size and Windows text size scale the editor, and CodeMirror still measures correctly.
  - Dark paper.
  - The status bar.
  - Drag-and-drop onto a folder.
  - Saving and closing:
    - typing while a save is in progress loses nothing;
    - after a main-file change, the old PDF stays until the new one builds;
    - closing a project during a compile doesn't recompile the next project.
  - Ending the editor's renderer process in Task Manager gives one lost-edits message, and closing still works.
  - Undo and Redo in the editor body and in its find field.
  - Narrator.
  - SyncTeX in both directions.
  - No `latexmk` is left running after quitting during a compile.
  - The file pickers.
  - The compile notification.
  - Nothing is written beside the exe.

## Rust cleanup (2026-09-26, uncommitted)

Behaviour-preserving, with no public API, C ABI or server-check change:
- The log parser uses 4 `LazyLock` regexes instead of 7, and is about 20% faster on a 16 MB log. CRLF logs (MiKTeX, Windows latexmk) no longer leave a `\r` inside messages.
- A cancelled compile kills its whole process tree, on Windows too (the registration guard owns the child, so `taskkill /T` runs while latexmk is alive). Registry locks recover from poisoning, since `kill_all` runs from `tl_close`.
- A ranged read is one blocking-pool trip, and the server resolves and stats a file in one more.
- One entry walk serves the file tree, search, the symbol scan and fingerprinting. A link loop in a project is skipped instead of failing all of them with a 500. ZIP export no longer packs its own temp file when the destination path runs through a link.
- `create_project` refuses an existing entry, including a dangling link, atomically.
- The Trash tests use a stand-in: `core.rs` runs in under a second instead of two minutes, and no longer fills the real Trash.

## Remaining plan

1. **Run both apps by hand** using the checklists above, and fix what they turn up.
2. **Windows:** the items under "Not done yet" above.
3. **Server hardening:** check Host, Origin and the cookie on the request head before reading a body of up to `MAX_BODY`. It needs a pre-body hook in `http::serve` and a lingering close, so the client still reads the 401.
4. **Edit › Find Next / Find Previous (⌘G, ⇧⌘G)** on the Mac: CodeMirror has them, but the embed has no command for them yet, and `commandDefs` would need the entries too.
5. **Retire Tauri** once both apps are verified by hand. Delete `src-tauri`, the Tauri path in `bridge.js` and `@tauri-apps/cli`, and replace `tauri-action` in `ci.yml` and `release.yml` with release builds of the two apps.

## Gotchas

- An unfinished Word-style safe save (write a temporary file, then replace) is kept, uncommitted, at `.claude/wip/safesave.rs`. It is not wired in.

- On the owner's Mac, `static.crates.io` is blocked by network policy, while GitHub works. Before adding a Rust dependency, check `~/.cargo/registry/cache`, or pin a dependency-free crate to its GitHub tag. That is why the server doesn't use axum.
- `CLAUDE.md` is deleted; the owner's global `AGENTS.md` replaces it.
- XcodeGen 2.46 is not installed system-wide. Download it from GitHub releases and regenerate after editing `project.yml`.
- The Tauri app's behaviour must not regress while it still ships. Run `npm run app` to check.
