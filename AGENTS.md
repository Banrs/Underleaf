# Underleaf

Rules for agents. The repository is Underleaf; the app is TeXLocal, as are its names on disk
(`~/TeXLocal`, `.texlocal.json`, `TEXLOCAL_DATA`), so existing projects keep working. The core's
contract is `docs/core-api.md`, what is open `docs/handoff.md`; `docs/windows.md`,
`docs/texpresso.md` and `docs/design-tokens.md` are the Windows app, Live Preview and the themes.

## Shape

- **The Rust core** (`crates/texlocal-core`) owns all but UI and OS integration: projects, builds,
  SyncTeX, logs, export and project sessions; logic the hosts share goes there. **`syntax`**,
  I/O-free, owns editor logic and maths (RaTeX); **`texlocal-ffi`** is the C ABI.
- **The apps** (`apps/macos`, `apps/ipados`, `apps/windows`) are UI only, with the same features,
  each in its system's design: the Mac the HIG, the iPad iPadOS's, Windows WinUI 3 and Fluent.
  **`apps/shared`** is the Swift both Apple apps compile; each has its platform's classes under one
  name (`SourceEditor`, `PDFController`, `MathGlyphs`, `LogTextView`).
- **Security**: `-shell-escape`, and with it a project's `latexmkrc`, only where a project turns it
  on; `.texlocal.json` can't be written through the generic file commands.

## The Mac app

Decided: change only when asked. A quirk's workaround names the test that fails without it, or why.

- **AppKit** for the window and splits; **SwiftUI** for panes, bars, sheets, popovers, Settings and
  Home. **Narrow windows** stop where Compile's symbol has room (`ColumnMetrics`), folding sidebar
  and inspector, unsaved as hidden; the title and the overflow menu are AppKit's.
- **Toolbar**: AppKit's spacing, separators tracking the source|PDF divider; narrowing sends the
  editing tools and Zoom to the overflow menu first. Compile is the one prominent item, a word, its
  symbol before Zoom or Compile would go, Stop with a spinner while building. Aa opens Notes' text
  styles (`FormatPopover`) beside Math and Insert, whose palettes are AppKit's. Zoom is a pill.
- **Source**: one TextKit 2 `SourceTextView` at Xcode's metrics and current line; the maths preview
  is 1.21 times the text; the completion list is Liquid Glass at a system menu's measures.
- **Issues** as Xcode's: a band over the paragraph and an `IssueBox` at the line's end with the
  core's message, its `compact` form or the symbol; a click opens the build panel on it. Live
  Preview's look the same (dim reads as disabled), give way to a build's and open its log.
- **Status bar**: one 36 pt bar across source and PDF, as Xcode's editor bar, over each pane's hard
  scroll edge. After a failed save it says Not Saved and saves on a click. Live pages from another
  engine than the project's show Live Preview On naming it, dimmed; its help says breaks may differ.
- **Build panel** below the columns, resized and dragged shut from the status bar's line; its foot
  bar as Xcode's console: Issues, Build Log, Live Preview Log, Warnings or Copy Log, a filter.
- **Splits**: AppKit's thin dividers, dragged freely, as Xcode's and Mail's; the source|PDF one
  stops at the even split with the alignment haptic, and parts from the toolbar's separator where
  it can't follow (moved to it, it fought each resize). A double-click does nothing.
- **File Outline** at the sidebar's foot, opening in one motion, dim and folded off LaTeX. **PDF**:
  a rebuild's pages replace those showing in place, live pages in one piece; fitted pages keep
  PDFKit's margins; paper is white, dark or automatic. **Dim, not hidden**, where hiding would jump.
- **Home**: template cards and every project, as Word's gallery and Overleaf's list. A folder opens
  where it is; its row shows its path, as Xcode's welcome window, dims when not found, and offers
  Remove from List, never Rename or Move to Trash. A bookmark follows its moves.
- **Builds** as Overleaf's: past errors, listing every issue; a project can Stop on First Error;
  a pause in typing saves and compiles. **Settings**: General, Editor, Compiling, PDF, Live Preview.
