# Underleaf

Rules and standing decisions for agents working here. `README.md` is the overview,
`docs/core-api.md` the hosts' contract with the core, `docs/handoff.md` what is open.

## Shape

- **Rust core** (`crates/texlocal-core`), macOS and Windows only, owns everything but UI and OS
  integration: projects, path safety, latexmk and SyncTeX, log parsing, ZIP export, the JSON
  command service and project sessions (`session/`: open documents, autosave, folder watching,
  builds, issues, the outline, the TeXpresso client). Hosts send commands and receive events
  (`tl_set_listener`). Logic both hosts need lives here, never in a host.
- **`syntax`**, I/O-free, owns editor logic: typing, snippets, completion, highlighting, themes,
  the symbol and template catalogue, heading styles, the ranges spelling skips, and maths and
  glyphs through RaTeX (`math_svg`, `glyph_svg`).
- **`crates/texlocal-ffi`** is the C ABI, a static library; Windows builds it as a DLL.
- **macOS app** (`apps/macos`) and **Windows app** (`apps/windows`, WinUI 3, `docs/windows.md`)
  are UI only, on the core. They should look and work alike.
- **CI** (`.github/workflows/ci.yml`): path-filtered jobs for Rust on both systems, the Windows
  app and the Mac app; `ci-ok` is the one required check.

## The Mac app

Decided; change only when the owner asks. Each 27.2 workaround is explained where it is handled.

- **Window and splits are AppKit**; panes, bars, sheets, popovers, Settings and Home are SwiftUI.
- **Narrow windows**: the window stops at 542 pt (`ColumnMetrics`); sidebar and inspector fold
  and aren't saved as hidden; the title and the overflow menu are AppKit's, not custom.
- **Toolbar**: its separators track the source|PDF divider. Compile is the one prominent item,
  a word, its symbol only without room; Stop with a spinner while building. Aa opens Notes'
  popover of text styles (`FormatPopover`); Math and Insert are menus beside it. The PDF's
  zoom is a pill (`zoomItem`).
- **Source**: one TextKit 2 `SourceTextView` at Xcode's metrics. The completion list
  (`CompletionList`) is Liquid Glass in a system menu's measures, a view in the window.
- **Issues** as Xcode's: a band over the paragraph and an `IssueBox` at the line's end with the
  core's message (or its `compact` form, or the symbol alone); a click opens the build panel on it.
- **Status bar**: one 36 pt bar (`BarMetrics`) across the source and PDF columns, as Xcode's
  editor bar, over each pane's hard scroll edge; text and pages ghost through it. After a failed
  save it says Not Saved and saves on a click.
- **Build panel** below the columns, resized and dragged shut from the status bar's line; a bar
  at its foot as Xcode's console: Issues, Build Log, Live Preview Log, then Warnings or Copy Log,
  then a filter.
- **Splits**: AppKit's thin dividers. A drag stops at the sidebar's opening width and at the even
  source|PDF split, with the alignment haptic; a double-click restores the even split.
- **File Outline** at the sidebar's foot; dim and folded on a file that isn't LaTeX.
- **PDF**: a rebuilt document's pages replace those showing in place; fitted pages keep
  PDFKit's margins, as Preview's; paper is white, dark or automatic.
- **Dim, not hidden**, where hiding would make things jump.
- **Settings**: General, Editor, Compiling, PDF, Live Preview.
- **Home**: template cards and every project in the library, as Word's gallery and Overleaf's list.
- **Builds** follow Overleaf: they run past errors with every issue listed, a project can Stop on
  First Error, and a pause in typing saves and compiles.
- **Changed on disk** with unsaved edits: an AppKit alert (Save Anyway, Revert, Cancel) with no
  default button; Cancel writes nothing. One moved or deleted gets a SwiftUI alert whose default
  saves it again.
- **Words**: the feature is Live Preview (TeXpresso only where the program is meant); the verb is
  Compile, a run is a build. British spelling (Colours) except LaTeX's terms (Math).

### How it talks to the core

