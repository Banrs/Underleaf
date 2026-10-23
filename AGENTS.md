# Underleaf

Rules for agents. `docs/core-api.md` is the hosts' contract with the core, `docs/handoff.md` what
is open, `docs/windows.md` the Windows app and its gaps, `docs/texpresso.md` Live Preview,
`docs/design-tokens.md` the themes and surfaces.

## Shape

- **Names**: the repository is Underleaf; the app is TeXLocal, and so are its names on disk
  (`~/TeXLocal`, `.texlocal.json`, `TEXLOCAL_DATA`), so existing projects keep working.
- **Rust core** (`crates/texlocal-core`, macOS, iPadOS and Windows) owns everything but UI and OS
  integration: projects, path safety, latexmk, SyncTeX, logs, ZIP export, the JSON service and
  project sessions (`session/`: documents, autosave, watching, builds, issues, outline, TeXpresso).
  Logic both hosts need goes here, never in a host.
- **`syntax`**, I/O-free, owns editor logic: typing, snippets, completion, highlighting, themes,
  the symbol and template catalogue, heading styles, spelling's skipped ranges, and maths and
  glyphs through RaTeX.
- **`crates/texlocal-ffi`** is the C ABI: a static library, built as a DLL for Windows.
- **The apps** (`apps/macos`, `apps/ipados`, `apps/windows`) are UI only. They have the same
  features, each in its own system's design: the Mac the HIG, the iPad iPadOS's, Windows WinUI 3
  and Fluent.
- **`apps/shared`** is the Swift both Apple apps compile: the models, the core's bridge, the menus
  and the views that are alike on both. Each app has its platform's classes under the same names
  (`SourceEditor`, `PDFController`, `MathGlyphs`, `LogTextView`); `#if os(macOS)` marks the rest.
- **Security**: `-shell-escape` is off unless a project turns it on, and a project's own
  `latexmkrc` is read only then; `.texlocal.json` can't be written through the generic file
  commands.

## The Mac app

Decided: change only when asked. Each macOS 27.2 workaround says why in its comment.

- **AppKit** for the window and splits; **SwiftUI** for panes, bars, sheets, popovers, Settings
  and Home.
- **Narrow windows** stop at 542 pt (`ColumnMetrics`); sidebar and inspector fold, and aren't
  saved as hidden; the title and the overflow menu are AppKit's.
- **Toolbar**: its separators track the source|PDF divider. Compile is the one prominent item, a
  word (its symbol only without room), Stop with a spinner while building. Aa opens Notes'
  popover of text styles (`FormatPopover`), with Math and Insert menus beside it. The PDF's zoom
  is a pill (`zoomItem`).
- **Source**: one TextKit 2 `SourceTextView` at Xcode's metrics. The completion list
  (`CompletionList`) is Liquid Glass at a system menu's measures, a view in the window.
- **Issues** as Xcode's: a band over the paragraph and an `IssueBox` at the line's end with the
  core's message (or its `compact` form, or the symbol alone); a click opens the build panel on it.
  Live Preview's look the same, as Xcode's live issues do (dimming would read as disabled), give
  way to a build's on their line, and open the Live Preview Log.
- **Status bar**: one 36 pt bar (`BarMetrics`) across the source and PDF, as Xcode's editor bar,
  over each pane's hard scroll edge, with text and pages ghosting through. After a failed save it
  says Not Saved and saves on a click.
  While live pages show and the project's engine isn't Live Preview's, Live Preview On names
  XeLaTeX, dimmed, as Build Succeeded its time; its help says line breaks may differ.
- **Build panel** below the columns, resized and dragged shut from the status bar's line; its foot
  bar as Xcode's console: Issues, Build Log, Live Preview Log, then Warnings or Copy Log, then a
  filter.
- **Splits**: AppKit's thin dividers, dragged freely as Xcode's and Mail's are, except that the
  source|PDF divider stops, with the alignment haptic, at the even split. Where the toolbar's
  separator can't follow it, they part, as AppKit leaves them: moved to the separator, the divider
  fought each resize and flickered. A double-click does nothing.
- **File Outline** at the sidebar's foot, dim and folded on a file that isn't LaTeX.
- **PDF**: a rebuild's pages replace those showing in place; fitted pages keep PDFKit's margins,
  as Preview's; paper is white, dark or automatic.
- **Dim, not hidden**, where hiding would make things jump.
- **Settings**: General, Editor, Compiling, PDF, Live Preview.
- **Home**: template cards and every project in the library, as Word's gallery and Overleaf's list.
  A folder opens where it is; its row shows its path, as Xcode's welcome window, dims when it's not
  found, and offers Remove from List, never Rename or Move to Trash. A bookmark follows its moves.
- **Builds** as Overleaf's: they run past errors listing every issue, a project can Stop on First
  Error, and a pause in typing saves and compiles.
- **Changed on disk** with unsaved edits: an AppKit alert (Save Anyway, Revert, Cancel) with no
  default button, Cancel writing nothing. Moved or deleted: a SwiftUI alert whose default saves it
  again.