- **Changed on disk** with unsaved edits: an AppKit alert (Save Anyway, Revert, Cancel), no default
  button, Cancel writing nothing. Moved or deleted: a SwiftUI alert whose default saves it again.
- **Words**: the feature is Live Preview (TeXpresso is the program); the verb is Compile, a run is
  a build. British spelling (Colours) but LaTeX's terms (Math).
- **The core**: a session is numbered before it opens (`Core.observe`) and its events reach its
  `ProjectModel` on the main actor in order; open folders and folds are project settings.

## The iPad app

Native APIs, as Apple's iPad apps use them; custom only where iPadOS has nothing.

- **By width**, never device or orientation: the sidebar floats over the panes, which keep their
  width; below 640 pt source and PDF take turns, and a collapsed split opens on the source.
- **Toolbar** as Pages': title and menu leading, editing tools grouped in the middle, the PDF and
  Inspector toggles and Compile at the end; `toolbarRole(.editor)` outside the inspector, inside
  which a first launch's bar may lose it. The panes scroll under the bar's edge effect.
- **No bottom bar**, as a window's bottom edge can be off screen: the status is the title's
  subtitle and menu; the build panel has its controls along its top, a sheet where compact.
- **Touch**: 44 pt targets, every gesture also a button or menu item, the keyboard's room left to
  the source. Names are edited where they show (`RenameField`), not in the title, which capitalises.
- **Source**: a TextKit 2 `UITextView` on the Mac's logic; every edit goes through the view's undo,
  which skips the core's, keys as one Typing; spelling the view's, kept to prose; LaTeX keys on the
  shortcuts bar; the maths preview glass in the window, as a popover animates at each caret step.
- **The menu bar** is the Mac's (`AppCommands`); Settings opens the app's page in Settings, App
  Settings the in-app sheet. The library is the app's Documents (On My iPad › TeXLocal).

## Writing code

Agents' code erodes with each change (`docs/agent-code.md`), so delete before adding: reuse what
exists; a new helper, option or type needs two callers. No checks for states that can't happen,
wrappers that only forward, or names for a value used once. Comments say why, never what or what
was. Before committing, read the whole diff and remove what the change doesn't need. Test each
rule once, deterministically, at the lowest level that holds it.

## Commits and agents

- A commit's subject is a sentence saying what is now true, with no closing full stop and no AI
  trailer. Follow-on work goes on the open PR's branch; ask before opening another PR.
- `README.md` tells people on GitHub what TeXLocal does and how to install it, in plain paragraphs
  without [Wikipedia's signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing);
  a change people would notice updates it. The Mac app links to `#requirements` and texpresso.md.
- Subagents, all 5.5 and few: Haiku (medium) for mechanical work, Sonnet (medium) ordinary, Opus
  (medium or high) refactors and Swift edited where it can't compile; Fable for special planning.

## Testing and installing

- Rust: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test`.
- Mac: `xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal test
  TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev`, else the test host shares the app's defaults.
  Agents use `zsh tools/qa/typecheck.sh` (the iPad's too) and `tools/qa/xctest.sh`, which takes
  turns; on screen only the QA copy (`tools/qa/README.md`), never the installed app or `~/TeXLocal`.
- iPad: `xcodebuild -project apps/ipados/TeXLocal.xcodeproj -scheme TeXLocal -destination
  'generic/platform=iOS Simulator' build`; XcodeGen makes it from `project.yml`, both committed.
- Windows: `dotnet test apps/windows/TeXLocal.Tests -c Debug`; `TeXLocal.exe --smoke` exits 0 once
  a new project's session is open. Dev builds run with a scratch `TEXLOCAL_DATA`.
- Tests needing TeX and the patched engine (`docs/texpresso.md`) run in `tex-check.yml`: nightly,
  from Run workflow, or on a push to `claude/tex-check/<name>`.
- Install: `zsh tools/install-mac.sh`, or with TeXLocal quit `apps/windows/install.ps1`. The
  version is the same in `Cargo.toml`, `project.yml`, both `.xcodeproj`s and `TeXLocal.csproj`.
