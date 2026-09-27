# Handoff: TeXLocal

## Status (2026-09-27)

- `main` is ahead of `origin/main` (`abe9b20`, CI green on both workflows) by the whole final polish pass, unpushed. CI has built none of it yet.
- PR #11 (`claude/windows-parity`: WebView2 browser-process recovery, a trimmed SDK, an Inno Setup installer) stays open for the owner to review on the Windows PC. It no longer merges cleanly: this pass also changed `Outline.cs`, `Dialogs.cs`, `LogsView.xaml.cs`, `ProjectModel.cs`, `SettingsView.xaml.cs` and `WorkspaceView.xaml(.cs)`, so it needs `main` merged in and resolved.
- Last full check on `main`: `cargo fmt --check`, clippy `-D warnings`, `cargo test --workspace`, `npm test` (81), Debug and Release builds with no Swift warnings, 33 XCTests.

## Goal

One Rust core under three clients; Linux is deferred.

- **macOS app** (`apps/macos`): SwiftUI, macOS 27 design, deployment target macOS 26.0 (26 has Liquid Glass too; only 26-SDK APIs, since CI builds with 26.5).
- **Windows app** (`apps/windows`): WinUI 3 in C#, Windows 11 Fluent 2.
- **Browser version** (`web/`, served by `crates/texlocal-server`): local only, never on the network.
- **Tauri** (`src-tauri`) still ships until both native apps reach parity, then gets deleted.

