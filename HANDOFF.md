# Handoff: native apps and browser version

Status as of 2026-09-26, on `main` (all earlier branches are merged and deleted).

**Last session (2026-09-26, afternoon): everything is committed on `main`.** In order: the macOS polish and cleanup (`cd671bb`, `97ed2cb`); server hardening (`65f2077`); macOS crash hardening, preview-state fixes, Find Next / Find Previous and split shares (`486843b`); the web source bar, location row and docked outline (`89bf1f2`); a deflation of the Rust and web code (`6dcb95f`); the macOS 27 refresh with built-in controls and one sizing system (`3b2becc`); palette symbols wrapped in `$…$` outside math and host line colours (`e3fb56a`); then the Swift deflation. `/Applications/TeXLocal.app` is a Release build of that tree.

All checks pass: Debug build with no Swift warnings, 30 XCTests, `cargo fmt`, clippy `-D warnings`, `cargo test --workspace`, and `npm test` (52). The Windows changes (Find Next / Find Previous in `MenuCommand`, the menus and `Commands.cs`) were checked by reading only: dotnet isn't installed on the Mac, so CI's Windows build is their first compile.

Crashes (18 reports, 25–26 Sep): 15 were one update-constraints loop that `d08f82b` (AppKit splits) fixed, and the editor view no longer adds constraints mid-layout; the startup-alert crash was already fixed; one was a debugger's leftover breakpoint. **Still open: an AppKit assertion leaving full screen** (`-[_NSFullScreenMenuBarCompanionController _relinquishTitlebar]`, 26 Sep 11:03, a window restored into full screen at launch). Not reproduced in many tries; if it recurs, break on `__assert_rtn` under lldb (developer mode is now on, so lldb attaches without a prompt).