- A session is numbered by the app before it opens (`Core.observe`); commands go through
  `tl_call_async` and are awaited; events reach the session's `ProjectModel` on the main actor in
  order. The sidebar's open folders and folds are project settings (`set_ui_state`).
- Each key asks the source for its edit (`tl_source_call`); each storage edit and selection is
  told back (`tl_source_edit`, `tl_source_select`). Command edits are the source's too
  (`toggle_style`, `wrap`, `set_heading`); themes, the menu catalogue and maths SVG come from
  `tl_syntax_call`. The maths preview is 1.21 times the text.
- Live Preview is its session's: TeXpresso's pages arrive as `live_document` and `live_page`, and
  `PDFController.showLive` swaps them in. The protocol is in `docs/texpresso.md`.

## Writing code

Agents' code runs long and erodes with each change (`docs/agent-code.md`). So:
- Delete before adding. Reuse what exists (grep first). A new helper, option or type needs two
  callers.
- No checks for states that can't happen, no wrappers that only forward, no single-use variables.
- Comments say why, never what, nor what the code used to do.
- Before committing, read the whole diff and remove what the change doesn't need.
- Test each rule once, deterministically, at one level.

## Commits and agents

- A commit's subject is a sentence saying what is now true, with no closing full stop and no AI
  attribution trailer.
- Follow-on work goes on the open PR's branch; ask the owner before opening another PR.
- Pick a subagent's model by its task, all of the 5.5 series: Haiku at medium for mechanical work,
  Sonnet at medium for ordinary work, Opus at medium or high (xhigh rarely) for refactors across
  files and for Swift edited where it can't be compiled; Fable only for a special planning agent.
  Use a few agents, not a fan-out of many.

## Testing

- `cargo test --workspace`; CI also runs `cargo fmt --all --check` (macOS) and
  `cargo clippy --workspace --all-targets -- -D warnings`.
- The Mac app: `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal test` with
  `TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`, or the test host shares the installed app's defaults.
- Quicker: `zsh tools/qa/typecheck.sh` type-checks the app and its tests in about 20 s;
  `tools/qa/xctest.sh <repo> <derived data> [-only-testing:…]` runs the native tests one at a time
  per session. Worktree agents use these rather than parallel `xcodebuild`s.
- On screen: the QA driver (`tools/qa/README.md`) on its QA copy (`com.texlocal.mac.qa`), never the
  installed app or `~/TeXLocal`.
- The Windows app: `dotnet test apps/windows/TeXLocal.Tests -c Debug`; `TeXLocal.exe --smoke` opens
  Home and exits 0. Run dev builds with a scratch `TEXLOCAL_DATA`, never beside the installed copy.
- Live Preview end to end needs the patched engine:
  `cargo test -p texlocal-core --test texpresso_live -- --ignored` (`docs/texpresso.md`).
- Profiling without the screen: `xcrun xctrace record --template 'Time Profiler' --attach <pid>`,
  with typing posted through Accessibility (`AXSelectedText`), not a driver that walks the tree per key.
- Trackpad gestures, the dividers' haptic, interactive IME and materials stay manual checks.

## Build and install

- **Mac** (Xcode 27, Rust stable): `zsh tools/install-mac.sh` builds the checkout's Release
  (derived data in `/private/tmp/underleaf-release`), quits TeXLocal, ad-hoc signs and installs
  `/Applications/TeXLocal.app`, verifies it and reopens it.
- **Windows** (.NET 10 SDK, Rust stable): quit TeXLocal, then `apps/windows/install.ps1`
  publishes a self-contained Release to `%LOCALAPPDATA%\Programs\TeXLocal` and points the Start
  menu's shortcut at it.

## Open

- Windows has no Live Preview yet; `docs/windows.md` lists what it lacks against the Mac.
- The TeXpresso engine is built with `tools/texpresso/build.sh` (needs Homebrew's TeXpresso
  dependencies and `pkg-config`; `texpresso-xetex` links Homebrew's `icu4c`, `harfbuzz` and
  `graphite2`, which must stay installed).
- On macOS 27, MacTeX 2026's biber launcher calls `lipo -extract_family`, which `lipo` refuses:
  `tlmgr update biber` fixes it.
