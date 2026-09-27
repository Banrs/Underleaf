# Handoff: TeXLocal

## Status (2026-09-27)

- `main` is pushed (`91bd62f`). CI hasn't reported on it yet.
- PR #11 (`claude/windows-parity`: WebView2 recovery, a trimmed SDK, an Inno Setup installer) is open. It needs `main` merged in; the conflicts are in the Windows `Outline`, `Dialogs`, `LogsView`, `ProjectModel`, `SettingsView` and `WorkspaceView`.
- Last full check passed: `cargo fmt --check`, clippy `-D warnings`, `cargo test --workspace`, `npm test`, Mac Debug and Release builds with no Swift warnings, and the XCTests.

## Layout

One Rust core (`crates/`) under three clients:
- **macOS** (`apps/macos`): SwiftUI, deployment target macOS 27.0. CI builds with Xcode 27 on the `xcode-27` runner image.
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
- **Typecheck against CI's SDK:** `xcrun swiftc -typecheck -swift-version 6 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos27.0 -I crates/texlocal-ffi/include apps/macos/TeXLocal/*.swift`.
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
- `TeXLocalApp`: two windows, Office style: the gallery (templates and recents) and one project window. Closing the project window closes the project and brings the gallery back; the app keeps running with no windows.
- `AppModel`: library, recents, imports, alerts.
- `ProjectModel`: the open project, saves, builds, file watching.
- `Core`, `Models`, `Commands`: menus and shortcuts. Every item is a `MenuCommand`, which also lists the chords the editor page hands back. The menus act on the key window's project (`focusedSceneValue`).
- `WorkspaceView`: columns, toolbar, inspector.
- `EditorView`: panes, previews, status bar.
- `EditorBridge`: the `WebPage`.
- `SourceBars`, `PDFPane`, `LogsView`: the build panel.
- `SidebarView`, `Outline`, `HomeView`, `SettingsView`.
- `PaneBars`: bar metrics (the UI kit's) and pieces: every bar control is a bordered control or `ControlGroup` at 24 pt; `PaneStack` and `FindBar` serve both panes.
- `SplitController`: `NSSplitViewController` panes, plus the sidebar's `SidebarSplit`.
- `SyncTeXGeometry`.

**AppKit that remains, and why:**
- `SplitController`: SwiftUI's `.inspector` crashes on resize on macOS 27, and `HSplitView`/`VSplitView` mislay panes.
- `SidebarSplit` is a plain `NSSplitView`: inside `NSSplitViewController` items, SwiftUI sidebar lists start 10 pt lower.
- `NSSearchField` in the find bars and the log filter (SwiftUI's search field is toolbar or sidebar only), `PDFView`, and an `NSTextView` for the build log.
- `FindMenuResponder`: Edit › Find is the system's (`TextEditingCommands`), whose items send `performFindPanelAction:` with a tag down the responder chain. Neither `WKWebView` nor `PDFView` answers it, so a responder after the project window takes it to the pane with the keyboard (`FocusedValues.find`); a find bar's field has its own field editor that passes the items on. Replacing `.textEditing` instead loses the spelling and substitution toggles' checkmarks.

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

- A full-screen assertion (`_relinquishTitlebar`) was seen once, when leaving full screen; it hasn't been reproduced.
- The sidebar outline's fold slides on a Timer: `displayLink` stops while the screen is locked.
- In the browser client, Stop pressed after the save but before `compile` reaches the core stops nothing.
- Compile flakes, each seen once:
  - `a_timed_out_compile_keeps_the_output_it_wrote`;
  - a build reported as failed with a truncated log.
- Not yet seen on screen: drag and drop, the clash alert, the nested section menu, focus rings.

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
  - import UI on Windows and the web;
  - a customizable toolbar.
- Web follow-ups are in `docs/web.md`.
- Retire Tauri once both apps are verified: delete `src-tauri`, the Tauri path in `bridge.js`, `@tauri-apps/cli`, and the Tauri entries in `check-version.mjs`, `ci.yml` and `release.yml`.

## Gotchas

- **A launch with saved window state presents no default window.** The gallery stays restorable: with `.restorationBehavior(.disabled)`, state holding only the gallery (a crash, or Quit and Keep Windows) opened the app with no window at all. Launch scratch builds with `-ApplePersistenceIgnoreState YES` for a clean start.

- **The sidebar column's minimum must be at least 140 pt.** Below that, hiding the sidebar pushes its toolbar toggle into the `>>` overflow, leaving no button to show it again.
- **`NSSplitViewController` opens an uncollapsed pane at its minimum** unless it has a size from this session. `PaneSplitViewController` holds a pane that has been hidden since launch at its autosaved size, or its share, and then lets it go.
- **PDFKit** re-anchors page one on every resize while fitting the width. `SyncPDFView` keeps the reading position through resizes and rebuilds, and `hideLinkBorders` hides hyperref's boxes.
- **Core Image filters work in linear light:** dark paper's `colorInvert` turns sRGB 0.84 grey into 0.61, not 0.16.
- **macOS 26's `setPosition`** doesn't lay out panes that were just added, as 27's does. The split tests size a window explicitly, and they clear `autosaveName` before closing so no sizes leak into the app's defaults.