**Windows session (2026-09-26, evening, on the owner's PC), branch `claude/windows-parity`.** The uncommitted 2026-09 Fluent redesign found in the Windows checkout is committed as `53e4a1e` and merged with `main`; then the parity gaps from issue #10 (Banrs/Underleaf), a native-motion pass and a WinUI deflation, described under the Windows app below. Later that night: the source and PDF bars became `CommandBar`s, WebView2 browser-process recovery, the trimmed Windows App SDK packages, an Inno Setup installer built in CI, and a behaviour-preserving deflation of the Windows code (its .cs and .xaml went from about 8,400 lines at their largest to 7,300). The Windows build (warnings as errors), its 41 xUnit tests and `npm test` (53) pass, and the deflated build was checked on screen.

Next:
- The on-screen checks that need TeXLocal frontmost (below), on both apps.
- Windows: try the installer from CI on the owner's PC (it installs over the hand-published copy).

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
  - Sidebar (`SidebarView.swift`, Overleaf's layout): Files on top, with add in its header, over a docked File Outline, split by a draggable `NSSplitView` divider (`SplitController`, autosave "OutlineSplit"). They are separate native `.sidebar` lists. The files keep the one selection (the open file); project search sits at the top and its results replace the files in a list of their own, and the outline hides meanwhile (and for files that aren't `.tex`).
    - The outline (restored 2026-09-26 after the one-list sidebar of `36e8c93` was rejected, then changed as the owner asked): its own `List` in the sidebar's Small rows (`.environment(\.sidebarRowSize, .small)`, the kit's 24 pt, 11 pt text), a size under the files' Medium 32 pt, so a table of contents is denser than the file list with native rows only. The headings nest with native disclosure triangles (`DisclosureGroup`s over `Outline.tree`, the list's own indent); the outermost triangles line up with the files' and the titles start where the file icons do. Folds are remembered in `OutlineFolded` by `Outline.foldKeys` (file, level, title and which of its namesakes it is, so a fold survives headings added above it), and the current section's enclosing sections open by themselves, so the current heading always shows.
    - Headings take no part in any selection, so no row draws a capsule: the current section (the top visible line, `ProjectModel.topLine`, sent by the editor as `scroll` messages; not the caret) is in the accent colour and semibold, and the list scrolls the least that keeps it in view. On purpose, the location row's section follows the caret instead, as Xcode's jump bar does. Clicking a heading scrolls it to the top of the source (`open(path, line:, atTop: true, focus: false)`), leaving focus where it was. VoiceOver reads each heading as its own button with its kind ("Subsection"); the list gives the depth. Only `OutlineList` reads `topLine`, and `HeadingRow` is equatable, so scrolling the source re-renders the outline's changed rows, not the files.
    - "File Outline" is a header pinned over the outline's list (`OutlineHeader`: the headings scroll under it, it never scrolls away; checked expanded and scrolled at 960 × 600 and wide). The title is in the kit's sidebar-header style (Bold 11, tertiary label colour), lined up with the Files header, and a borderless chevron button sits at the trailing edge, always visible, lined up with the Files header's +. The chevron is the sidebar's disclosure vocabulary, as on the headings and folders: down while open, right while folded (a state, not a direction, so it reads the same docked at the foot of the sidebar). Clicking the title or the chevron folds and opens; the button takes Tab focus with Keyboard Navigation on and Space toggles it; VoiceOver reads "File Outline" with "Expanded" / "Collapsed" (checked through Accessibility). View › Hide / Show File Outline does the same. Folded (`OutlineCollapsed`), the pane shrinks to the header, docked at the foot of the sidebar, and the files take the room; unfolded, it comes back at the height it had (`SplitPane.collapsed`: the pane is fixed at that size and its divider doesn't drag; the unfolded height is kept in `OutlineSplit Unfolded 1`). The header is the status bar's 28 pt (`BarMetrics.secondaryBarHeight`), so folded, the divider over it continues the status bar's top hairline in one line across the window (the same pixel row in captures at Small, Medium and Large sidebar sizes, light and dark).
  - Detail: the source beside the PDF, a build panel below (Issues | Build Log, the log an `NSTextView`), a status bar, and a trailing inspector on edge-to-edge system glass.
  - The window toolbar holds a back button (Close Project, as the web's and Windows' title bars have), the window's title (the file, the project as subtitle, with its proxy icon), and the PDF and inspector toggles, each its own piece of glass (a `ToolbarSpacer(.fixed)` between them: they are two functions). What acts on a pane sits over it, in the in-pane accessory bars under the toolbar (restored 2026-09-26: `36e8c93` had moved every action into a customizable window toolbar, and the owner rejected it).
  - Over the source: undo and redo, Section Level, bold | italic, inline math | display math | symbols, links / references / citations, figure | table, lists, and a ⋯ menu for the rest (`SourceBar`). Under that, the location row: project › folders › file › section; the find bar, while shown, under that.
  - Over the PDF: Compile (prominent; a spinner and Stop while building), zoom (− | scale menu | +), Share. The pages run under that bar; what acts on the pages themselves floats over them on Liquid Glass: at the foot, the page (previous / "Page 2 of 5" / next) and, when the PDF no longer matches the source, a freshness button that fixes it ("Preview Out of Date" compiles; "Last Successful Build" shows the issues); at the top, Find in PDF (field, count, previous / next, Done).
  - **Design rules (cleanup pass, 2026-09-26):**
    - Liquid Glass wherever it applies (the owner's direction, 2026-09-26): the window toolbar, the sidebar column, the inspector (edge-to-edge glass beside the content, as WWDC25 310 describes inspectors), the controls floating over the PDF, popovers, menus, sheets and alerts. Never on content: the editor, the PDF pages, the log, list rows, the empty states' buttons (`.borderedProminent`, content). The pane bars (over the source, over the PDF, the build panel's header), the location row, the source's find bar and the status bar stay flat bars stacked above their content on one opaque `BarMetrics.background` (`windowBackgroundColor`), so they read as one chrome block with the toolbar: they don't float over anything.
    - The inspector: its `SplitPane` has `glass: true`, so `SplitController` puts the hosting view inside an `NSGlassEffectView` (corner radius 0, the view as its `contentView`, never a sibling behind it); the grouped form hides its scroll background (`.scrollContentBackground(.hidden)`) so the glass shows. `NSSplitViewItem(inspectorWithViewController:)` and SwiftUI's `.inspector` stay out (see the layout rules); full screen, resizes to the minimum and toggling the pane were checked with the glass in.
    - Floating controls (`FloatingMetrics`, `floatingGlass()`, `onGlass()` in `PaneBars.swift`): each capsule is `glassEffect(.regular, in: .capsule)`, in the paper's colour scheme rather than the window's (`paperScheme` in `PDFPane`), so on white paper in a dark window its labels are drawn dark, as over any light content (they were white on light glass over the page), at the window toolbar's size (the kit's XL pill: large 28 pt controls, 4 pt of glass, 36 pt), 12 pt from the pane's edges, separate capsules 8 pt apart in a `GlassEffectContainer` whose blending distance (4) is less than that, so they never melt into one shape. Buttons in a capsule are borderless in the primary colour, dimmed when disabled (`onGlass()`): accessory-bar and borderless buttons draw secondary, which read as disabled on glass. No `glassEffectUnion` and no interactive glass on the capsules: merged interactive glass glitched icons on hover. The find field leads its capsule 4 pt from the end, so its own capsule sits concentric in the glass. Narrow panes drop the count, then the arrows (Return / Shift-Return still step); the page reads "2 / 5" and the freshness shows only its symbol. The PDF scroll view keeps room at its foot so the last page scrolls clear of the capsules. Find in PDF no longer hides the build panel (`requestPDF`).
    - One set of metrics, from the kit, in `PaneBars.swift`: `BarMetrics` (one size, the standard one: bar = regular controls + 8 pt above and below, 40 pt, 8 pt side insets, 4 pt within a group, 8 pt between groups, 16 pt separators; secondary rows 28 pt), `FloatingMetrics` (the glass capsules, above) and `Typography` (the text role → system text style map: `.body` content, `sectionTitle` = `.title3` semibold for section and sheet titles, `secondary` = `.subheadline` with `.small` controls, SF Mono at the same size for the log). No literal point sizes except the editor's user-set size.
    - Bars: `PaneBar` (one row of a pane's actions: over the source, over the PDF, the build panel's header), `PaneBarRows` (the source find bar's two rows), `SecondaryBar` (the location row and the status bar: one text style and control size for both).
    - Sheets, not alerts, ask for values (`DialogSheet` in `PaneBars.swift`: a `sectionTitle` title and optional `secondary` message over a grouped form on the sheet's own background (its scroll background hidden: in dark it differed, a seam under the title), Cancel and the default action at the foot, `.controlSize(.regular)` set inside since macOS 27 resets it in sheets, 400 pt wide as the kit's dialogs): New File / New Folder (name, preselected "untitled.tex" / "untitled folder", and a Where pop-up of the project's folders, the open file's first), Go to Line (its placeholder gives the file's range), New Project (name "Untitled" so Create is ready, and the template). `AppModel.prompt` picks the sheet.
    - Renames are in place, as Finder's: the context menu's Rename (no ellipsis) turns the row's name into a field; Return or clicking away renames, Escape doesn't. In the sidebar the field edits the name only (the folder stays). In the start window's table the name is its own cell view (`ProjectNameCell`) reading the rename through bindings, because the table redraws a cell only when its row's value changes. The field takes focus 150 ms after the menu closes; focused at once, the list or table took focus straight back and the field closed.
    - Alerts are `AppAlert` (a short title of what couldn't be done, "Couldn’t Rename “x”", "Unsaved Changes Were Lost", with the error as the message), never a whole sentence in the title. Moving a file or project to the Trash still confirms (the Trash gives it back, but the first delete also brings macOS's Automation prompt), with a plain, not destructive, button: the person chose it (HIG, Alerts).
    - The open file is watched (`FileWatcher` in `ProjectModel.swift`: a `DispatchSource` on the file, re-opened after a rename or delete, as editors save by renaming a new file over the old). A change from elsewhere with nothing unsaved reloads the editor at the same top line, marks the preview out of date and, with auto-compile, builds; with unsaved edits it asks ("“main.tex” Changed on Disk": Keep Editing, or Revert, destructive-styled as it discards the edits), and the autosave holds off until answered, so the other app's change isn't written over while asking. This app's own saves are told apart by comparing with the text last read or written.
    - Values are bordered system controls with their own indicators, actions are flat accessory-bar buttons. Section Level is a `Picker(.menu)` (checks the current level, names itself to VoiceOver); zoom is a bordered `Menu` (the scale is any percentage) holding Fit Width / Fit Height and an inline `Picker` of presets, the current one checked. The accessory-bar pull-down draws no indicator, so no value menu uses it. A menu of actions (⋯, +) is an icon-only pull-down.
    - The PDF and inspector toggles are plain buttons whose title and help say what they will do, as the sidebar's toggle and Xcode's inspector button: as `Toggle`s the toolbar drew their on state as solid accent discs, the loudest controls in the window.
    - The source's find bar is native (`SourceFindBar`, Edit › Find and Replace…, ⌘F in the text): an `NSSearchField` with the find options (Match Case, Whole Words, Regular Expression) in its own magnifier menu, as Xcode's and Safari's are, and a replace field under it that is the same `NSSearchField` with the magnifier's image cleared (AppKit's plain text field stays 24 pt at every control size; the search field grows to 28 / 36 pt), so both rows match; previous / next, the match count, then Replace / Replace All and Done as bordered push buttons, apart from the icon buttons. The fields are drawn once, over the bar (`placingFields` over `FieldSlot`s in `PDFPane.swift`), not in each of the `ViewThatFits` layouts: a field in each was a new `NSSearchField` whenever the bar refolded (the count growing from "Not found" to "46 of 512" did it), so the field being typed in lost focus mid-word and the rest of the word went nowhere. Find in PDF does the same. ⌘F and Edit › Find › Find and Replace… put the caret in the Find field with its text selected (`FocusingSearchField` takes focus once it is in its window, on the next turn, after the key or menu item that asked). A `ViewThatFits` folds it for narrow panes: Replace All moves into Replace's menu (`Menu` with `primaryAction`), then the fields shrink from `BarMetrics.fieldWidth` to `fieldMinWidth`, and only then does the count go, so the minimum window still says "Not found". The replace field gets an empty `searchMenuTemplate` so AppKit lays out the same magnifier-with-menu slot as the find field, and the two texts start on one line. CodeMirror still searches: the embed's `setHostFind(true)` swaps its search panel for an empty stand-in whose opening and closing post `findOpen` / `findClosed`, and the page posts `findMatches` as the selection moves. Other hosts (Windows) keep CodeMirror's panel.
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
  - PDF bar: Compile, then zoom as − / the scale as a percentage (a menu with Fit Width and presets) / +, a separator, then Share. The zoom label is padded with figure spaces to four digits, so the group keeps its width and − stays under the pointer. Share uses `NSSharingServicePicker`, anchored to its button through `ViewAnchor`: `ShareLink` opened centred on the PDF. Toolbar-free zoom (the bar's) acts on the pane directly; the View menu's zoom goes through `requestPDF`, which also shows the PDF.
  - Settings › General › Toolbar Size is gone: the pane bars have one size, the standard 40 pt (the Large size looked wrong), and its `paneBarSize` preference is removed at launch. The secondary rows and status bar are 28 pt. The status bar leaves out the save state while a build runs (it said "Compiling…" twice) and, in a narrow window, drops whole items rather than truncating them (`ViewThatFits`): the engine first (the inspector and the Compile menu show it), then the word and line counts, then the save state. Show / Hide Word Count is in the status bar's context menu and the View menu, as Pages has it, not in Settings (`AppModel.showWordCount`, the same `showWordCount` preference).
  - Settings: each tab is a grouped form at its content's height, 500 pt wide as the kit's form window, so the window resizes per tab. Font Size is the system `Stepper(value:in:format:)`, whose editable value and arrows a grouped form lines up itself.
  - The build panel is at most 40% of the editors' height (`SplitPane.maxFraction`), so a small window keeps the source and PDF. The build's summary shows only in the status bar. Issues are a selectable list (double-click or Return opens the line); a failed build with no parsed error says so and offers the Build Log. Accessory-bar buttons measure 22 pt, 2 pt under the kit's 24, so those bars have 9 pt insets; the bar-fit test allows 8 to 9.
  - The PDF pane's empty states have one action each, `.borderedProminent`: Compile, Get MacTeX (a button that opens the page, as the start window's is), or Show Build Panel after a build that made no PDF (hidden while the panel shows); the Issues tab's Compile and Show Build Log are prominent too. With no build yet, the status bar, the inspector's Last Build and the Issues tab share one phrase (`ProjectModel.noBuildTitle`): "Not Built Since Opening" over a PDF built before the project was opened (this run of the app or an earlier one), else "Not Compiled". The inspector's Last Build shortens it to "None Yet" / "None" so it stays beside its label at 960 pt ("None Since Opening" wrapped under it). A failed build reads "Build Failed · 1 Error" with one symbol. Issue rows show `file:line`, the main file's when the log names none, as double-click opens; the parser (`logparse.rs`) no longer gives a "!" error the next error's `l.<n>`, nor TeX's closing "==> Fatal error occurred" the stopping error's line, so neither shows a place; that summary is left out after the error it follows (one mistake is one error) and kept only when it is the log's only error. After any failed run the core deletes latexmk's `build/<main>.fdb_latexmk` (`finish` in `compile.rs`): after a fatal error in a project with a bibliography its record held the truncated .aux, bibtex failed on it, and every later build stopped at "gave an error in previous invocation" (0 errors, no PDF) even with the source fixed and `-g`. The Warnings filter shows only when there are warnings; Copy Log uses the HIG's Copy symbol, `document.on.document`. The zoom menu checks Fit Width / Fit Height while fitting (`PDFController.fit`).
  - The sidebar opens files and sections without focusing the editor (`ProjectModel.open(…, focus: false)`), so the arrow keys stay in the list; search hits, issues, Go to Line and SyncTeX still focus it.
  - Format menu: Bold, Italic; then Section Level, Inline Math, Display Math, Symbols, Reference; then the blocks ("Aligned Equations" is the web's "Align (multi-line math)"); then Comment Selection. Settings › TeX Distribution names the distribution from the folder latexmk runs from, links followed ("TeX Live 2026", "MiKTeX"), else latexmk's version. The Section Level pop-up is the system's, sized by AppKit to its longest level; with "Subsubsection" its chevron sits close to the text, as AppKit draws it.
  - Menus: Edit › Spelling and Grammar (the stateless items only; the While Typing toggles need an AppKit-validated menu item to show their checkmarks), "Comment Selection", and Help › TeXLocal on GitHub. The app icon is a flat PNG set from `assets/TeXLocal.png`; a layered Icon Composer `.icon` is the macOS 26+ ideal.
  - A library folder that can't be opened shows an alert and quits. The alert is posted on the next main-queue turn: `Core.shared` is first made during SwiftUI's first scene update, where a modal alert aborted the app.
  - The start window: template cards, then recent projects as a sortable table. Each card is the kit's group box (12 pt continuous corners, a `.fill.quinary` fill that steps to tertiary under the pointer and secondary while pressed, `CardButtonStyle`); the page drawing is white paper, dimmed to 88% in dark mode, drawn in the light appearance's semantic fills with the accent for the slide's header. The toolbar's search is a 180 pt search field item on its own glass capsule, apart from + by a fixed spacer: `.searchable` grew to half the window, and neither its width nor `searchToolbarBehavior(.minimize)` (iOS only) can be set on macOS.
  - Editor current line and selection matches use the host's `current-line` (quaternary system fill) and `selection-match` colours; in dark mode other find matches take the host text colour so they stay readable.
  - Splits keep each pane's share across window resizes (`splitView(_:resizeSubviewsWithOldSize:)`), so a small window no longer leaves the PDF at its minimum afterwards.
  - "Preview Out of Date" is save-counted: it clears after the lost-edits alert when nothing was saved since the last good build, and stays set when a save lands during a build.
- **Layout rules learnt the hard way:**
  - The window has one minimum size (960 × 600, the whole window) whatever it shows. SwiftUI's content minimum leaves out the 52 pt toolbar, so the content's is 548 (`WindowMetrics` in `TeXLocalApp.swift`); a 600 pt content minimum made the smallest window 652 pt tall. Changing it as a project opened crashed AppKit ("more Update Constraints in Window passes than there are views").
  - Every split is AppKit's `NSSplitView` (`SplitController.swift`; the bar components are in `PaneBars.swift`, the source's bars in `SourceBars.swift`): source | PDF, the editors over the panel, and the editors beside the inspector. Each pane is an `NSHostingView` made once (its views observe the models), with `sizingOptions = []` so SwiftUI's sizes stay out of Auto Layout; the delegate enforces minimums and maximums. A hidden pane is removed from the split, since AppKit kept room for a merely hidden one, and comes back at its previous size. Divider positions are autosaved.
  - SwiftUI's split views don't work in this window (2026-09-26). `.inspector` crashed on window resize with the same loop. `HSplitView` and `VSplitView` laid the PDF out under the inspector, and a pane shown after launch opened at zero size. `NSSplitViewController` blurred the pane bars with the toolbar's scroll-edge effect.
  - Menu clicks through System Events do update the window in the background. An earlier "frozen window" came from pane views built from values rather than views that observe the models.
  - Bars are stacked above their content, not attached with `safeAreaBar`: they are opaque, so content under them was only hidden.
  - The 26.5 SDK is at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` on the owner's Mac: `xcrun swiftc -typecheck -swift-version 6 -sdk <it> -target arm64-apple-macos26.0 -I crates/texlocal-ffi/include apps/macos/TeXLocal/*.swift` (without `-swift-version 6` it fails on `Outline.swift`'s regex literal) checks a change against it.
  - A divider's position is where the pane before it ends; the pane after starts a divider's thickness later, so `SplitController`'s drag limits subtract it (they were 1 pt off, which a folded pane showed).
  - Separators are stock `Divider()`s placed as siblings in a `VStack`. An overlaid `Divider()` takes its parent's layout context, so inside an `HStack` it turns vertical.
  - PDFKit re-anchors page one's top to the view on every resize while fitting the width, so the gap above page one is a scroll-view content inset.
- **Parity and review fixes:** every command in `commandDefs`, and the settings with a native meaning. Saves run one at a time; quit waits for a save in flight; compiles queue; a WebContent crash recovers the editor; overlapping file opens can no longer save one file's text into another; undo and redo always reach CodeMirror's history.
- **Tests:** 34 XCTests, including the outline tree and its fold keys surviving renumbering, the bar's standard 40 pt and a group fitting it, that a floating glass capsule is 36 pt, that the file watcher tells a change written in place and one saved by renaming over the file (and keeps watching after), a folded split pane keeping its header's height and unfolding to its height, the build panel keeping within its largest share (the split tests put the split in a window and size it once it has its delegate, as the app does: macOS 26's `setPosition` doesn't first lay out panes just added, as 27's does, and CI runs on 26), the source find count, the duration text, and the Build Panel and spelling menu items. The test scheme sets `TEXLOCAL_DATA=/tmp/texlocal-xctest`, and its pre-action copies `web/src/workspace.js` there for the command-table test: the tests run inside TeXLocal.app, which would otherwise need Documents access, and macOS asks again after every re-signing build, blocking the read.
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
    - It is unpackaged and x64. .NET 10 and the Windows App SDK are both bundled, so users install neither. It references the SDK's WinUI, Foundation and InteractiveExperiences packages rather than the `Microsoft.WindowsAppSDK` metapackage, which also shipped the AI, ML, search and widgets runtimes (onnxruntime, DirectML…): a Release publish went from 234 MB to 174 MB.
    - `texlocal_ffi.dll` is copied from `target\debug` or `target\release` to match the configuration.
- **Web surfaces:** the editor and PDF pages each run in a WebView2.
  - The bundled `web\` is served at `app.texlocal`. The PDF is answered at `project.texlocal` from `WebResourceRequested`, with a CORS header for `app.texlocal`, set up on each new CoreWebView2 before the page loads (`EmbeddedPage`'s `configure`).
  - A renderer crash reloads the page. When the whole browser process dies, every WebView2 is dead and can't be started again, so `EmbeddedPage.Replace` puts a new one in the old one's place in its panel; the pages come back as after a renderer crash (checked by killing the browser process: a new one started, both pages reloaded with the document, and editing and autosave worked).
  - Window-level keyboard shortcuts stand down while a page has focus. The page posts the chord back instead: the editor page already did this, and `web/src/embed/pdf.js` now does too.
- **Parity:** every command in `commandDefs`, and every setting the macOS app has.
  - Done: menus, toolbar, sidebar (tree, search, outline), autosave and the compile queue, compile and log, PDF find and zoom, SyncTeX, import and export.
  - Also done: word count and the breadcrumb in a status bar, interface size, PDF paper, numpad shortcuts, and dropping files onto a tree folder to import into it.
  - Closing flushes first and then calls `kill_all`. A crashed editor page recovers.
  - Both macOS reviews' bug fixes are applied here too. The app uses `texlocal.rename` and the undo fallback from `web/src/embed/editor.js`.
  - On Windows, CmdOrCtrl+Return and Ctrl+Return are the same keys. Compile keeps the shortcut, and Go to PDF position is on the Compile menu only.
  - Find Next / Find Previous (Ctrl+G, Ctrl+Shift+G) are in `MenuCommand`, the Edit menu and `Commands.cs`; F3 / Shift+F3 still work inside the editor page. Showing F3 in the menu would need a Windows-only shortcut in the table and its test.
  - **Issue #10's parity gaps (2026-09-26, evening):**
    - The source bar has the Mac's and the browser's groups and order: undo, redo | section level (a `DropDownButton` naming the caret line's level, as wide as "Subsubsection"; `setHeading`) | bold, italic | inline math, display math, symbols (a `Flyout` holding a grouped `GridView`, 10 columns, one tab stop; `insertSymbol` via the `symbol` command) | link, reference, citation | figure, table | bulleted, numbered list | "See more". It is a `CommandBar` with dynamic overflow, so WinUI itself moves buttons into "See more" from the end; the templates with no button are its secondary commands. The PDF's zoom and Share are a `CommandBar` too. The Format menu gains Display math, Symbols and Section level. `LatexTemplates` holds the levels and symbols; a test reads `SYMBOL_GROUPS` from `web/src/sourcebar.js` so the tables can't drift.
    - Segoe Fluent Icons has no sigma, pi, number sign or numbered list: Σ and # come from Segoe UI, π and the numbered list are 16 px `PathIcon`s (`PiIconData`, `NumberedListIconData`). The glyph sheets were rendered from `SegoeIcons.ttf` to check.
    - The File Outline is docked under Files: a 32 px "File outline" heading (its line is the divider) with a chevron that folds it to the sidebar's foot, a divider whose height is remembered (`OutlineHeight`), folds remembered per project and file (`OutlineFolded`, by `Outline.FoldKeys`). It has no selection: the current section is accent semibold, follows the editor's top visible line (the page's `scroll` message → `ProjectModel.TopLine`), and opens its parents and scrolls into view. Choosing a heading reveals it at the top of the editor without taking focus (`reveal(line, atTop, focus)`).
    - "Out of date" by save counting (`writes` / `builtWrites`), as the Mac: it clears after the lost-edits message when nothing was saved since the last good build.
    - The open file is watched (`FileSystemWatcher` on its folder, filtered to its name, for editors that save by renaming). A change with no unsaved edits reloads at the same top line, marks the preview out of date and auto-compiles; with unsaved edits a dialog asks "Keep editing" (default, saves over it) or "Revert". Saves wait while it asks. A save that starts during a check makes the check stand down; its own change notice checks again.
    - Messages have a short title and the detail (`MainWindow.Report(title, message)`, the InfoBar's Title), e.g. "Couldn’t rename “x”".
    - The status bar drops whole items as it narrows: the engine, then the counts, then the save state (hidden while compiling, as the Mac).
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
      - The source and PDF toolbars are `CommandBar`s (icon buttons, labels in tooltips), whose own overflow folds them into "See more" as they narrow. Hand-folded rows of buttons were tried first and took far more code.
    - **Layers.**
      - The sidebar sits on Mica, 280 wide by default (200–360), in an inline `SplitView` pane. It has no footer: Add is the Files heading's action (Settings stays in the File menu, Ctrl+,).
      - The trees' expander column is narrowed from 40 to 24 at runtime (`OnTreeItemLoaded`), since the template hard-codes its padding. Rows then start 12 in from their heading.
      - The main file's name is semibold, as Visual Studio shows its startup project, with a "Main file" tooltip and accessible name. The Mac's yellow star was dropped on Windows as not native.
      - The content layer has an 8 px top-left corner and a 1 px stroke on its top and left edges, like NavigationView's content area. It contains the source, the PDF, the bottom panel, the status bar under the document only, and the Details pane.
      - The Details pane is File Explorer's pattern: Alt+Shift+P, 220–320 wide, in a right-hand inline `SplitView` pane inside the layer.
      - Pane sizes are remembered in `Preferences`.
    - **Motion** (`Motion.cs`) uses the Windows animation library's theme animations:
      - DrillIn and DrillOut between the library, a project and Settings, as Settings and File Explorer do;
      - the sidebar and the Details pane are inline `SplitView` panes, so they slide open *and* closed with WinUI's own storyboards (about 200 ms open, 120 ms close), the content moving with them; frame captures confirmed both directions. Their dividers set `OpenPaneLength`;
      - PopIn from its own edge for the PDF, the panel and the File Outline;
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
- **Installer:** `apps/windows/installer/TeXLocal.iss` (Inno Setup 6): per user, no admin rights, into `%LOCALAPPDATA%\Programs\TeXLocal` (where the owner's PC already has it) with a Start-menu shortcut and an entry in Settings › Apps; an update replaces the whole folder, and projects and settings stay on uninstall. The Windows app workflow's "Installer" job builds it (`cargo build --release -p texlocal-ffi`, `dotnet publish … -c Release -o release/windows`, `iscc`) and uploads `TeXLocal-<version>-setup.exe` as an artifact. Inno Setup isn't installed on the owner's PC, so it was first built in CI. By hand: build the Rust core with `--release` first (a stale `target\release\texlocal_ffi.dll` from 25 Sep was being published).
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
  - **2026-09-26, evening, a Debug build against a scratch `TEXLOCAL_DATA`:** the source bar at full width and folding as the PDF divider moves, "See more"'s contents, the section level menu turning `\section` into `\subsection` (and the outline nesting it), the symbol palette inserting `$\alpha$` in text, undo after both, the outline's current section following wheel-scrolling, choosing a heading, a file changed by another program reloading and rebuilding, the semibold main file, and the sidebar and Details pane sliding both ways.
  - Launching the installed build while a Debug build runs breaks the Debug build's WebView2 pages (the two share `%LOCALAPPDATA%\TeXLocal\WebView2` with different options); run one at a time.
- **Known issues:**
  - Once (2026-09-26, 22:29), a Release build crashed while idle with a fail-fast in `ucrtbase.dll` (0xc0000409, abort). That build linked a stale `target\release\texlocal_ffi.dll` from 25 Sep; rebuilt against the current core, it ran 8 minutes of editing, compiling and idling without a crash. Not reproduced since.
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
  - The status bar, and its items dropping as the window narrows.
  - The unsaved-edits conflict dialog (a change on disk within 700 ms of typing).
  - The InfoBar's title and message on a real failure.
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
2. **Windows:** the installer on a real install and uninstall.
3. **The full-screen assertion** (above), if it recurs.
4. **Small follow-ups:** in the web version, `contextMenu` / `menuUnder` in `web/src/dom.js` place menus with unscaled rects, so under Interface Size ≠ 100% they may land offset (`popoverUnder` already converts); the web outline has no per-section folding; the server has no cap on concurrent connections (local only, so low value); a light One Dark variant for Syntax Colors. A later run (2026-09-26, night) had `a_timed_out_compile_keeps_the_output_it_wrote` (`crates/texlocal-core/tests/compile_stub.rs:128`) fail once; three reruns passed.
5. **Retire Tauri** once both apps are verified by hand. Delete `src-tauri`, the Tauri path in `bridge.js` and `@tauri-apps/cli`, and replace `tauri-action` in `ci.yml` and `release.yml` with release builds of the two apps.

## Gotchas

- An unfinished Word-style safe save (write a temporary file, then replace) is kept, uncommitted, at `.claude/wip/safesave.rs`. It is not wired in.

- On the owner's Mac, `static.crates.io` is blocked by network policy, while GitHub works. Before adding a Rust dependency, check `~/.cargo/registry/cache`, or pin a dependency-free crate to its GitHub tag. That is why the server doesn't use axum.
- `CLAUDE.md` is deleted; the owner's global `AGENTS.md` replaces it.
- XcodeGen 2.46 is not installed system-wide. Download it from GitHub releases and regenerate after editing `project.yml`.
- The Tauri app's behaviour must not regress while it still ships. Run `npm run app` to check.
