# Handoff: native apps and browser version

Status as of 2026-09-26, on `main` (all earlier branches are merged and deleted).

**Last session (2026-09-26, afternoon): everything is committed on `main`.** In order: the macOS polish and cleanup (`cd671bb`, `97ed2cb`); server hardening (`65f2077`); macOS crash hardening, preview-state fixes, Find Next / Find Previous and split shares (`486843b`); the web source bar, location row and docked outline (`89bf1f2`); a deflation of the Rust and web code (`6dcb95f`); the macOS 27 refresh with built-in controls and one sizing system (`3b2becc`); palette symbols wrapped in `$…$` outside math and host line colours (`e3fb56a`); then the Swift deflation. `/Applications/TeXLocal.app` is a Release build of that tree.

All checks pass: Debug build with no Swift warnings, 30 XCTests, `cargo fmt`, clippy `-D warnings`, `cargo test --workspace`, and `npm test` (52). The Windows changes (Find Next / Find Previous in `MenuCommand`, the menus and `Commands.cs`) were checked by reading only: dotnet isn't installed on the Mac, so CI's Windows build is their first compile.

Crashes (18 reports, 25–26 Sep): 15 were one update-constraints loop that `d08f82b` (AppKit splits) fixed, and the editor view no longer adds constraints mid-layout; the startup-alert crash was already fixed; one was a debugger's leftover breakpoint. **Still open: an AppKit assertion leaving full screen** (`-[_NSFullScreenMenuBarCompanionController _relinquishTitlebar]`, 26 Sep 11:03, a window restored into full screen at launch). Not reproduced in many tries; if it recurs, break on `__assert_rtn` under lldb (developer mode is now on, so lldb attaches without a prompt).

Next:
- The Windows app, which the owner is picking up from `main`.
- The on-screen checks that need TeXLocal frontmost (below).

## Goal

TeXLocal is moving from a single Tauri web UI to three clients over one Rust core:

