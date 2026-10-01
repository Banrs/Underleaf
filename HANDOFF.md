# Handoff: TeXLocal

## Status (2026-10-01)

- **Branch `claude/native-finish`:** a PR on `main` after PR #16 (Codex's `codex/finish-native-workflows`, merged). It keeps #16's fixes, rewrites the features it kept at their smallest, and drops the rest.
- Last full check: TBD
- **Windows is a work in progress** (the owner's). It may change in the same commit as the core or the web; CI is its only check, since it can't be built here.
- **The native frontend study:** https://claude.ai/artifact/7ZvNe2J8nNvsG8vBxTxVVm.
- **Owner decisions are marked "(owner's decision)".** Don't reverse one without asking.

## Layout

One Rust core (`crates/`) under three clients:
- **macOS** (`apps/macos`): AppKit and SwiftUI, deployment target macOS 27.0; Swift 6 with Approachable Concurrency and main-actor default isolation, as Xcode 27's App template sets them. CI builds with Xcode 27 on the `xcode-27` runner image (macOS 27.0).
- **Windows** (`apps/windows`): WinUI 3, C#.
- **Browser** (`web/`, served by `crates/texlocal-server`): local only.
- **Tauri** (`src-tauri`) still ships until both native apps are verified.

The editor is native on the Mac (TextKit 2 over `crates/texlocal-syntax`; the Mac embeds no web page but the maths preview) and CodeMirror elsewhere (the browser; Windows embeds `web/embed/editor.html`). The PDF is PDFKit on the Mac and pdf.js elsewhere.

## Architecture

- **`Service::call(cmd, json)`** (`crates/texlocal-core/src/service.rs`) is the one JSON command table every host forwards to. The browser server exposes it, so nothing that takes raw bytes or a host-chosen absolute path belongs in it; `set_tex_dir` and `list_dirs` are the exceptions.
- **FFI** (`crates/texlocal-ffi`, header in `include/`): `tl_open`, `tl_call` (blocking: call it off the main thread), `tl_free`, `tl_close`. Native-only commands: `pdf_path`, `raw_path`, `project_root`, `export_zip`, `import_files`, `import_project`, `kill_all`.
- **Hosts:** the Mac (`Core.swift`) and Windows (`Core.cs`) link the FFI; the browser server calls `Service` directly, with `web/src/bridge.js` as its client; Tauri forwards to one `call` command; `serve.rs` serves `__pdf` / `__raw`.
- **`texlocal-syntax`:** the editing logic, pure Rust with no I/O.
  - A `SourceDocument` mirrors the editor's text through its edits and answers in UTF-16 offsets: highlights (CodeMirror's stex mode, token for token), completions with snippet fields, comments, indentation, headings, blocks and maths. The editor owns the text, undo and drawing, and applies the edits it gets back.
  - The ports follow `web/src/editor.js`, regex for regex. `src/catalog.json` (commands, environments, blocks, sectioning) is the one copy; `web/src/latex-data.js` reads it. `tests/fixtures/editing.json` holds both to the same answers (`cargo test`, `test/mathmode.test.js`, `test/editor.test.js`).
  - `texlocal-ffi` exposes it as `tl_source_*`: edits, lines and highlights as plain C, the commands as JSON, which Windows could P/Invoke too. Hand-written: UniFFI generated 2,400 lines for a dozen functions.
- **`analyze`** (`analyze.rs`): outline, words and lines, ported from the web's `analyzeDoc` (`web/src/state.js`), which stays the source of truth. `crates/texlocal-core/tests/fixtures/analyze.json` holds both (`cargo test`, `test/analyze.test.js`).
- **Atomic saves** (`atomic.rs`): a temporary file beside the target, synced, then renamed over it.
- **Embed protocol (Windows):** the host calls `window.texlocal`; the page posts `ready`, `changed`, `cursor`, `scroll` and `command` (a menu chord). Insert blocks are named by id; their LaTeX is the catalog's `blocks`, and `test/blocks.test.js` checks every client's ids.
- **Commands and chords:** accelerators live in `web/src/shortcuts.json`, which the web and the Mac read. `test/protocol.test.js` holds Windows' copies and both apps' palettes and fonts to the web's, and checks the Mac menu has every web command but the web-only ones it lists.

## Build, test, run

