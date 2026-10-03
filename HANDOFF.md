# Underleaf: current state

One Rust core, two clients. The Mac app (`apps/macos`, shown as TeXLocal) is the
focus; the browser version (`web/`, served by `crates/texlocal-server`) shares the core.

## Build, test, install (Mac)

Needs Xcode 27 (Swift 6, macOS 27 target), Rust stable, and `npm ci` once (the build
copies KaTeX from `node_modules`).

```sh
# Debug build and the full test suite
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-native-build \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test

# Release build, for installing
xcodebuild -project apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/underleaf-native-build \
  CODE_SIGNING_ALLOWED=NO build
```

To install: ad-hoc sign the Release product (`codesign --force --deep -s -`), verify it
with `codesign --verify --strict`, quit TeXLocal, and replace `/Applications/TeXLocal.app`.
Run one test with `-only-testing:TeXLocalTests/Suite/method()`; zero tests executed
proves nothing. The layout tests need an awake, unlocked display.
`project.yml` generates the committed `TeXLocal.xcodeproj` (xcodegen).

## Architecture

The Rust core (`crates/texlocal-core`) owns projects, path safety, latexmk and SyncTeX,
log parsing and ZIP export, behind a JSON command service. The Mac app reaches it through
the C ABI in `crates/texlocal-ffi`, wrapped by `Core.swift`; calls run on a GCD thread
because a compile blocks. `AppModel` holds app-wide state and preferences,
`ProjectModel` one open project (files, saves, builds, PDF, SyncTeX), and
`WorkspaceController` the window: an AppKit split view of sidebar, source, PDF and
inspector with an NSToolbar, hosting SwiftUI for the sidebar, bars and Home. Commands
(`Commands.swift`) are the one definition of menus, shortcuts and toolbar items. The
editor is an NSTextView (TextKit 2) mirrored by Rust's syntax crate through
`SourceDocument`, styled after Xcode's editor; it uses the stock find bar, so Find and
Replace are the system's. The
PDF is one persistent PDFKit view owned by `PDFController`.

## Details worth preserving

- SyncTeX: keep the occurrence and UTF-16 context through repeats, wrapping, ligatures
  and hyphenation; when the evidence is ambiguous, fall back to SyncTeX's own box.
- PDFKit: use `shownDestination`, not `currentDestination`; keep the margin handling,
  the unchanged-frame guards during zoom and the glyph-selection click offsets. Saved
  state uses `restorePage ?? page`, so a hidden zero-size view cannot overwrite the page.
- A no-op compile keeps the same PDFDocument.
- IME: autosave reads only committed text during composition, and composition ends
  before the per-file undo managers switch.
- One ordered lane serialises saves, settings, renames and deletes.
- Toolbar: Aa, Math and + are three plain items; zoom is the stock minus, percentage
  menu and plus, left to automatic overflow; the 0.5 pt trailing safe-area adjustment.
- Security: loopback only, startup token, Host/Origin checks, CSP, path boundaries,
  output limits, shell escape off unless a project turns it on.

## Design direction (as of 3 October 2026)

Starting points, not fixed constraints. Explore first: look at how Apple's own apps, the HIG,
the design resources, WWDC sessions and the SDK handle a problem, and at what TeX editors do,
before settling on an answer. Any Apple app or guideline may turn out to be the better
reference for a given part; say which you used and why.

- The aim is a native macOS 27 app that feels like Apple built it: system controls and
  behaviour, nothing that reads as legacy AppKit even if it is stock.
- References that have worked so far: Xcode for the text editor (font, line height, gutter,
  rounded current line, completion list) and for the bottom bar's and sidebar's metrics;
  Preview for the PDF side; Mail for split-view logic; Overleaf, Texifier and TeXstudio for
  what a TeX editor does and where it puts it, more than for how it looks. Xcode's chrome as a
  whole is busier than this app should be.
- Daniel liked the File Outline's and status bar's look and animation as they were at commit
  6342673. When rebuilding something from system parts, capture how it looks and moves first;
  he reads unplanned visible drift as a regression.
- The editor is on TextKit 2 and stays there.
- Working agreements: propose visible UI changes before making them; commit and push to this
  branch, no PR; the Rust core waits for its own session, except bugs that show in the Mac app.

## State at 87574f9

Done this session: Tauri and Windows removed; core, syntax, server and FFI crates simplified;
stock find bar with Replace; Home as a template chooser over Recent; Compile as word and
symbol with a spinner in Stop at the same width; status bar with Line/Col; outline header that
rides the fold; divider detents with a haptic; a glass completion list; the maths preview over
the caret; double-click SyncTeX both ways; Colour Theme in Settings (Overleaf, TeXstudio, System).

Not verified by hand:
- The PDF's scrollers staying hidden during a divider drag (77aa8ad relies on live resize).
- The detent haptic, the bracket flash, the completion list's click and dark mode for the bars.
- Xcode's focused-window editor state (caret width, highlight during a selection) and its
  completion popup's metrics were not measured; those parts are from the theme file or memory.
- `/Applications/TeXLocal.app` is still an older Release build.
- `apps/macos/TeXLocal/LaTeX.swift` has an uncommitted whitespace edit of Daniel's.
- Layout and outline tests failed intermittently in some runs, a different one each time.

Open questions for Daniel:
- Which highlight colour looked wrong (current line and selection match Xcode's Default theme).
- Whether unmatched braces get a mark again beyond the theme's invalid colour.
- Compact rows for the File Outline (13 pt text kept, about Xcode's 17 pt row pitch).
- A Texifier theme needs its colour values; none are published.

Proposed, not built:
- Editor: wrapped-line continuation indent, scroll past the end, a tint on lines with an issue.
- Status bar: the engine's name; hairlines between every trailing item.
- Toolbar: Compile at the far trailing edge (HIG's place for the prominent action).
- Tokenizer (Rust): keyword commands, control symbols, commands in maths, environment names
  and `&` as their own kinds, so the themes can colour them as Overleaf and TeXstudio do;
  bold and italic styles.

## Issues (Daniel)

<!-- Add issues here for the next session: what you did, what you saw, what you expected. -->

-

## Known limits

- Physical trackpad pinch and interactive IME sessions are only tested through code paths.
- ZIP imports have per-entry limits but no total budget; a late failure can leave a
  partial import.
