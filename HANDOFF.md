# Handoff: native apps and browser version

Status as of 2026-09-25, branch `claude/handoff-continuation-e94xnl` (continues `feat/browser-server`).

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

## The macOS app (`apps/macos`): builds and tests green, not yet run by hand

- **Project:** `project.yml` is the XcodeGen source, and the generated `TeXLocal.xcodeproj` is committed. Edit both by hand in step, or regenerate.
  - The pre-build script runs `cargo build -p texlocal-ffi`.
  - A post-compile script runs `npm run build` and copies the editor embed files into `Resources/web`.
  - The app links `target/{debug,release}/libtexlocal_ffi.a` by path, plus `-liconv`. `-ltexlocal_ffi` would pick the cdylib that sits beside it, and the app would then load it from `target/`.
  - The bundle ID is `com.texlocal.mac`. There is no sandbox and signing is ad hoc. `NSAppleEventsUsageDescription` is declared because `trash::delete` moves files to the Trash through Finder.
- **Parity:** every command in `commandDefs` and every setting with a native meaning.
  - The web's remaining settings are in: PDF paper (white, dark or auto), interface size (the editor's `pageZoom`), word count and auto-compile.
  - Also done: word count, the breadcrumb in the window subtitle, the web's PDF find behaviour (`NSSearchField`), and Undo and Redo routed to CodeMirror.
  - Not ported on purpose:
    - floating panels (macOS already floats the sidebar);
    - remembered split widths;
    - the sync pill (sync is in the Compile menu);
    - remembered expanded folders (`OutlineGroup` can't report them).
- **Review fixes (bugs found by reading the code):**
  - Renaming a folder moves the open file's path with it.
  - Saves run one at a time, and quit waits for one in flight.
  - Compiles requested during a compile are queued, and an early ⌘S still compiles.
  - The editor recovers from a WebContent crash.
  - The PDF is read into memory, so a rewrite can't corrupt the view, and reloading keeps the scroll position.
  - A new main file rebuilds the PDF.
- **Tests:** 19 XCTests. The test scheme sets `TEXLOCAL_DATA=/tmp/texlocal-xctest`. One test checks the command and shortcut table against `web/src/workspace.js`.
- **Check by hand on a Mac:**
  - Undo and Redo from the menu and from ⌘Z / ⇧⌘Z, each undoing exactly once.
  - ⌘, and ⌘\ and ⌥⌘= / ⌥⌘-.
  - Dark paper.
  - The find field's Return, Shift-Return and Escape.
  - Killing the WebContent process in Activity Monitor recovers the editor.
  - Quit during a save.
  - ⌘Z in the editor's Find & Replace fields undoes the field.
  - Renaming a file or folder keeps its undo history.
  - Rename a folder that contains the open file, then delete the open file.
  - Forward and inverse SyncTeX.
  - Drag-and-drop import.
  - The first delete shows the Finder Automation prompt.
  - A built `TeXLocal.app` launches after being copied to another location.

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
  - **The 2026-09 redesign.** The macOS app's features, laid out as a native Windows app at WinUI's standard density. The spec, Microsoft's numbers and measurements of the inbox apps were worked up during the redesign; the decisions are summarised here.
    - **Title bar: the Tall 48 px bar, with the system's own 48 × 48 caption buttons.**
      - Left to right:
        - back and the sidebar toggle;
        - the icon, with the project (or the app, or Settings) as the title;
        - the default 40 px MenuBar, on every screen, as Visual Studio keeps its menus in its title bar;
        - one search box, centred on the window as Windows 11 apps centre theirs (`PlaceSearch`). It searches the projects on the library and the open project in a workspace, with results shown in place;
        - the PDF and Details toggles.
      - The open file is named by the jump bar below.
      - WinUI's TitleBar makes only the menus, the search box and the toggles non-draggable. Hit-testing confirms that the gaps between them still drag the window.
      - TitleBar sizes its caption-button column from `AppWindow.TitleBar.RightInset`, which is in physical pixels, as if it were in effective ones, so at 200% it reserved twice the buttons' width. `FitCaptionInset` corrects the column on load and whenever the scale changes. The 48 px left between the toggles and the buttons is TitleBar's own minimum drag area.
      - A 40 px bar with Terminal-style caption buttons drawn by the app was tried and dropped: at 40, the toolbars under it had to be cramped to match.
    - **Rhythm: 48 px rows, 32 px detail rows.**
      - 48 px: title bar, pane toolbars, panel header, the Details pane's name row.
      - 32 px: jump bar, PDF location row (and the folder row of the Details pane, which carries their divider across), status bar, the sidebar's section headings.
      - Every control stays its standard size: 32 px buttons, 14 px text, 16 px icons, with 8 px between buttons.
      - The pane toolbars are rows of standard buttons rather than CommandBars, so their labels are Body text like the rest of the app. When narrow, their labels drop first, then whole groups fold into "See more", as the macOS app's ViewThatFits does.
    - **Layers.**
      - The sidebar sits on Mica, 280 wide by default (200–360). It has no footer: Add is the Files heading's action (Settings stays in the File menu, Ctrl+,), so nothing at its foot needs to line up with the status bar.
      - The trees' expander column is narrowed from 40 to 24 at runtime (`OnTreeItemLoaded`), since the template hard-codes its padding. Rows then start 12 in from their heading. The main file's star sits at the far end of its row.
      - The references with no button of their own (equation reference, label, link, URL) are in the Insert menu, so the toolbar has no bare chevron button.
      - The content layer has an 8 px top-left corner and a 1 px stroke on its top and left edges, like NavigationView's content area. It contains the source, the PDF, the bottom panel, the status bar under the document only, and the Details pane.
      - The Details pane is File Explorer's pattern: Alt+Shift+P, 220–320 wide.
      - Pane sizes are remembered in `Preferences`.
    - **Motion** (`Motion.cs`) uses the Windows animation library's theme animations:
      - DrillIn and DrillOut between the library, a project and Settings, as Settings and File Explorer do;
      - PopIn from its own edge for the sidebar, the Details pane and the panel;
      - FadeIn for search results and the trees they replace.
      - Theme *transitions* (such as PaneThemeTransition) were tried, but they play only when an element joins the tree, not when it is shown again, and these panes are shown by Visibility. Frame captures confirmed they did nothing on a toggle. `Motion.Show` starts the animation as an element goes from collapsed to visible. None of it runs when Windows' animation effects are off.
    - **Toggles are subtle everywhere.** `SubtleToggles.xaml` is merged by App.xaml and again by the title bar's toggle group, because the title-bar toggles didn't pick it up from the app's resources.
    - **Library and Settings** are WinUI Gallery pages: a column at most 1064 wide with 36 px gutters, centred inside a full-width grid. Given to the ScrollViewer directly, that column landed off-centre.
    - **Parity additions:**
      - Cut, Copy, Paste and Select all; Exit; Add folder…;
      - Full screen (F11) and Stop (Ctrl+Break);
      - one-click Reference and Citation;
      - project search grouped by file;
      - a minimum window of 960 × 600, and "Open folder location";
      - an About card in Settings;
      - WebView2 context menus trimmed to editing commands;
      - PDF find fixes;
      - 700 ms autosave, and forward search that saves first.
    - **Metrics** come from WinUI's `generic.xaml`, the Windows UI Kit in code, since the Figma kit needs a sign-in.
  - Accessibility:
    - accessible names on icon-only buttons and on tree, log and project rows;
    - the dividers take focus and resize with the arrow keys;
    - the editor's zoom follows the Windows text-size setting.
- **Deliberate deviations:**
  - The settings cards and the divider are hand-written, rather than taken from the Community Toolkit, to avoid adding NuGet packages.
  - Interface size scales only the editor page. Native controls follow Windows text size.
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
  - The Tall title bar was measured with UI Automation and hit-testing. Menu clicks reach the menus and empty space drags the window.
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

## Remaining plan

1. **Run both apps by hand** using the checklists above, and fix what they turn up.
2. **Windows:** the items under "Not done yet" above.
3. **Retire Tauri** once both apps are verified by hand. Delete `src-tauri`, the Tauri path in `bridge.js` and `@tauri-apps/cli`, and replace `tauri-action` in `ci.yml` and `release.yml` with release builds of the two apps.

## Gotchas

- On the owner's Mac, `static.crates.io` is blocked by network policy, while GitHub works. Before adding a Rust dependency, check `~/.cargo/registry/cache`, or pin a dependency-free crate to its GitHub tag. That is why the server doesn't use axum.
- `CLAUDE.md` was deleted by the owner on purpose. That deletion is left unstaged and is not part of these commits.
- XcodeGen 2.46 is not installed system-wide. Download it from GitHub releases and regenerate after editing `project.yml`.
- The Tauri app's behaviour must not regress while it still ships. Run `npm run app` to check.