- **Web and core:** `npm install`, `npm test`, `npm run build`; `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`. `npm run serve` runs the browser version; `npm run app` runs Tauri.
- **macOS:** `npm ci` first, then `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -derivedDataPath <dd> build` (or `test`).
  - Pre-build runs `cargo build -p texlocal-ffi`, and the app links the static `libtexlocal_ffi.a` by path. Post-compile (`apps/macos/scripts/copy-resources.sh`) copies `shortcuts.json`, JetBrains Mono and KaTeX from `node_modules` into the app's Resources.
  - Bundle id `com.texlocal.mac`.
  - `project.yml` and the committed `.xcodeproj` are kept in step by hand (XcodeGen isn't installed). `TeXLocal/` and `TeXLocalTests/` are synchronized folders: a new file joins its target from disk (`Info.plist` excepted).
- **Mac tests** are Swift Testing (`TeXLocalTests/`). `-only-testing:TeXLocalTests/<Type>` takes a suite's type; a file's name matches none and runs 0 tests. The types, by file:
  - `CommandTests.swift`: `MenuCommandTests`, `MenuStructureTests`, `FindRoutingTests`;
  - `DocumentTests.swift`: `SyncTeXGeometryTests`, `OutlineTests`, `FindTests`, `PDFFitTests`, `PDFFindTests`;
  - `ProjectTests.swift`: `FolderWatcherTests`, `CoreTests`, `ProjectFlowTests`;
  - `BarTests.swift`: `PaneBarLayoutTests`, `FindBarTests`, `RemapPathTests`, `InPlaceRenameTests`;
  - `SourceEditorTests.swift`: `SourceEditorTests`;
  - `WorkspaceLayoutTests.swift`: `WorkspaceLayoutTests` (the split, on screen and unseen).

  The scheme runs one suite at a time (`parallelizable = NO`) in the scratch library `TEXLOCAL_DATA=/tmp/texlocal-xctest`. The test host is the app, with its defaults (`com.texlocal.mac`); the suites put back what they change. Run them under `caffeinate -d -i -u`: the split tests need an awake, unlocked display.
- **Typecheck against CI's SDK:** `xcrun swiftc -typecheck -swift-version 6 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos27.0 -I crates/texlocal-ffi/include apps/macos/TeXLocal/*.swift`.
- **Windows:** `cargo build -p texlocal-ffi`, then `dotnet build apps/windows/TeXLocal/TeXLocal.csproj -c Debug -p:Platform=x64` and `dotnet test apps/windows/TeXLocal.Tests/TeXLocal.Tests.csproj`.
- **CI:** `ci.yml` (web, version check, Rust on Linux, Tauri bundles); `macos-app.yml` (the Mac tests on the `xcode-27` runner: macOS 27.0, in preview, with no `macos-27` label); `windows-app.yml`; `release.yml` (`v*` tags).
- **A Mac Debug build on screen, beside the installed app:**
  - Build it with `PRODUCT_BUNDLE_IDENTIFIER=com.texlocal.mac.check`, so its defaults and window state are its own.
  - Run it with `open -g -n --env TEXLOCAL_DATA=<library copy> <app> --args -openProject <id>` (add `-ApplePersistenceIgnoreState YES` for a clean window).
  - Afterwards run `lsregister -u <app>` (or the Dock and Spotlight can open a stale copy) and `defaults delete com.texlocal.mac.check`.
  - Capture by window id (`screencapture -l`), the process's largest window: it also owns a blank helper window.
  - Match Accessibility elements by exact title within the window: a substring can hit a menu-bar item.

## macOS app (`apps/macos/TeXLocal`)

**Design:** AppKit owns the window, its split and its toolbar; SwiftUI draws every pane and bar inside them. The models (`AppModel`, `ProjectModel`, `PDFController`) drive the AppKit side through `track(_:initial:_:)` (`MainWindow.swift`), over Swift Observation's `Observations`.

**Files** (each opens with a comment on what it holds):
- `TeXLocalApp`: the App (its only scene Settings) and the `AppDelegate`, which owns the window, quits after it closes, and holds Quit until the open file is saved.
- `MainWindow`: `MainWindowController`, the one window: the projects screen (`HomeView`, its SwiftUI toolbar bridged in) until a project opens, then its `WorkspaceController` and toolbar. Restoration, Edit › Find routing, `track`.
- `WorkspaceController`: nested split view controllers, sidebar (files over the File Outline) | source | PDF over the build panel | inspector. Bars are split-item accessories: the sidebar's search, the find bars, the File Outline's header (the files' foot) and the status bar. `ColumnMetrics` holds the sizes; `PaneSize` keeps them in the `PaneSizes` defaults dictionary.
- `WorkspaceToolbar`: one section per column: the sidebar toggle; back, the title, B I and Insert; from an `NSTrackingSeparatorToolbarItem` on the source/PDF divider, zoom, Share and Compile; from `.inspectorTrackingSeparator`, the PDF toggle and `.toggleInspector`, so the columns' toggles keep to the window's edges. Customize Toolbar adds Undo, Redo, Section Level, Math and the templates.
- `SourceEditor` (one `SourceTextView` for a project's files; per-file undo and selection; find, with CodeMirror's semantics; formatting), `SourceTextView`, `SourceDocument` (the core's mirror), `MathPopover`.
- `PaneBars` (bar metrics, `FindBar`, `SearchField`, `FindPassingTextView`, `ItemActions`) and `MenuItems` (shared by the menu bar and the toolbar's `NSHostingMenu`s); `PDFController` holds `SyncPDFView`. The other views are named for what they show.
- `AppModel` (library, recents, imports, alerts; `DefaultsKey`), `ProjectModel` (the open project, saves, builds, watching), `FolderWatcher`, `Core`, `Models`, `LaTeX`, `Commands` (every menu item a `MenuCommand`, acting on `app.commandProject`: the open project while the main window is key).
- Leaf views have `#Preview`s that need no Rust core.

**Behaviour and decisions:**
- **Columns:** the inspector is AppKit's fixed 270 pt, its divider taking no drag. The sidebar opens at the same 270 pt, with the system's limits (144 pt, no maximum).
- **The sidebar keeps two panes, files over the outline** (owner's decision): one sectioned list would scroll the outline away under a long file list. No `QLPreviewView` for file previews (owner's decision): it draws hyperref's link boxes.
- **The status bar and the File Outline header are 36 pt** (`BarMetrics.secondaryBarHeight`), folded or not: Xcode's editor status bar between its hairlines, so the two lines run on as one, and a fold or reveal moves only the split's collapse. The header's title sits at its foot, over the outline's first row, with more room above it than under it, as over Files (owner's decision).
- **Bar lines** are a small view (`Hairline`) in the split's `dividerColor`, 1 pt like the dividers they continue (`NSBox`'s separator is 1 px).
- **The status bar's ends** are constrained to `layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))`: 16 pt from the window's edge at a corner, as Xcode's bottom bars, and 8 pt elsewhere. SwiftUI's `containerCornerInsets` are zero inside an AppKit split item's accessory.
- **The build panel's** tabs both run on under the status bar, whose automatic insets keep the last row clear (the log ignores the bottom safe area, as a `List` does). Its header is 24 pt in both tabs, since Copy Log's bezel is 2 pt taller than Warnings'. An issue's row is its place in the errors then warnings (LaTeX repeats identical warnings), so the selection stays while the filter or Warnings hide others.
- **The PDF's find bar stays open across rebuilds** (the web closes it): each new PDF is searched again, keeping the current match and the place.
- **The creation sheets** (New Project, New File, New Folder) stay open with what was typed when creating fails, the error in their own alert.
- **Files** drag out as the file and move within the tree onto a folder, a file's folder or the Files header (the top level), as in Finder; files from elsewhere are copied in. The Files header scrolls away with the list, as Finder's, Mail's and Notes' group titles do, and is the only top-level drop target.
- **The outline:** native list rows, the current heading the selection. Choosing one (a click, or the arrow keys) scrolls the source to it and leaves the keyboard in the list; a click on the current row goes back to its heading. Return or Escape in a rename gives the keyboard back to the list, as in Finder; a click elsewhere leaves it there.
- **Menus:** File › Rename, Show in Finder, Move to Trash (⌘⌫, without asking, as in Finder; a bare ⌫ does nothing) and Share… (a `ShareLink`) aren't `MenuCommand`s: the web has no ids for them. The first three act on the chosen item of the list with the keyboard, passed to `AppModel.chosenItem` (`offersActions`): a SwiftUI focused value doesn't reach the menus from an AppKit window's hosting views. `MenuCommand.macAccel` holds the Mac's departures from the shared chords; Go to Source Position has none (⌘-click, or the PDF's context menu).

**AppKit that remains, and why:**
- **The window, split and toolbar.** `NavigationSplitView` can't hide its last column, run a panel under two columns, or take split-item accessories; SwiftUI's toolbar has no tracking separators; a SwiftUI scene's window owns its toolbar.
- **The inspector** is AppKit's split item, the one `.inspector` builds on: the modifier needs a SwiftUI split. Its content is SwiftUI.
- **An `NSTextView` (TextKit 2) for the source.** `TextEditor` has no gutter, no viewport hook to colour only what shows, no completion list, and one undo manager, not one per file.
  - The caret, context menu, Services, dictation, text drags, completion list, find indicator and Undo are the system's. Each file has its own undo manager; the core's edits go in as one named step each.
  - Edit › Find's items pass on (`FindPassingTextView`) to `MainWindowController`, which sends them to the pane with the keyboard.
  - Spelling is underlined in the prose only (comments are prose), a kept setting. No substitutions: smart dashes and quotes would rewrite LaTeX.
  - The completion list is the system's, words only (owner's decision: native over custom).
  - Dropped files open. JetBrains Mono is the web's WOFF2, registered with CoreText.
- **The maths preview** (`MathPopover`): the core's `math_at`, typeset by the web's KaTeX in SwiftUI's `WebView` (no clicks or keys) in the system's popover over where the maths starts, while the caret is in it and the text has the keyboard. SwiftUI's margins; never narrower than tall, or a single letter reads as an egg. There's no system maths typesetter.
- **Compile's own view** (`CompileButton`, SwiftUI in an `NSHostingView`): `.prominent`, and while a build runs, Stop with a spinner at the same width on clear glass, which an item's image can't animate. The title is the system font, 12 pt from the ends, as an item's is (medium reads wider and bolder). One view for both states: swapping an item's `view` in the toolbar throws in `NSToolbarItemViewer` on the next layout (27.2).
- **The segmented zoom and Math controls open their menu segment from their action** (`openMenu(of:)`). AppKit opens a segment's menu on a click only in a control with no action, and with none the control can't tell which other segment was clicked (`selectedSegment` is -1 after `mouseDown`), and keyboard and VoiceOver presses send nothing. Segment frames aren't public API. A click opens it on mouse-up; a press and hold opens AppKit's own after 0.26 s.
- **`NSSearchField`** (find bars, sidebar, log filter): SwiftUI's is toolbar or sidebar only. **`PDFView`**: SwiftUI has none. **An `NSTextView` for the build log:** a SwiftUI `Text` lays out megabyte logs whole on every change.
- **The drag pasteboard** (`NSPasteboard(name: .drag)`): a SwiftUI drop session names none of its items before the drop, so the file drops read it to refuse what they can't take.

## Core behaviour (every host)

- **Compiling past errors:** builds run with latexmk `-f`, so a PDF comes back even on failure. The per-project `stopOnFirstError` passes `-halt-on-error` instead.
- **Stopping:** `stop_compile {id}` stops one project's build; `kill_all` is for quit.
- **Import name clashes** are per file: Replace (the old file goes to the Trash or Recycle Bin), Keep Both, or cancel (the Mac's Cancel, Windows' Stop).
- **`build` is reserved** at a project's top level: it holds the compiled PDF.
- **latexmkrc:** a project's own rc runs only with shell escape on (`-norc` otherwise).

## Browser server security (security-critical: shell escape runs code)

- It binds `127.0.0.1` only.
- A startup token goes in an `X-TeXLocal-Token` header on every `/api/` and `/__` request, never in a cookie. The page keeps it in sessionStorage.
- It refuses foreign Hosts (DNS rebinding) and non-GET requests with a foreign Origin, checking both on the request head before reading the body.
- Every response carries `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `nosniff` and `no-referrer`. Project files are served with a sandbox CSP.

## Windows (`apps/windows`)

- **Projects:** `TeXLocal.Core` (FFI, models, preferences, no WinUI), `TeXLocal.Tests` (xUnit) and `TeXLocal` (WinUI 3, unpackaged x64, .NET 10, with .NET and the Windows App SDK bundled).
- **SDK packages:** WinUI, Foundation and InteractiveExperiences only, not the `Microsoft.WindowsAppSDK` metapackage (174 MB published, not 234 MB).
- **Web surfaces:** the editor and PDF pages each run in a WebView2: `web\` at `app.texlocal`, the PDF at `project.texlocal`. A renderer crash reloads the page; a dead browser process gets a new WebView2 in its place (`EmbeddedPage.Replace`). Window shortcuts stand down while a page has focus; the pages post chords back.
- **Layout (Fluent):** the Tall 48 px `TitleBar` over Mica (menus, a centred search box, PDF and Details toggles; `FitCaptionInset` corrects WinUI's caption column above 100% scale); 48 px rows and 32 px detail rows; the sidebar and Details are inline `SplitView` panes; the source and PDF bars are `CommandBar`s that fold into their overflow. Motion is in `Motion.cs`.
- **Behaviour:** Insert blocks go by id (`LatexTemplates.Lists` / `Environments`) with the editor's `block` command. The PDF pane shows Compile, or a spinner and Stop (`stop_compile`); a stopped build reads "Build stopped" and sends no notification. Stop on first error is per project, in Settings. An import onto taken names asks once (Replace, Keep both, Stop). The outline, words and lines come from the core's `analyze`.
- **Deviations:** settings cards and dividers are hand-written, not the Community Toolkit; Interface Size scales only the editor page.
- **Installer:** `apps/windows/installer/TeXLocal.iss` (Inno Setup 6), per user into `%LOCALAPPDATA%\Programs\TeXLocal`; the Windows workflow's "Installer" job builds `TeXLocal-<version>-setup.exe`. By hand, build the core with `--release` first, or a stale `target\release\texlocal_ffi.dll` ships.
- **A Debug build beside the installed one** breaks the Debug build's WebView2 pages (they share `%LOCALAPPDATA%\TeXLocal\WebView2`); run one at a time.
- **The core on Windows:**
  - Project-relative paths the core returns or stores use forward slashes; both separators are accepted on input, SyncTeX included (tested).
  - ZIP export is the `zip` crate (`zipexport.rs`), no `zip` CLI.
  - Every `latexmk` and `synctex` spawn passes `CREATE_NO_WINDOW`, or each flashes a console. A stopped, timed-out or superseded compile kills the tree with `taskkill /PID <pid> /T /F` (POSIX signals the process group).
  - Windows won't rename over a file another program holds open without sharing, so an atomic save moves the old file aside first and puts it back if the move still fails.
  - TeX is searched for after the folder chosen in Settings and the user's `PATH`: `C:\texlive\<year>\bin\windows` and `...\bin\win32`, newest year first; `%LOCALAPPDATA%\Programs\MiKTeX\miktex\bin\x64`; `C:\Program Files\MiKTeX\miktex\bin\x64`.
- **Tauri on Windows** (goes with `src-tauri`): a standard decorated window and an opaque background, as the hidden title bar and vibrancy are macOS-only (`src-tauri/src/window.rs`); `texlocal://` loads from `http://texlocal.localhost`, WebView2's form for custom schemes. `src-tauri/src/menu.rs` translates the `Return` and `Plus` spellings muda doesn't accept, as an unknown key name binds to nothing, silently (a test reads the renderer's accelerators). A pale system accent flips primary-button labels to black (`src-tauri/src/accent.rs`, `onAccent` in `web/src/prefs.js`).
- **Verified by hand** (Windows 11 26340, TeX Live 2026), before the Stop, clash and analyze work: PDF rendering and find, compiling and recompiling, choosing the TeX folder, the title bar's hit-testing, the layout's measurements, pane motion, the source bar and its overflow, the symbol palette and section level, the outline following the editor, a file changed on disk reloading, WebView2 browser-process recovery.
- **Known issues:** a Release build once fail-fasted in `ucrtbase.dll` while idle (it linked a stale core; not seen since). A window once showed a frozen frame while it went on working.
- **Checklist** (the owner's):
  - By hand: Stop, Stop on first error, the import clash dialog and the core-analyzed outline; shortcuts firing once from every pane; the title bar (themes, high contrast, Snap Layouts); access keys; dividers by keyboard; Settings surviving a restart; the unsaved-edits conflict dialog; drops; saving and closing during a compile; SyncTeX both ways; Narrator; no `latexmk` left after quitting; the installer's install and uninstall.
  - Check the path of the text a save writes, as the Mac's `SourceEditor.document` pairs them (`EditorBridge.cs` reads `getText`, which knows no path).
  - Read `web/src/shortcuts.json` rather than keeping `MenuCommand.Accel`'s copy (the protocol test holds the copy to it meanwhile).
  - Check for the bugs the Mac pass fixed: the non-text `flush()` loop, stale state after deleting the open file, the fixed-delay watcher re-arm, a closed project's popovers and sheets carrying over.
  - `EditorBridge.RenameAsync`'s fallback for "pages without rename()" is dead: `web/src/embed/editor.js` always defines `rename`.
  - `LatexTemplates.cs`'s comment names `web/src/latex-data.js` `BLOCK_TEMPLATES`, now the catalog's `blocks` (`crates/texlocal-syntax/src/catalog.json`).
  - Mirror the visible Mac changes if the platforms should match.

## Known issues

- **Full screen:** a `_relinquishTitlebar` assertion was seen once, leaving full screen; the prime suspect is the Home→Workspace toolbar swap. Unchecked repro: in full screen, Quit and Keep Windows, relaunch, Exit Full Screen. The View menu's Enter and Exit Full Screen are clean (27.2).
- **Browser Stop** pressed after the save but before `compile` reaches the core stops nothing.
- **Compile flakes, each seen once:** `a_timed_out_compile_keeps_the_output_it_wrote`; a build reported as failed with a truncated log.
- **Not yet seen on screen:** focus rings with Keyboard navigation on.
- **The toolbar short of room:** a column narrower than its section's tools parts the section line from the divider (the system's layout). The source section needs about 350 pt with the sidebar and 480 pt without. Short of room window-wide, zoom overflows first, then Share; Compile and the toggles last.
- **With the PDF hidden, the toolbar is one joined band**, a line under it even at rest: the PDF's section is empty, and AppKit joins the toolbar while it has one (27.2). Hiding Share, Compile and zoom doesn't part it, nor does pointing the PDF's separator at the inspector's divider (which draws Compile over Share). Removing the separator while the PDF is hidden would rewrite the saved toolbar configuration.
- **The PDF toolbar section's material switches from 12 to 38** after the inspector first shows, with no visible effect at style 5.
- **Window minimums:** the content goes down to 642 × 318 pt, or 642 × 370 pt with the build panel open (27.2). Hiding the PDF doesn't narrow it; the projects screen stops at the same size.
- **The launch log** is the system's: App Intents rejects the ad-hoc signature ("Unable to get teamId", `linkd.autoShortcut`; a team-signed build shouldn't, and this Mac has no signing identity), and PDFKit's text recognition logs `e5rt` errors.
- **`theSideColumnsOpenAtTheirWidths` misses a727502's bug** (the inspector shown at open squeezed the sidebar to 200 pt), which showed only in the real window.
- **Toolbar configurations:** the inspector section's items are immovable defaults, and a configuration saved before they existed could lack them, with no way back. The toolbar saves as "Workspace"; none was saved on the owner's Mac, and the owner accepted the risk (owner's decision).
- **Orphaned defaults:** older builds' per-split size keys stay, unread, beside `PaneSizes`.
- **The source/PDF divider takes AppKit's 5 pt** (2 either side of its line). While the source's overlay scroller shows, its 17 pt track takes presses from 4 pt left of the line (27.2), the system's layout. In the toolbar band the line's place is the tracking separator's item (4 pt either side); whether a drag there moves the split, as in Mail, is unchecked.
- **The source's scroller knob jumps in a long file:** TextKit 2 re-estimates what isn't laid out on each viewport layout, so past a few hundred lines the knob's size and place shift as it scrolls, and a drag maps to a moving estimate. A stock `scrollableTextView()` does the same (27.2); a whole-document `ensureLayout` holds at 1,000 lines, not 3,000; `layoutQueue` changes nothing. At rest the overlay scroller takes no clicks, so a press at the edge selects text; posted hovers don't expand it. TextKit 1 keeps a steady height; staying on TextKit 2 is the owner's decision. Worth a Feedback with the stock prototype.
- **The source re-wraps only as a live divider drag ends** (`widthTracksTextView`, the system's way), so line ends clip during the drag. The owner's to judge.
- **Edit › Find…, Find Next and Find and Replace… are disabled while the source's Replace field has the keyboard:** it's a SwiftUI `TextField`, whose field editor isn't `FindPassingTextView`.
- **`ProjectModel.reveal`'s guard doesn't stop a second reveal** for a heading that can't scroll to the top (in the last screenful).
- **The maths preview's glass shows the source behind the maths,** which, as web text, can't be vibrant as a label is. It's a stock `NSPopover` with SwiftUI's 16 pt margins, concentric with its corners (the web tooltip's 8 × 16 pt put a matrix's brackets against the curve); checked in light and dark.
- **The PDF's knob follows the paper, not the appearance:** zoomed out until it runs over the background, a dark knob on white paper in Dark mode (or the reverse) has less contrast. Fit Width, the default, keeps it over the pages.
- **Biber on macOS 27:** TeX Live 2026's `biber` 2.21 unpacks its arm64 half with `lipo -extract_family`, which Xcode 27's `lipo` lacks ("extracting arm64 binary with lipo failed"), so biblatex with biber gets no bibliography (the build panel shows undefined citations). Replacing it with its arm64 half (`lipo -thin arm64`) works.

## Deferred (not dropped)

- **SwiftUI lays out the PDF pane on each of PDFKit's scroll steps** (about 0.17 ms in Debug, harmless). If a Release profile shows it, host `SyncPDFView` as the PDF item's view.
- **Dark paper's saturated mid-tones differ from the web's** (`green!60!black` medium, not light; orange brown, not peach): it inverts lightness and keeps hue and saturation, as the web's `invert(1) hue-rotate(180deg)` means to. The owner's to compare with Test Contrast.
- **The core as the only source of the default engine and library folder.** The Mac repeats the library rule (`Core.libraryFolder`) where Windows lets the core choose (`tl_open(null)`); it needs a small FFI getter for the path the Mac shows when it can't open it.
- **An empty-space drop on the Files list does nothing:** a `List` hands it to neither `dropDestination` nor `onDrop` (27.2), so the Files header takes the top level.
- **Folding the File Outline of a long document stalls** at the collapse's end (about 200 ms with 300 headings; 27.2): the animated collapse is a live resize, the table drops and re-adds its row views, and SwiftUI re-expands each `DisclosureGroup`. The fix is an `NSOutlineView` (rows still SwiftUI) or no folding: the owner's to weigh.
- **Toolbar:** the zoom group shrinking as the toolbar runs short (owner's decision to defer; to try: `NSToolbarItemGroup`'s segmented constructor with `controlRepresentation = .automatic`, keeping the hairlines). A Feedback on the inspector's section ending half a point inside the window (Gotchas › Split view), shown by a plain AppKit scroll view as the last column before an inspector.
- **The app icon** is a flat PNG set; macOS 27's layered icon (dark, clear, tinted) needs an `AppIcon.icon` from Icon Composer: new artwork, the owner's to make.
- **The native editor:** the web could run `texlocal-syntax` through wasm and drop its copies (the fixtures keep them equal meanwhile). One caret: typing over several selections replaces the first. Quotes aren't paired (LaTeX's are two backticks and two apostrophes). The session (open files, undo, saves) stays in each host until a second native host would share it.
- **Untitled headings:** the core and `analyzeDoc` send `"(untitled)"`, which the Mac (`Analysis.untitledTitle`) and Windows (`Outline.DisplayTitle`, `Rows.Untitled`) string-match. The fix: an empty title (the fixture, `analyze.rs`, `state.js`), each client naming it by its kind; the web shows the title as it comes. Windows' side must change in the same commit.
- **Core and build:**
  - The root `Cargo.toml`'s `[profile.release.build-override] strip = false` is justified by "a macOS 26.0 target", but the Mac app targets 27.0: recheck whether it's still needed.
  - `CoreError.status` (`error.rs`) reaches no UI decision: the browser client uses it only as a fallback message, and Tauri drops it.
- **Windows:** the checklist in the Windows section. **Web:** the Open list in `docs/web.md`.

## Next

- Confirm CI on `claude/native-finish`'s PR.
- The study's next phases: Windows' editor (native, or CodeMirror over the core's logic through wasm), then the session in the core once two native hosts would share it.
- Deferred features: error hints and gutter markers; `.blg` parsing; Clean and Compile; TinyTeX / package install; `!TEX` magic comments; more templates; version history; duplicate project; an image dropped in the editor uploaded into Insert Figure, as Overleaf does; import UI on Windows and the web.
- Retire Tauri once both apps are verified: delete `src-tauri`, the Tauri path in `bridge.js`, `@tauri-apps/cli`, and the Tauri entries in `check-version.mjs`, `ci.yml` and `release.yml`.

## Gotchas

**Window and restoration**
- **`-ApplePersistenceIgnoreState YES` writes the new state to a temporary folder** and leaves the old one, so the next launch without it restores the state from before. Restoration repros need both launches without it.
- **Setting `contentViewController` sizes the window to the new view and zeroes `contentMinSize`.** `MainWindowController.setContent` sizes the view to the window first (an unsized one squeezes the bridged toolbar into conflicting constraints), then sets the minimum again. The projects screen's `NSHostingController` sets it from its SwiftUI content, zero for a list, so `HomeRoot` carries the app's minimum as a frame.
- **`contentMinSize` counts the area under the toolbar**, but the panes' limits hold below it: with the build panel open, the window stops a toolbar's height above the minimum.
- **Ordered front, a titled window shrinks to the screen's visible frame.** The CI runner's screen is about 1024 pt wide, so `WorkspaceLayoutTests` use an `UnclampedWindow`.

**Split view**
- **A pane opens at its view's frame as it's added,** so `WorkspaceController` sets each frame from `PaneSize` or its share.
- **A collapsed pane uncollapses to its frame on 27.2, to its minimum on 27.0.** Show PDF (`setPDFShown`) sets the PDF's frame and minimum to its kept share until it's back. The build panel (`setPanelShown`) uses its frame alone on 27.2 (lowering a raised minimum jumps it) and the minimum on 27.0; it fades, as it rises from under the status bar's glass.
- **Divider detents:** `NSSplitViewController` doesn't implement `splitView(_:constrainSplitPosition:ofSubviewAt:)`, so there's no super to call. Only the sidebar (270 pt) and source/PDF (half) dividers have detents: the others have no size worth stopping at, and a snap would fight fine adjustment.
- **The column line and the toolbar's section line are one only while they track:** a section wider than its column parts them. The column minimums are the content's, not the toolbar's tools.
- **Both columns run on under the toolbar,** which is adaptive, as Mail's: each section paints its own background while it holds its tools, and when one can't (about 370 pt for the PDF's, 350 pt for the source's) they join into one band. Fit Height, the sync point and forward search measure the part that shows (`shownHeight`).
  - A section takes its column's edge effect only from a scroll view whose safe area spans it exactly (27.2); otherwise it's the opaque titlebar material. AppKit ends the last column's section at the inspector's glass divider, half a point inside the window (it adds the overhang only for a sidebar), so the columns get a 0.5 pt trailing safe-area inset (`ColumnMetrics.toolbarInset`) that the panes ignore. The window's minimum is 642 pt for it.
  - A section keeps a scroll view it once took: without the inset, an inspector animation whose frame landed on the edge left the PDF's section see-through until relaunch.
  - Remove the inset if a later macOS adds the overhang, or the section misses by half a point the other way: a view-tree dump of the titlebar shows no `scrollViewTrackingAdapter` on the PDF's section.
  - The source's scroll view runs under the toolbar and the find bar (`ignoresSafeArea`); its automatic content insets take in both.
  - A SwiftUI-only `NavigationSplitView` gets the soft edge effect in every state: its sections take the window background material, not the titlebar's.
- **The PDF column doesn't collapse on a drag,** on purpose: collapsed at the trailing edge, its divider would sit under the window's resize edge.
- **Sidebars fold on a window resize, inspectors don't** (`canCollapseFromWindowResize`). A narrowing window squeezes the sidebar to 144 pt once source and PDF reach their minimums, folds it, and brings it back with room. Tiling (Window › Move & Resize › Left) folds it to fit half the display; `setContentSize` doesn't, so the minimum test hides the sidebar first. Scripted resizes (AppleScript, Return to Previous Size) don't grow a squeezed sidebar back; a drag does.
- **Pane sizes are saved only from a divider drag** (`didResizeSubviews` with `userResize`, macOS 27), never from a window resize, a collapse, a close or a quit.
- **AppKit's fixed inspector divider shows a resize cursor;** `WorkspaceController` gives it no hit area (`splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)`).
- **The inspector item is made before the area,** which opens in the room both side columns leave; sized past the sidebar alone, the area pushes the sidebar to its minimum.
- **The nested split view controllers answer `toggleSidebar:` and `toggleInspector:` before the window's split,** and have neither; `WorkspaceToolbar.toolbarWillAddItem` points the system's toggles at the `WorkspaceController`.
- **The File Outline's header is the files pane's foot accessory,** folded or not, so it never swaps views.
  - The sidebar split's divider runs under it and draws nothing (`QuietSplitView`); its reach moves up onto the header's line, and folded it has none.
  - The header is the system's collapsible sidebar section (`Section(isExpanded:)` in a one-section `.sidebar` list with no rows).
  - The list is the header row's whole 39 pt content, moved down to put the 19 pt row at the foot: any shorter, a drag from the header autoscrolls it, which `scrollDisabled` doesn't stop.
  - A header whose height changes with the fold jumps in the first frame, and SwiftUI animates its title on its own curve.
  - A sidebar `List`'s 10 pt over its first row is inside its table, out of reach of `contentMargins(.scrollContent)` and `safeAreaPadding`. The outline pulls its list up 10 pt and clips it; `contentMargins(.top, 10, for: .scrollIndicators)` puts the scroller's top back.
- **The sidebar's minimum must be at least 140 pt:** below that, hiding the sidebar pushes its toggle into the `>>` overflow, with no button left to show it.

**Toolbar**
- **Toolbar groups on macOS 27:** adjacent plain items share one glass capsule with no line between (73 pt for two); an `NSMenuToolbarItem` breaks the grouping. An `NSToolbarItemGroup` with subitems draws a wider capsule (82 pt) with lines between its parts and sits 3.5 pt from a tracking separator; the segmented constructor (`images:selectionMode:`) draws lines too. A `.prominent` item gets glass of its own, a `.plain` one joins its neighbours'; Stop stays `.prominent` with `backgroundTintColor = .clear`, which looks plain but keeps its glass. `.toggleInspector` keeps its own glass, so the PDF toggle beside it is a separate circle (owner's decision: native, with the divide). Zoom and Math stay segmented around their pull-downs (owner's decision, for zoom).
- **A toolbar item's own view** sits in the item's 36 pt glass, which passes it no clicks: the view must fill it. Customize Toolbar draws it without the style, so its copy (`willBeInsertedIntoToolbar` false) is a title item.
- **Customize Toolbar compresses the default set's views.** The zoom control's palette copy resists compression, or its scale reads "…"; the toolbar's own copy must not, or it holds the window 50 pt wider even from the overflow menu.
- **Items at the same visibility priority overflow together.** Rank the widest lowest.
- **Xcode's bottom bars (27.2):** a corner glyph 16.5 pt from the window's edge; a 1 × 12 pt separator 8.5 pt from either neighbour. The status bar's controls are at least the HIG's 20 × 20 pt (`hitTarget`: a borderless button's hit area is only what it draws).
- **Closing a toolbar popover logs "Invalid attempt to open a new transaction during CA commit"** (27.2). It's AppKit's: a bare SwiftUI app logs it too.

**Swift and SwiftUI**
- **`Core` makes the blocking `tl_call` on a GCD thread,** not in a `@concurrent` function, which would block the cooperative pool.
- **`track` needs `nonisolated` Equatable values,** or a main-actor conformance can't satisfy `Sendable`. It runs after the change, never inside a SwiftUI update, so collapsing a split item there is safe.
- **An `NSMenuItem` subclass can't override its initialisers under default main-actor isolation;** the toolbar's menus are `NSHostingMenu`s instead.
- **Hide an AppKit view to take it out of the key view loop.** A SwiftUI view at zero opacity stays in the loop, and a hidden split-item accessory only folds to no height, its controls still in the loop and VoiceOver; hide its view too.
- **A `Picker` whose selection has no matching tag logs a fault,** nil included: list the current value as a choice until the real ones come.
- **A field that appears while the editor has focus needs `focused = true` in `onAppear`:** `.defaultFocus` leaves focus in the text view, so a rename types into the document. `defaultFocus` is right for sheets, a new focus scope.

**The source's text view**
- **The edited range runs past the change** to the paragraph's end. Snippet fields and stepped-over brackets follow the range `shouldChangeText(inRanges:)` passed (`SourceTextView.changing`), or typing in a field ends its snippet.
- **The system's completion list closes on a typed key** with `NSTextMovement.other` and `isFinal`, so `insertCompletion` takes only Return, Tab or a click, and the list reopens, narrowed, after the key.
- **The selection draws over rendering attributes' backgrounds,** so the current find match is the selection, with the find indicator; the other matches are tinted.
- **A taller line keeps its extra room above the text,** and a positive baseline offset shrinks the line rather than raising the text. `lineStyle` splits the extra between the line and line spacing, which TextKit puts at the top of the next paragraph's fragment, so the current line's fill takes it from there.
- **Spell checking's results count from the start of the range checked** (`textView(_:didCheckTextIn:…)`, 27.2), not the document's.
- **The maths preview's web view** needs `webViewContentBackground(.hidden)` for the material to show through (a `WKWebView` has no public switch; `underPageBackgroundColor` isn't enough) and `focusable(false)`, or it takes the keyboard. Measure it after `document.fonts.ready`, or the maths is cut short. Move the popover by showing it again, whatever `isShown` says: `isShown` stays true while it animates out, and `positioningRect` raises until it shows (27.2).
- **Observe a scroll's reports only as the views need them.** `ProjectModel.topLine` changes on every line and is unobserved; the outline follows `topHeading`. Observed per line, the File Outline re-diffed on every step and scrolling a long file dropped frames.
- **`ATSApplicationFontsPath` doesn't load a WOFF2;** CoreText registers it from a URL.
- **TextKit 2 keeps the scroll offset as the width changes,** though the heights above what's laid out are estimates a new width changes: a divider drag lands a long file hundreds of lines away, in a stock text view too (27.2). `keepingTopLine` keeps the top paragraph on every width change and as a live resize ends, from the viewport as last laid out: asked by point, TextKit answers from its new estimates.
  - The view sizes its own container (`widthTracksTextView`). A container the app sizes confuses a live resize's end, putting a drag's text back at its first line.
- **A jump to a line lays out only that line,** then a second pass puts it exactly once the viewport is laid out there; laying out everything above takes a third of a second in a long file. Only in a window: laid out outside one, it kept the test host from quitting.
- **An outline click chooses the row on mouse-down and taps it on mouse-up,** so `ProjectModel.reveal` does nothing when the caret and the top line are already the heading's; otherwise the find indicator starts again.
- **In a test, a file's undo steps are one group:** `groupsByEvent` closes a group only as the run loop turns. Check one step per opened file.

**PDF**
- **PDFKit is left to itself:** no insets of the app's round its fit-width layout. `loadDocument` hides hyperref's boxes.
- **A rebuild goes back to `SyncPDFView.shownDestination`,** the point under the toolbar and find bar, where `go(to:)` puts a destination. `currentDestination` is the view's top, behind them, so a round trip through it moved the pages down by their height on every build.
- **The pages keep PDFKit's own margins** (set ones scroll the pages on every resize step). They scale with the page, so Fit Height counts them, and PDFView keeps a set scale as it resizes, so `SyncPDFView.onResize` fits the height again.
- **Command-click in the PDF jumps to the source,** as in the Mac's TeX apps; a double-click stays PDFKit's word selection. The web and Windows viewers use a double-click.
- **Dark paper is PDFView's `draw(_:to:)` (`drawPage:toContext:`),** which PDFKit calls per tile on its tile queue: the override is `nonisolated` (a main-actor one crashes) and reads the paper from an `Atomic`. Filters on `documentView` render at one pixel per page point, soft over 50% zoom.
  - PDFKit keeps drawn tiles through `layoutDocumentView`, `annotationsChanged(on:)`, a redisplay and a same-value set; only a new `displayBox` redraws them, so a change of paper sets it there and back.
  - The knob's style is set on the scroll view, which comes with the first document.
- **PDF find is PDFKit's `beginFindString`,** off the main thread (a first query in 392 pages takes 445 ms). Its match and end notifications come on the main queue and are taken there as posted, so in order (two `notifications(named:)` tasks don't keep it); `cancelFindString` posts the end at once, so `PDFController` clears its search before cancelling.
- **SwiftUI sets the PDF view's frame again, unchanged, on each scroll step,** so `SyncPDFView.setFrameSize` acts only on a new size; acting on each pins a document at its start and re-fits Fit Height.

**Files and TeX**
- **One FSEvents stream watches the project folder** (`FolderWatcher`). The open file is checked when it or a folder above it changes; the tree is read again when something comes, goes or moves in a folder it shows. The open file moved or deleted elsewhere closes, or, with unsaved edits, asks Save Again or Close. Compare paths with `realpath`: `resolvingSymlinksInPath` drops /private, which FSEvents keeps.
- **Spawn TeX tools by their full path.** With PATH set for the child, std forks for a bare program name instead of using posix_spawn, and a forked child of the multithreaded app can crash before exec. `program_path` (`compile.rs`) resolves it; `tools_start_by_posix_spawn_never_a_fork` guards it.

**Tests**
- **Recents are filtered, not pruned,** when the library lists without them (`AppModel.recents`): the tests' scratch library would wipe them.
- **Swift Testing's expansion of a failed `#expect` can mislabel nested calls' values.** Put the values in the comment when they matter.
