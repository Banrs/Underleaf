# Handoff: native apps and browser version

Status as of 2026-09-24, branch `feat/browser-server`.

## Goal

TeXLocal is moving from a single Tauri web UI to three clients over one Rust core:

- **macOS app:** SwiftUI (macOS 27 design), in `apps/macos`.
- **Windows app:** WinUI 3 in C# (Windows 11 Fluent 2), planned for `apps/windows`.
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

- `cargo fmt`, clippy and `cargo test --workspace` are clean, and `npm test` passes (36 tests).
- The browser version works end to end in real Chrome, driven over CDP:
  - sign-in, the editor, a compile, the PDF render, the menu bar, and ⌘↩ compiling;
  - a foreign Origin or Host is refused with 403.
- The embed pages work in Chrome:
  - open, format, `getText`, per-file undo across file switches, and host keys posting `command:compile.run`;
  - the PDF page loads the PDF and search works.

## In progress: the macOS app (`apps/macos`), written but never compiled

- **Project:** `project.yml` is the XcodeGen source, and the generated `TeXLocal.xcodeproj` is committed.
  - The pre-build script runs `cargo build -p texlocal-ffi`.
  - A post-compile script runs `npm run build` and copies the embed files into `Resources/web`.
  - The app links `-ltexlocal_ffi -liconv`, from `target/debug` or `target/release` depending on configuration.
  - The bundle ID is `com.texlocal.mac`. There is no sandbox and signing is ad hoc.
- **Sources** (`apps/macos/TeXLocal/`):
  - `Core.swift`: FFI actor.
  - `Models.swift`
  - `AppModel.swift`, `ProjectModel.swift`: state, commands, autosave and compile.
  - `Commands.swift`: the menu, whose IDs and accelerators come from `web/src/workspace.js commandDefs`.
  - `EditorBridge.swift`: WKWebView with a `texlocal-app:` scheme handler serving the bundled `web/`.
  - `HomeView`, `WorkspaceView`, `SidebarView`, `PDFPane`, `LogsView`, `SettingsView`
  - `SyncTeXGeometry.swift`: converts between SyncTeX's top-left origin and PDFKit's bottom-left origin.
  - `Outline.swift`
- **Tests:** `TeXLocalTests/`. The test scheme sets `TEXLOCAL_DATA=/tmp/texlocal-xctest`.

**Next step:** on a Mac with Xcode 27, run `cd apps/macos && xcodebuild -scheme TeXLocal -destination 'platform=macOS' test`, then fix compile errors. Swift 6 strict concurrency is the most likely source. After that, run the app by hand and check:

- editor load
- autosave
- compile
- the PDF reload keeps the page
- forward and inverse SyncTeX
- drag-and-drop import
- quit with unsaved edits

A cloud or Linux session cannot build this. Use a macOS CI runner or a Mac.

## Remaining plan

1. **macOS app:** reach a green build, then parity with every command in `commandDefs`. Things not yet done: word count, breadcrumb, the Windows-style PDF find UX, and the full settings list from `web/src/settings.js` (UI scale, floating panels, PDF paper).
2. **Windows app:** `apps/windows`, WinUI 3 in C#, unpackaged.
   - `Core.cs` with `[LibraryImport("texlocal_ffi")]` and `System.Text.Json`.
   - `NavigationView`, `TreeView`, `CommandBar`, Mica, `ContentDialog`.
   - WebView2 panes for `web/embed/editor.html` and `pdf.html`, using `SetVirtualHostNameToFolderMapping`. The PDF page's CSP expects the project build folder at `https://project.texlocal`.
   - It can only be built and verified on `windows-latest` CI or on Windows.
3. **CI:** add an `xcodebuild test` job on `macos-latest` and a `dotnet build` job on `windows-latest`. The core job already covers the ffi and server crates.
4. **Retire Tauri:** delete `src-tauri`, the Tauri path in `bridge.js` and `@tauri-apps/cli`, and replace `tauri-action` in `ci.yml` and `release.yml`.

## Gotchas

- On the owner's Mac, `static.crates.io` is blocked by network policy, while GitHub works. Before adding a Rust dependency, check `~/.cargo/registry/cache`, or pin a dependency-free crate to its GitHub tag. That is why the server doesn't use axum.
- `CLAUDE.md` was deleted by the owner on purpose. That deletion is left unstaged and is not part of these commits.
- XcodeGen 2.46 is not installed system-wide. Download it from GitHub releases and regenerate after editing `project.yml`.
- The Tauri app's behaviour must not regress while it still ships. Run `npm run app` to check.