- **macOS app:** SwiftUI (macOS 27 design), in `apps/macos`. It runs on macOS 26 and later: 26 has Liquid Glass, so the look is the same there, and nothing uses a 27-only API (the compiler flags one at the 26.0 target).
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
  - Those checks and the cookie run on the request head, before any body is read (`http::serve`'s pre-body check); a refusal is followed by a lingering close so the client still reads the 401/403. A head must arrive within 10 s, Content-Length is strict (duplicates and signs get 400), and writes time out after 60 s.
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
- **The source bar matches the Mac's** (`web/src/sourcebar.js`): the same groups and order, folding into ⋯ from the end, a location row under it, and a symbol palette whose symbols are wrapped in `$…$` outside math (`insertSymbol`, `mathModeAt` in `web/src/editor.js`). Files sit over a docked File Outline (a listbox) with a resizable divider (`outlineHeight` pref); the outline follows the top visible line.

## Done and verified

| Commit | Contents |
|---|---|
| `e409056` | Core service refactor; Tauri commands become thin wrappers |
| `d6b1b26` | FFI crate |
| `68939af` | Browser bridge and menu bar |
| `9ae3bc5` | Browser server |
| `45cfe04` | Embed pages |
| `4a5a6cf` | macOS app, first draft |

- `cargo fmt`, clippy and `cargo test --workspace` are clean, and `npm test` passes (52 tests).
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
  - The app's deployment target is macOS 26.0 (`project.yml` and the pbxproj), which the runner meets, so CI builds exactly what ships. The Rust cache key names the target: cargo doesn't rebuild when `MACOSX_DEPLOYMENT_TARGET` changes, so after changing it locally run `cargo clean` once, or the linker warns that objects were built for a newer macOS.
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
  - Sidebar (`SidebarView.swift`, Overleaf's layout): Files on top (no add button: a + pull-down in the toolbar over the sidebar was dropped, 2026-09-26, since Apple's sidebars don't pop menus out of a toolbar button and it crowded the toolbar's leading edge; adding is the File menu and the list's own menu on its empty space, as Finder's; double-click or Return on a folder opens or closes it, as Xcode's navigator does, through the list's `primaryAction`, so the tree is `DisclosureGroup`s over an `expanded` set rather than an `OutlineGroup`), over a docked File Outline, split by a draggable `NSSplitView` divider (`SplitController`, autosave "OutlineSplit"). They are separate native `.sidebar` lists. The files keep the one selection (the open file); project search sits at the top and its results replace the files in a list of their own, and the outline hides meanwhile (and for files that aren't `.tex`).
    - The outline (restored 2026-09-26 after the one-list sidebar of `36e8c93` was rejected, then changed as the owner asked): its own `List` in the sidebar's Small rows (`.environment(\.sidebarRowSize, .small)`, the kit's 24 pt, 11 pt text), a size under the files' Medium 32 pt, so a table of contents is denser than the file list with native rows only. The headings nest with native disclosure triangles (`DisclosureGroup`s over `Outline.tree`, the list's own indent); the outermost triangles line up with the files' and the titles start where the file icons do. Folds are remembered in `OutlineFolded` by `Outline.foldKeys` (file, level, title and which of its namesakes it is, so a fold survives headings added above it), and the current section's enclosing sections open by themselves, so the current heading always shows.
    - Headings take no part in any selection, so no row draws a capsule: the current section is in the accent colour and semibold, and the list scrolls the least that keeps it in view. It follows whichever moved last, the caret or the top visible line (`ProjectModel.topLine`, sent by the editor as `scroll` messages), as Overleaf's outline highlights where you are (2026-09-26: following the top line alone, a document that fit the pane never highlighted anything). The location row's section follows the caret, as Xcode's jump bar does. Clicking a heading scrolls it to the top of the source (`open(path, line:, atTop: true, focus: false)`), leaving focus where it was. VoiceOver reads each heading as its own button with its kind ("Subsection"); the list gives the depth. Only `OutlineList` reads `topLine`, and `HeadingRow` is equatable, so scrolling the source re-renders the outline's changed rows, not the files.
    - "File Outline" is the outline list's own sidebar section (`Section(isExpanded:)`), so its header is the system's, in the same font as Files, with the system's chevron (shown under the pointer, as in every Apple sidebar; the owner chose it over the hand-built always-visible caret, 2026-09-26). The chevron and View › Hide / Show File Outline fold it. Folded (`OutlineCollapsed`), the pane slides down to the header, docked at the foot of the sidebar, and the files take the room; unfolded, it slides back up to the height it had (`SplitPane.collapsed`: the pane is fixed at that size and its divider doesn't drag; the unfolded height is kept in `OutlineSplit Unfolded 1`). The rows ride with the slide, as a drawer's contents do: the section empties once the slide down is over and fills before the slide up (`expanded` lags `collapsed`), since the section's own collapse moved its rows up into the header while the pane moved down. Folded, the pane is the status bar's height (`NavigatorView.outlineHeaderHeight`, the secondary rows'), so the divider over it continues the status bar's top hairline in one line across the window, and the list's 4 pt top padding centres the header in it.
  - Detail: the source beside the PDF, a build panel below (Issues | Build Log, the log an `NSTextView`), a status bar, and a trailing inspector on edge-to-edge system glass. The status bar is text, as Finder's is (HIG, Windows: a little information about the window's contents): the build's status, the save state, the line, the counts and the engine. The build's status is the one control, a SwiftUI `Toggle` (`.button` style, in the bar's accessory style) that shows and hides the build panel, opening on Issues; its bezel stays on while the panel shows, as the kit's borderless buttons ('on = bezel') are. The separate panel icon at the trailing edge is gone (2026-09-26): it did the same, and its hover shape (35×18, against the status item's 21 pt) sat unaligned in the window's corner. View › Show Build Panel stays.
  - The window toolbar holds a back button (Close Project, as the web's and Windows' title bars have), the window's title (the file, the project as subtitle, with its proxy icon), then the PDF and inspector toggles sharing one piece, as related buttons do. Nothing there acts on the PDF alone: Share in the window toolbar read as sharing the project (the owner, 2026-09-26), so it is the PDF bar's. What acts on a pane sits over it, in the in-pane accessory bars under the toolbar (restored 2026-09-26: `36e8c93` had moved every action into a customizable window toolbar, and the owner rejected it).
  - Over the source: undo and redo, Section Level, bold | italic, inline math | display math | symbols, links / references / citations, figure | table, lists, and a ⋯ menu for the rest (`SourceBar`). Under that, the location row: project › folders › file › section (the file and section menus are accessory-bar buttons, so they highlight under the pointer as Xcode's jump bar does); the find bar, while shown, under that.
  - Over the PDF: Compile (prominent; Stop with a spinner while building), Share, zoom (− | the scale, a menu | +). Under it, the page row (below); under that, while shown, Find in PDF, a bar as the source's find bar is (field, previous / next, count, Done).
  - **Design rules (cleanup pass, 2026-09-26):**
    - Liquid Glass wherever it applies (the owner's direction, 2026-09-26): the window toolbar, the sidebar column, the inspector (edge-to-edge glass beside the content, as WWDC25 310 describes inspectors), popovers, menus, sheets and alerts. Never on content: the editor, the PDF pages, the log, list rows, the empty states' buttons (`.borderedProminent`, content). The pane bars (over the source, over the PDF, the build panel's header), the location and page rows, both find bars and the status bar stay flat bars stacked above their content on one opaque `BarMetrics.background` (`windowBackgroundColor`), so they read as one chrome block with the toolbar: they don't float over anything. Glass inside those bars was tried and rejected (2026-09-26): a `ControlGroup` always draws its own fill, so glass over it doubled up; hand-built glass segments were inconsistent beside the flat controls, and interactive glass flickered after a press. The only native glass group for zoom is the window toolbar, and the owner chose to keep zoom in the PDF bar.
    - The inspector: its `SplitPane` has `glass: true`, so `SplitController` puts the hosting view inside an `NSGlassEffectView` (corner radius 0, the view as its `contentView`, never a sibling behind it); its content is a `Grid` in a `ScrollView`, as Xcode's inspectors are: bold section titles (Project, Document, Build) over hairlines, trailing-aligned secondary labels beside their values, the Main File and Engine pop-ups at their own width, nothing drawn behind so the glass shows. `NSSplitViewItem(inspectorWithViewController:)` and SwiftUI's `.inspector` stay out (see the layout rules); full screen, resizes to the minimum and toggling the pane were checked with the glass in.
    - The PDF's page and preview state are quiet text in a secondary row under its bar (`PageRow`: the Out of Date / Last Successful Build button leading, "Page 3 of 12" trailing, the PDF's page rather than LaTeX's printed number, which front matter and roman numbers make differ; a hairline between each pane's action bar and its secondary row), as Preview shows the page, so the source's and the PDF's rows and hairlines line up. Paging is the keyboard's and the scroll's. The earlier floating glass page capsule was dropped as too big for what it said.
    - Nothing floats over the pages any more (2026-09-26): Find in PDF was a hand-built glass capsule over them, and became a stacked bar like the source's, so both panes find the same way and no hand-made glass is left. It doesn't hide the build panel (`requestPDF`).
    - One set of metrics, from the kit, in `PaneBars.swift`: `BarMetrics` (one size, the standard one: bar = regular controls + 8 pt above and below, 40 pt, 8 pt side insets, 4 pt within a group, 8 pt between groups, 16 pt separators; secondary rows 28 pt) and `Typography` (the text role → system text style map: `.body` content, `sectionTitle` = `.title3` semibold for section and sheet titles, `secondary` = `.subheadline` with `.small` controls, SF Mono at the same size for the log). No literal point sizes except the editor's user-set size.
    - Bars: `PaneBar` (one row of a pane's actions: over the source, over the PDF, the build panel's header), `PaneBarRows` (the source find bar's two rows), `SecondaryBar` (the location row and the status bar: one text style and control size for both).
    - Sheets, not alerts, ask for values (`DialogSheet` in `PaneBars.swift`: a `sectionTitle` title and optional `secondary` message over a grouped form on the sheet's own background (its scroll background hidden: in dark it differed, a seam under the title), Cancel and the default action at the foot, `.controlSize(.regular)` set inside since macOS 27 resets it in sheets, 400 pt wide as the kit's dialogs): New File / New Folder (name, preselected "untitled.tex" / "untitled folder", and a Where pop-up of the project's folders, the open file's first), Go to Line (its placeholder gives the file's range), New Project (name "Untitled" so Create is ready, and the template). `AppModel.prompt` picks the sheet.
    - Renames are in place, as Finder's: the context menu's Rename (no ellipsis) turns the row's name into a field; Return or clicking away renames, Escape doesn't. In the sidebar the field edits the name only (the folder stays). In the start window's table the name is its own cell view (`ProjectNameCell`) reading the rename through bindings, because the table redraws a cell only when its row's value changes. The field takes focus 150 ms after the menu closes; focused at once, the list or table took focus straight back and the field closed.
    - Alerts are `AppAlert` (a short title of what couldn't be done, "Couldn’t Rename “x”", "Unsaved Changes Were Lost", with the error as the message), never a whole sentence in the title. Moving a file or project to the Trash still confirms (the Trash gives it back, but the first delete also brings macOS's Automation prompt), with a plain, not destructive, button: the person chose it (HIG, Alerts).
    - The open file is watched (`FileWatcher` in `ProjectModel.swift`: a `DispatchSource` on the file, re-opened after a rename or delete, as editors save by renaming a new file over the old). A change from elsewhere with nothing unsaved reloads the editor at the same top line, marks the preview out of date and, with auto-compile, builds; with unsaved edits it asks ("“main.tex” Changed on Disk": Keep Editing, or Revert, destructive-styled as it discards the edits), and the autosave holds off until answered, so the other app's change isn't written over while asking. This app's own saves are told apart by comparing with the text last read or written.
    - Values are bordered system controls with their own indicators, actions are flat accessory-bar buttons. Section Level is a `Picker(.menu)` (checks the current level, names itself to VoiceOver); the PDF's scale is the middle segment of the zoom control group, a menu holding Fit Width / Fit Height and an inline `Picker` of presets, the current one checked; Actual Size is in the View menu and PDFKit's own context menu (the scale was tried in the page row and dropped: the owner wants − | % | + together). The accessory-bar pull-down draws no indicator, so no value menu uses it. A menu of actions (⋯, +) is an icon-only pull-down.
    - The PDF and inspector toggles are plain buttons whose title and help say what they will do, as the sidebar's toggle and Xcode's inspector button: as `Toggle`s the toolbar drew their on state as solid accent discs, the loudest controls in the window.
    - Both find bars are native pieces in one layout (`SourceFindBar`, Edit › Find and Replace…, ⌘F in the text; `PDFPane.findBar`, Edit › Find › Find in PDF…): an `NSSearchField` (`SearchField`, as SwiftUI has search fields only as `.searchable` in the toolbar or sidebar) with the source's find options (Match Case, Whole Words, Regular Expression) in its magnifier menu, as Xcode's and Safari's are; previous / next (`FindSteps`), the match count (`FindCount`, left out when there isn't room) and Done, a bordered push button. The source's replace row is a SwiftUI text field, then Replace and Replace All, which fold into Replace's menu (`Menu` with `primaryAction`) in a narrow pane. The text field is a rounded rectangle beside the search field's capsule: every native text field is on macOS 26 (TextEdit's capsule replace field is private to `NSTextFinder`), and the owner chose the native field over a search field with its magnifier removed (2026-09-26). No `ViewThatFits` holds a field: one used to, which made a new `NSSearchField` whenever the bar refolded and lost focus mid-word, so the fields were drawn over placeholders (`placingFields`); that machinery is gone. ⌘F and Edit › Find › Find and Replace… put the caret in the Find field with its text selected (`FocusingSearchField` takes focus once it is in its window, on the next turn, after the key or menu item that asked). CodeMirror still searches: the embed's `setHostFind(true)` swaps its search panel for an empty stand-in whose opening and closing post `findOpen` / `findClosed`, and the page posts `findMatches` as the selection moves. Other hosts (Windows) keep CodeMirror's panel.
    - The embed matches the chrome when the host sends `host` colours in `setAppearance` (text background, secondary label, find highlight, selected content): all of it scoped under `:root[data-host]` in `web/embed/editor.html`, so the browser version and Windows are unchanged. The gutter is Xcode's (numbers 2 px smaller in SF Mono), completions and the math preview are menu-like (12 px corners, 24 px rows, no kind icons, the system selection colour).
    - Vocabulary: the bottom panel is the "Build Panel" everywhere (View menu, status bar); durations come from `CompileResult.durationText` ("1.2 s"); short status strings are title case.
    - Semantic colours only. The embed takes the system accent and selection colours from the host (`setAppearance`); Windows and the browser keep their defaults.
    - Only APIs in the macOS 26 SDK, since CI builds with 26.5.
  - The bars under the toolbar use AppKit's accessory-bar style (`.accessoryBar`, set once on `PaneBar`), as Finder's and Mail's in-window bars do: flat buttons that highlight on hover, with `ToolSeparator` lines between groups. Hand-made glass was dropped there: merged interactive glass (`glassEffectUnion`) glitched icons on hover, and pills read too heavy for bars stacked above content.
  - The source bar follows Overleaf's toolbar:
    - undo | redo, then a section-level menu for the caret's line (`setHeading`);
    - bold | italic, then inline math | display math | a symbol palette (a popover, `symbolGroups`);
    - link | reference | citation, figure | table, and bulleted | numbered;
    - a trailing ⋯ menu for the rest.
    Narrow panes fold groups into ⋯ from the end.
  - The editor operations are in `web/src/editor.js`, used by the embed page: `setHeading`, `insertText`, `insertSymbol` (wraps in `$…$` outside math), `inline` (a `pre$0post` wrap in the line) and `displayMath`.
  - Edit › Find › Find Next / Find Previous (⌘G, ⇧⌘G) step whichever find field has focus: the PDF's, the build log's, or the editor's (`findAgain` in `Commands.swift`).
  - PDF bar: Compile at the leading edge (prominent; while building, a bordered Stop in its place with the system spinner as its icon; nothing follows it on that side, so the swap moves nothing), then at the trailing edge Share, then zoom (− | 77% | +). Share and zoom are AppKit's `NSSegmentedControl` (`SegmentedControl` in `PaneBars.swift`), for what SwiftUI's `ControlGroup` can't do and Apple's apps do: the scale segment keeps its widest label's width ("000%", in monospaced digits), centred with no menu arrow, so − and + don't move as the scale changes (with a `ControlGroup` the arrow pulled the % off centre, and padding it with figure spaces did too); and Share opens the system's `NSSharingServicePicker` from its own segment, one size with zoom's. Each segment is set to the width AppKit gives it alone (a one-segment control's intrinsic width), so the control is their sum and a segment's menu opens under it. Share sits before zoom, not at the bar's edge, where its picker had no room in a full-screen window. Tried and dropped (2026-09-26): Share as a bordered button beside zoom or Compile, a one-item control group, `ShareLink` in a group (does nothing), the window toolbar (read as sharing the project), a split Compile | ⌄ (can't be prominent or hold a spinner). No download button: File › Save PDF As… (⇧⌘S) is the Mac's.
  - Settings › General › Toolbar Size is gone: the pane bars have one size, the standard 40 pt (the Large size looked wrong), and its `paneBarSize` preference is removed at launch. The secondary rows and status bar are 28 pt. The status bar leaves out the save state while a build runs (it said "Compiling…" twice) and, in a narrow window, drops whole items rather than truncating them (`ViewThatFits`): the engine first (the inspector and the Compile menu show it), then the word and line counts, then the save state. Show / Hide Word Count is in the status bar's context menu and the View menu, as Pages has it, not in Settings (`AppModel.showWordCount`, the same `showWordCount` preference).
  - Settings: each tab is a grouped form at its content's height, 500 pt wide as the kit's form window, so the window resizes per tab. Font Size is the system `Stepper(value:in:format:)`, whose editable value and arrows a grouped form lines up itself.
  - The build panel is at most 40% of the editors' height (`SplitPane.maxFraction`), so a small window keeps the source and PDF. The build's summary shows only in the status bar. Issues are a selectable list (double-click or Return opens the line); a failed build with no parsed error says so and offers the Build Log. Accessory-bar buttons measure 22 pt, 2 pt under the kit's 24, so those bars have 9 pt insets; the bar-fit test allows 8 to 9.
  - The PDF pane's empty states have one action each, `.borderedProminent`: Compile, Get MacTeX (a button that opens the page, as the start window's is), or Show Build Panel after a build that made no PDF (hidden while the panel shows); the Issues tab's Compile and Show Build Log are prominent too. With no build yet, the status bar, the inspector's Last Build and the Issues tab share one phrase (`ProjectModel.noBuildTitle`): "Not Built Since Opening" over a PDF built before the project was opened (this run of the app or an earlier one), else "Not Compiled". The inspector's Last Build shortens it to "None Yet" / "None" so it stays beside its label at 960 pt ("None Since Opening" wrapped under it). A failed build reads "Build Failed · 1 Error" with one symbol. Issue rows show `file:line`, the main file's when the log names none, as double-click opens; the parser (`logparse.rs`) no longer gives a "!" error the next error's `l.<n>`, nor TeX's closing "==> Fatal error occurred" the stopping error's line, so neither shows a place; that summary is left out after the error it follows (one mistake is one error) and kept only when it is the log's only error. After any failed run the core deletes latexmk's `build/<main>.fdb_latexmk` (`finish` in `compile.rs`): after a fatal error in a project with a bibliography its record held the truncated .aux, bibtex failed on it, and every later build stopped at "gave an error in previous invocation" (0 errors, no PDF) even with the source fixed and `-g`. The Warnings filter shows only when there are warnings; Copy Log uses the HIG's Copy symbol, `document.on.document`. The zoom menu checks Fit Width / Fit Height while fitting (`PDFController.fit`).
  - The sidebar opens files and sections without focusing the editor (`ProjectModel.open(…, focus: false)`), so the arrow keys stay in the list; search hits, issues, Go to Line and SyncTeX still focus it.
  - Format menu: Bold, Italic; then Section Level, Inline Math, Display Math, Symbols, Reference; then the blocks ("Aligned Equations" is the web's "Align (multi-line math)"); then Comment Selection. Settings › TeX Distribution names the distribution from the folder latexmk runs from, links followed ("TeX Live 2026", "MiKTeX"), else latexmk's version. The Section Level pop-up is the system's, sized by AppKit to its longest level; with "Subsubsection" its chevron sits close to the text, as AppKit draws it.
  - Menus: Edit › Spelling and Grammar (the stateless items only; the While Typing toggles need an AppKit-validated menu item to show their checkmarks), "Comment Selection", and Help › TeXLocal on GitHub. The app icon is a flat PNG set from `assets/TeXLocal.png`; a layered Icon Composer `.icon` is the macOS 26+ ideal.
  - A library folder that can't be opened shows an alert and quits. The alert is posted on the next main-queue turn: `Core.shared` is first made during SwiftUI's first scene update, where a modal alert aborted the app.
  - The start window: template cards, then recent projects as a two-line list, as Xcode's and Keynote's welcome windows have them (`ProjectRow`: the name in `.headline` over the main file and when it changed, newest first; double-click or Return opens, the context menu opens, renames in place, shows in Finder and trashes). Open (the toolbar's folder button, sharing a glass piece with New Project, and File › Open…, ⌘O, Mac only) makes a project from a folder, a .tex file or a .zip anywhere on disk: `AppModel.importProject` creates a blank project under a free name ("Name 2"…), copies the visible contents in (a zip through `ditto`, its one top folder unwrapped; hidden entries such as `.git` skipped), drops the template's main.tex when TeX came in, and sets the main file (the chosen .tex, else main.tex, else the first with `\documentclass`). The original stays where it is. Each card is the system's `GroupBox` in a plain button (a hand-made card style with hover fills was dropped, 2026-09-26); the page drawing is white paper, dimmed to 88% in dark mode, drawn in the light appearance's semantic fills with the accent for the slide's header. The toolbar's search is the system's `.searchable(placement: .toolbar)`, at the width macOS gives it. Project search results in the sidebar are a selectable list: choosing a hit opens it, as Xcode's find navigator does.
  - Editor current line and selection matches use the host's `current-line` (quaternary system fill) and `selection-match` colours; in dark mode other find matches take the host text colour so they stay readable.
  - Splits keep each pane's share across window resizes (`splitView(_:resizeSubviewsWithOldSize:)`), so a small window no longer leaves the PDF at its minimum afterwards.
  - "Preview Out of Date" is save-counted: it clears after the lost-edits alert when nothing was saved since the last good build, and stays set when a save lands during a build.
- **Layout rules learnt the hard way:**
  - The window has one minimum size (960 × 600, the whole window) whatever it shows. SwiftUI's content minimum leaves out the 52 pt toolbar, so the content's is 548 (`WindowMetrics` in `TeXLocalApp.swift`); a 600 pt content minimum made the smallest window 652 pt tall. Changing it as a project opened crashed AppKit ("more Update Constraints in Window passes than there are views").
  - Every split is AppKit's `NSSplitView` (`SplitController.swift`; the bar components are in `PaneBars.swift`, the source's bars in `SourceBars.swift`): source | PDF, the editors over the panel, and the editors beside the inspector. Each pane is an `NSHostingView` made once (its views observe the models), with `sizingOptions = []` so SwiftUI's sizes stay out of Auto Layout; the delegate enforces minimums and maximums. A hidden pane is removed from the split, since AppKit kept room for a merely hidden one, and comes back at its previous size. Divider positions are autosaved. Showing, hiding and folding a pane slide its divider over 0.25 s, eased (`Coordinator.slide`, a timer driving `setPosition`; the limits stand aside while it moves), at once off screen or with Reduce Motion; a pane sliding shut stays in the split until closed, and showing it again mid-slide turns it back. A pane sliding open or shut goes from and to nothing, under its minimum (the limits stand aside for the instant placing too, or it jumped to its minimum first), and its content is laid out at its open size throughout and clipped by the pane (`PaneClip`), so it slides in and out whole, as the system's inspectors do, rather than rewrapping at every width.
  - SwiftUI's split views don't work in this window (2026-09-26). `.inspector` crashed on window resize with the same loop. `HSplitView` and `VSplitView` laid the PDF out under the inspector, and a pane shown after launch opened at zero size. `NSSplitViewController` blurred the pane bars with the toolbar's scroll-edge effect.
  - Menu clicks through System Events do update the window in the background. An earlier "frozen window" came from pane views built from values rather than views that observe the models.
  - Bars are stacked above their content, not attached with `safeAreaBar`: they are opaque, so content under them was only hidden.
  - The 26.5 SDK is at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` on the owner's Mac: `xcrun swiftc -typecheck -swift-version 6 -sdk <it> -target arm64-apple-macos26.0 -I crates/texlocal-ffi/include apps/macos/TeXLocal/*.swift` (without `-swift-version 6` it fails on `Outline.swift`'s regex literal) checks a change against it.
  - A divider's position is where the pane before it ends; the pane after starts a divider's thickness later, so `SplitController`'s drag limits subtract it (they were 1 pt off, which a folded pane showed).
  - Separators are stock `Divider()`s placed as siblings in a `VStack`. An overlaid `Divider()` takes its parent's layout context, so inside an `HStack` it turns vertical.
  - PDFKit re-anchors page one's top to the view on every resize while fitting the width, so the gap above page one is a scroll-view content inset.
- **Parity and review fixes:** every command in `commandDefs`, and the settings with a native meaning. Saves run one at a time; quit waits for a save in flight; compiles queue; a WebContent crash recovers the editor; overlapping file opens can no longer save one file's text into another; undo and redo always reach CodeMirror's history.
- **Tests:** 34 XCTests, including the outline tree and its fold keys surviving renumbering, the bar's standard 40 pt and a group fitting it, that a find bar is a bar's height, that the file watcher tells a change written in place and one saved by renaming over the file (and keeps watching after), a folded split pane keeping its header's height and unfolding to its height, the build panel keeping within its largest share (the split tests put the split in a window and size it once it has its delegate, as the app does: macOS 26's `setPosition` doesn't first lay out panes just added, as 27's does, and CI runs on 26), the source find count, the duration text, and the Build Panel and spelling menu items. The test scheme sets `TEXLOCAL_DATA=/tmp/texlocal-xctest`, and its pre-action copies `web/src/workspace.js` there for the command-table test: the tests run inside TeXLocal.app, which would otherwise need Documents access, and macOS asks again after every re-signing build, blocking the read.
- **PDF links:** PDFKit draws hyperref's coloured link boxes, which pdf.js (browser, Windows) leaves out, so `hideLinkBorders` zeroes each link's border on load. The links still work.
- **Checked by hand on a Mac (2026-09-26), against a scratch `TEXLOCAL_DATA`:**
  - click-and-slide from Bold to Italic applied only Italic (with the hand-built groups since replaced by `ControlGroup`);
  - undo and redo move exactly one step, from the pane bar and from the Edit menu;
  - dark paper inverts the preview;
  - SyncTeX forward (highlights the line) and Go to Source Position;
  - killing the editor's WebContent recovers the editor. With an unsaved edit it shows one lost-edits alert, and the file is untouched;
  - quitting straight after an edit saves the edit first and leaves no `latexmk`;
  - a copied `TeXLocal.app`, with the build moved away, opens and compiles a project.
- **Also checked on screen (2026-09-26, afternoon):** the outline following the scroll, the symbol palette, sidebar glass and selection, the accent in the editor, the Files list's Delete key and focus, the find field's keys and ⌘G / ⇧⌘G, inverse SyncTeX with real double-clicks (the earlier wrong line came from injected clicks carrying a modifier flag), the lost-edits alert clearing the out-of-date label, full screen in and out, and quitting mid-compile.
- **Also checked on screen (2026-09-26, late, light and dark):** a 960 × 600 window (both windows; sidebar, inspector and build panel shown or hidden), ⌘F and Edit › Find › Find and Replace… focusing the Find field with fast typing kept in it at 960 pt, Find in PDF typing, the page / freshness / find capsules over white paper in a dark window, a build with an undefined macro in a project with a bibliography reading 1 error and the fixed source then building a PDF, the New File sheet in dark (one background), Settings › General, the Format menu's order.
- **Also checked on screen (2026-09-26, night, light and dark, 960 × 600 and larger):** the inspector's glass, the floating page and find capsules (narrow and wide), New File / Go to Line / New Project sheets (a file made through the sheet), in-place rename in the sidebar and the projects table (a file and a project renamed on disk; Escape cancels), a file changed on disk reloading and building, and the conflict alert keeping the other app's text on disk until Revert, the start window's cards and search, Settings at 500 pt, the symbol palette's large cells, full screen in and out and resizing with the inspector on glass.
- **Also checked on screen (2026-09-26, after restoring the in-pane bars, light and dark, 960 × 600 and 1480 pt wide):** the source and PDF bars (all source groups shown when wide, folded into ⋯ at 960), the toolbar's two toggles as separate glass, the outline's Small rows and disclosure triangles, folding a heading (remembered) and its reopening when the current section moves into it, the current-section tint following wheel-scrolling, clicking a heading, dragging the Files | File Outline divider (remembered), folding the outline from the pinned header's chevron and from the View menu, the header staying in view while the headings scroll under it and unfolding to the same height, and the folded header's hairline meeting the status bar's at Small, Medium and Large sidebar sizes.
- **Seen, not fixed:** once, an automatic build was reported failed with a log cut short mid-run while the PDF was written; the next build succeeded (not reproduced).
- **Still to check by hand on a Mac, with TeXLocal frontmost:** rename with undo history, drag-and-drop import, the first delete's Automation prompt (confirming a Move to Trash), the zoom menu's and find options' checkmarks, focus rings, Compile's accent tint, Issues selection with Return, and accessory-bar hover.
- **Driving the app without taking focus:** Accessibility actions work while TeXLocal is in the background: AXPress on the pane-bar buttons, menu items through System Events, and alert buttons. Synthetic key and mouse events posted to its process are dropped unless it is the active app. Setting AX text in the CodeMirror editor is ignored.
- **Claude's access on the owner's Mac (2026-09-26):** Screen Recording, Accessibility, Automation (System Events, Finder), App Management and developer mode (lldb attaches without a prompt) are all granted. When the screen locks, `screencapture` returns black frames; the owner runs `caffeinate -dimsu -t 21600` before leaving. When injecting CGEvents, clear the modifier flags or CodeMirror reads clicks as right-clicks. Before killing a WebContent process, check it belongs to TeXLocal.
- **Looking at the app without Accessibility or Screen Recording:** launch a Debug build directly (`TEXLOCAL_DATA=<scratch> …/TeXLocal.app/Contents/MacOS/TeXLocal -openProject <id>`; preferences can be overridden with launch arguments such as `-pdfPaper dark`), attach `lldb --batch`, and in an Objective-C expression draw the largest visible window's theme frame with `cacheDisplayInRect:toBitmapImageRep:` into a PNG. Cast every message send (`(NSArray *)[(NSApplication *)[NSApplication sharedApplication] windows]`). This shows layout and sizes, but not glass, vibrancy, list selection or PDFKit pages.

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
  - Find Next / Find Previous (Ctrl+G, Ctrl+Shift+G) are in `MenuCommand`, the Edit menu and `Commands.cs`, unbuilt so far; F3 / Shift+F3 still work inside the editor page. Showing F3 in the menu would need a Windows-only shortcut in the table and its test.
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

## Rust cleanup (2026-09-26, `97ed2cb`)

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
3. **The full-screen assertion** (above), if it recurs.
4. **Small follow-ups:** in the web version, `contextMenu` / `menuUnder` in `web/src/dom.js` place menus with unscaled rects, so under Interface Size ≠ 100% they may land offset (`popoverUnder` already converts); the web outline has no per-section folding; the server has no cap on concurrent connections (local only, so low value); a light One Dark variant for Syntax Colors. A later run (2026-09-26, night) had `a_timed_out_compile_keeps_the_output_it_wrote` (`crates/texlocal-core/tests/compile_stub.rs:128`) fail once; three reruns passed.
5. **Retire Tauri** once both apps are verified by hand. Delete `src-tauri`, the Tauri path in `bridge.js` and `@tauri-apps/cli`, and replace `tauri-action` in `ci.yml` and `release.yml` with release builds of the two apps.

## Gotchas

- An unfinished Word-style safe save (write a temporary file, then replace) is kept, uncommitted, at `.claude/wip/safesave.rs`. It is not wired in.

- On the owner's Mac, `static.crates.io` is blocked by network policy, while GitHub works. Before adding a Rust dependency, check `~/.cargo/registry/cache`, or pin a dependency-free crate to its GitHub tag. That is why the server doesn't use axum.
- `CLAUDE.md` is deleted; the owner's global `AGENTS.md` replaces it.
- XcodeGen 2.46 is not installed system-wide. Download it from GitHub releases and regenerate after editing `project.yml`.
- The Tauri app's behaviour must not regress while it still ships. Run `npm run app` to check.
