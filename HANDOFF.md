# Handoff: native apps and browser version

Status as of 2026-09-24, branch `claude/handoff-continuation-e94xnl` (continues `feat/browser-server`).

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

- `cargo fmt`, clippy and `cargo test --workspace` are clean, and `npm test` passes (36 tests).
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

## The Windows app (`apps/windows`): builds and tests green, not yet run by hand

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
  - The bundled `web\` is served at `app.texlocal`, and the project's build folder at `project.texlocal`.
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
- **Not done yet:**
  - recovery when the whole WebView2 browser process dies;
  - trimming the output size (the Windows App SDK brings its AI/ML parts);
  - an installer.
- **Check by hand on Windows:**
  - The PDF actually loads. This is the riskiest item: the page at `app.texlocal` fetches from `project.texlocal`.
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
