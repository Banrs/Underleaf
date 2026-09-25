# Handoff: native apps and browser version

Status as of 2026-09-26, on `main` (all earlier branches are merged and deleted).

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

## The macOS app (`apps/macos`): redesigned, run by hand in part

- **Project:** `project.yml` is the XcodeGen source, and the generated `TeXLocal.xcodeproj` is committed. Edit both by hand in step, or regenerate.
  - The pre-build script runs `cargo build -p texlocal-ffi`.
  - A post-compile script runs `npm run build` and copies the editor embed files into `Resources/web`.
  - The app links `target/{debug,release}/libtexlocal_ffi.a` by path, plus `-liconv`. `-ltexlocal_ffi` would pick the cdylib that sits beside it, and the app would then load it from `target/`.
  - The bundle ID is `com.texlocal.mac`. There is no sandbox and signing is ad hoc. `NSAppleEventsUsageDescription` is declared because `trash::delete` moves files to the Trash through Finder.
  - `open TeXLocal.app --args -openProject <id>` opens a project at launch.
- **Window:** one `NavigationSplitView`, sized to the macOS 27 UI kit (`~/Downloads/Apple macOS 27 UI Kit.sketch` on the owner's Mac).
  - Sidebar: the files, then the open document's outline as a real hierarchy with disclosure triangles (`Outline.tree`), and project search.
  - Detail: the source beside the PDF, a build panel below (Issues | Build Log, the log an `NSTextView`), a status bar, and a trailing inspector.
  - The window toolbar holds a back button (Close Project, as the web's and Windows' title bars have) and the PDF and inspector toggles. What acts on a pane sits over it.
  - Over the source: undo and redo, Heading, bold / italic | math, reference and citation, Insert. A LaTeX writer's tools, after Overleaf's; commenting out is only in the Format menu. Under that, a location row: project › folders › file › section.
  - Over the PDF: Compile (prominent), zoom (out | level | in), Share. Under that, the page and whether the preview is current.
  - Pane bar controls are native only; the owner asked for native over hand-built. Each group is native `.glass` buttons whose glass `glassEffectUnion` merges into one capsule with no separators, as Notes' toolbar groups look. `ControlGroup` was tried and dropped: AppKit's segmented control puts a separator between every button. The zoom level is a borderless menu on its own glass in the same union: as a `.glass` menu, its label drew blurred.
  - Glass buttons draw their icons dimmed while the window is inactive; that is the system's, not disabled.
  - Settings › General › Toolbar Size: Compact uses Large controls (26 pt glass buttons, 44 pt bars); Large uses Extra Large controls (34 pt, 52 pt bars), the window toolbar's size. Both keep the standard toolbar spacing (8 pt insets and gaps). The location row is 28 pt.
  - The start window: template cards, then recent projects as a sortable table.
- **Layout rules learnt the hard way:**
  - The window has one minimum size (960 × 600) whatever it shows. Changing it as a project opened crashed AppKit ("more Update Constraints in Window passes than there are views").
  - The inspector is a SwiftUI pane of the detail, not `.inspector`: that made a third AppKit split column whose minimums looped the same way.
  - The editor/PDF and panel splits are SwiftUI (`SplitPair`), not `HSplitView`/`VSplitView`, for the same reason.
  - Bars are stacked above their content, not attached with `safeAreaBar`: they are opaque, so content under them was only hidden.
  - An overlaid `Divider()` inside an `HStack` turns vertical. Use `Hairline`.
  - PDFKit re-anchors page one's top to the view on every resize while fitting the width, so the gap above page one is a scroll-view content inset.
- **Parity and review fixes:** every command in `commandDefs`, and the settings with a native meaning. Saves run one at a time; quit waits for a save in flight; compiles queue; a WebContent crash recovers the editor; overlapping file opens can no longer save one file's text into another; undo and redo always reach CodeMirror's history.
- **Tests:** 22 XCTests, including the outline tree and the pane bar groups' height at each toolbar size. The test scheme sets `TEXLOCAL_DATA=/tmp/texlocal-xctest`, and its pre-action copies `web/src/workspace.js` there for the command-table test: the tests run inside TeXLocal.app, which would otherwise need Documents access, and macOS asks again after every re-signing build, blocking the read.
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

## Remaining plan

1. **Run both apps by hand** using the checklists above, and fix what they turn up.
2. **Windows:** the items under "Not done yet" above.
3. **Retire Tauri** once both apps are verified by hand. Delete `src-tauri`, the Tauri path in `bridge.js` and `@tauri-apps/cli`, and replace `tauri-action` in `ci.yml` and `release.yml` with release builds of the two apps.

## Gotchas

- An unfinished Word-style safe save (write a temporary file, then replace) is kept, uncommitted, at `.claude/wip/safesave.rs`. It is not wired in.

- On the owner's Mac, `static.crates.io` is blocked by network policy, while GitHub works. Before adding a Rust dependency, check `~/.cargo/registry/cache`, or pin a dependency-free crate to its GitHub tag. That is why the server doesn't use axum.
- `CLAUDE.md` was deleted by the owner on purpose. That deletion is left unstaged and is not part of these commits.
- XcodeGen 2.46 is not installed system-wide. Download it from GitHub releases and regenerate after editing `project.yml`.
- The Tauri app's behaviour must not regress while it still ships. Run `npm run app` to check.
