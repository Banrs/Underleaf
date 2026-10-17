# Underleaf

Status and decisions for agents working here. `README.md` is the overview and
`docs/core-api.md` the hosts' contract with the core.

## Shape

- **Rust core** (`crates/texlocal-core`) builds and tests on macOS and Windows; Linux isn't
  supported. It owns everything but UI and OS integration: projects, path safety, latexmk
  and SyncTeX, log parsing, ZIP export, the JSON command service, and **project sessions**
  (`session/`): each open document's text, autosave, notify-based folder watching, builds,
  issues, the outline's analysis and the TeXpresso client. Hosts send commands and receive events
  (`tl_set_listener`). Logic both hosts need lives here, never in a host.
- **The core's `syntax` module** is I/O-free and owns editor logic: typing transforms,
  snippets, completion, highlighting, themes, the symbol and template catalogue, heading
  styles, the ranges spelling and Writing Tools leave alone, and maths and glyph rendering
  through RaTeX (`math_svg`, `glyph_svg`).
- **`crates/texlocal-ffi`** is the C ABI, built as a static library (and an rlib for its
  tests); the Windows app builds its DLL with `cargo rustc --crate-type cdylib`.
- **macOS app** (`apps/macos`) is UI only, on the core.
- **Windows app** (`apps/windows`) is a native WinUI 3 / Fluent app, UI only, on the core;
  `docs/windows.md` has its design and the core gaps it waits on.
- **CI** is `.github/workflows/ci.yml`: a path-filtered `changes` job, Rust on macOS and
  Windows, the Windows app's build, tests and smoke run, the Mac app's `xcodebuild test` on
  the `xcode-27` runner, and `ci-ok`, the one required check.

## The Mac app