Chrome is native per platform. Two surfaces stay web: the editor is CodeMirror everywhere (`web/embed/editor.html`; on the Mac in SwiftUI's `WebView`/`WebPage`, on Windows in WebView2), and the PDF is PDFKit on the Mac and pdf.js elsewhere (`web/embed/pdf.html` on Windows). WinUI has no code editor, and Windows' PDF API renders images only.

## Architecture

- **`Service::call(cmd, json)`** (`crates/texlocal-core/src/service.rs`) is the one JSON command table every host forwards to: projects, settings, files, `validate_uploads`, `compile`, `stop_compile`, SyncTeX, `scan_symbols`, `analyze`, `status`, `set_tex_dir`, `list_dirs`. Nothing that takes raw bytes or a host-chosen absolute path is in it, because the browser server exposes it; `set_tex_dir` / `list_dirs` are the documented exception (the folder only goes first on latexmk's PATH).
- **FFI** (`crates/texlocal-ffi`, header and module map in `include/`): `tl_open`, `tl_call` (JSON in and out, blocking: call it off the main thread; the Mac blocks a GCD thread, not Swift's cooperative pool), `tl_free`, `tl_close`. Native-only commands: `pdf_path`, `raw_path`, `project_root`, `export_zip`, `import_files`, `import_project`, `kill_all`.
- **Hosts:**
  - the Mac (`Core.swift`) and Windows (`Core.cs`, `[LibraryImport]`) link the FFI;
  - the browser server (`crates/texlocal-server`, `npm run serve`) calls `Service` directly; `web/src/bridge.js` `httpBridge()` is its client, and `commands.js` draws an in-page menu bar only where there's no native one;
  - Tauri's commands collapse onto one `call` command, except `upload_file`, `compile`, `export_project`, `save_pdf_as` and its window commands;
  - `serve.rs` answers `__pdf` / `__raw` (ranges, MIME, the sandbox CSP) for the server and Tauri.
- **`analyze`** (`analyze.rs`): outline headings (depth 0 `\part` to 5 `\paragraph`), words and lines, a port of the web's `analyzeDoc` (`web/src/state.js`), which stays the source of truth. The Mac and Windows call the core; the web keeps its JS. `crates/texlocal-core/tests/fixtures/analyze.json` is checked by both `cargo test` and `test/analyze.test.js`; take a new case's expected value from the JS.
- **`import_project`** (`import.rs`, FFI only): a folder, a `.zip` (one top folder unwrapped) or a `.tex` becomes a new project ("Name 2" when taken). Visible files only, the source's top-level `build/` skipped, the main file is the chosen `.tex`, else `main.tex`, else the first with `\documentclass`; a failed import removes the half-made project. `import_files` (drops) reports clashes (below).
- **Atomic saves** (`atomic.rs`), for file saves, `.texlocal.json` and `.texlocal-app.json`: a hidden temporary file beside the target, given the old file's mode before any text, synced, renamed over it. A symlinked file is written through to its target; a read-only file is refused; on Windows the old file steps aside when a plain rename is refused.
- **Embed protocol:** the host calls `window.texlocal`; the page posts `ready`, `changed`, `cursor`, `scroll` (top visible line), `command`, and with `setHostFind(true)` (Mac only) `findOpen` / `findClosed` / `findMatches`. `setHostKeys` hands menu chords back to the host; `setAppearance` takes `host` colours (Mac only, scoped to `:root[data-host]`). Insert blocks are named by id (`block`); their LaTeX lives only in `BLOCK_TEMPLATES` (`web/src/latex-data.js`), and `test/blocks.test.js` checks every host's ids against it.

## Build, test, run

- **Web and core:** `npm install`, `npm test`, `npm run build`; `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`. `npm run serve` starts the browser version and prints its URL with `?token=`; `npm run app` runs Tauri.
- **macOS:** `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug -derivedDataPath <dd> build` (then `test`). The pre-build script runs `cargo build -p texlocal-ffi`; a post-compile script runs `npm run build` and copies the editor embed into `Resources/web`. The app links `target/{debug,release}/libtexlocal_ffi.a` by path (`-ltexlocal_ffi` would pick the dylib beside it). Bundle id `com.texlocal.mac`, no sandbox, ad hoc signing. The test scheme sets `TEXLOCAL_DATA=/tmp/texlocal-xctest` and copies `web/src/workspace.js` there for the command-table test.
- **Against CI's SDK:** `xcrun swiftc -typecheck -swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos26.0 -I crates/texlocal-ffi/include apps/macos/TeXLocal/*.swift`.
- **XcodeGen** isn't installed: `project.yml` and the committed `TeXLocal.xcodeproj` are kept in step by hand. To regenerate, download XcodeGen 2.46 into a scratch folder and generate with `--project <scratch>` first to diff.
- **Windows:** `npm run build`, `cargo build -p texlocal-ffi` (`--release` for Release), then `dotnet build apps/windows/TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64` and `dotnet test apps/windows/TeXLocal.Tests/TeXLocal.Tests.csproj`. Install on main: `dotnet publish … -c Release -p:Platform=x64 -r win-x64 -o %LOCALAPPDATA%\Programs\TeXLocal` plus a Start-menu shortcut (PR #11 adds an installer).
- **CI:** `ci.yml` (web tests and bundle, version check, Rust core on Linux, Tauri bundles on macOS and Windows), `macos-app.yml` (`macos-26`, newest Xcode, fails if the core is loaded as a dylib, runs the XCTests; the Rust cache key names the deployment target, so after changing it locally run `cargo clean` once), `windows-app.yml` (.NET 10, warnings as errors, xUnit), `release.yml` (on `v*` tags; `scripts/check-version.mjs` checks package.json, Cargo.toml, tauri.conf.json and the Mac's `MARKETING_VERSION`).

### Driving the Mac Debug build for on-screen checks

- Copy a scratch library and point the app at it: `open -g -n --env TEXLOCAL_DATA=<copy> <dd>/Build/Products/Debug/TeXLocal.app --args -openProject <id>` (`-openProject` and preference overrides such as `-pdfPaper dark` land in the argument domain for that run only). Never touch `/Applications/TeXLocal.app`.
- The Debug build shares `com.texlocal.mac` with the installed app: `defaults export com.texlocal.mac <backup>` first, then `defaults import` afterwards and delete test-only keys (`NSQuitAlwaysKeepsWindows`, `recentProjects`). Its saved window state is shared too.
- Capture with `screencapture -x -o -l<window id>`. Press content controls through Accessibility by their exact title only. **Never press menu-bar items that way**: a substring match once pressed the Apple menu's System Settings…. Send no keystrokes. An app-menu item can be sent from lldb: `[NSApp sendAction:[item action] to:[item target] from:item]`.
- Background events: AXPress, alert buttons and System Events menu clicks work in the background; synthetic key and mouse events are dropped unless the app is active (clear modifier flags, or CodeMirror reads clicks as right-clicks). A never-active window doesn't paint CodeMirror's measure pass, and hover shows only when the app is frontmost. A locked screen gives black captures.

## macOS app

**Files** (`apps/macos/TeXLocal`): `TeXLocalApp` (scene, root, reopening, Open With, window minimum), `AppModel` (library, Open Recent, imports, alerts, window corners), `ProjectModel` (the open project: files, saves, builds, `FileWatcher`, `SavedWorkspace`, `ImportClash`), `Core`, `Models`, `Commands` (`MenuCommand`, `macAccel`, menus), `WorkspaceView` (columns, toolbar, sheets, inspector), `EditorView` (panes, `FilePreview`, `StatusBar`), `EditorBridge` (the `WebPage` and its messages), `SourceBars` (source bar, location row, find bar), `LaTeX` (templates and symbols), `PDFPane`, `LogsView` (build panel), `SidebarView` (Files over File Outline), `Outline` (tree and fold keys over the core's `analyze`), `HomeView` (start window), `SettingsView`, `PaneBars` (metrics and bar pieces), `SplitController`, `SyncTeXGeometry`.

**Design system** (the owner's settled rules; each value's source is noted in its comment):
- **Native only.** No hand-built look-alikes; sizes, spacing and styles from Apple (SwiftUI defaults, HIG, the macOS 27 UI kit at `~/Downloads/Apple macOS 27 UI Kit.sketch`, Apple's apps). Semantic colours only.
- **`BarMetrics`** (`PaneBars.swift`), from the kit's toolbars:
  - pane bars: regular controls (24 pt) with 8 pt above and below, 40 pt (the kit's Unified Compact toolbar); 8 pt side insets;
  - secondary rows (location row, status bar): small controls (20 pt) with 4 pt above and below, 28 pt;
  - a group's controls abut; `groupSpacing` 8 pt between groups (the kit's toolbar group gap); separators 16 pt tall (the kit's 1 × 16);
  - `itemSpacing` 12 pt between the status bar's text items; search fields 100–180 pt.
- **`Typography`:** `.body` (13 pt) content, `sectionTitle` `.title3` semibold, `groupTitle` `.headline`, `secondary` `.subheadline` (11 pt) with `.small` controls, SF Mono for the log. No literal point sizes except the editor's user-set size.
- **Hairlines:** every `ToolSeparator` has `groupSpacing` (8 pt) either side, the source bar's too: SwiftUI's own spacing beside a `Divider` on macOS, which is the kit's group gap. Beside a flat icon the visible gap looks wider than beside a bezel, since the button's padding counts.
- **Bars** stack above their content on one opaque `BarMetrics.background` (`windowBackgroundColor`), so they read as one chrome block with the toolbar, which draws no line under it in the workspace or the start window (`toolbarBackgroundVisibility(.hidden)`, as Xcode has none over its jump bar); pane bars use `.accessoryBar` buttons (Finder's and Mail's in-window bars). Over the source: undo | redo, Section Level, bold | italic, math | display math | symbols, reference | citation | link, figure | table, lists, then ⋯ (narrow panes fold groups in from the end); under it the location row, as Xcode's jump bar: every crumb an accessory-bar menu (the project and each folder list what they hold, folders as submenus; the file lists its siblings; the section the file's sections), then the find bar. Over the PDF: Compile (prominent; a bordered Stop with the spinner while building), then Share and zoom; under it the page row, then Find in PDF.
- **Status bar:** as Xcode's editor status bar. A borderless build-status button (shows or hides the Issues; no on state, since the panel toggle is the one place the open state shows), a hairline, the save state, line, counts and engine, a hairline, and the borderless build-panel toggle; both toggles tint while on. Spacing is measured from Xcode 27 (`BarMetrics.status*`): 10 pt between text and a line, 7 pt between a line and a toggle, 15 pt from a window corner the bar meets (the sidebar or inspector hidden, read from `containerCornerInsets` at the root into `AppModel.windowCorners`, since views inside the split's panes see none), 8 pt beside a pane. A narrow window drops whole items: engine, then counts, then save state.
- **Build panel:** under the source and PDF, not the inspector (as Xcode's debug area); 30% by default, at most 40%, at least 80 pt. Issues | Build Log tabs, the Warnings filter only when there are warnings, Copy Log, a filter field. Before any build Issues shows just No Issues, as after a clean build. Issue rows give `file:line` only when the core placed them.
- **`SegmentedControl` exception:** zoom (− | scale | +) and Share are AppKit's `NSSegmentedControl`, because a SwiftUI `ControlGroup` can't keep the scale segment at its widest label's width ("000%", centred, no menu arrow) or open `NSSharingServicePicker` from a segment.
- **Glass only where the system draws it:** the window toolbar, the sidebar, the inspector (SwiftUI `.glassEffect` over the pane, up under the toolbar to the window's top as Pages' inspector: the inspector split ignores the top safe area and only the glass does, so the panes' content stays below the toolbar), popovers, menus, sheets, alerts. Never on content or in the stacked bars.
- **SwiftUI first**, modern APIs over old (the editor is SwiftUI's `WebView` over a `WebPage`; file panels are `fileImporter` / `fileExporter`). AppKit stays only where SwiftUI can't do the job:
  - `SplitController`: every split is an `NSSplitView` (SwiftUI's `.inspector` crashed on resize, `HSplitView` / `VSplitView` mislaid panes and opened late ones at zero, `NSSplitViewController` blurred the bars with the toolbar's scroll-edge effect);
  - `SegmentedControl` (above);
  - `SearchField`: SwiftUI's search field goes only in a toolbar or sidebar;
  - PDFKit's `PDFView`, and the build log's `NSTextView` (megabyte logs and the system find bar).
- **Other rules:** sheets ask for values (`DialogSheet`, 400 pt); alerts are short titles with the error as message (`AppAlert`); renames are in place; Settings is a grouped form 500 pt wide; one window minimum of 960 × 600 whatever it shows.

**Behaviour the owner settled:**
- **Shortcuts:** the shared `commandDefs` chords, with Apple's on the Mac (`MenuCommand.macAccel`): ⌃⌘S Show / Hide Sidebar, ⌘0 Actual Size, ⌘9 Fit Width, ⌥⌘9 Fit Height; ⌘F Find… in the pane with the keyboard (source or PDF), ⌥⌘F Find and Replace… (caret in Replace), Find in PDF… with no chord. The editor hands these back to the menu. Windows and the web keep theirs.
- **Previews:** images (SVG too) and PDF figures show in the source pane, fitted and never enlarged, a PDF on white; any other non-text file shows No Preview with Open in Default App. Both keep the formatting bar's place, empty, so the source's rows and lines stay level with the PDF's, and keep the location row.
- **Reopen:** the project open at quit reopens with its file, line, build panel and PDF page (`SavedWorkspace` in `@SceneStorage`; pane visibility and sizes are in the defaults and the splits' autosave), following System Settings' Close windows when quitting.
- **Drag to open:** a folder, `.zip` or `.tex` dropped on the start window, or handed over by Open With or the Dock icon (`CFBundleDocumentTypes` at Alternate rank, `org.tug.tex` imported), opens as File › Open… does. Files dropped on a sidebar row import into that folder, or the file's folder.
- **File › Open Recent:** the last ten projects by id (kept across renames), with Clear Menu.

## Behaviour decisions (every host)

- **Compile past errors**, as Overleaf does (latexmk `-f`): `pdf` is set whenever this run wrote one, even when `ok` is false, and hosts show it with the issues. `errors` is never empty on a failure that wasn't stopped (fallbacks: `.blg` errors, latexmk's summary, the exit code). A per-project **Stop on First Error** (`stopOnFirstError`, default off) passes `-halt-on-error` instead. After a failed run the core deletes `build/<main>.fdb_latexmk`, so a bibliography project recovers.
- **`stop_compile {id}`** stops that project's build only; stopped, superseded and quit-killed builds return `stopped: true` (Build Stopped, no notification). `kill_all` is for quit.
- **Name clashes** are per file: the core names each taken path with a free Keep Both name; hosts ask once per import (Replace / Keep Both / Stop, Replace the default); Replace moves the old file to the Trash (Recycle Bin), and a folder holding the main file is never replaced. An upload never overwrites without `replace`.
- **`build` is reserved** (any case) at a project's top for creates, renames, saves and uploads: it holds the compiled PDF.
- **latexmkrc trust:** a project's own rc runs only when that project has shell escape on (`-norc` otherwise); the user's own rc is named again with `-r`. System-wide rc files stay off for untrusted projects. Imports leave hidden files, `.latexmkrc` included, behind.

## Browser server security (security-critical: shell escape makes compiling running code)

- Binds `127.0.0.1` only. The startup token travels in an `X-TeXLocal-Token` header on every `/api/` and `/__` request, never a cookie (cookies ignore ports). The page keeps `?token=` in sessionStorage (per origin, so per port) and drops it from the address bar (`takeToken` in `web/src/bridge.js`); pdf.js gets it through `httpHeaders`, previews and downloads come through fetch as blob URLs. The UI's own files hold no data and load without it; a new tab needs the printed URL.
- Any Host but the bound address is refused (DNS rebinding), and non-GET requests from a foreign Origin. These and the token are checked on the request head before any body is read; heads must arrive within 10 s, Content-Length is strict, writes time out after 60 s.
- Every response: `frame-ancestors 'none'` (unless it has its own CSP), `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy: no-referrer`. Project files are served with a sandbox CSP.
- Its HTTP/1.1 layer (`src/http.rs`) is on `httparse`, pinned to a GitHub tag, since crates.io is blocked on the owner's Mac.

## Windows (`apps/windows`)

- `TeXLocal.Core` (no WinUI: FFI calls off the UI thread, models, `MenuCommand`, `Outline.AnalyzeAsync` over the core plus `Chain`, `Preferences` under `%LOCALAPPDATA%\TeXLocal`), `TeXLocal.Tests` (xUnit: FFI round trip, the shortcut table against `workspace.js`, logic), `TeXLocal` (WinUI 3, unpackaged x64, .NET 10 and Windows App SDK 2.5.1 bundled).
- WebView2 serves `web\` at `app.texlocal` and the PDF at `project.texlocal`. Window shortcuts stand down while a page has focus; the pages post chords back.
- Deliberate deviations: hand-written settings cards and divider (no Community Toolkit); Interface Size scales only the editor page; the tree uses a copy of WinUI's TreeViewItem template (`CompactTree.xaml`, 16 px expander), to re-copy when the SDK is upgraded. Labels are sentence case ("Build stopped").
- Wired to this pass by reading only (no dotnet on the Mac): Stop, a build's PDF past errors, the Stop on first error card, the clash `ContentDialog`, the core's `analyze`, Insert blocks by id. **CI must confirm:**
  - `TeXLocal.Core` and `TeXLocal` build with warnings as errors: the private nested records `Outline.Heading` / `Outline.Analysis` deserialising through System.Text.Json; `shown[..^1]` on a `List<string>` in `Dialogs.cs`; the `CompileLabel` `x:Name` in `WorkspaceView.xaml`; `AutomationProperties.SetName` on the Compile `SplitButton`; the `StopOnFirstErrorSwitch` toggle and `OnStopOnFirstErrorToggled`; the `ImportResult` / `ImportClash` records; `CompileResult` with its non-optional `Stopped`; `ProjectSettings` with four parameters (the `with { MainFile = … }` use).
  - `TeXLocal.Tests` build and pass: `[CollectionDefinition("Rust core", DisableParallelization = true)] public sealed class RustCoreCollection;` under the xunit analyzers; `OutlineTests` through the core; the `CoreTests` clash assertions (`ImportClash("notes.tex", "notes 2.tex")`, `"in/notes 2.tex"`); `stop_compile` returning false.
  - The macOS workflow on the 26.5 SDK, and `ci.yml` (including `test/blocks.test.js`, which reads the Swift and C# sources, and the analyze fixtures on both sides).

## Known issues and checks by hand

- **Full-screen assertion:** once, `-[_NSFullScreenMenuBarCompanionController _relinquishTitlebar]` asserted leaving full screen (a window restored into full screen at launch). Not reproduced; if it recurs, break on `__assert_rtn` under lldb.
- **Pane slides stay on a Timer:** stepping them on `NSView.displayLink` was reverted, because the display link stops while the screen is locked and a pane shown then stayed stuck mid-slide with its limits off.
- **Not yet seen on screen (Mac, app frontmost):** drag and drop onto the start window and onto sidebar rows (and the row's drop highlight), Finder's Open With and Dock drops (a Debug build may need LaunchServices registration), the clash alert, the ⌥⌘F caret landing in Replace, Settings' Not Found state and spinner (TeX is installed here), the nested section menu, rename with undo history, the first Trash's Automation prompt, focus rings, and File › Close enabled with the window key.
- **Web Stop:** Stop pressed after the save but before `compile` reaches the core stops nothing.
- **Exported ZIPs** (Mac) stay in the temporary folder until the OS clears it.
- **Flakes seen once:** `a_timed_out_compile_keeps_the_output_it_wrote` (`crates/texlocal-core/tests/compile_stub.rs`); an automatic build reported failed with a truncated log while the PDF was written.
- **Windows, by hand:** every shortcut fires once from the editor, PDF and sidebar; the title bar (buttons, dragging, forced themes, high contrast, Snap Layouts); access keys; dividers by keyboard; Settings applying and persisting; text size scaling the editor; dark paper; the status bar; drops onto a folder and onto a taken name; Compile ⇄ Stop and Stop ending a long build; typing during a save, a main-file change keeping the old PDF, closing mid-compile; killing the editor's renderer; undo in the editor and its find field; Narrator; SyncTeX both ways; no `latexmk` left after quitting mid-compile; file pickers; the compile notification; nothing written beside the exe.

## Next

- Push `main`, confirm CI, then bring PR #11 up to date with it and merge after the owner's review on Windows.
- Deferred features: error hints; editor gutter markers; parsing `.blg` into Issues beyond errors; Clean and Compile; TinyTeX / package install; missing-package explanations; `!TEX` magic comments; more templates; version history; duplicate project; dropping an image to insert a figure; project import UI on Windows and the web; possibly a user-customizable toolbar (`toolbar(id:)` with `ToolbarItem(id:)`, which would bring back View › Customize Toolbar…).
- Web follow-ups are in `docs/web.md`.
- **Retire Tauri** once both apps are verified by hand: delete `src-tauri` (its 12 unbundled Store/appx icons go with it), the Tauri path in `web/src/bridge.js`, `@tauri-apps/cli`, the tauri.conf entry in `scripts/check-version.mjs`, and `tauri-action` in `ci.yml` and `release.yml` (replace with release builds of the two apps).

## Gotchas

- `static.crates.io` is blocked on the owner's Mac (GitHub works). Before adding a Rust dependency check `~/.cargo/registry/cache`, or pin a dependency-free crate to its GitHub tag.
- Tauri must not regress while it ships: `npm run app`.
- PDFKit re-anchors page one's top on every resize while fitting the width, so the gap above page one is a scroll-view content inset; a rebuilt PDF keeps its scroll offset (`currentDestination` and `go(to:)` disagree by that inset). PDFKit keeps its place against the scroll view's edge, not under that inset, and loses a little on every step of a sliding pane, so `SyncPDFView` pins the spot at the top of what shows through a resize, and a new document scrolls to page one's top with the gap. PDFKit draws hyperref's link boxes, so `hideLinkBorders` zeroes them.
- Core Image filters work in linear light: dark paper's `colorInvert` turns sRGB 0.84 grey into 0.61, not 0.16. Pick the input for the grey wanted out.
- macOS 26's `setPosition` doesn't lay out panes just added, as 27's does, so split tests put the split in a window and size it once it has its delegate (CI runs on 26).
