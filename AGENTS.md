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
- **`crates/texlocal-ffi`** is the C ABI, built as a static library; the Windows app builds
  its DLL with `cargo rustc --crate-type cdylib`.
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
completion list as a SwiftUI glass list. Since then (2026-10-18) the status bar takes
Xcode's editor bar and Aa's popover Notes' measures.

**Where main is now:** the window, toolbar and splits are AppKit (`WorkspaceController`,
`WorkspaceToolbar`, `SplitViews`), because SwiftUI's split can't give the AppKit editor and
`PDFView` the system's scroll edge under one bar (a probe on 27.2); they take the system's widths
and minimums, with no detents and none of the old 27.2 split workarounds. Panes, bars, sheets,
popovers, Settings and Home are SwiftUI.

- **Toolbar**: Compile is the window's one prominent item, its word, or its symbol's circle
  where the toolbar has no room for the word (`CompileHost`); while building it is Stop, with
  progress. Aa (text styles, Notes' popover with standard toggle buttons for Bold, Italic and
  Underline), Math and Insert (its symbol a plus) sit over the source; Zoom (minus, percentage, plus),
  Compile and the PDF and Inspector toggles over the PDF. Tools without room go to the system's
  overflow by `visibilityPriority`.
- **Source**: one TextKit 2 `NSTextView` (`SourceTextView`) shared across files, never
  touching `layoutManager`. Issues sit on their lines as in Xcode (numbers-only gutter, a box
  at the line's end); the measures come from the system font's metrics. Syntax colours are
  rendering attributes, and a recolouring redraws only the fragments whose runs changed.
- **Status bar and build panel**: one bar across source and PDF at the system's spacing, as
  Xcode's editor bar: each pane has an empty bottom accessory of the bar's height
  (`BarMetrics.height`) with AppKit's hard scroll edge, whose ground and line are the bar's and
  which text and pages scroll through; the File Outline's header is level with its line. Not
  Saved after a failed save, and a failed autosave is told once in an alert, as NSDocument's are. The build panel opens below
  the columns with a console-style bar (Issues, Build Log, Live Preview Log, Warnings, a
  filter); it resizes from the status bar's line and is dragged open and shut there, as Xcode's
  debug area (`area.grip`, an additional effective rect; the panel's `canCollapse`).
- **PDF**: PDFKit as Preview has it, on PDFKit's own canvas colour and always white paper. A
  rebuilt document's pages replace those showing in the same `PDFDocument` (a new document
  flashes the background); PDFKit keeps replaced pages' objects, so once the app has grown 512
  MB since a document was last shown whole, the next one is shown whole
  (`PDFController.memoryAtWhole`). A fitted page keeps PDFKit's side margins, as Preview's;
  pages have no top margin, so the first meets the toolbar's edge and, at the document's start,
  stays there as the pane resizes.
- **Sessions**: the open project is a core session, numbered by the app before it opens
  (`Core.observe`), so none of its events can come before the app listens. Commands go
  through `tl_call_async` and are awaited, so no thread waits on the core; a session takes
  them in the order sent. Events are decoded on the core's thread and reach their session's
  `ProjectModel` on the main actor in order. `ProjectModel` is split by concern (`+Build`,
  `+Live`, `+Files`, `SessionEvents.swift`). The sidebar's open folders and folded headings are
  the project's settings (`session_open`'s `ui`, `set_ui_state`, a rename's answer), not
  UserDefaults.
- **Editor logic is the core's**: each key asks the source (`tl_source_call`: `type`,
  `delete_backward`, `insert_newline`) for the edit to type instead; each storage edit is
  told back once (`tl_source_edit`, which also answers a snippet's mirror edits) and each
  selection too (`tl_source_select`). The text comes from `tl_source_text`, and what
  spelling and Writing Tools skip from `code_ranges`. Command edits are the source's too
  (`toggle_style`, `wrap`, `set_heading`, …); theme colours, the menu catalogue and maths SVG
  come from `tl_syntax_call` (`Syntax`). The maths preview is set at 1.21 times the text.
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
  Preview.
- **Words**: the feature is Live Preview; TeXpresso is named only where the program is the
  subject. The verb is Compile, and a run and its result are a build. Interface spelling is
  British (Colours) except LaTeX's own terms (Math).
- **Home** is the start screen, as Word's gallery and Overleaf's project list: template
  cards and every project in the library (recent ones are in Open Recent and the Dock menu).
  The Mac and Windows apps should look and work alike.
- **Builds** follow Overleaf and IDEs: they run past errors with every issue listed, a
  project can Stop on First Error, and a pause in typing saves and compiles.

Platform quirks met on the way (27.2) are in the code's comments where they're handled; one
without a capture of its bug on the current OS is a candidate for removal.

## Writing code

Agents' code runs long and erodes with each change (SlopCodeBench, arXiv 2603.24755), and
human code erodes more slowly. So keep a change to what it needs:
- Delete before adding. Reuse what exists (grep first). A new helper, option or type needs two
  callers.
- No checks for states that can't happen, no wrappers that only forward, no single-use variables.
- Comments say why, never what, nor what the code used to do.
- Before committing, read the whole diff and remove what the change doesn't need.
- Test each rule once, deterministically, at one level.

## Testing

- `cargo test --workspace`; CI also runs `cargo fmt --all --check` (macOS) and
  `cargo clippy --workspace --all-targets -- -D warnings`.
- The Mac app: `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal test`
  (Swift Testing). The tests run a host app that shares the app's defaults unless built
  with another bundle identifier: pass `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`, as CI
  does with its own, or quit the installed app first.
- The Windows app: `dotnet test apps/windows/TeXLocal.Tests -c Debug`; `TeXLocal.exe --smoke`
  opens Home and exits 0. Run dev builds with a scratch `TEXLOCAL_DATA`, never beside the
  installed copy (`docs/windows.md`, Building and testing).
- Quicker than a build: `zsh tools/qa/typecheck.sh` type-checks the app and its tests in about
  20 s; `tools/qa/xctest.sh <repo> <derived data> [-only-testing:…]` runs the native tests one
  at a time per session. Worktree agents use these rather than parallel `xcodebuild`s.
- On screen: the QA driver in `tools/qa` (its README has the setup and the rules), on a QA copy
  (`com.texlocal.mac.qa`, data in a scratchpad), never the installed app or `~/TeXLocal`.
- The live preview's end-to-end check needs the patched engine:
  `cargo test -p texlocal-core --test texpresso_live -- --ignored` (`docs/texpresso.md`).
- Physical trackpad gestures, the dividers' haptic, interactive IME and visual-material
  checks stay manual.

## Build and install the Mac app

Requires Xcode 27 and Rust stable. `zsh tools/install-mac.sh` builds the checkout it is in
(Release, derived data in `/private/tmp/underleaf-release`), quits TeXLocal, ad-hoc signs and
installs `/Applications/TeXLocal.app`, verifies its signature, compares the installed and built
binaries, and reopens it.

## Build and install the Windows app

Requires the .NET 10 SDK and Rust stable. Quit TeXLocal, then run `apps/windows/install.ps1`:
it publishes a self-contained Release build to `%LOCALAPPDATA%\Programs\TeXLocal`, replacing
what is there, and points the Start menu's TeXLocal shortcut at it.

## Open

- A long document's live preview latency has not been measured on screen.
- The TeXpresso engine on Daniel's Mac is the patched `texpresso` built against MuPDF and
  SDL2 made from source, and `texpresso-xetex` built against Homebrew's `icu4c`, `harfbuzz`
  and `graphite2`, which have to stay installed. `tools/texpresso/build.sh` builds both
  where Homebrew has all of TeXpresso's dependencies and `pkg-config`.
- Not watched on screen since the live preview's rewrite: a restart after TeXpresso exits,
  and a quick Stop and Start.
- The Windows app is not finished (no live preview yet); it follows `docs/core-api.md` and is
  ported to its "Changes for hosts (October 2026)". `docs/audit-2026-10.md` lists what it lacks
  against the Mac, surface by surface, and why. Its shell was redone on 2026-10-19 (menus in the
  title bar, one command bar, Word's navigation pane and Home, layers on Mica; `docs/windows.md`):
  seen in light and dark at 1280 × 800 and 800 × 550, not yet in a high-contrast theme, by touch,
  or with a real pointer over the sizers' grips.
- `docs/handoff.md` lists what the October concise pass left, the Mac's unchecked 27.2
  workarounds among it.
- The Mac still calls the core on the main thread (`Core.now`) for `locate` while files are
  dragged over the editor or the tree, and for `kill_all` at quit; core-api.md allows only
  `session_outline_current` there.
- Measured on the 400-page test document (2026-10-18), not yet improved: a build's PDF shown in
  place costs the main thread about 0.7 s, mostly PDFKit relaying out its view per inserted and
  removed page (quadratic in the page count; a 20-page document is a few milliseconds); a SyncTeX
  query runs the `synctex` program, which reads the whole 14 MB file each time (about 80 ms).
  Keeping unchanged pages would need a comparison that also sees changed images and fonts, and an
  in-core SyncTeX index would have to match the program's box choice exactly.
- Profiling without the screen: `xcrun xctrace record --template 'Time Profiler' --attach <pid>`,
  with typing posted through Accessibility (`AXSelectedText`); a driver that walks the window's
  tree per key measures PDFKit building accessibility nodes (it runs text recognition on pages),
  not typing. The per-key core work is about 0.1 ms; AppKit's text checking and drawing are the rest.
- TeX on macOS 27 (MacTeX 2026, March package): biber's universal launcher calls
  `lipo -extract_family`, which macOS 27's `lipo` refuses, so biber exits with lipo's usage until
  `tlmgr update biber` (or its arm64 slice) replaces it. ConTeXt and arara are not in that package.