**Direction (2026-10-17):** native default behaviour first. The app is to be built as Apple
recommends for a new app: SwiftUI scenes and views, with AppKit only behind representables
where SwiftUI has nothing (the TextKit 2 editor and PDFKit's `PDFView`). No measured or tuned
numbers, no custom colours, no platform workaround without a capture of the bug it fixes;
what Apple's own apps do (Preview, TextEdit, Xcode, Notes) settles a question before taste
does. The few custom pieces kept on purpose: the File Outline at the sidebar's foot, opening
upward; Home's template cards; Compile as a word; one status bar across source and PDF; the
completion list as a SwiftUI glass list.

**Where main is now:** the window, toolbar and splits are still AppKit
(`WorkspaceController`, `WorkspaceToolbar`, `SplitViews`); a SwiftUI shell (three-column
`NavigationSplitView`, whose toolbar sections follow the source|PDF divider, plus
`.inspector`) is on trial on its own branch. Panes, bars, sheets, popovers, Settings and Home
are SwiftUI.

- **Toolbar**: Compile is the window's one prominent item, a word that becomes a symbol only
  in a narrow window; while building it is Stop, with progress. Aa (text styles), Math and Insert sit over the source; Zoom (minus,
  percentage, plus), Compile and the PDF and Inspector toggles over the PDF. Tools without
  room go to the system's overflow by `visibilityPriority`.
- **Source**: one TextKit 2 `NSTextView` (`SourceTextView`) shared across files, never
  touching `layoutManager`. Issues sit on their lines as in Xcode (numbers-only gutter, a box
  at the line's end); the measures come from the system font's metrics.
- **Status bar and build panel**: one bar across source and PDF, the system's spacing and
  scroll edge; Not Saved after a failed save. The build panel opens below the columns with
  a console-style bar (Issues, Build Log, Live Preview Log, Warnings, a filter).
- **PDF**: PDFKit as Preview has it. A rebuilt document's pages replace those showing in the
  same `PDFDocument` (a new document flashes the background); PDFKit keeps replaced pages'
  objects, so once the app has grown 512 MB since a document was last shown whole, the next
  one is shown whole (`PDFController.memoryAtWhole`).
- **Sessions**: the open project is a core session, numbered by the app before it opens
  (`Core.observe`), so none of its events can come before the app listens. Commands go
  through `tl_call_async` and are awaited, so no thread waits on the core; a session takes
  them in the order sent. Events are decoded on the core's thread and reach their session's
  `ProjectModel` on the main actor in order. `ProjectModel` is split by concern:
  `ProjectModel.swift` (state, events, editing, outline, conflicts, settings),
  `+Build`, `+Live` (live preview and SyncTeX), `+Files`, and `SessionEvents.swift`. The
  sidebar's open folders and folded headings are the project's settings (`get_ui_state`,
  `set_ui_state`, and a rename's answer), not UserDefaults.
- **Editor logic is the core's**: each key asks the source (`tl_source_call`: `type`,
  `delete_backward`, `insert_newline`) for the edit to type instead; each storage edit is
  told back once (`tl_source_edit`, which also answers a snippet's mirror edits) and each
  selection too (`tl_source_select`). The text comes from `tl_source_text`, and what
  spelling and Writing Tools skip from `code_ranges`. Command edits, theme colours, the menu
  catalogue and maths SVG come from `tl_syntax_call` (`Syntax`). The maths preview is set at
  1.21 times the text.
- **Other helpers are the core's**: SyncTeX finds the word (`synctex_match`,
  `synctex_inverse`); `session_analyze` gives the outline's tree with its fold keys, the
  word count and the main file's heading styles, and `session_outline_current` the heading
  at a line; an issue line carries its message's `compact` form and where its command is
  (`tokens`); a file's kind comes with `file_tree`; a free name with `create_entry`.
- **Live preview** belongs to its project session, by the session's number. The session
  sends each edit on to TeXpresso and reports its pages (`live_document`, `live_page`);
  `TeXpressoSession` reads them off the main actor and `PDFController` swaps them into the
  pane (`showLive`). The whole document follows 300 ms after the last key and replaces only
  the pages that changed. While the Live Preview Log shows, the `live` event carries its
  text (`session_live_log`). Settings ▸ Live Preview chooses the pane or TeXpresso's own
  window. The protocol is in `docs/texpresso.md`.
- **A file another app changed** while it has unsaved edits here is asked about in an AppKit
  alert (Save Anyway, Revert, Cancel) with no default button, since either answer loses a
  version; SwiftUI's alert can't omit the default. One moved or deleted gets a SwiftUI alert
  whose default saves it again. Cancel writes nothing (the session's `conflict` event,
  answered with `session_resolve`).
- **Dim, not hidden**, where hiding would make things jump: the File Outline, the panel's
  Warnings toggle with no warnings, Live Preview Log before Live Preview has run, and
  Format items in files the toolbar's are dim in.
- **Settings** is a multi-pane window per the HIG: General, Editor, Compiling and Live
  Preview. The PDF pane goes with its only setting, dark paper (Preview has none).
- **Words**: the feature is Live Preview; TeXpresso is named only where the program is the
  subject. The verb is Compile, and a run and its result are a build. Interface spelling is
  British (Colours) except LaTeX's own terms (Math).
- **Home** is the start screen, as Word's gallery and Overleaf's project list: template
  cards and recent projects. The Mac and Windows apps should look and work alike.
- **Builds** follow Overleaf and IDEs: they run past errors with every issue listed, a
  project can Stop on First Error, and a pause in typing saves and compiles.

Platform quirks met on the way (27.2) are in the code's comments where they're handled; one
without a capture of its bug on the current OS is a candidate for removal.

## Testing

- `cargo test --workspace`; CI also runs `cargo fmt --all --check` (macOS) and
  `cargo clippy --workspace --all-targets -- -D warnings`.
- The Mac app: `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal test`
  (Swift Testing). The tests run a host app that shares the app's defaults unless built
  with another bundle identifier: pass `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`, as CI
  does with its own, or quit the installed app first.
- The live preview's end-to-end check needs the patched engine:
  `cargo test -p texlocal-core --test texpresso_live -- --ignored` (`docs/texpresso.md`).
- Physical trackpad gestures, the dividers' haptic, interactive IME and visual-material
  checks stay manual.

## Build and install the Mac app

Requires Xcode 27 and Rust stable.

```sh
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-release \
  CODE_SIGNING_ALLOWED=NO build
```

Quit TeXLocal, ad-hoc sign the Release product, replace `/Applications/TeXLocal.app`, verify
its signature, and compare the installed and built binaries.

## Open

- A long document's live preview latency has not been measured on screen.
- The TeXpresso engine on Daniel's Mac is the patched `texpresso` built against MuPDF and
  SDL2 made from source, and `texpresso-xetex` built against Homebrew's `icu4c`, `harfbuzz`
  and `graphite2`, which have to stay installed. `tools/texpresso/build.sh` builds both
  where Homebrew has all of TeXpresso's dependencies and `pkg-config`.
- Not watched on screen since the live preview's rewrite: a restart after TeXpresso exits,
  and a quick Stop and Start.
- The Windows app is not finished (no live preview yet); it follows `docs/core-api.md` and is
  ported to its "Changes for hosts (October 2026)".
