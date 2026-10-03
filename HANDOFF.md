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
`SourceDocument`; it uses the stock find bar, so Find and Replace are the system's. The
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

## Known limits

- Physical trackpad pinch and interactive IME sessions are only tested through code paths.
- Minimum-layout tests log a hidden-outline 28.5 against 29 pt constraint diagnostic.
- A same-size external symbol edit that keeps its mtime is missed by the symbol cache.
- ZIP imports have per-entry limits but no total budget; a late failure can leave a
  partial import.