- **Words**: the feature is Live Preview (TeXpresso only for the program); the verb is Compile, a
  run is a build. British spelling (Colours) but LaTeX's terms (Math).
- **The core**: the app numbers a session before opening it (`Core.observe`); commands go through
  `tl_call_async` and are awaited; events reach the session's `ProjectModel` on the main actor in
  order. The sidebar's open folders and folds are project settings (`set_ui_state`). Keys and
  command edits (`toggle_style`, `wrap`, `set_heading`) are the source's (`tl_source_call`), told
  back with `tl_source_edit` and `tl_source_select`. The maths preview is 1.21 times the text.
  Live pages arrive as `live_document` and `live_page` for `PDFController.showLive`.

## The iPad app

- **By width**, never device or orientation: the sidebar floats over the panes, then source and
  PDF take turns below 640 pt, and a collapsed split opens on the source.
- **No bottom bar**, as a window's bottom edge can be off screen: the status is the title's
  subtitle and its menu, the build panel has its controls along its top and is a sheet where the
  window is compact.
- **Touch**: 44 pt targets, every gesture also a button or menu item, the software keyboard's
  room left to the source.
- **Source**: a TextKit 2 `UITextView` on the Mac editor's shared logic. Every edit goes into the
  storage with the view's own undo, keys coalesced into one Typing, as UIKit's undo skips the
  core's edits; spelling is the view's own, kept to the prose; the shortcuts bar has the LaTeX keys;
  the maths preview is glass in the window, as a popover would animate at each step of the caret.
- **The menu bar** is the Mac's (`AppCommands`); its Settings item opens the app's page in the
  Settings app, App Settings the in-app sheet. The library is the app's Documents (On My iPad ›
  TeXLocal).

## Writing code

Agents' code runs long and erodes with each change (`docs/agent-code.md`), so:
- Delete before adding; grep for what exists and reuse it. A new helper, option or type needs two
  callers.
- No checks for states that can't happen, no wrappers that only forward, no variable that only
  renames a value used once.
- Comments say why, never what, nor what the code used to do.
- Before committing, read the whole diff and remove what the change doesn't need.
- Test each rule once, deterministically, at one level.

## Commits and agents

- A commit's subject is a sentence saying what is now true, with no closing full stop and no AI
  trailer.
- Follow-on work goes on the open PR's branch; ask before opening another PR.
- `README.md` is for people reading about TeXLocal on GitHub: what it does and how to install it,
  in plain paragraphs without
  [Wikipedia's signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing)
  (lists led by bold labels, threes for rhythm, false ranges, puffery, em dashes). A change people
  would notice updates it; rules and internals go here or in `docs/`. The Mac app links to its
  `#requirements` and to `docs/texpresso.md`, so both stay.
- Subagents, all 5.5: Haiku at medium for mechanical work, Sonnet at medium for ordinary work,
  Opus at medium or high (xhigh rarely) for refactors across files and Swift edited where it can't
  be compiled; Fable only for a special planning agent. A few agents, never a fan-out.

## Testing

- Rust: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`,
  `cargo test --workspace`.
- Mac: `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal test
  TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev` (without it the test host shares the installed
  app's defaults). Worktree agents use `zsh tools/qa/typecheck.sh` (20 s) and `tools/qa/xctest.sh`,
  which takes turns, rather than parallel `xcodebuild`s.
- On screen: only the QA copy through `tools/qa/README.md`, never the installed app or `~/TeXLocal`.
  Trackpad gestures, the divider's haptic, interactive IME and materials stay manual checks.
- iPad: `xcodebuild -project apps/ipados/TeXLocal.xcodeproj -scheme TeXLocal -destination
  'generic/platform=iOS Simulator' build`. XcodeGen generates the project from `project.yml`, and
  both are committed; the Mac's project is edited by hand. `typecheck.sh` checks the iPad too.
- Windows: `dotnet test apps/windows/TeXLocal.Tests -c Debug`; `TeXLocal.exe --smoke` exits 0 once
  a new blank project's session is open. Dev builds run with a scratch `TEXLOCAL_DATA`.
- Live Preview end to end needs the patched engine: `docs/texpresso.md`, Verify.
- Tests that need TeX Live and TeXpresso run in `.github/workflows/tex-check.yml`: nightly, from
  Actions' Run workflow, or on a push to a `claude/tex-check/<name>` branch.

## Build and install

- Mac (Xcode 27, Rust stable): `zsh tools/install-mac.sh` builds this checkout's Release, quits
  TeXLocal, installs it to `/Applications`, verifies it and reopens it.
- Windows (.NET 10 SDK, Rust stable): quit TeXLocal, then `apps/windows/install.ps1`.
- The version is the same in the workspace `Cargo.toml`, `apps/macos/project.yml` and
  `apps/ipados/project.yml`, both `.xcodeproj`s (`MARKETING_VERSION`) and
  `apps/windows/TeXLocal/TeXLocal.csproj`.
